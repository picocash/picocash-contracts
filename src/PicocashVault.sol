// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IPicocashVault} from "./interfaces/IPicocashVault.sol";
import {PicocashEmergencyVerifier} from "./emergency/PicocashEmergencyVerifier.sol";

interface ITIP20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title PicocashVault — USDC.e backing vault for a picocash mint
/// @notice See IPicocashVault for the design constraints. The primary deposit
///         flow is a TIP-20 `transferWithMemo(vault, amount, quoteId)` straight
///         to this contract's address (the mint watches the token's event);
///         `ecashMint()` is the allowance-based fallback for memo-less callers.
contract PicocashVault is IPicocashVault {
    ITIP20 private immutable _token;
    address private _operator;
    address public pendingOperator;
    uint256 public operatorRotationEta;
    uint256 public immutable rotationTimelock;
    bool private _depositsPaused;
    /// @notice One payout per melt id, forever.
    mapping(bytes32 meltId => bool paid) public meltPaid;

    // --- mint discovery metadata (operator-maintained, read via info()) ---
    string private _name;
    string private _mintUrl;
    bytes8 private _activeKeysetId;
    uint256 public lastOutstanding;
    uint256 public lastPublishedAt;
    uint256 public lastPublishedBlock;
    uint256 public balanceAtLastPublish;

    // --- publication policy, fixed at deployment (at least one rule set) ---
    /// @notice Publish when balance drifts more than this many bps since the last publication (0 = unset).
    uint16 public immutable publishThresholdBps;
    /// @notice Max blocks between publications (0 = unset).
    uint64 public immutable publishIntervalBlocks;

    // --- melt-fee ceiling: the on-chain cap on the exit tax ---
    /// @notice The mint MUST NOT quote a melt fee above this (base units).
    uint256 public maxMeltFee;
    uint256 public pendingMaxMeltFee;
    uint256 public maxMeltFeeIncreaseEta;

    // --- emergency redemption (PIP-04 §Emergency redemption): unilateral holder exit ---
    /// @notice Shared stateless verifier (deployed by the factory). Proves a token with the mint's PUBLIC key.
    PicocashEmergencyVerifier public immutable emergencyVerifier;
    /// @notice Blocks past an overdue attestation before holders may redeem at the vault directly (0 = disabled).
    uint64 public immutable emergencyGraceBlocks;
    uint256 public immutable deployBlock;
    /// @notice Keyset public keys per denomination, registered by the operator (append-only).
    mapping(bytes8 keysetId => mapping(uint256 amount => bytes pubkey)) private _keysetKeys;
    /// @notice Ledger keys (Y.x) already redeemed in emergency mode.
    mapping(bytes32 y => bool) public emergencySpent;
    /// @notice Running total paid out through emergencyRedeem.
    uint256 public emergencyRedeemed;

    error NotOperator();
    error NotPendingOperator();
    error DepositsArePaused();
    error NoPublicationPolicy();
    error InvalidThreshold();
    error PublicationOverdue();
    error NotADecrease();
    error NotAnIncrease();
    error NoPendingIncrease();
    error MeltAlreadyPaid(bytes32 meltId);
    error TimelockNotElapsed(uint256 eta);
    error ZeroAddress();
    error TokenTransferFailed();
    error TokenHasNoCode();
    error CannotSweepBackingToken();
    error InvalidEmergencyConfig();
    error KeyAlreadyRegistered(bytes8 keysetId, uint256 amount);
    error KeyLengthInvalid();
    error NotInEmergency();
    error KeysetKeyUnknown(bytes8 keysetId, uint256 amount);
    error EmergencyAlreadyRedeemed(bytes32 y);
    error EmergencyCapExceeded(uint256 cap);

    event OperatorProposed(address indexed newOperator, uint256 eta);
    event OperatorRotated(address indexed oldOperator, address indexed newOperator);
    event DepositsPausedSet(bool paused);
    event Swept(address indexed strandedToken, address indexed to, uint256 amount);
    event KeysetRegistered(bytes8 indexed keysetId, uint256 count);
    event EmergencyRedeemed(bytes32 indexed y, bytes8 indexed keysetId, uint256 amount, address indexed to);

    modifier onlyOperator() {
        if (msg.sender != _operator) revert NotOperator();
        _;
    }

    constructor(
        address token_,
        address operator_,
        uint256 rotationTimelock_,
        uint16 publishThresholdBps_,
        uint64 publishIntervalBlocks_,
        uint256 maxMeltFee_,
        string memory name_,
        string memory mintUrl_,
        PicocashEmergencyVerifier emergencyVerifier_,
        uint64 emergencyGraceBlocks_
    ) {
        if (token_ == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        // The vault IS its token binding — refuse to deploy bound to nothing.
        if (token_.code.length == 0) revert TokenHasNoCode();
        // Solvency publication is a commitment, not a courtesy: at least one rule.
        if (publishThresholdBps_ == 0 && publishIntervalBlocks_ == 0) revert NoPublicationPolicy();
        if (publishThresholdBps_ > 10_000) revert InvalidThreshold();
        // Emergency exit is measured from an overdue interval rule: grace without interval can never trigger.
        if (emergencyGraceBlocks_ != 0 && (publishIntervalBlocks_ == 0 || address(emergencyVerifier_) == address(0))) {
            revert InvalidEmergencyConfig();
        }
        emergencyVerifier = emergencyVerifier_;
        emergencyGraceBlocks = emergencyGraceBlocks_;
        deployBlock = block.number;
        _token = ITIP20(token_);
        _operator = operator_;
        rotationTimelock = rotationTimelock_;
        publishThresholdBps = publishThresholdBps_;
        publishIntervalBlocks = publishIntervalBlocks_;
        maxMeltFee = maxMeltFee_;
        _name = name_;
        _mintUrl = mintUrl_;
    }

    /// @inheritdoc IPicocashVault
    /// @dev Also gated on the publication policy's interval rule: a mint whose
    ///      solvency attestation is overdue cannot take new allowance deposits.
    ///      (Memo-path deposits are plain token transfers and cannot be gated
    ///      here; the mint server enforces the same rule when issuing quotes.)
    function ecashMint(uint256 amount, bytes32 mintQuoteId) external {
        if (_depositsPaused) revert DepositsArePaused();
        if (isPublicationOverdue()) revert PublicationOverdue();
        if (!_token.transferFrom(msg.sender, address(this), amount)) revert TokenTransferFailed();
        emit EcashMintDeposit(mintQuoteId, msg.sender, amount);
    }

    /// @inheritdoc IPicocashVault
    /// @dev Deliberately no pause check anywhere on this path: withdrawals are
    ///      never pausable. Holders must always be able to exit.
    function ecashMelt(address to, uint256 amount, bytes32 meltId) external onlyOperator {
        if (to == address(0)) revert ZeroAddress();
        if (meltPaid[meltId]) revert MeltAlreadyPaid(meltId);
        meltPaid[meltId] = true;
        if (!_token.transfer(to, amount)) revert TokenTransferFailed();
        emit EcashMeltPayout(meltId, to, amount);
    }

    /// @inheritdoc IPicocashVault
    function publishOutstandingSupply(bytes8 keysetId, uint256 outstanding) external onlyOperator {
        uint256 balance = _token.balanceOf(address(this));
        lastOutstanding = outstanding;
        lastPublishedAt = block.timestamp;
        lastPublishedBlock = block.number;
        balanceAtLastPublish = balance;
        emit OutstandingSupplyPublished(keysetId, outstanding, balance);
    }

    /// @inheritdoc IPicocashVault
    function isPublicationOverdue() public view returns (bool) {
        if (publishIntervalBlocks == 0) return false;
        if (lastPublishedBlock == 0) return true; // never attested
        return block.number > lastPublishedBlock + publishIntervalBlocks;
    }

    /// @inheritdoc IPicocashVault
    function isPublicationDue() public view returns (bool) {
        if (isPublicationOverdue()) return true;
        if (publishThresholdBps == 0) return false;
        uint256 balance = _token.balanceOf(address(this));
        uint256 base = balanceAtLastPublish;
        if (base == 0) return balance > 0;
        uint256 drift = balance > base ? balance - base : base - balance;
        return drift * 10_000 > base * publishThresholdBps;
    }

    /// @inheritdoc IPicocashVault
    function decreaseMaxMeltFee(uint256 newMaxMeltFee) external onlyOperator {
        if (newMaxMeltFee >= maxMeltFee) revert NotADecrease();
        emit MaxMeltFeeChanged(maxMeltFee, newMaxMeltFee);
        maxMeltFee = newMaxMeltFee;
    }

    /// @inheritdoc IPicocashVault
    function proposeMaxMeltFeeIncrease(uint256 newMaxMeltFee) external onlyOperator {
        if (newMaxMeltFee <= maxMeltFee) revert NotAnIncrease();
        pendingMaxMeltFee = newMaxMeltFee;
        maxMeltFeeIncreaseEta = block.timestamp + rotationTimelock;
        emit MaxMeltFeeIncreaseProposed(newMaxMeltFee, maxMeltFeeIncreaseEta);
    }

    /// @inheritdoc IPicocashVault
    function applyMaxMeltFeeIncrease() external onlyOperator {
        if (pendingMaxMeltFee == 0) revert NoPendingIncrease();
        if (block.timestamp < maxMeltFeeIncreaseEta) revert TimelockNotElapsed(maxMeltFeeIncreaseEta);
        emit MaxMeltFeeChanged(maxMeltFee, pendingMaxMeltFee);
        maxMeltFee = pendingMaxMeltFee;
        pendingMaxMeltFee = 0;
    }

    /// @inheritdoc IPicocashVault
    function setMintInfo(string calldata name_, string calldata mintUrl_) external onlyOperator {
        _name = name_;
        _mintUrl = mintUrl_;
        emit MintInfoUpdated(name_, mintUrl_);
    }

    /// @inheritdoc IPicocashVault
    function setActiveKeyset(bytes8 keysetId) external onlyOperator {
        _activeKeysetId = keysetId;
        emit ActiveKeysetSet(keysetId);
    }

    /// @inheritdoc IPicocashVault
    function info() external view returns (MintInfo memory) {
        return MintInfo({
            name: _name,
            mintUrl: _mintUrl,
            token: address(_token),
            operator: _operator,
            activeKeysetId: _activeKeysetId,
            depositsPaused: _depositsPaused,
            balance: _token.balanceOf(address(this)),
            lastOutstanding: lastOutstanding,
            lastPublishedAt: lastPublishedAt,
            lastPublishedBlock: lastPublishedBlock,
            publishThresholdBps: publishThresholdBps,
            publishIntervalBlocks: publishIntervalBlocks,
            publicationDue: isPublicationDue(),
            maxMeltFee: maxMeltFee
        });
    }

    // ------------------------------------------------------------------
    // Emergency redemption — PIP-04 §Emergency redemption
    // ------------------------------------------------------------------

    /// @notice Register a keyset's public keys per denomination (the same keys GET /v1/keys serves). Append-only:
    ///         a (keyset, amount) pair can be set once. Without this, a keyset cannot be emergency-redeemed.
    function registerKeyset(bytes8 keysetId, uint256[] calldata amounts, bytes[] calldata pubkeys)
        external
        onlyOperator
    {
        if (amounts.length != pubkeys.length) revert KeyLengthInvalid();
        for (uint256 i = 0; i < amounts.length; i++) {
            if (pubkeys[i].length != 33) revert KeyLengthInvalid();
            bytes storage existing = _keysetKeys[keysetId][amounts[i]];
            if (existing.length != 0) {
                if (keccak256(existing) != keccak256(pubkeys[i])) revert KeyAlreadyRegistered(keysetId, amounts[i]);
                continue;
            }
            _keysetKeys[keysetId][amounts[i]] = pubkeys[i];
        }
        emit KeysetRegistered(keysetId, amounts.length);
    }

    function keysetKey(bytes8 keysetId, uint256 amount) external view returns (bytes memory) {
        return _keysetKeys[keysetId][amount];
    }

    /// @notice True once the attestation has been overdue for longer than the grace period. Nobody flips this:
    ///         it is a function of the last publication and the block number; publishing again clears it.
    function emergencyMode() public view returns (bool) {
        if (emergencyGraceBlocks == 0 || publishIntervalBlocks == 0) return false;
        uint256 since = (lastPublishedBlock == 0 ? deployBlock : lastPublishedBlock) + publishIntervalBlocks;
        return block.number > since + emergencyGraceBlocks;
    }

    /// @notice Ceiling on total emergency payouts: the last attested outstanding supply, or — for a vault that was
    ///         never attested — the balance (there is no better number, and refusing would strand every holder).
    function emergencyCap() public view returns (uint256) {
        return lastPublishedBlock == 0 ? _token.balanceOf(address(this)) : lastOutstanding;
    }

    /// @notice Holder exit with no operator involved. Each proof is verified with the registered PUBLIC key
    ///         (DLEQ), its ledger key is recorded here so it can be redeemed once, its P2PK lock (if any) must be
    ///         satisfied, and the total stays under emergencyCap(). No fee: the redeemer pays their own gas.
    function emergencyRedeem(PicocashEmergencyVerifier.Proof[] calldata proofs, address to) external {
        if (!emergencyMode()) revert NotInEmergency();
        if (to == address(0)) revert ZeroAddress();
        uint256 total;
        for (uint256 i = 0; i < proofs.length; i++) {
            PicocashEmergencyVerifier.Proof calldata p = proofs[i];
            bytes memory key = _keysetKeys[p.keysetId][p.amount];
            if (key.length == 0) revert KeysetKeyUnknown(p.keysetId, p.amount);
            bytes32 y = emergencyVerifier.verifyRedemption(p, key, block.timestamp);
            if (emergencySpent[y]) revert EmergencyAlreadyRedeemed(y);
            emergencySpent[y] = true;
            total += p.amount;
            emit EmergencyRedeemed(y, p.keysetId, p.amount, to);
        }
        uint256 cap = emergencyCap();
        if (emergencyRedeemed + total > cap) revert EmergencyCapExceeded(cap);
        emergencyRedeemed += total;
        if (!_token.transfer(to, total)) revert TokenTransferFailed();
    }

    /// @notice Everything a wallet needs to judge the emergency path before depositing.
    function emergencyInfo()
        external
        view
        returns (bool mode, uint64 graceBlocks, uint256 redeemed, uint256 cap, address verifier)
    {
        return (emergencyMode(), emergencyGraceBlocks, emergencyRedeemed, emergencyCap(), address(emergencyVerifier));
    }

    /// @inheritdoc IPicocashVault
    function setDepositsPaused(bool paused) external onlyOperator {
        _depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    /// @inheritdoc IPicocashVault
    function proposeOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert ZeroAddress();
        pendingOperator = newOperator;
        operatorRotationEta = block.timestamp + rotationTimelock;
        emit OperatorProposed(newOperator, operatorRotationEta);
    }

    /// @inheritdoc IPicocashVault
    function acceptOperator() external {
        if (msg.sender != pendingOperator) revert NotPendingOperator();
        if (block.timestamp < operatorRotationEta) revert TimelockNotElapsed(operatorRotationEta);
        emit OperatorRotated(_operator, pendingOperator);
        _operator = pendingOperator;
        pendingOperator = address(0);
    }

    /// @notice Return tokens mistakenly sent to the vault. The backing token
    ///         is structurally unsweepable — custody can never leave via this
    ///         path, only strangers' mistakes can be undone.
    function sweep(address strandedToken, address to) external onlyOperator {
        if (to == address(0)) revert ZeroAddress();
        if (strandedToken == address(_token)) revert CannotSweepBackingToken();
        uint256 amount = ITIP20(strandedToken).balanceOf(address(this));
        if (!ITIP20(strandedToken).transfer(to, amount)) revert TokenTransferFailed();
        emit Swept(strandedToken, to, amount);
    }

    function token() external view returns (address) {
        return address(_token);
    }

    function operator() external view returns (address) {
        return _operator;
    }

    function depositsPaused() external view returns (bool) {
        return _depositsPaused;
    }
}
