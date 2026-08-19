# picocash-contracts

> **Status: pre-alpha, interface draft.** Nothing here is deployed or audited. Do not use with real funds.

Solidity contracts for [picocash](https://github.com/picocash/picocash) — private, instant eCash for machine payments, backed 1:1 by USDC.e on [Tempo](https://tempo.xyz). This repo holds the on-chain half: the **vault** that custodies the stablecoin backing outstanding eCash tokens.

## What the vault must guarantee

- **1:1 backing, provable**: vault balance ≥ outstanding token supply per keyset, with outstanding supply published on-chain each epoch — anyone can check solvency (proof of liabilities, not "trust me").
- **Exit is sacred**: withdrawals are **never pausable**. Deposits may be paused; redemptions may not.
- **Timelocked operator rotation** — no instant key swaps over custody.
- **Memo-bound deposits**: a deposit is a TIP-20 `transferWithMemo(vault, amount, quoteId)` where the memo is the mint quote id; the mint's deposit oracle watches exactly that event (the memo is indexed on Tempo's TIP-20). The interface in [`src/interfaces/IPicocashVault.sol`](src/interfaces/IPicocashVault.sol) documents the full surface, including the allowance-based fallback and melt payouts.

The protocol spec lives in the main repo: [`spec/05-vault.md`](https://github.com/picocash/picocash/blob/main/spec/05-vault.md) (design constraints) and [`spec/03-mint-api.md`](https://github.com/picocash/picocash/blob/main/spec/03-mint-api.md) (the mint that consumes these events). Per the build order, the vault is implemented **against the already-running mint** — the interface here is dictated by a live consumer, not guessed.

## Layout & tooling

Standard [Foundry](https://getfoundry.sh) project:

```sh
forge build
forge test
```

- `src/interfaces/` — `IPicocashVault` (draft)
- `src/` — vault implementation (build step 5, in progress)
- `test/` — Foundry tests incl. fuzzed solvency-invariant properties (with the implementation)

Target chain: Tempo — testnet **Moderato** (chain id 42431, RPC `https://rpc.moderato.tempo.xyz`) first; mainnet only behind the reference mint's hard caps. Note Tempo has no native gas token: fees are paid in the TIP-20 being transferred.

## Security

See [SECURITY.md](SECURITY.md). The headline attack surfaces: any path where outstanding supply can exceed vault balance, and any path that can freeze withdrawals.

## License

[Apache-2.0](LICENSE)
