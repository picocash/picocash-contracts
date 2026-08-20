// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {PicocashVault} from "./PicocashVault.sol";

/// @title PicocashVaultFactory — canonical deployer & registry for picocash vaults
/// @notice A mint operator (or the customer entity that will hold custody) calls
///         `deployVault` to create their vault. The factory gives the ecosystem
///         two things:
///
///         1. **Provenance**: `isVault(addr)` proves a vault runs exactly this
///            audited bytecode — never-pausable withdrawals, one payout per
///            meltId, timelocked rotation. Services allowlisting mints can
///            check it in one call instead of verifying source per vault.
///         2. **Discovery**: `VaultDeployed` events + the `vaults` array
///            enumerate every picocash vault on this chain, and each vault's
///            `info()` points to its mint's HTTP API.
///
///         The factory is permissionless and holds ZERO authority over
///         deployed vaults — it is a birth certificate, not a parent. There is
///         no owner, no upgrade path, and no function that touches a vault
///         after deployment.
contract PicocashVaultFactory {
    event VaultDeployed(
        address indexed vault,
        address indexed token,
        address indexed operator,
        string name,
        string mintUrl,
        uint256 rotationTimelock,
        uint16 publishThresholdBps,
        uint64 publishIntervalBlocks,
        uint256 maxMeltFee
    );

    /// @notice True iff the address was deployed by this factory.
    mapping(address vault => bool) public isVault;
    /// @notice Every vault ever deployed, in order.
    address[] public vaults;

    /// @notice Deploy a vault. The caller pays gas; `operator` (the mint's
    ///         key) controls the vault from birth — the factory and the caller
    ///         retain nothing. The publication policy (at least one rule) is a
    ///         deploy-time commitment: `publishThresholdBps` (publish when the
    ///         backing drifts more than X bps) and/or `publishIntervalBlocks`
    ///         (publish at least every X blocks).
    function deployVault(
        address token,
        address operator,
        uint256 rotationTimelock,
        uint16 publishThresholdBps,
        uint64 publishIntervalBlocks,
        uint256 maxMeltFee,
        string calldata name,
        string calldata mintUrl
    ) external returns (address vault) {
        vault = address(
            new PicocashVault(
                token, operator, rotationTimelock, publishThresholdBps, publishIntervalBlocks, maxMeltFee, name, mintUrl
            )
        );
        isVault[vault] = true;
        vaults.push(vault);
        emit VaultDeployed(
            vault, token, operator, name, mintUrl, rotationTimelock, publishThresholdBps, publishIntervalBlocks, maxMeltFee
        );
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }
}
