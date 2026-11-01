# Changelog

Each release is a git tag. To roll back: `git checkout v0.2.0 -- index.html` (then commit), or `git revert <commit>`.

## v0.3.0 - Access and Clinical slices
- New Access section (14 tabs): home, contact console (booking, red-flag and instruction-injection calls), schedule, appointment, referrals, registration, duplicates, eligibility, authorization, estimate, clearance, check-in, reminders, admissions and ED
- New Clinical revenue section (11 tabs): encounter, queries, utilization review, CDI, coding, charge capture, charge master, holds, enrollment, liability, release queue
- Five synthetic visits run from request to a released claim with gates: 72-hour eligibility freshness, authorized-date booking block, good-faith estimate timing, clearance override, point-of-service collection, uncertain-diagnosis edit, bill holds, provider enrollment
- Fifteen more provider personas (25 total) with permissions; persona menu grouped by area
- Inbox now includes visit tasks and handovers H01 to H13


## v0.2.0 - Recovery slice
- Ten provider personas with permissions, approval limits and separation of duties
- Task inbox built from case state and handovers
- Nine new workspace tabs: Triage, Corrected claim, Evidence packet, Appeal builder, AR follow-up, Deposits, Ledger, Closure, Timeline
- Closure rule, write-off approval, patient balance and payer takeback (reopen)
- Live analytics computed from test-bench actions

## v0.1.0 - First prototype
- Landing page, dashboard, nine workspace tabs, workflows, users, analytics, settings
- Five synthetic cases through the denial-appeal-recovery loop
