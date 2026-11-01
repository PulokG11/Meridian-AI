# Meridian AI

A clickable prototype of an AI-native revenue cycle platform for physician groups and hospitals. Patients, providers, payers, clearinghouses and platform operators each sign in to their own portal, and every handover between them is checked before work moves on.

A meridian is a shared reference line. Here the claim and its history are that line: a biller sees what was submitted, an appeals specialist sees what the payer disputed, and finance traces the payment back to the same service line. "Meridian" is a working name and open to change.

**All data is synthetic.** Nothing here connects to a real EHR, payer, clearinghouse or bank.

**Current version: v0.6.4** (see [Version history](#version-history))

## Live links

| What | Link |
|---|---|
| Prototype | https://pulokg11.github.io/Meridian-AI/ |
| Process maps | https://pulokg11.github.io/Meridian-AI/process-maps.html |

Both sites redeploy automatically on every push to `main` (GitHub Actions, `.github/workflows/pages.yml`).

## What is in the prototype

Sign-in is two steps: choose a portal, then choose a job role. There are 48 roles in all, plus a tester role that unlocks everything in a portal.

| Portal | Roles | What it covers |
|---|---|---|
| Provider | 31 | 9 sections and 61 tabs across three loops: Scheduling; Registration and clearance; Documentation and coding; Charges and release; Denials; Claims and cash; Cases and disputes; Patient finance and compliance; Leadership, privacy and administration |
| Patient | 3 | PP01 to PP09: book, intake and consents, insurance and ID, estimate and payment option, pay and plan, questions and disputes, financial assistance, proxy access, statements and receipts |
| Payer | 8 | Y01 to Y08: eligibility, prior authorization, claim adjudication, records requests, appeals, remittance and payment, payment integrity, fee schedules |
| Clearinghouse | 3 | C01 to C05: enrollment, edits and routing, eligibility routing, remittance delivery, rejection monitoring |
| Platform | 3 | X01 to X05: identity and access, AI governance, audit trail, integrations, rules packs |

Behavior that is built, not just drawn:

- Role permissions, approval limits and separation of duties
- Gates that block the next step (authorization dates, 72-hour eligibility freshness, estimate timing, unsupported statements in an appeal draft, deposit over-allocation, the closure rule)
- Live cases wait for the payer portal to decide, so there is no "simulate payer" step in the loop
- A shared audit trail whose entries are chained, so edits are detectable
- AI switches per workflow (automatic, suggestion only, off), and downtime shared between the clearinghouse and the platform

Five synthetic cases run the whole loop:

| Case | Path |
|---|---|
| CLM-24017 | Appeal (the draft has an unsupported statement that blocks approval) |
| CLM-24033 | Corrected claim |
| CLM-24051 | Request for evidence |
| CLM-24068 | Coverage update (coordination of benefits) |
| CLM-23988 | Completed example with a service-line trace |

## Process maps

`process-maps.html` has swimlane maps for the whole platform: end to end, Access, Clinical revenue, Claim to cash, and Denial and recovery. It also lists the 24 handover checks and a matrix of which portal acts at each stage. Click any step for who does it, what happens and where it lives in the prototype.

## Run it locally

Open `index.html` or `process-maps.html` in a browser. Each is one self-contained file. Fonts load from Google Fonts, so an internet connection is needed for the intended typefaces.

## Version history

Every release is a git tag. Details and rollback steps for each are in [CHANGELOG.md](CHANGELOG.md). To restore an earlier prototype: `git checkout v0.5.0 -- index.html`, then commit.

| Tag | What changed |
|---|---|
| v0.6.4 | README updated with live links and version history |
| v0.6.3 | GitHub Pages deployment for the prototype and the process maps |
| v0.6.2 | Process maps added |
| v0.6.1 | Two-step sign-in (portal, then role), new landing page, polish |
| v0.6.0 | Patient, payer, clearinghouse and platform portals; last 3 provider roles |
| v0.5.0 | Tabs regrouped into sections; role picker replaces the Acting-as drop-down |
| v0.4.0 | Remaining provider screens: underpayments, audits, disputes, patient finance |
| v0.3.0 | Access and Clinical revenue slices |
| v0.2.0 | Recovery slice: ten provider roles, task inbox, triage through closure tabs |
| v0.1.0 | First prototype: landing, dashboard, workspace, five synthetic cases |

## Left to implementation

- Payer-specific filing rules and real timelines (the values shown are synthetic)
- Production integrations with the EHR, clearinghouse, payers, bank and the voice agent
- Role permissions, approval limits and rule values (the ones shown are examples)
- Receipt downloads in the published artifact view (the viewer blocks file downloads)
- Interaction polish and transitions
