// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IPicocashVault} from "./interfaces/IPicocashVault.sol";

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

    error NotOperator();
    error NotPendingOperator();
    error DepositsArePaused();
    error MeltAlreadyPaid(bytes32 meltId);
    error TimelockNotElapsed(uint256 eta);
    error ZeroAddress();
    error TokenTransferFailed();
    error TokenHasNoCode();
    error CannotSweepBackingToken();

    event OperatorProposed(address indexed newOperator, uint256 eta);
    event OperatorRotated(address indexed oldOperator, address indexed newOperator);
    event DepositsPausedSet(bool paused);
    event Swept(address indexed strandedToken, address indexed to, uint256 amount);

    modifier onlyOperator() {
        if (msg.sender != _operator) revert NotOperator();
        _;
    }

    constructor(
        address token_,
        address operator_,
        uint256 rotationTimelock_,
        string memory name_,
        string memory mintUrl_
    ) {
        if (token_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        // The vault IS its token binding — refuse to deploy bound to nothing.
        if (token_.code.length == 0) revert TokenHasNoCode();
        _token = ITIP20(token_);
        _operator = operator_;
        rotationTimelock = rotationTimelock_;
        _name = name_;
        _mintUrl = mintUrl_;
    }

    /// @inheritdoc IPicocashVault
    function ecashMint(uint256 amount, bytes32 mintQuoteId) external {
        if (_depositsPaused) revert DepositsArePaused();
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
        lastOutstanding = outstanding;
        lastPublishedAt = block.timestamp;
        emit OutstandingSupplyPublished(keysetId, outstanding, _token.balanceOf(address(this)));
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
            lastPublishedAt: lastPublishedAt
        });
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
