# Security Policy

Pre-alpha and unaudited. Testnet-only deployments exist on Tempo Moderato (see README); nothing is deployed on a mainnet. Do not use with real funds.

Report vulnerabilities privately to **security@picocash.dev** — please do not open public issues for exploitable bugs. Acknowledgment within 72 hours; reporters credited (or kept anonymous) in release notes.

Priority surfaces for this repo:

1. **Solvency** — any path where outstanding token supply can exceed vault balance, or where `publishOutstandingSupply` can lie undetectably.
2. **Withdrawal liveness** — anything that can pause, freeze, or grief melts (payouts must never be contract-pausable).
3. **Deposit binding** — memo confusion: crediting the wrong quote, replaying a memo, or double-crediting across the memo-transfer and allowance flows.
4. **Operator rotation** — timelock bypasses.
5. **Withdrawal breaker** — allowance accounting across epoch boundaries, latch bypasses, anything that lets the operator key pay out past the allowance or un-latch without the timelock.
6. **Emergency verifier (prototype, `src/emergency/`)** — curve-arithmetic edge cases (infinity, doubling branches, non-canonical scalars), hash_to_curve divergence from the reference, DLEQ forgeries.
| Breaker under-limit drain | An operator can melt just under the allowance every epoch without tripping the breaker. | Loss rate bounded at `meltLimitBps` per epoch, fully visible in `breakerInfo()` and on the status page; holders' normal melts keep working. | Wallets/services alert on sustained utilisation; mints size the limit to a small multiple of honest volume; cumulative multi-epoch caps are an open PIP-04 item. |
