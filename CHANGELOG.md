# Changelog

Each release is a git tag. To roll back: `git checkout v0.4.0 -- index.html` (then commit), or `git revert <commit>`.

## v0.6.3 - GitHub Pages deployment
- Added a GitHub Actions workflow that publishes index.html and process-maps.html to GitHub Pages on every push to main
- Site: https://pulokg11.github.io/Meridian-AI/ (prototype) and /process-maps.html (process maps)
- Rollback: delete .github/workflows/pages.yml; the site stops updating

## v0.6.2 - Process maps
- New file process-maps.html: swimlane maps for the whole platform (end to end, Access, Clinical revenue, Claim to cash, Denial and recovery), the 24 handover checks and a portal-by-stage matrix. Published as its own artifact
- The product (index.html) is unchanged in this release
- Rollback: delete process-maps.html, or `git checkout v0.6.1`

## v0.6.1 - Two-step sign-in, new landing page, polish
- Sign-in is now two steps: first choose a portal (5 cards with who uses it, what they do, role and workflow counts, sign-in method), then choose a role; "Change portal" returns to step 1
- Landing page rewritten for the five-portal platform: portal cards, three loops, updated scope; landing buttons open the portal step
- Claim adjudication: the denial-code and allowed-amount fields appear only when Deny or Pay in part is chosen
- Proxy access: the proxy list is full width and permission buttons no longer wrap
- Audit trail: new entries advance the clock, so timestamps differ
- Rollback: `git checkout v0.6.0 -- index.html`

## v0.6.0 - Four more portals and the last 3 provider roles
- Provider: 3 new roles (Practice administrator or CFO, Privacy officer, Provider system administrator) with a new section "Leadership, privacy and administration" (Financial health, Cash forecast, Access review, Disclosures, Users and roles, Integrations, Rules) and a Patient requests tab in Patient finance
- Patient portal, PP01 to PP09: book/reschedule/cancel, intake and consents, insurance and ID, estimate and payment option, pay and plan, questions and disputes, financial assistance, proxy access, statements and receipts (3 patient roles)
- Payer portal, Y01 to Y08: eligibility, prior authorization, claim adjudication, records requests, appeals, remittance, payment integrity, fee schedules (8 roles). Live provider cases now wait for the payer to decide
- Clearinghouse portal, C01 to C05 (3 roles) and Platform console, X01 to X05 (3 roles)
- Role picker has a portal tab row; every portal has Home, a queue per role and an "Other portals" list
- Shared audit trail (hash chained) records actions across portals; interface downtime is shared between clearinghouse and platform
- Rollback: `git checkout v0.5.0 -- index.html`

## v0.5.0 - Navigation and role picker
- Tabs regrouped into 8 sections of 4 to 9 tabs: Scheduling, Registration and clearance, Documentation and coding, Charges and release, Denials, Claims and cash, Cases and disputes, Patient finance and compliance
- Sidebar grouped under the three loops (Access, Clinical revenue, Billing and recovery)
- New first screen "Who are you today?": 28 job roles plus a tester role, grouped, searchable, each with a one-line job and open-task count; replaces the Acting-as drop-down
- Top bar shows a compact role chip; clicking it (or the name at the bottom of the sidebar) reopens the picker
- All existing links and hashes keep working


## v0.4.0 - Remaining Provider screens (53 of 53)
- Recovery workspace: Underpayments, Audits (recoupment reopens a closed case), Disputes (independent dispute resolution and estimate disputes)
- New Finance section (6 tabs): Patient accounts (outreach limits, opt-out, dispute pause, overpayment creates a credit), Plans and assistance (poverty-line bands, $25 installment minimum, default), Refunds and credits (return clock, approval limits), Write-offs (open-rights check, bad-debt placement), Compliance (sample, findings routed to authors), Prevention loop (simulate and publish rules)
- Three more personas (28 in total); ledger now includes refunds, write-offs, awards and assistance
- Inbox includes finance tasks


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
