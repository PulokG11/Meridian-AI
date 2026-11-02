# Meridian back end, release 1: design

Status: **draft for review** · Date: 2026-11-01 · Builds on: `Meridian_Technical_Specification.docx` (sections 2–5, 10, 14, 16.8) and the 154-table model in `Meridian_Platform_Plan_Part2_DataModel.xlsx`.
All data is synthetic. Nothing here is a production or PHI-safe deployment.

## 1. Intent

Give Meridian a real database and API, with Supabase (Postgres) as the store, so the Cases + Denials loop runs outside the browser with the rules the prototype only imitates: gated commands, legal state transitions, append-only money, a tamper-evident audit chain, handovers that hold work instead of losing it, and tenant/portal isolation enforced by the database.

**Decided with you**
| Question | Answer |
|---|---|
| Scope of release 1 | Cases + Denials loop (the spec's "Tier A: behavior" set), not all 154 tables |
| Prototype | `index.html` stays unchanged (v7.0.0). Wiring it to the back end is a later release |
| Access | Real Supabase Auth, row-level security (RLS) on every table |

**Out of scope for release 1:** access/scheduling/estimate workflows, clinical core, real EDI/payer/bank connections, a real language model (the AI stand-in stays rule-based and labeled "Simulated"), the browser wiring, any PHI.

## 2. Approach

| | A. Logic in Postgres (recommended) | B. Logic in Edge Functions (TypeScript) | C. Separate Node/Python service |
|---|---|---|---|
| Where commands live | SQL functions `cmd_*`, one transaction each | Deno code calling tables with the service role | Own server and host |
| Guards cannot be bypassed | Yes: triggers and RLS apply to every client | Only if every path goes through the function | Same as B |
| Fits this machine | Yes: migrations are applied through the Supabase connector | Yes (deploy via connector) | No Node/Python installed; extra hosting |
| Testing | SQL test suite inside the database | Needs a test harness | Needs a test harness |
| Cost / ops | Just Supabase | Supabase | Supabase plus a second host |

**Recommendation: A**, plus a thin Edge Function for the pieces SQL does badly (the HTTP facade, the AI stand-in, file intake). This matches spec ADR 01–03: all change goes through named commands, state machines are data, money tables are append-only. Postgres enforces those even if a client misbehaves.

## 3. Architecture

```
client (later: index.html)  ──HTTPS+JWT──►  Edge Function `api`  ──►  SQL command cmd_*(…)
                                              │                          │ one transaction:
 Supabase Auth (JWT: tenant, portal, role) ───┘                          │ authorize → validate → guard
                                                                         │ → idempotency → mutate → audit → outbox
 PostgREST (read-only views under RLS) ◄─────────────────────────────────┘
 Edge Function `ai-standin` (Simulated; returns the spec §7.3 shape)
 `app.process_outbox()` (SQL, run every minute by pg_cron: reads the outbox, runs the handover engine)
```

- **Reads:** PostgREST views and tables under RLS. **Writes:** only through `cmd_*` functions. Direct `INSERT/UPDATE/DELETE` is revoked for client roles.
- **Handover engine:** the SQL function `app.process_outbox()`, scheduled with pg_cron (no separate relay service), turns events into handover events H13–H24 (the denials/claims/cash handovers) with ready checks; a failed check creates a task in a named queue (IV26); replays create no duplicates (IV27).
- **Schema layout:** `app` (domain tables), `ref` (state machines, rule packs, code sets), `audit` (audit log, outbox), `api` (the `cmd_*` functions and read views). Only `api` is exposed.

## 4. Data model (release 1)

About **55–60 tables**, taken from the Part 2 domains with the same names and conventions (`<table>_id` UUIDv7, `tenant_id` on every tenant-owned table, audit columns, soft-delete only where the spec allows). The exact count is fixed in the schema migration; if it passes 60 I cut seeded-only tables first.

| Domain | Tables |
|---|---|
| Platform | `tenant`, `org_unit`, `app_user`, `role`, `permission`, `role_permission`, `user_role`, `approval_limit`, `audit_log`, `idempotency_key`, `outbox_event` |
| Parties | `patient`, `patient_relationship`, `proxy_access`, `provider` |
| Payers & coverage | `payer`, `payer_plan`, `payer_config`, `coverage`, `eligibility_request`, `eligibility_response`, `clearinghouse`, `clearinghouse_connection` |
| Claims | `claim`, `claim_service_line`, `claim_diagnosis`, `claim_edit_result`, `edi_interchange`, `claim_ack` |
| Payments & recovery | `remittance`, `remittance_line`, `payment_posting`, `deposit`, `deposit_allocation`, `denial`, `denial_triage`, `root_cause`, `records_request`, `evidence_item`, `appeal`, `appeal_statement`, `deadline` |
| Patient billing | `patient_responsibility`, `patient_statement`, `patient_payment`, `patient_dispute` |
| Case | `case`, `case_claim`, `case_status_history`, `reopen_event`; `line_balance` is a **view** over postings (closure is computed, D6) |
| Workflow | `work_queue`, `task`, `approval_request`, `handover_def`, `handover_event` |
| Rules & AI | `rule_pack`, `rule`, `state_transition`, `ai_model_version`, `ai_interaction`, `ai_review` |

**Mapping to the prototype:** `CL` → `claim` + `claim_service_line` + `case`; `STAGES` 0–8 → `denial.status` + `case.status` + posting facts (derived, not typed); `S.st/tri/ev/stm/pat/closed/reopen` → the rows above; `MX`/`MA` → payer/clearinghouse/platform tables and `audit.audit_log`.

## 5. Rules enforced in the database

| Mechanism | What it enforces | Spec ref |
|---|---|---|
| `ref.state_transition` + `BEFORE UPDATE` trigger | Illegal status moves are refused | IV39 |
| Append-only triggers on `payment_posting`, `deposit_allocation`, `audit_log` | No update/delete; corrections are reversing rows | IV04 |
| Hash-chained `audit.audit_log` (`prev_hash`, `hash`) with a `verify_audit_chain()` function | Tampering is detectable (same scheme as the prototype's `chainOk`) | NFR audit |
| Constraints / commands | Billed = paid + adjustment + patient share per line; deposit allocation ≤ deposit; replacement claim ≠ original; no release with hold or failed hard edit; approver ≠ author and within limit; no appeal approval with an unsupported statement; AI output needs a recorded review before any external effect | IV01, IV06, IV10–IV16 |
| `cmd_case_close` reads `line_balance` | Closure requires payer share + patient share collected or approved for write-off, cash reconciled, no open patient dispute | D6, IV07/08 |
| `idempotency_key` table | A repeated command with the same key returns the first result | IV37 |
| Refusal format | `RAISE` with a code, rule name, blocking object and what to do | spec §9.5 |

## 6. Access model

- Supabase Auth users for the **48 roles** (synthetic emails). `app_user` links `auth.users` to `tenant_id`, `portal` (provider, patient, payer, clearinghouse, platform), `role`, and, for external parties, `party_id` (a payer, clearinghouse or patient).
- A custom access-token hook puts `tenant_id`, `portal`, `role` and `party_id` in the JWT.
- RLS: provider and platform staff see their tenant's rows; a payer sees only claims addressed to its `payer_id`; a clearinghouse only its interchanges; a patient/proxy only their own responsibility rows (and guarded proxy scope). Permissions per command come from `role_permission` and `approval_limit` (the prototype's `PERM` table and approval limits are seeded from the same values).
- The **service-role key is never committed or used by a client**; only the public (publishable) key can appear in client code later. Test-user passwords are written to a git-ignored file (`backend/seed/test-users.local.md`) and are not repeated in chat.

## 7. Seed data

Deterministic SQL seed (fixed values, no randomness) that loads: one tenant, org units, the 48 roles and permissions, test users, 13 payers (+ plans, configs), clearinghouse and connections, the **15 synthetic cases** with their claims, service lines, denials, triage, evidence, appeals, remittances, deposits, patient responsibilities and disputes at the same starting stages as the prototype, and the rule pack (state machines, deadline and appeal-level rules). A case's stage must be reproducible from rows, not stored.

## 8. Testing

All inside Postgres, runnable through the connector (no Node/Python needed):
1. **Invariant suite:** one assertion per implemented invariant (IV01, 04, 06, 07, 08, 09, 10–16, 26, 27, 37, 39), failing loudly.
2. **Scenario tests:** replay the prototype's journeys as `cmd_*` calls: corrected claim, evidence request with PR-4 retro-authorization, appeal with unsupported statement refused then fixed, duplicate 835 rejected, coverage-ended → self-pay, recoupment reopening CLM-24207, patient payment clearing the closure blocker, dispute blocking closure.
3. **RLS tests:** impersonate each portal's role (`SET LOCAL request.jwt.claims`) and assert cross-portal reads return zero rows.
4. **Advisors:** run Supabase security and performance advisors after each migration batch and fix every finding.

## 9. Delivery, versioning, rollback

- Files in the repo under `backend/`: `supabase/migrations/NNN_*.sql` (each with a matching `down` script), `supabase/functions/{api,ai-standin}`, `seed/`, `tests/`, and a short `backend/README.md`.
- Release tag: **v8.0.0** (the next major after v7.0.0; tell me if you prefer another number). CHANGELOG entry with rollback steps. README gets a "Back end" section.
- Rollback: `git checkout v7.0.0` restores the repo; database rollback is the down scripts in reverse order, or dropping the four schemas (the project holds only synthetic data).
- The process maps describe the front-end behavior, which does not change in this release, so no map update is needed; I'll add a note to the data-handover map only if a handover behaves differently in the database.
- I will commit and tag only when you ask.

## 10. Cost, risks, open items

| Item | Detail |
|---|---|
| **Supabase cost** | Org `PulokG11` has no project. I will call the cost check first, show you the exact price, and create the project only after you say yes. Region: your choice, defaulting to the nearest. |
| Single-tenant seed | Seed has one tenant. RLS is written for many, tested with a second throwaway tenant. |
| Edge Function deploys | Written and deployed through the connector; no local runtime to test them first, so they get tested live against synthetic data. |
| Prototype/DB drift | The prototype's rules are in JavaScript; the database copies them. A parity check (same journeys, same results) is part of the scenario tests. A later release should make the browser use the database rules. |
| AI | No real model. `ai-standin` returns the spec's interface with a "Simulated" label. |
| Hosting a public key | Not needed in this release (no client wiring). |

## 11. Build order (for the implementation plan)

1. Cost check → your yes → create the project.
2. Schemas, reference tables, state machines (migration 1–2).
3. Platform, parties, payers/coverage tables, RLS, JWT hook (3–4).
4. Claims, remittances, postings, deposits, denials, appeals, case, patient billing (5–7).
5. Workflow, handover engine, outbox, audit chain (8–9).
6. Commands `cmd_*` (10–12), read views.
7. Seed: reference data, users, the 15 cases (13).
8. Edge Functions `api`, `ai-standin`.
9. Test suites; advisors; fix findings.
10. Docs, CHANGELOG, README; commit and tag when you approve.
