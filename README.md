# picocash-contracts

> **Status: pre-alpha, interface draft.** Nothing here is deployed or audited. Do not use with real funds.

Solidity contracts for [picocash](https://github.com/picocash/picocash) — private, instant eCash for machine payments, backed 1:1 by TIP-20 stablecoins (e.g. USDC.e) on [Tempo](https://tempo.xyz). This repo holds the on-chain half: the **vault** that custodies the stablecoin backing outstanding eCash tokens.

## What the vault must guarantee

- **1:1 backing, checkable**: vault balance ≥ outstanding token supply per keyset. The *balance* is on-chain truth; the *outstanding supply* is an operator attestation published on-chain under a committed policy. Anyone can compare the two; a lying operator is caught by holders whose tokens stop redeeming, not by the contract.
- **Exit is sacred**: `ecashMelt` has no pause switch — the contract cannot be told to stop paying out. What it cannot do is force the operator to sign melts: a mint that goes offline is a liveness failure the contract does not cure. Deposits may be paused; payouts may not.
- **Timelocked operator rotation** — no instant key swaps over custody.
- **Withdrawal breaker** (vault v3): operator payouts are capped at `meltLimitBps` of backing per `meltEpochBlocks`; consuming the allowance latches the vault — no more `ecashMelt`/`ecashMint`, and `emergencyMode()` is true immediately so holders exit. Reset only through the rotation timelock. Bounds an *active* rogue operator to one epoch's allowance.
- **Unilateral holder exit** (vault v2): once the attestation is overdue past a deploy-time grace period, anyone redeems tokens at the vault directly — `emergencyRedeem` verifies each proof with the registered keyset *public* key, keeps its own spent set, honours P2PK locks, and caps total payouts at the last attested outstanding supply. No operator involved. The timelock length is a per-deployment constructor argument (the testnet vaults use 2 days); check `info()` before trusting a vault.
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
- `src/emergency/` — on-chain eCash proof verification for PIP-04 §Emergency redemption: `Secp256k1.sol` (curve math), `EcashProofVerifier.sol` (DLEQ with only the mint's public key), `PicocashEmergencyVerifier.sol` (shared stateless contract the factory deploys: adds PIP-08 P2PK evaluation with on-chain BIP-340 Schnorr). ≈2.1 M gas per plain proof, ≈2.35 M per locked proof; tested against vectors from the reference TypeScript crypto.
- `test/` — Foundry tests incl. fuzzed withdraw-vs-balance, rotation timelock, and sweep guards

Target chain: Tempo — testnet **Moderato** (chain id 42431, RPC `https://rpc.moderato.tempo.xyz`) first; mainnet only behind the reference mint's hard caps. Note Tempo has no native gas token: fees are paid in the TIP-20 being transferred.

## Factory & discovery

`PicocashVaultFactory.deployVault(token, operator, timelock, publishThresholdBps, publishIntervalBlocks, maxMeltFee, name, mintUrl, emergencyGraceBlocks, meltLimitBps, meltEpochBlocks)` is how vaults are born: permissionless, zero authority retained. `isVault(addr)` proves a vault runs the canonical bytecode (the one-call allowlist check for services), and `VaultDeployed` events plus the `vaults[]` array enumerate every picocash vault on the chain. Each vault's read-only `info()` returns the on-chain mint record — name, mint API URL, token, operator, active keyset, deposits-paused flag, live backing balance, the last published outstanding supply with its timestamp, and the publication policy with its current due-state. Discovery and solvency in a single `eth_call`: factory → vault → mint URL → keys, no off-chain registry.

**Publication policy**: every vault commits at deployment to at least one solvency-publication rule — a balance-drift threshold (bps) that makes a publication *due*, and/or a block interval whose breach makes it *overdue*. While overdue, `ecashMint` (allowance deposits) reverts — a mint that stops attesting stops taking new money; `ecashMelt` is never affected. `isPublicationDue()` / `isPublicationOverdue()` make both rules machine-checkable, so silence from a mint has a defined, queryable meaning.

**Melt-fee ceiling** (`maxMeltFee`): the on-chain cap on the exit tax. The mint must never quote a melt fee above it (the reference mint refuses to start otherwise); wallets should read it on-chain before depositing — it is the only fee ceiling a wallet can enforce. Decreases are instant; increases go through the rotation timelock — raising the cost of leaving requires the same public notice as changing who controls custody.

## Deployments

| Network | Contract | Address |
|---|---|---|
| Moderato (testnet, 42431) | **PicocashVaultFactory** | `0xE49A8fEA32448bd7cBFF7Aa0A3509e473D4CC377` (v3) |
| Moderato (testnet, 42431) | PicocashEmergencyVerifier (shared, deployed by the factory) | `0x7b64972Dd8027f64a2186E5831272774e2f0eC84` |
| Moderato (testnet, 42431) | PicocashVault (hosted mint `mint.picocash.dev`, via factory) | `0x4380094eeEF8AB12B868bFBB46c7e7B90a713a83` |
| Moderato (testnet, 42431) | PicocashVault (dev mint, via factory) | `0xA46E150426959dbd40A3bAD372C8ABbBE57b8396` |

Token pathUSD `0x20c0…0000`, 2-day rotation timelock, 6000-block attestation interval, ~7-day (967,680-block) emergency grace, breaker 50 % per 5400 blocks, test funds only.

## Security

See [SECURITY.md](SECURITY.md). The headline attack surfaces: any path where outstanding supply can exceed vault balance, and any path that can freeze withdrawals.

## License

[Apache-2.0](LICENSE)
