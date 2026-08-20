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
///    (proof of liabilities beats "trust me").
///  - Withdrawals are NEVER pausable — holders must always be able to exit.
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
    /// @notice Emitted for allowance-based deposits (the memo-transfer flow
    ///         emits the token's own TransferWithMemo event instead).
    event EcashMintDeposit(bytes32 indexed mintQuoteId, address indexed from, uint256 amount);

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

    /// @notice Publish outstanding token supply for a keyset (proof of liabilities).
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

    function token() external view returns (address);
    function operator() external view returns (address);
    function depositsPaused() external view returns (bool);
}
