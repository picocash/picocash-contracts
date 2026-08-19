# Security Policy

Pre-alpha; nothing deployed or audited. Do not use with real funds.

Report vulnerabilities privately to **security@picocash.dev** — please do not open public issues for exploitable bugs. Acknowledgment within 72 hours; reporters credited (or kept anonymous) in release notes.

Priority surfaces for this repo:

1. **Solvency** — any path where outstanding token supply can exceed vault balance, or where `publishOutstandingSupply` can lie undetectably.
2. **Withdrawal liveness** — anything that can pause, freeze, or grief melts (withdrawals must never be pausable).
3. **Deposit binding** — memo confusion: crediting the wrong quote, replaying a memo, or double-crediting across the memo-transfer and allowance flows.
4. **Operator rotation** — timelock bypasses.
