# Changelog

Each release is a git tag. To roll back: `git checkout v0.1.0 -- index.html` (then commit), or `git revert <commit>`.

## v0.2.0 - Recovery slice
- Ten provider personas with permissions, approval limits and separation of duties
- Task inbox built from case state and handovers
- Nine new workspace tabs: Triage, Corrected claim, Evidence packet, Appeal builder, AR follow-up, Deposits, Ledger, Closure, Timeline
- Closure rule, write-off approval, patient balance and payer takeback (reopen)
- Live analytics computed from test-bench actions

## v0.1.0 - First prototype
- Landing page, dashboard, nine workspace tabs, workflows, users, analytics, settings
- Five synthetic cases through the denial-appeal-recovery loop
