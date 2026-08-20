// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title IPicocashVault — USDC.e backing vault for a picocash mint (DRAFT)
/// @notice Holds the TIP-20 stablecoin backing outstanding eCash tokens 1:1.
///         Spec: picocash/picocash `spec/05-vault.md`. Interface status: draft —
///         shaped by the already-running mint (build step 4/5), not yet frozen.
///
/// Design constraints (settled, non-negotiable):
///  - Solvency invariant: vault balance >= outstanding token supply per keyset;
///    outstanding supply is published on-chain per epoch so anyone can verify
///    (operator-attested liabilities, checkable against the on-chain balance).
///  - Payouts are NEVER contract-pausable — holders must always be able to exit
///    (liveness still depends on the operator signing melts).
///    Deposits MAY be paused.
///  - Operator key rotation is timelocked.
///
/// Deposit binding: the mint credits quotes from `TransferWithMemo` events where
/// memo = the 32-byte mint quote id. The primary deposit flow is therefore a
/// plain `transferWithMemo(vault, amount, quoteId)` on the TIP-20 token itself —
/// no vault call needed, and the mint's oracle already watches exactly that
/// event shape today (against the operator EOA it replaces). `ecashMint()` below
/// is the secondary allowance-based flow for callers that cannot emit memos.
interface IPicocashVault {
    /// @notice On-chain mint discovery record — the stable subset of the mint
    ///         server's `GET /v1/info`, plus live custody/solvency figures.
    struct MintInfo {
        string name;
        /// @dev Base URL of the mint's HTTP API (`/v1/…`).
        string mintUrl;
        address token;
        address operator;
        /// @dev The mint's currently active 8-byte keyset id.
        bytes8 activeKeysetId;
        bool depositsPaused;
        /// @dev Current backing balance (live `token.balanceOf(vault)`).
        uint256 balance;
        /// @dev Outstanding supply as of the last publication (0 if never published).
        uint256 lastOutstanding;
        /// @dev Timestamp of the last solvency publication (0 if never).
        uint256 lastPublishedAt;
        /// @dev Block of the last solvency publication (0 if never).
        uint256 lastPublishedBlock;
        /// @dev Publication policy: publish when balance drifts more than this many bps (0 = rule unset).
        uint16 publishThresholdBps;
        /// @dev Publication policy: max blocks between publications (0 = rule unset).
        uint64 publishIntervalBlocks;
        /// @dev True when either policy rule says a publication should happen now.
        bool publicationDue;
        /// @dev On-chain ceiling on the mint's melt fee (base units). The mint
        ///      MUST NOT quote above it; wallets SHOULD check before depositing.
        uint256 maxMeltFee;
    }

    /// @notice Emitted for allowance-based deposits (the memo-transfer flow
    ///         emits the token's own TransferWithMemo event instead).
    event EcashMintDeposit(bytes32 indexed mintQuoteId, address indexed from, uint256 amount);

    /// @notice Emitted when the operator updates the discovery metadata.
    event MintInfoUpdated(string name, string mintUrl);

    /// @notice Emitted when the operator advertises a new active keyset.
    event ActiveKeysetSet(bytes8 indexed keysetId);

    /// @notice Emitted when a melt-fee-ceiling increase is proposed (timelocked).
    event MaxMeltFeeIncreaseProposed(uint256 newMaxMeltFee, uint256 eta);

    /// @notice Emitted when the ceiling changes (instant decrease or applied increase).
    event MaxMeltFeeChanged(uint256 oldMaxMeltFee, uint256 newMaxMeltFee);

    /// @notice Emitted on every melt payout.
    event EcashMeltPayout(bytes32 indexed meltId, address indexed to, uint256 amount);

    /// @notice Emitted each epoch with the mint-attested outstanding supply.
    event OutstandingSupplyPublished(bytes8 indexed keysetId, uint256 outstanding, uint256 vaultBalance);

    /// @notice Pull `amount` of the backing token (requires prior approve) and
    ///         bind it to a mint quote. Reverts while deposits are paused.
    function ecashMint(uint256 amount, bytes32 mintQuoteId) external;

    /// @notice Operator-authorized payout for a melt. MUST NOT be pausable.
    /// @param meltId The mint's melt quote id; one payout per meltId.
    function ecashMelt(address to, uint256 amount, bytes32 meltId) external;

    /// @notice Publish outstanding token supply for a keyset (operator attestation).
    ///         `keysetId` is the mint's 8-byte keyset id.
    function publishOutstandingSupply(bytes8 keysetId, uint256 outstanding) external;

    /// @notice Pause/unpause deposits only. There is deliberately no
    ///         corresponding control for withdrawals.
    function setDepositsPaused(bool paused) external;

    /// @notice Return a token mistakenly sent to the vault. MUST revert for
    ///         the backing token itself — custody never leaves via sweep.
    function sweep(address strandedToken, address to) external;

    /// @notice Begin timelocked rotation to a new operator key.
    function proposeOperator(address newOperator) external;

    /// @notice Complete rotation after the timelock has elapsed.
    function acceptOperator() external;

    /// @notice Update the mint's discovery metadata (name, API base URL).
    function setMintInfo(string calldata name_, string calldata mintUrl_) external;

    /// @notice Advertise the mint's active keyset (call on rotation).
    function setActiveKeyset(bytes8 keysetId) external;

    /// @notice Lower the melt-fee ceiling — user-favorable, takes effect instantly.
    function decreaseMaxMeltFee(uint256 newMaxMeltFee) external;

    /// @notice Propose raising the melt-fee ceiling; applies only after the
    ///         rotation timelock elapses. Raising the exit tax requires public notice.
    function proposeMaxMeltFeeIncrease(uint256 newMaxMeltFee) external;

    /// @notice Apply a proposed increase after its timelock.
    function applyMaxMeltFeeIncrease() external;

    function maxMeltFee() external view returns (uint256);

    /// @notice One-call discovery + solvency read: everything a client needs
    ///         to find the mint and judge its backing.
    function info() external view returns (MintInfo memory);

    /// @notice HARD policy breach: the interval rule is set and more than
    ///         `publishIntervalBlocks` blocks have passed since the last
    ///         publication (or none was ever made). While overdue, allowance
    ///         deposits (`ecashMint`) revert — a mint that stops attesting
    ///         stops taking new money. Withdrawals are never affected.
    function isPublicationOverdue() external view returns (bool);

    /// @notice SOFT policy trigger: overdue per the interval rule, OR the
    ///         threshold rule is set and the backing balance has drifted more
    ///         than `publishThresholdBps` since the last publication. The
    ///         operator's publish job polls this.
    function isPublicationDue() external view returns (bool);

    function token() external view returns (address);
    function operator() external view returns (address);
    function depositsPaused() external view returns (bool);
}
