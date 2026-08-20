# picocash-contracts

> **Status: pre-alpha, interface draft.** Nothing here is deployed or audited. Do not use with real funds.

Solidity contracts for [picocash](https://github.com/picocash/picocash) — private, instant eCash for machine payments, backed 1:1 by USDC.e on [Tempo](https://tempo.xyz). This repo holds the on-chain half: the **vault** that custodies the stablecoin backing outstanding eCash tokens.

## What the vault must guarantee

- **1:1 backing, provable**: vault balance ≥ outstanding token supply per keyset, with outstanding supply published on-chain each epoch — anyone can check solvency (proof of liabilities, not "trust me").
- **Exit is sacred**: withdrawals are **never pausable**. Deposits may be paused; redemptions may not.
- **Timelocked operator rotation** — no instant key swaps over custody.
- **Memo-bound deposits**: a deposit is a TIP-20 `transferWithMemo(vault, amount, quoteId)` where the memo is the mint quote id; the mint's deposit oracle watches exactly that event (the memo is indexed on Tempo's TIP-20). The interface in [`src/interfaces/IPicocashVault.sol`](src/interfaces/IPicocashVault.sol) documents the full surface, including the allowance-based fallback and melt payouts.
- **One vault per currency, provably bound**: the token is immutable, must have code at deployment, and `vault.token()` is the on-chain authority the mint checks its unit (`tip20:<chain_id>:<token_address>`) against at startup. Tokens sent to the vault by mistake can be returned via `sweep` — which structurally cannot touch the backing token.

The protocol specs live in [picocash/pips](https://github.com/picocash/pips): [PIP-04](https://github.com/picocash/pips/blob/main/PIP-04.md) (design constraints) and [PIP-02](https://github.com/picocash/pips/blob/main/PIP-02.md) (the mint that consumes these events). Per the build order, the vault is implemented **against the already-running mint** — the interface here is dictated by a live consumer, not guessed.

## Layout & tooling

Standard [Foundry](https://getfoundry.sh) project:

```sh
forge build
forge test
```

- `src/interfaces/` — `IPicocashVault` (draft)
- `src/PicocashVault.sol` — implemented and deployed (see Deployments)
- `test/` — Foundry tests incl. fuzzed withdraw-vs-balance, rotation timelock, and sweep guards

Target chain: Tempo — testnet **Moderato** (chain id 42431, RPC `https://rpc.moderato.tempo.xyz`) first; mainnet only behind the reference mint's hard caps. Note Tempo has no native gas token: fees are paid in the TIP-20 being transferred.

## Factory & discovery

`PicocashVaultFactory.deployVault(token, operator, timelock, publishThresholdBps, publishIntervalBlocks, maxMeltFee, name, mintUrl)` is how vaults are born: permissionless, zero authority retained. `isVault(addr)` proves a vault runs the canonical bytecode (the one-call allowlist check for services), and `VaultDeployed` events plus the `vaults[]` array enumerate every picocash vault on the chain. Each vault's read-only `info()` returns the on-chain mint record — name, mint API URL, token, operator, active keyset, deposits-paused flag, live backing balance, the last published outstanding supply with its timestamp, and the publication policy with its current due-state. Discovery and solvency in a single `eth_call`: factory → vault → mint URL → keys, no off-chain registry.

**Publication policy**: every vault commits at deployment to at least one solvency-publication rule — a balance-drift threshold (bps) that makes a publication *due*, and/or a block interval whose breach makes it *overdue*. While overdue, `ecashMint` (allowance deposits) reverts — a mint that stops attesting stops taking new money; `ecashMelt` is never affected. `isPublicationDue()` / `isPublicationOverdue()` make both rules machine-checkable, so silence from a mint has a defined, queryable meaning.

**Melt-fee ceiling** (`maxMeltFee`): the on-chain cap on the exit tax. The mint must never quote a melt fee above it (the reference mint refuses to start otherwise); wallets should check it before depositing. Decreases are instant; increases go through the rotation timelock — raising the cost of leaving requires the same public notice as changing who controls custody.

## Deployments

| Network | Contract | Address |
|---|---|---|
| Moderato (testnet, 42431) | **PicocashVaultFactory** | `0xbcaa0658103C88B30c7028d2f28964403AEf0BFe` |
| Moderato (testnet, 42431) | PicocashVault (dev mint, via factory) | `0xd409D3c16F3472bD75fb86eF3f2D69d602F3cfA3` |

Token pathUSD `0x20c0…0000`, 2-day rotation timelock, test funds only.

## Security

See [SECURITY.md](SECURITY.md). The headline attack surfaces: any path where outstanding supply can exceed vault balance, and any path that can freeze withdrawals.

## License

[Apache-2.0](LICENSE)
