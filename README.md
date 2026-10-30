# Meridian AI

A clickable prototype of an AI-assisted revenue cycle workspace for a custom EHR.

A meridian is a shared reference line. In this prototype the claim and its history are that line: a biller sees what was submitted, an appeals specialist sees what the payer disputed, and finance traces the payment back to the same service line. "Meridian" is a working name and open to change.

**All data is synthetic.** Nothing here connects to a real EHR, payer, clearinghouse or bank.

## What is in it

- Landing page
- Dashboard
- Workspace with nine tabs: Workqueues, Submission, Account, Claims, Remits, Report, Appeals, Coverage, Approvals
- Workflows: 15 back-office process workflows
- Users, Analytics and Settings

The prototype covers the claim, denial, appeal and recovery loop with five synthetic cases:

| Case | Path |
|---|---|
| CLM-24017 | Appeal (the draft has an unsupported statement that blocks approval) |
| CLM-24033 | Corrected claim |
| CLM-24051 | Request for evidence |
| CLM-24068 | Coverage update (coordination of benefits) |
| CLM-23988 | Completed example with a service-line trace |

Analytics measures median analyst minutes per resolved case, filing deadlines missed, unsupported statements in reviewed drafts, and reconciled cash recovered per eligible denied dollar, on a fixed denial cohort and recovery window. Appeal approvals, payer overturns and cash receipts are tracked as separate stages.

## Run it

Open `index.html` in a browser. It is one self-contained file. Fonts load from Google Fonts, so it needs an internet connection for the intended typefaces.

## Left to implementation

- Payer-specific filing rules (the deadlines shown use synthetic rules)
- Production integrations with the EHR, clearinghouse, payers and bank
- Role permissions and approval limits (the values shown are examples)
- Interaction polish and transitions
- Payer responses and deposits are simulated by buttons in the prototype
