# picocash-contracts

> **Status: pre-alpha, interface draft.** Nothing here is deployed or audited. Do not use with real funds.

Solidity contracts for [picocash](https://github.com/picocash/picocash) — private, instant eCash for machine payments, backed 1:1 by USDC.e on [Tempo](https://tempo.xyz). This repo holds the on-chain half: the **vault** that custodies the stablecoin backing outstanding eCash tokens.

## What the vault must guarantee

- **1:1 backing, provable**: vault balance ≥ outstanding token supply per keyset, with outstanding supply published on-chain each epoch — anyone can check solvency (proof of liabilities, not "trust me").
- **Exit is sacred**: withdrawals are **never pausable**. Deposits may be paused; redemptions may not.
- **Timelocked operator rotation** — no instant key swaps over custody.
- **Memo-bound deposits**: a deposit is a TIP-20 `transferWithMemo(vault, amount, quoteId)` where the memo is the mint quote id; the mint's deposit oracle watches exactly that event (the memo is indexed on Tempo's TIP-20). The interface in [`src/interfaces/IPicocashVault.sol`](src/interfaces/IPicocashVault.sol) documents the full surface, including the allowance-based fallback and melt payouts.
- **One vault per currency, provably bound**: the token is immutable, must have code at deployment, and `vault.token()` is the on-chain authority the mint checks its unit (`tip20:<chain_id>:<token_address>`) against at startup. Tokens sent to the vault by mistake can be returned via `sweep` — which structurally cannot touch the backing token.

The protocol spec lives in the main repo: [`spec/05-vault.md`](https://github.com/picocash/picocash/blob/main/spec/05-vault.md) (design constraints) and [`spec/03-mint-api.md`](https://github.com/picocash/picocash/blob/main/spec/03-mint-api.md) (the mint that consumes these events). Per the build order, the vault is implemented **against the already-running mint** — the interface here is dictated by a live consumer, not guessed.

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

`PicocashVaultFactory.deployVault(token, operator, timelock, name, mintUrl)` is how vaults are born: permissionless, zero authority retained. `isVault(addr)` proves a vault runs the canonical bytecode (the one-call allowlist check for services), and `VaultDeployed` events plus the `vaults[]` array enumerate every picocash vault on the chain. Each vault's read-only `info()` returns the on-chain mint record — name, mint API URL, token, operator, active keyset, deposits-paused flag, live backing balance, and the last published outstanding supply with its timestamp. Discovery and solvency in a single `eth_call`: factory → vault → mint URL → keys, no off-chain registry.

## Deployments

| Network | Contract | Address |
|---|---|---|
| Moderato (testnet, 42431) | **PicocashVaultFactory** | `0x54b7b22c660Bd2e32c0403A3F3D2A454f92DD192` |
| Moderato (testnet, 42431) | PicocashVault (dev mint, via factory) | `0x91Dd6be2EF2e363b088b2EEf5a20d32f10b455be` |

Token pathUSD `0x20c0…0000`, 2-day rotation timelock, test funds only.

## Security

See [SECURITY.md](SECURITY.md). The headline attack surfaces: any path where outstanding supply can exceed vault balance, and any path that can freeze withdrawals.

## License

[Apache-2.0](LICENSE)
