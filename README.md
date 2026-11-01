# Meridian AI

A clickable prototype of an AI-native revenue cycle platform for physician groups and hospitals. Patients, providers, payers, clearinghouses and platform operators each sign in to their own portal, and every handover between them is checked before work moves on.

A meridian is a shared reference line. Here the claim and its history are that line: a biller sees what was submitted, an appeals specialist sees what the payer disputed, and finance traces the payment back to the same service line. "Meridian" is a working name and open to change.

**All data is synthetic.** Nothing here connects to a real EHR, payer, clearinghouse or bank.

**Current version: v7.0.0** (see [Version history](#version-history))

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

Fifteen synthetic cases run the whole loop and are linked across all five portals:

| Case | Path | Starts at | Links to the other portals |
|---|---|---|---|
| CLM-24017 | Appeal (the draft has an unsupported statement that blocks approval) | Action drafted | Payer: appeals |
| CLM-24033 | Corrected claim | Triaged | Payer: claim adjudication; payer audit AU-201 |
| CLM-24051 | Request for evidence | Triaged | Payer: records requests |
| CLM-24068 | Coverage update (coordination of benefits) | Triaged | Payer: eligibility |
| CLM-23988 | Completed example with a service-line trace | Reconciled | |
| CLM-24201 | Corrected claim (taxonomy code), patient Alex Morgan | Triaged | Patient: statement appears once the payer pays; clearinghouse rejection |
| CLM-24202 | Evidence request (MRI knee), patient Alex Morgan | Deposit allocated | Patient: pays the $800 deductible, which clears the closure blocker; clearinghouse: 835 not delivered |
| CLM-24203 | Coordination of benefits, patient Riley Morgan (guardian Jamie) | Payer responded | Payer: eligibility inquiry E-6; patient: proxy and statement; clearinghouse: duplicate 835 |
| CLM-24204 | Coverage ended, patient Sam Okoye becomes self-pay | Payer responded | Payer: eligibility inquiry E-5; patient: $1,325 balance, good faith estimate and dispute |
| CLM-24205 | Appeal with an unsupported statement (knee arthroscopy) | Action drafted | Platform: AI governance and compliance sample |
| CLM-24206 | Evidence request, authorization missing | Triaged | Payer: retrospective authorization PR-4 supplies the number |
| CLM-24207 | Corrected claim, reopened by a $420 payer recoupment | Reconciled, reopened | Payer: payment integrity; platform audit trail |
| CLM-24208 | Appeal (sleep study), all statements sourced | Sent | Payer: appeals decision |
| CLM-24209 | Evidence request (MRI lumbar), packet complete | Sent | Payer: records requests |
| CLM-24210 | Corrected claim (Payer C taxonomy rule change) | Sent | Payer: claim adjudication; clearinghouse rejection monitoring |

## Process maps

`process-maps.html` has swimlane maps for the whole platform: end to end, Access, Clinical revenue, Claim to cash, and Denial and recovery. It also lists the 24 handover checks and a matrix of which portal acts at each stage. Click any step for who does it, what happens and where it lives in the prototype.

## Run it locally

Open `index.html` or `process-maps.html` in a browser. Each is one self-contained file. Fonts load from Google Fonts, so an internet connection is needed for the intended typefaces.

## Version history

Every release is a git tag. Details and rollback steps for each are in [CHANGELOG.md](CHANGELOG.md). To restore an earlier prototype: `git checkout v0.5.0 -- index.html`, then commit.

| Tag | What changed |
|---|---|
| v7.0.0 | Ten new cases (fifteen in all) linked across the provider, patient, payer, clearinghouse and platform portals |
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
