# Meridian Back End (release 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Supabase Postgres back end that runs the Meridian Cases + Denials loop with database-enforced commands, state machines, append-only money, a hash-chained audit log, handovers and per-portal row-level security, seeded with the 15 synthetic cases.

**Architecture:** All writes go through SQL functions `api.cmd_*(p_idem text, p_args jsonb) returns jsonb`, each one transaction (authorize → validate → guard → idempotency → mutate → audit → outbox). Reads are RLS-protected tables and views. A SQL function `app.process_outbox()` (run by `pg_cron`) is the handover engine. Two Edge Functions: `api` (HTTP facade) and `ai-standin` (Simulated AI).

**Tech Stack:** Supabase (Postgres, Auth, PostgREST, Edge Functions on Deno, pg_cron), SQL/PLpgSQL, PowerShell for local tooling (no Node/Python on this machine).

**Spec:** `docs/superpowers/specs/2026-11-01-meridian-backend-design.md` (read it first), plus `Meridian_Technical_Specification.docx` §4.3, §5.2, §5.4 and Appendix B.

## Global Constraints

- All data synthetic; no PHI; label AI output "Simulated".
- Schemas: `app` (domain tables), `ref` (state machines, rule packs, code sets), `audit` (audit_log, outbox_event), `api` (commands and read views), `tests` (assertions; not exposed). Only `api` is exposed to PostgREST.
- Primary keys `<table>_id uuid` from `app.uuid_v7()`; every tenant-owned table has `tenant_id uuid not null` and RLS enabled; audit columns `created_at, created_by, updated_at, updated_by`.
- Money is `numeric(12,2)`, never float; per line: billed = paid + adjustment + patient_share.
- `payment_posting`, `deposit_allocation`, `audit.audit_log` are append-only (IV04); corrections are reversing rows.
- Client roles (`authenticated`, `anon`) have no direct INSERT/UPDATE/DELETE on any `app`/`ref`/`audit` table; they call `api.cmd_*` only.
- Command convention: `api.cmd_<name>(p_idem text, p_args jsonb) returns jsonb`, `security definer`, `set search_path = ''`. Refusals use `app.refuse(code, rule, object, todo)` (SQLSTATE `MR001` illegal transition, `MR002` gate, `MR003` permission, `MR004` scope/not found, `MR005` validation).
- The service-role key is never written to any repo file. Test-user password lives only in git-ignored `backend/seed/test-users.local.md` and is not repeated in chat.
- Migrations: `backend/supabase/migrations/NNN_name.sql` each with `backend/supabase/migrations/NNN_name.down.sql`; apply with the Supabase `apply_migration` tool; run `get_advisors` (security and performance) after every task that changes the schema and fix every finding.
- Tests are SQL files in `backend/tests/`, run with `execute_sql`; each ends with a `select tests.report()` that raises if any assertion failed.
- **No git commits or tags until the user approves the release (Task 13).**

## Review Focus

1. Same idempotency key sent twice (or two commands with the same key but different args): second call returns the first result / is refused; nothing is double-posted (Task 2 and Task 6 tests).
2. Amounts that are zero, negative, over-precise, or exceed the billed amount: refused with `MR005`, no row written (Task 8).
3. A caller guessing another tenant's or another party's id (claim, case, appeal): `MR004`, with no hint the row exists (Task 11 RLS/scope tests).
4. A payer, clearinghouse, patient or anonymous caller invoking provider commands, and a provider invoking payer-only commands: `MR003` (Task 11).
5. Closing a case twice, reopening one that is not closed, approving your own appeal, or approving over your limit: refused, state unchanged (Task 7, Task 8).

---

### Task 0: Project, repository scaffold and cost confirmation

**Files:**
- Create: `backend/README.md`, `backend/.gitignore` (ignores `*.local.md`, `.env*`), `backend/supabase/migrations/.gitkeep`, `backend/tests/.gitkeep`, `backend/seed/.gitkeep`, `backend/PROJECT.md` (project id, region, URL; no keys)

**Interfaces:**
- Produces: a Supabase project id (`<PROJECT_ID>`) used by every later task; the project URL.

- [ ] **Step 1:** Call `get_cost` (type `project`, organization `umjgfxvpozacusuhmkca`). Show the user the exact cost and ask for a yes; also ask for region (default: nearest, e.g. `ap-south-1` if they have no preference).
- [ ] **Step 2:** After an explicit yes, call `confirm_cost` then `create_project` named `meridian-ai`. Poll `get_project` until status is `ACTIVE_HEALTHY`.
- [ ] **Step 3:** Run `select version(), current_setting('server_version_num')` via `execute_sql`. Expected: Postgres 15 or later. Record the id, region and URL in `backend/PROJECT.md`.
- [ ] **Step 4:** Create the scaffold files above; `backend/.gitignore` must be verified by `git check-ignore backend/seed/test-users.local.md` (prints the path).

### Task 1: Schemas, UUIDv7, state machines

**Files:**
- Create: `backend/supabase/migrations/001_schemas_ref.sql` (+ `.down.sql`), `backend/tests/001_state_machine.sql`

**Interfaces:**
- Produces: schemas `app, ref, audit, api, tests`; `app.uuid_v7() returns uuid`; `ref.state_transition(entity text, from_status text, to_status text, primary key(entity, from_status, to_status))`; `ref.transition_ok(p_entity text, p_from text, p_to text) returns boolean`; trigger function `app.enforce_transition()` (reads `TG_ARGV[0]` entity name, compares `OLD.status` to `NEW.status`, raises `MR001` via `app.refuse`); `app.refuse(p_code text, p_rule text, p_object text, p_todo text) returns void`; test helpers `tests.assert(p_cond boolean, p_msg text)` (records a row in `tests.result`) and `tests.report()` (raises if any failed, otherwise returns pass count).
- Seeds `ref.state_transition` for entities `claim`, `denial`, `appeal`, `case` exactly as spec §4.3 (claim: draft→ready→submitted→accepted/rejected, accepted→paid/partially_paid/denied; denial: new→triaged→in_correction/in_evidence/in_appeal/in_coverage_update→recovered, any→written_off; appeal: drafting→pending_approval→approved→filed→decided; case: open→closed, closed→open).

- [ ] **Step 1:** Write `tests/001_state_machine.sql` first: assertions `uuid_v7 values sort by creation` (two calls 1 ms apart compare ascending), `legal denial transition accepted` (`ref.transition_ok('denial','new','triaged')`), `illegal denial transition refused` (`new→recovered` is false), and `trigger raises MR001` (update a temp table's status illegally inside a `begin ... exception when sqlstate 'MR001'` block).
- [ ] **Step 2:** Run it. Expected: FAIL (`schema "tests" does not exist`).
- [ ] **Step 3:** Implement the migration (schemas, functions above, seed rows). Use a time-ordered UUID built from `gen_random_uuid()` with the first 48 bits replaced by epoch ms.
- [ ] **Step 4:** Apply with `apply_migration`, re-run the test. Expected: `tests.report()` returns the pass count, no exception.
- [ ] **Step 5:** `get_advisors` security; fix findings (functions use `set search_path = ''`).

### Task 2: Platform core, audit chain, idempotency, outbox, permissions

**Files:**
- Create: `backend/supabase/migrations/002_platform.sql` (+ down), `backend/tests/002_platform.sql`

**Interfaces:**
- Produces tables: `app.tenant`, `app.org_unit`, `app.app_user (user_id uuid pk references auth.users, tenant_id, portal text check in ('provider','patient','payer','clearinghouse','platform'), role_key text, party_id uuid null, display_name)`, `app.role`, `app.permission`, `app.role_permission`, `app.user_role`, `app.approval_limit (role_key, kind, max_amount numeric(12,2))`, `audit.audit_log (n bigserial, tenant_id, at, actor, portal, action, object_type, object_id, detail jsonb, prev_hash, hash)`, `audit.outbox_event (event_id, tenant_id, type, aggregate_id, payload jsonb, correlation_id, processed_at null)`, `app.idempotency_key (tenant_id, command, key, args_hash, result jsonb, primary key(tenant_id, command, key))`.
- Produces functions: `app.ctx() returns app.ctx_t` (`tenant_id, user_id, portal, role_key, party_id`, from `auth.jwt()` claims `tenant_id`, `portal`, `role_key`, `party_id`; raises `MR003` when missing); `app.authorize(p_permission text) returns void`; `audit.write(p_action text, p_object_type text, p_object_id uuid, p_detail jsonb) returns void` (computes `hash = md5(prev_hash || n || at || actor || action || object_id)` per tenant, matching the prototype's chain idea); `audit.verify_chain(p_tenant uuid) returns boolean`; `app.begin_cmd(p_cmd text, p_idem text, p_args jsonb) returns jsonb` (cached result, `null` if new, `MR005` if same key with different args); `app.finish_cmd(p_cmd text, p_idem text, p_args jsonb, p_result jsonb, p_event text, p_aggregate uuid) returns jsonb` (stores result, writes outbox row and audit row); `public.custom_access_token_hook(event jsonb) returns jsonb` adding `tenant_id, portal, role_key, party_id` from `app.app_user`; trigger `audit.no_modify()` blocking UPDATE/DELETE on `audit.audit_log`.

- [ ] **Step 1:** Tests first, in `tests/002_platform.sql`: `audit chain verifies after 3 writes`; `tampering with a row breaks verify_chain` (disable trigger inside the test via a superuser path, change `action`, expect `false`, restore); `update on audit_log refused`; `begin_cmd returns cached result for same key and args`; `begin_cmd refuses same key with different args (MR005)`; `ctx() raises MR003 with no claims`.
- [ ] **Step 2:** Run. Expected: FAIL (objects missing).
- [ ] **Step 3:** Implement the migration. RLS: `tenant_id = (auth.jwt()->>'tenant_id')::uuid` on all tenant tables; revoke all DML from `anon, authenticated` on `app`, `ref`, `audit`. Enable the access-token hook (Task 2 step 4 sets the Auth hook via `execute_sql` on `auth` config if available; otherwise document it as the one dashboard click and verify with a test token).
- [ ] **Step 4:** Apply, re-run tests (Expected: pass), run advisors.

### Task 3: Parties, payers, coverage, clearinghouse tables and RLS

**Files:**
- Create: `backend/supabase/migrations/003_parties_coverage.sql` (+ down), `backend/tests/003_rls_basic.sql`

**Interfaces:**
- Produces tables listed in spec §4 for Parties and Payers & coverage (`patient`, `patient_relationship`, `proxy_access`, `provider`, `payer`, `payer_plan`, `payer_config`, `coverage`, `eligibility_request`, `eligibility_response`, `clearinghouse`, `clearinghouse_connection`). `coverage` is dated (`effective_from, effective_to, source, verified_at`). `payer_config` holds the payer rules pack fields the prototype uses (timely filing days, appeal levels, records-request days).
- Produces RLS helper `app.in_scope(p_tenant uuid, p_payer uuid default null, p_clearinghouse uuid default null, p_patient uuid default null) returns boolean`: true for provider/platform callers of the same tenant; for `payer` callers only when `p_payer = ctx.party_id`; for `clearinghouse` only `p_clearinghouse = ctx.party_id`; for `patient` only `p_patient = ctx.party_id` or a patient reachable through an active `proxy_access`.

- [ ] **Step 1:** Write `tests/003_rls_basic.sql`: create two tenants and four fake users via `set local request.jwt.claims`; assertions `provider sees own tenant payers`, `provider sees zero rows of the other tenant`, `payer sees only coverage for its payer_id`, `patient sees only own patient row`, `proxy sees dependent only while proxy_access active`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement migration and policies using `app.in_scope`.
- [ ] **Step 4:** Apply, run tests (pass), advisors.

### Task 4: Claims, payments, recovery, patient billing, case tables and money invariants

**Files:**
- Create: `backend/supabase/migrations/004_money_case.sql` (+ down), `backend/tests/004_invariants.sql`

**Interfaces:**
- Produces the Claims, Payments & recovery, Patient billing and Case tables from spec §4 (`claim` with `original_claim_id`, `status`, `claim_service_line (billed numeric(12,2))`, `remittance`, `remittance_line`, `payment_posting (line_id, kind in ('payment','adjustment','patient_share','recoupment','reversal'), amount, reverses_posting_id)`, `deposit`, `deposit_allocation`, `denial (status, line_id, root_cause, carc, rarc)`, `denial_triage`, `appeal (parent_appeal_id, status, author_id, approver_id)`, `appeal_statement (text, source_ref null, unsupported boolean)`, `records_request`, `evidence_item`, `deadline`, `patient_responsibility`, `patient_statement`, `patient_payment`, `patient_dispute (status)`, `case`, `case_claim`, `case_status_history`, `reopen_event (trigger)`).
- Produces view `api.line_balance (line_id, billed, paid, adjusted, patient_share, patient_paid, open_amount)` and `api.case_blockers (case_id, blocker text)` listing every unmet closure condition (cash not reconciled, patient balance open, open patient dispute, open deposit allocation difference).
- Triggers: `enforce_transition` on `claim, denial, appeal, case`; `audit.no_modify`-style append-only on `payment_posting, deposit_allocation`; check constraint `replacement claim original_claim_id <> claim_id` (IV10); allocation total ≤ deposit amount via constraint trigger (IV06).

- [ ] **Step 1:** Tests: `posting update refused`, `posting delete refused`, `reversal row nets to zero in line_balance`, `allocation over deposit refused (IV06)`, `claim cannot be its own replacement (IV10)`, `billed = paid + adjusted + patient_share enforced when a line is marked balanced (IV01)`.
- [ ] **Step 2:** Run, expect FAIL. **Step 3:** Implement. **Step 4:** Apply, tests pass, advisors.

### Task 5: Workflow tables and the handover engine

**Files:**
- Create: `backend/supabase/migrations/005_workflow_handover.sql` (+ down), `backend/tests/005_handover.sql`

**Interfaces:**
- Produces: `app.work_queue`, `app.task (queue_id, subject_type, subject_id, status, due_at)`, `app.approval_request (kind, amount, requester_id, approver_id, status)`, `ref.handover_def (handover_id text pk, trigger_event text, ready_check text, hold_queue text)` seeded for **H13–H24 exactly as in spec §5.4** (read the table rows there; do not invent), `app.handover_event (handover_id, subject_id, status in ('passed','held','failed_check'), unique(handover_id, subject_id, source_event_id))`.
- Produces `app.process_outbox() returns integer` (processes unprocessed `audit.outbox_event` rows in `event_id` order per aggregate, runs the ready check for matching `handover_def`, inserts a `handover_event`, and on a failed check also inserts a `task` in the named queue; `unique` constraint plus `on conflict do nothing` makes replays create nothing, IV26/IV27) and a `pg_cron` job `process_outbox_every_minute`.
- Ready checks are implemented as `ref.check_<handover_id>(p_subject uuid) returns boolean` SQL functions (one per handover) so each is testable alone.

- [ ] **Step 1:** Tests: `passing check yields passed handover and no task`, `failing check yields held handover and exactly one task in the named queue (IV26)`, `processing the same outbox event twice creates no second handover or task (IV27)`, `events for one aggregate are processed in order`.
- [ ] **Step 2:** Run, FAIL. **Step 3:** Implement. **Step 4:** Apply, tests pass, advisors, confirm `select * from cron.job` lists the job.

### Task 6: Commands, part 1 — remittance, denial, claim

**Files:**
- Create: `backend/supabase/migrations/006_cmd_claims.sql` (+ down), `backend/tests/006_cmd_claims.sql`

**Interfaces:**
- Consumes: Task 2 `app.ctx/authorize/begin_cmd/finish_cmd`, Task 4 tables.
- Produces (all `api.cmd_*(p_idem text, p_args jsonb) returns jsonb`): `cmd_remittance_receive` (args `interchange_trace`, `payer_id`, `lines[]`; refuses a trace already seen, IV37), `cmd_remittance_post` (control totals must match, IV01; creates postings and a `denial` per denied line), `cmd_denial_triage` (stores `denial_triage`, root cause, recommended path, confidence), `cmd_denial_confirm_path` (reason required when overriding), `cmd_claim_create_replacement` (new `claim` row, `original_claim_id` set), `cmd_claim_release` (refuses with an active bill hold or a failed hard edit, IV11/IV12), `cmd_claim_submit`.
- Permission keys (seeded in Task 9 from the prototype's `PERM`): `tri, draft, send, release, post`.

- [ ] **Step 1:** Tests first, one per command plus: `duplicate 835 trace refused and no second posting`; `same idem key twice posts once`; `release refused while a hard edit failed (MR002)`; `confirm_path override without reason refused (MR005)`; `posting with mismatched control total refused`.
- [ ] **Step 2:** Run, FAIL. **Step 3:** Implement the commands. **Step 4:** Apply, tests pass, advisors.

### Task 7: Commands, part 2 — evidence, appeals, approvals, AI review

**Files:**
- Create: `backend/supabase/migrations/007_cmd_appeals.sql` (+ down), `backend/tests/007_cmd_appeals.sql`

**Interfaces:**
- Consumes: Task 6 conventions.
- Produces: `cmd_evidence_assemble`, `cmd_appeal_draft` (statements carry `source_ref` or are flagged `unsupported`), `cmd_appeal_request_approval` (refuses while any statement is unsupported, IV14), `cmd_approval_decide` (refuses author = approver, IV13, and amount above `approval_limit`), `cmd_appeal_file` (needs approved status and open deadline), `cmd_appeal_record_decision` (payer-portal command; next-level appeal row with `parent_appeal_id` when upheld and the rule allows), `cmd_records_request_respond`, `cmd_ai_review` (records `ai_review`; any external-effect command above checks that a review exists for the AI interaction, IV16).
- Also adds `ai_interaction` rows written by the `ai-standin` function (Task 12); here only the review gate is built.

- [ ] **Step 1:** Tests: `appeal with unsupported statement cannot request approval (IV14)`; `approving own appeal refused (IV13)`; `approval above limit refused`; `filing before approval refused`; `upheld decision opens next level only when payer_config allows`; `AI-drafted appeal without review cannot be filed (IV16)`.
- [ ] **Step 2:** Run, FAIL. **Step 3:** Implement. **Step 4:** Apply, tests pass, advisors.

### Task 8: Commands, part 3 — cash, patient billing, write-off, case closure

**Files:**
- Create: `backend/supabase/migrations/008_cmd_cash_case.sql` (+ down), `backend/tests/008_cmd_cash_case.sql`

**Interfaces:**
- Produces: `cmd_posting_apply_payment`, `cmd_posting_reverse`, `cmd_deposit_allocate` (total ≤ deposit, IV06), `cmd_patient_payment_apply`, `cmd_patient_dispute_open`, `cmd_patient_dispute_resolve`, `cmd_writeoff_request`, `cmd_writeoff_post` (approval and open-rights check, IV32), `cmd_case_close` (refuses unless `api.case_blockers` is empty, IV07/IV08), `cmd_case_reopen` (needs a `reopen_event` trigger such as a recoupment, IV09).
- Amount validation shared helper `app.valid_amount(p_amount numeric, p_max numeric) returns numeric` (refuses ≤ 0, more than 2 decimals, > max with `MR005`).

- [ ] **Step 1:** Tests: `zero, negative and 3-decimal amounts refused`; `overpayment above billed refused`; `reversal restores open amount`; `patient payment clears the patient-balance blocker`; `open dispute blocks close`; `close twice refused`; `reopen of an open case refused`; `recoupment reopens a reconciled case with reason (CLM-24207 shape)`.
- [ ] **Step 2:** Run, FAIL. **Step 3:** Implement. **Step 4:** Apply, tests pass, advisors.

### Task 9: Reference seed — roles, permissions, users, payers, rule pack

**Files:**
- Create: `backend/seed/010_reference.sql`, `backend/tools/make-users.ps1`, `backend/seed/test-users.local.md` (git-ignored)

**Interfaces:**
- Produces: one tenant `Meridian Demo Health`; the **48 roles** with their portal (read names, portals, `PERM` keys and approval limits from `index.html`: `PERM` at about line 351 and the persona list); permissions and `role_permission`; 13 payers with `payer_config` (from Part 3 payer behavior sheet in `Meridian_Platform_Plan_Part3_TestCases_and_SyntheticData.xlsx`, read with PowerShell zip/XML since no Python); clearinghouses and connections; `ref.rule_pack`/`rule` rows for deadlines and appeal levels.
- `make-users.ps1` generates one random password, writes it to `test-users.local.md`, and emits SQL that creates `auth.users` + `auth.identities` rows (bcrypt via `crypt(pw, gen_salt('bf'))`) for one synthetic user per role at `<role_key>@meridian.test`, and fills `app.app_user`.

- [ ] **Step 1:** Test `tests/010_reference.sql`: `48 roles seeded`, `every role has a portal`, `every app_user has an auth.users row`, `13 payers with configs`, `ps verify: git check-ignore backend/seed/test-users.local.md` succeeds.
- [ ] **Step 2:** Run, FAIL. **Step 3:** Build and run the seed through `execute_sql` (pass the generated SQL; do not echo the password). **Step 4:** Tests pass.

### Task 10: Case seed — the 15 synthetic cases

**Files:**
- Create: `backend/tools/export-cases.ps1`, `backend/seed/cases.json` (generated), `backend/seed/020_cases.sql` (generated), `backend/tests/020_cases.sql`

**Interfaces:**
- Consumes: Task 9 payers and patients; Task 6–8 commands (the seed replays the history through commands, so each case's stage is reproducible from rows).
- Produces: patients, coverages, 15 claims with service lines and cases, with the prototype's start stage per case (CLM-24017, 24033, 24051, 24068, 23988, 24201–24210) reached by replaying commands as the seed user for that role.

- [ ] **Step 1:** Serve `index.html` locally (`serve.ps1` pattern from the earlier scratchpad: HttpListener on a free port), open it in the browser pane, and dump `CL`, `IDS`, `CLS`, `S.st`, `S.tri`, `S.ev`, `S.stm`, `S.pat`, `S.closed`, `S.reopen` and the `NEWC` case parameters to `cases.json` with the javascript tool. Stop the server.
- [ ] **Step 2:** Tests: `15 cases exist`; `each case's derived stage equals the prototype stage` (a SQL function `api.case_stage(case_id) returns int` derived from rows, 0–8 matching `STAGES`); `billed = paid + adjusted + patient share on every closed line`; `CLM-23988 closed and reconciled`; `CLM-24207 reopened by a 420.00 recoupment`; `CLM-24206 has no authorization number`; `audit chain verifies for the tenant`.
- [ ] **Step 3:** Run, FAIL. **Step 4:** Implement `export-cases.ps1` (JSON → SQL calls to `api.cmd_*` as each role) and run the seed. **Step 5:** Tests pass, advisors.

### Task 11: Scenario, scope and RLS test suites

**Files:**
- Create: `backend/tests/100_scenarios.sql`, `backend/tests/110_access.sql`

**Interfaces:**
- Consumes: everything above; calls commands under `set local request.jwt.claims` for the relevant seeded user.

- [ ] **Step 1:** Scenarios, each its own `do` block with assertions: corrected claim path; evidence request with retro-authorization supplying the number on CLM-24206; appeal with unsupported statement refused, fixed, approved by a different user, filed, decided; duplicate 835 refused; coverage ended → self-pay on CLM-24204; recoupment reopens CLM-24207; patient payment clears the blocker on CLM-24202; dispute blocks close on CLM-24204.
- [ ] **Step 2:** Access suite: for every portal's representative user, `select count(*)` on each `app` table returns 0 outside scope; each portal calling a command it lacks returns `MR003`; guessing a foreign-tenant claim id returns `MR004` and an identical message to a nonexistent id; anonymous calls fail.
- [ ] **Step 3:** Run both. Expected: all pass. Fix defects in the owning migration (new migration number, never edit an applied one) and re-run the earlier tests too.

### Task 12: Edge Functions

**Files:**
- Create: `backend/supabase/functions/api/index.ts`, `backend/supabase/functions/ai-standin/index.ts`, `backend/tests/120_edge.md` (the curl checks and results)

**Interfaces:**
- `api`: `POST /functions/v1/api/<command>` with header `Authorization: Bearer <user JWT>` and `Idempotency-Key`; body is the `p_args` JSON; calls `rpc('cmd_<command with dots→underscores>')` using a client built from the caller's JWT (never the service role); maps `MR001`–`MR005` to HTTP 409, 422, 403, 404, 400 with body `{error:{code, rule, object, todo}}`; success `200 {ok:true,...}`; `verify_jwt` on.
- `ai-standin`: `POST` with `{task: 'triage_denial'|'draft_appeal'|'assemble_evidence', case_id}`; returns the spec §7.3 shape (`recommendation, confidence, reasons[], sources[], model_version: 'simulated-1', label: 'Simulated'`), writes an `ai_interaction` row through a command, never calls an external model.

- [ ] **Step 1:** Define checks in `120_edge.md`: unauthenticated request → 401; valid provider JWT triage → 200; payer JWT calling a provider command → 403; repeated `Idempotency-Key` → identical body, one row; `ai-standin` output includes `label: 'Simulated'`.
- [ ] **Step 2:** Deploy with `deploy_edge_function` (both). **Step 3:** Obtain a user JWT by signing in a seeded user (password from the local file) and run the checks with `curl` from PowerShell; record actual results in the file. Expected: every line matches; otherwise fix and redeploy.
- [ ] **Step 4:** `get_edge_function` for both and `query_logs` (edge-function) to confirm no errors.

### Task 13: Hardening, documentation, release

**Files:**
- Modify: `README.md` (add "Back end" section and link), `CHANGELOG.md` (v8.0.0 entry with rollback), `backend/README.md` (setup, commands list, how to run tests, how to rebuild); process maps unchanged unless a handover behavior differs (then update `process-maps.html`, and republish its artifact per the standing rule).

- [ ] **Step 1:** Run all test files in order (`001` … `120`). Expected: all pass. Run `get_advisors` security and performance; every finding fixed or documented with a reason.
- [ ] **Step 2:** Run the full audit check: `select audit.verify_chain(<tenant>)` returns true; run `generate_typescript_types` and save to `backend/types.ts` for the later front-end release.
- [ ] **Step 3:** Update the docs above; check `git status` shows no `*.local.md` or key material staged.
- [ ] **Step 4:** Show the user the summary (tables, commands, test counts, advisor result). **Only after the user says to commit:** `git add backend README.md CHANGELOG.md docs`, commit `Back end release 1: Supabase schema, commands, RLS, seed (v8.0.0)` with the attribution line, tag `v8.0.0`, push main and tags.
