-- Task 4 tests: claims, payments & recovery, patient billing and case tables; money invariants
-- (IV01, IV04, IV06, IV10), state-machine triggers, case history, line_balance / case_blockers views, RLS.
-- Run with execute_sql (whole file in one call). Starts by clearing tests.result.
-- All fixtures live in a sub-transaction rolled back at the end of the DO block, so nothing remains.
select tests.begin();

create or replace function pg_temp._add(r jsonb, m text, p boolean) returns jsonb
language sql as $$ select r || jsonb_build_array(jsonb_build_object('m', m, 'p', coalesce(p, false))) $$;

-- Runs one statement and returns 'ok' or the SQLSTATE it raised.
create or replace function pg_temp._try(q text) returns text
language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- Same, but as the function owner (stands in for a SECURITY DEFINER api.cmd_* command).
create or replace function pg_temp._as_cmd(q text) returns text
language plpgsql security definer as $$
begin
  execute q;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- Runs a count query under the current role (so RLS applies) and returns the number.
create or replace function pg_temp._n(q text) returns bigint
language plpgsql as $$
declare n bigint;
begin
  execute q into n;
  return n;
end $$;

create or replace function pg_temp._claims(u uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    case when u is null then '{}' else json_build_object('sub', u, 'role', 'authenticated')::text end, true);
end $$;

do $$
declare
  r jsonb := '[]'::jsonb;
  m text;
  res text;
  tbl text;
  n bigint;
  new_tables text[] := array['claim','claim_service_line','claim_diagnosis','claim_edit_result','edi_interchange','claim_ack',
    'remittance','remittance_line','payment_posting','deposit','deposit_allocation','denial','denial_triage','root_cause',
    'records_request','evidence_item','appeal','appeal_statement','deadline',
    'patient_responsibility','patient_statement','patient_payment','patient_dispute',
    'case','case_claim','case_status_history','reopen_event'];
  t1 uuid := app.uuid_v7(); t2 uuid := app.uuid_v7();
  u_prov uuid := gen_random_uuid(); u_appr uuid := gen_random_uuid(); u_prov2 uuid := gen_random_uuid();
  u_payer uuid := gen_random_uuid(); u_pat uuid := gen_random_uuid(); u_prox uuid := gen_random_uuid(); u_clr uuid := gen_random_uuid();
  prv uuid := app.uuid_v7();
  pat_a uuid := app.uuid_v7(); pat_b uuid := app.uuid_v7(); pat_p uuid := app.uuid_v7(); pat_d uuid := app.uuid_v7(); pat_x uuid := app.uuid_v7();
  pay_a uuid := app.uuid_v7(); pay_b uuid := app.uuid_v7(); pay_c uuid := app.uuid_v7();
  ch_a uuid := app.uuid_v7(); ch_b uuid := app.uuid_v7();
  cov_a uuid := app.uuid_v7();
  cl_a1 uuid := app.uuid_v7(); cl_a2 uuid := app.uuid_v7(); cl_b1 uuid := app.uuid_v7(); cl_d uuid := app.uuid_v7(); cl_x uuid := app.uuid_v7();
  cl_r uuid := app.uuid_v7();
  ln1 uuid := app.uuid_v7(); ln2 uuid := app.uuid_v7(); ln3 uuid := app.uuid_v7(); ln_d uuid := app.uuid_v7(); ln_x uuid := app.uuid_v7();
  ei_a uuid := app.uuid_v7(); ei_b uuid := app.uuid_v7(); ei_ack_a uuid := app.uuid_v7(); ei_ack_b uuid := app.uuid_v7();
  rem_a uuid := app.uuid_v7(); rem_b uuid := app.uuid_v7();
  rl_a uuid := app.uuid_v7(); rl_b uuid := app.uuid_v7();
  den_a uuid := app.uuid_v7(); den_b uuid := app.uuid_v7();
  ap_a1 uuid := app.uuid_v7(); ap_a2 uuid := app.uuid_v7(); ap_b uuid := app.uuid_v7();
  resp_a uuid := app.uuid_v7(); resp_b uuid := app.uuid_v7(); resp_d uuid := app.uuid_v7();
  cs_a uuid := app.uuid_v7(); cs_b uuid := app.uuid_v7();
  dp_a uuid := app.uuid_v7();
  dep_a uuid := app.uuid_v7();
  pp1 uuid := app.uuid_v7(); pp2 uuid := app.uuid_v7(); pp_rev1 uuid := app.uuid_v7(); pp_rc uuid := app.uuid_v7();
  al1 uuid := app.uuid_v7(); al2 uuid := app.uuid_v7();
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner, no claims)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values
      ('t_prov', 'Provider', 'provider'), ('t_payer', 'Payer', 'payer'),
      ('t_pat', 'Patient', 'patient'), ('t_clr', 'Clearinghouse', 'clearinghouse');
    insert into auth.users (id, aud, role, email) values
      (u_prov,  'authenticated', 'authenticated', 'p1@meridian.test'),
      (u_appr,  'authenticated', 'authenticated', 'ap@meridian.test'),
      (u_prov2, 'authenticated', 'authenticated', 'p2@meridian.test'),
      (u_payer, 'authenticated', 'authenticated', 'py@meridian.test'),
      (u_pat,   'authenticated', 'authenticated', 'pt@meridian.test'),
      (u_prox,  'authenticated', 'authenticated', 'px@meridian.test'),
      (u_clr,   'authenticated', 'authenticated', 'ch@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, party_id, display_name) values
      (u_prov,  t1, 'provider',      't_prov',  null,  'Prov One'),
      (u_appr,  t1, 'provider',      't_prov',  null,  'Approver One'),
      (u_prov2, t2, 'provider',      't_prov',  null,  'Prov Two'),
      (u_payer, t1, 'payer',         't_payer', pay_a, 'Payer A user'),
      (u_pat,   t1, 'patient',       't_pat',   pat_a, 'Patient A user'),
      (u_prox,  t1, 'patient',       't_pat',   pat_p, 'Proxy user'),
      (u_clr,   t1, 'clearinghouse', 't_clr',   ch_a,  'Clearinghouse A user');

    insert into app.provider (provider_id, tenant_id, npi, name) values (prv, t1, '1000000001', 'Dr One');
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values
      (pat_a, t1, 'MRN-A', 'Ada',  'Alpha', date '1980-01-01'),
      (pat_b, t1, 'MRN-B', 'Ben',  'Beta',  date '1981-02-02'),
      (pat_p, t1, 'MRN-P', 'Pia',  'Proxy', date '1975-05-05'),
      (pat_d, t1, 'MRN-D', 'Dan',  'Proxy', date '2012-09-09'),
      (pat_x, t2, 'MRN-X', 'Xena', 'Other', date '1990-03-03');
    insert into app.proxy_access (tenant_id, patient_id, proxy_patient_id, scope, active, effective_from) values
      (t1, pat_d, pat_p, 'full', true, current_date - 30);
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values
      (pay_a, t1, 'Payer A', 'PA01', 'commercial'),
      (pay_b, t1, 'Payer B', 'PB01', 'medicare'),
      (pay_c, t2, 'Payer C', 'PC01', 'commercial');
    insert into app.clearinghouse (clearinghouse_id, tenant_id, name, clearinghouse_code) values
      (ch_a, t1, 'CH A', 'CHA'), (ch_b, t1, 'CH B', 'CHB');
    insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values
      (cov_a, t1, pat_a, pay_a, 'MEM-A', date '2026-01-01', 'eligibility');

    -- claims: cl_a2 is an unsubmitted draft (hidden from the payer)
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status) values
      (cl_a1, t1, 'CLM-A1', pat_a, prv, pay_a, cov_a, 'accepted'),
      (cl_a2, t1, 'CLM-A2', pat_a, prv, pay_a, cov_a, 'draft'),
      (cl_b1, t1, 'CLM-B1', pat_b, prv, pay_b, null,  'accepted'),
      (cl_d,  t1, 'CLM-D1', pat_d, prv, pay_b, null,  'accepted');
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, payer_id, status) values
      (cl_x, t2, 'CLM-X1', pat_x, pay_c, 'accepted');
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (ln1,  t1, cl_a1, 1, '99213', 100.00),
      (ln2,  t1, cl_b1, 1, '99214', 200.00),
      (ln3,  t1, cl_a2, 1, '99212',  50.00),
      (ln_d, t1, cl_d,  1, '99211',  30.00),
      (ln_x, t2, cl_x,  1, '99211',  10.00);
    insert into app.claim_diagnosis (tenant_id, claim_id, sequence, icd10_code) values
      (t1, cl_a1, 1, 'Z00.00'), (t1, cl_b1, 1, 'I10');
    insert into app.claim_edit_result (tenant_id, claim_id, line_id, rule_code, severity, passed) values
      (t1, cl_a1, ln1, 'NCCI-01', 'hard', true);
    insert into app.edi_interchange (edi_interchange_id, tenant_id, clearinghouse_id, payer_id, direction, transaction_set, trace_number) values
      (ei_a,     t1, ch_a, pay_a, 'inbound', '835', 'TRN-1'),
      (ei_ack_a, t1, ch_a, pay_a, 'inbound', '999', 'ACK-1'),
      (ei_b,     t1, ch_b, pay_b, 'inbound', '835', 'TRN-2'),
      (ei_ack_b, t1, ch_b, pay_b, 'inbound', '999', 'ACK-2');
    insert into app.claim_ack (tenant_id, edi_interchange_id, claim_id, ack_type, status) values
      (t1, ei_ack_a, cl_a1, '999', 'accepted'), (t1, ei_ack_b, cl_b1, '999', 'accepted');
    insert into app.remittance (remittance_id, tenant_id, payer_id, edi_interchange_id, trace_number, payment_method, payment_amount) values
      (rem_a, t1, pay_a, ei_a, 'TRN-1', 'eft', 70.00),
      (rem_b, t1, pay_b, ei_b, 'TRN-2', 'eft', 150.00);
    insert into app.remittance_line (remittance_line_id, tenant_id, remittance_id, claim_id, line_id, billed, paid, adjusted, patient_share, carc) values
      (rl_a, t1, rem_a, cl_a1, ln1, 100.00, 70.00, 10.00, 20.00, '45'),
      (rl_b, t1, rem_b, cl_b1, ln2, 200.00, 150.00, 0, 50.00, '1');
    insert into app.root_cause (tenant_id, code, label, category) values (t1, 'AUTH', 'Missing authorization', 'front_end');
    insert into app.denial (denial_id, tenant_id, claim_id, line_id, remittance_line_id, carc, rarc, denied_amount, root_cause) values
      (den_a, t1, cl_a1, ln1, rl_a, '197', 'N54', 30.00, 'AUTH'),
      (den_b, t1, cl_b1, ln2, rl_b, '50', null, 50.00, null);
    insert into app.denial_triage (tenant_id, denial_id, root_cause, recommended_path, confidence) values
      (t1, den_a, 'AUTH', 'appeal', 0.820);
    insert into app.records_request (tenant_id, claim_id, denial_id, requested_items) values
      (t1, cl_a1, den_a, 'Operative note'), (t1, cl_b1, den_b, 'Visit note');
    insert into app.appeal (appeal_id, tenant_id, claim_id, denial_id, parent_appeal_id, level, status, author_id, amount) values
      (ap_a1, t1, cl_a1, den_a, null,  1, 'filed',    u_prov, 30.00),
      (ap_a2, t1, cl_a1, den_a, ap_a1, 2, 'drafting', u_prov, 30.00),
      (ap_b,  t1, cl_b1, den_b, null,  1, 'filed',    u_prov, 50.00);
    insert into app.appeal_statement (tenant_id, appeal_id, seq, text, source_ref, unsupported) values
      (t1, ap_a2, 1, 'Authorization was on file before the visit.', 'evidence:auth-letter', false);
    insert into app.evidence_item (tenant_id, claim_id, denial_id, appeal_id, kind, title) values
      (t1, cl_a1, den_a, ap_a1, 'authorization', 'Auth letter (synthetic)');
    insert into app.deadline (tenant_id, subject_type, subject_id, kind, due_at) values
      (t1, 'appeal', ap_a1, 'appeal_filing', now() + interval '30 days');
    insert into app.patient_responsibility (patient_responsibility_id, tenant_id, patient_id, claim_id, line_id, amount, reason) values
      (resp_a, t1, pat_a, cl_a1, ln1,  20.00, 'coinsurance'),
      (resp_b, t1, pat_b, cl_b1, ln2,  50.00, 'deductible'),
      (resp_d, t1, pat_d, cl_d,  ln_d, 30.00, 'deductible');
    insert into app.patient_statement (tenant_id, patient_id, amount_due) values
      (t1, pat_a, 20.00), (t1, pat_b, 50.00), (t1, pat_d, 30.00);
    insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method) values
      (t1, pat_a, resp_a, 5.00, 'portal'), (t1, pat_b, resp_b, 10.00, 'card');
    insert into app."case" (case_id, tenant_id, case_number, patient_id) values
      (cs_a, t1, 'CASE-A', pat_a), (cs_b, t1, 'CASE-B', pat_b);
    insert into app.case_claim (tenant_id, case_id, claim_id) values (t1, cs_a, cl_a1), (t1, cs_b, cl_b1);
    insert into app.patient_dispute (patient_dispute_id, tenant_id, patient_id, claim_id, reason) values
      (dp_a, t1, pat_a, cl_a1, 'I already paid at the front desk');
    insert into app.patient_dispute (tenant_id, patient_id, case_id, reason) values
      (t1, pat_b, cs_b, 'Wrong amount');
    insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values
      (dep_a, t1, pay_a, 'BANK-1', 100.00);
    insert into app.reopen_event (tenant_id, case_id, trigger, source_type, source_id, reason) values
      (t1, cs_a, 'recoupment', 'payment_posting', gen_random_uuid(), 'Synthetic recoupment');

    -- ---------------------------------------------------------------- RLS: provider (own tenant only)
    perform pg_temp._claims(u_prov);
    set local role authenticated;
    r := pg_temp._add(r, 'provider sees all own-tenant claims, lines, cases',
      pg_temp._n('select count(*) from app.claim') = 4 and pg_temp._n('select count(*) from app.claim_service_line') = 4
      and pg_temp._n('select count(*) from app."case"') = 2 and pg_temp._n('select count(*) from app.appeal') = 3);
    r := pg_temp._add(r, 'provider reads api.line_balance and api.case_blockers',
      pg_temp._n(format('select count(*) from api.line_balance where line_id = %L', ln1)) = 1
      and pg_temp._n(format('select count(*) from api.case_blockers where case_id = %L', cs_a)) > 0);
    n := 0;
    foreach tbl in array new_tables loop
      n := n + pg_temp._n(format('select count(*) from app.%I where tenant_id = %L', tbl, t2));
    end loop;
    r := pg_temp._add(r, 'provider sees zero rows of the other tenant (all 27 tables)', n = 0);
    r := pg_temp._add(r, 'authenticated cannot insert a posting (42501)',
      pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount) values (%L, %L, 'payment', 1)$q$, t1, ln1)) = '42501');
    r := pg_temp._add(r, 'authenticated cannot update a claim (42501)',
      pg_temp._try(format($q$update app.claim set hold = true, hold_reason = 'x' where claim_id = %L$q$, cl_a1)) = '42501');
    r := pg_temp._add(r, 'authenticated cannot delete a case (42501)',
      pg_temp._try(format($q$delete from app."case" where case_id = %L$q$, cs_a)) = '42501');
    reset role;

    perform pg_temp._claims(u_prov2);
    set local role authenticated;
    r := pg_temp._add(r, 'second tenant provider sees only its own claim and nothing of tenant one',
      pg_temp._n('select count(*) from app.claim') = 1
      and pg_temp._n(format('select count(*) from app.claim where tenant_id = %L', t1)) = 0
      and pg_temp._n(format('select count(*) from api.line_balance where line_id = %L', ln1)) = 0);
    reset role;

    -- ---------------------------------------------------------------- RLS: payer sees only its payer's claims
    perform pg_temp._claims(u_payer);
    set local role authenticated;
    r := pg_temp._add(r, 'a payer sees only its payer''s claims (submitted ones; not drafts, not other payers)',
      pg_temp._n('select count(*) from app.claim') = 1
      and pg_temp._n(format('select count(*) from app.claim where claim_id = %L', cl_a1)) = 1
      and pg_temp._n(format('select count(*) from app.claim where payer_id <> %L', pay_a)) = 0
      and pg_temp._n(format('select count(*) from app.claim where claim_id = %L', cl_a2)) = 0);
    r := pg_temp._add(r, 'payer sees lines and diagnoses of its claims only',
      pg_temp._n('select count(*) from app.claim_service_line') = 1 and pg_temp._n('select count(*) from app.claim_diagnosis') = 1);
    r := pg_temp._add(r, 'payer sees only its remittances, remittance lines, denials, records requests',
      pg_temp._n('select count(*) from app.remittance') = 1 and pg_temp._n(format('select count(*) from app.remittance where payer_id <> %L', pay_a)) = 0
      and pg_temp._n('select count(*) from app.remittance_line') = 1
      and pg_temp._n('select count(*) from app.denial') = 1 and pg_temp._n(format('select count(*) from app.denial where denial_id = %L', den_a)) = 1
      and pg_temp._n('select count(*) from app.records_request') = 1);
    r := pg_temp._add(r, 'payer sees only filed appeals of its claims (not drafts, not other payers)',
      pg_temp._n('select count(*) from app.appeal') = 1 and pg_temp._n(format('select count(*) from app.appeal where appeal_id = %L', ap_a1)) = 1);
    r := pg_temp._add(r, 'payer sees no internal rows (postings, deposits, triage, edits, statements, evidence, cases, patient billing, interchanges)',
      pg_temp._n('select count(*) from app.payment_posting') + pg_temp._n('select count(*) from app.deposit')
      + pg_temp._n('select count(*) from app.denial_triage') + pg_temp._n('select count(*) from app.claim_edit_result')
      + pg_temp._n('select count(*) from app.appeal_statement') + pg_temp._n('select count(*) from app.evidence_item')
      + pg_temp._n('select count(*) from app."case"') + pg_temp._n('select count(*) from app.patient_responsibility')
      + pg_temp._n('select count(*) from app.patient_dispute') + pg_temp._n('select count(*) from app.edi_interchange')
      + pg_temp._n('select count(*) from app.claim_ack') + pg_temp._n('select count(*) from app.deadline') = 0);
    reset role;

    -- ---------------------------------------------------------------- RLS: patient sees only own billing rows
    perform pg_temp._claims(u_pat);
    set local role authenticated;
    r := pg_temp._add(r, 'a patient sees only own responsibility',
      pg_temp._n('select count(*) from app.patient_responsibility') = 1
      and pg_temp._n(format('select count(*) from app.patient_responsibility where patient_responsibility_id = %L', resp_a)) = 1);
    r := pg_temp._add(r, 'patient sees only own statements, payments, disputes',
      pg_temp._n('select count(*) from app.patient_statement') = 1 and pg_temp._n('select count(*) from app.patient_payment') = 1
      and pg_temp._n('select count(*) from app.patient_dispute') = 1
      and pg_temp._n(format('select count(*) from app.patient_statement where patient_id <> %L', pat_a)) = 0);
    r := pg_temp._add(r, 'patient sees no claims, cases, remittances, postings or line balances',
      pg_temp._n('select count(*) from app.claim') + pg_temp._n('select count(*) from app."case"')
      + pg_temp._n('select count(*) from app.remittance') + pg_temp._n('select count(*) from app.payment_posting')
      + pg_temp._n('select count(*) from api.line_balance') + pg_temp._n('select count(*) from api.case_blockers') = 0);
    reset role;

    perform pg_temp._claims(u_prox);
    set local role authenticated;
    r := pg_temp._add(r, 'proxy sees the dependent''s responsibility and statement through active proxy access',
      pg_temp._n('select count(*) from app.patient_responsibility') = 1
      and pg_temp._n(format('select count(*) from app.patient_responsibility where patient_id = %L', pat_d)) = 1
      and pg_temp._n('select count(*) from app.patient_statement') = 1);
    reset role;

    -- ---------------------------------------------------------------- RLS: clearinghouse only its interchanges
    perform pg_temp._claims(u_clr);
    set local role authenticated;
    r := pg_temp._add(r, 'a clearinghouse sees only its interchange rows',
      pg_temp._n('select count(*) from app.edi_interchange') = 2
      and pg_temp._n(format('select count(*) from app.edi_interchange where clearinghouse_id <> %L', ch_a)) = 0);
    r := pg_temp._add(r, 'clearinghouse sees only acks on its interchanges',
      pg_temp._n('select count(*) from app.claim_ack') = 1);
    r := pg_temp._add(r, 'clearinghouse sees no claims, remittances, denials, patient billing',
      pg_temp._n('select count(*) from app.claim') + pg_temp._n('select count(*) from app.remittance')
      + pg_temp._n('select count(*) from app.denial') + pg_temp._n('select count(*) from app.patient_responsibility') = 0);
    reset role;

    -- ---------------------------------------------------------------- anon
    perform pg_temp._claims(null);
    set local role anon;
    r := pg_temp._add(r, 'anon cannot read api.line_balance, api.case_blockers, app.claim (42501)',
      pg_temp._try('select count(*) from api.line_balance') = '42501'
      and pg_temp._try('select count(*) from api.case_blockers') = '42501'
      and pg_temp._try('select count(*) from app.claim') = '42501');
    reset role;

    -- ---------------------------------------------------------------- IV04: postings are append-only
    insert into app.payment_posting (payment_posting_id, tenant_id, line_id, remittance_line_id, kind, amount)
      values (pp1, t1, ln1, rl_a, 'payment', 60.00);
    r := pg_temp._add(r, 'posting insert allowed and shows in line_balance',
      (select paid = 60.00 and open_amount = 40.00 from api.line_balance where line_id = ln1));
    r := pg_temp._add(r, 'posting update refused',
      pg_temp._try(format('update app.payment_posting set amount = 1 where payment_posting_id = %L', pp1)) = 'MR002');
    r := pg_temp._add(r, 'posting delete refused',
      pg_temp._try(format('delete from app.payment_posting where payment_posting_id = %L', pp1)) = 'MR002');
    r := pg_temp._add(r, 'posting truncate refused', pg_temp._try('truncate app.payment_posting') = 'MR002');
    r := pg_temp._add(r, 'refused changes left the posting intact',
      (select amount = 60.00 from app.payment_posting where payment_posting_id = pp1));

    -- ---------------------------------------------------------------- reversals
    insert into app.payment_posting (payment_posting_id, tenant_id, line_id, kind, amount, reverses_posting_id, reason)
      values (pp_rev1, t1, ln1, 'reversal', 60.00, pp1, 'Posted to wrong line');
    r := pg_temp._add(r, 'reversal row nets to zero in line_balance',
      (select paid = 0 and adjusted = 0 and patient_share = 0 and open_amount = 100.00 from api.line_balance where line_id = ln1));
    r := pg_temp._add(r, 'a posting cannot be reversed twice (MR002)',
      pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount, reverses_posting_id) values (%L, %L, 'reversal', 60.00, %L)$q$, t1, ln1, pp1)) = 'MR002');
    insert into app.payment_posting (payment_posting_id, tenant_id, line_id, kind, amount) values (pp2, t1, ln1, 'payment', 70.00);
    r := pg_temp._add(r, 'reversal with a different amount refused (MR005)',
      pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount, reverses_posting_id) values (%L, %L, 'reversal', 50.00, %L)$q$, t1, ln1, pp2)) = 'MR005');
    r := pg_temp._add(r, 'reversal on a different line refused (MR005)',
      pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount, reverses_posting_id) values (%L, %L, 'reversal', 70.00, %L)$q$, t1, ln2, pp2)) = 'MR005');
    r := pg_temp._add(r, 'reversal of a reversal refused (MR005)',
      pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount, reverses_posting_id) values (%L, %L, 'reversal', 60.00, %L)$q$, t1, ln1, pp_rev1)) = 'MR005');
    r := pg_temp._add(r, 'reversal without reverses_posting_id refused, payment with one refused (23514)',
      pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount) values (%L, %L, 'reversal', 70.00)$q$, t1, ln1)) = '23514'
      and pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount, reverses_posting_id) values (%L, %L, 'payment', 70.00, %L)$q$, t1, ln1, pp2)) = '23514');
    r := pg_temp._add(r, 'zero and negative posting amounts refused (23514)',
      pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount) values (%L, %L, 'payment', 0)$q$, t1, ln1)) = '23514'
      and pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount) values (%L, %L, 'adjustment', -5)$q$, t1, ln1)) = '23514');
    r := pg_temp._add(r, 'unknown posting kind refused (23514)',
      pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount) values (%L, %L, 'bonus', 1)$q$, t1, ln1)) = '23514');
    r := pg_temp._add(r, 'posting with a tenant different from its line refused (MR005)',
      pg_temp._try(format($q$insert into app.payment_posting (tenant_id, line_id, kind, amount) values (%L, %L, 'payment', 1)$q$, t2, ln1)) = 'MR005');

    -- ---------------------------------------------------------------- IV01: balanced flag
    r := pg_temp._add(r, 'billed = paid + adjusted + patient_share enforced when a line is marked balanced (IV01): refused at 70 of 100',
      pg_temp._try(format('update app.claim_service_line set balanced = true where claim_service_line_id = %L', ln1)) = 'MR002'
      and (select not balanced from app.claim_service_line where claim_service_line_id = ln1));
    insert into app.payment_posting (tenant_id, line_id, kind, amount) values
      (t1, ln1, 'adjustment', 10.00), (t1, ln1, 'patient_share', 20.00);
    -- (a subquery in the same statement as a volatile _try() would read the pre-update snapshot, so check separately)
    res := pg_temp._try(format('update app.claim_service_line set balanced = true where claim_service_line_id = %L', ln1));
    r := pg_temp._add(r, 'billed = paid + adjusted + patient_share enforced when a line is marked balanced (IV01): allowed at 70 + 10 + 20',
      res = 'ok' and (select balanced and balanced_at is not null from app.claim_service_line where claim_service_line_id = ln1));
    r := pg_temp._add(r, 'line_balance shows paid, adjusted, patient_share, patient_paid, open 0',
      (select billed = 100.00 and paid = 70.00 and adjusted = 10.00 and patient_share = 20.00 and patient_paid = 5.00
              and open_amount = 0 and balanced from api.line_balance where line_id = ln1));
    r := pg_temp._add(r, 'IV01: changing billed on a balanced line so it no longer balances is refused',
      pg_temp._try(format('update app.claim_service_line set billed = 120.00 where claim_service_line_id = %L', ln1)) = 'MR002');
    r := pg_temp._add(r, 'IV01: a new line inserted already balanced with no postings is refused',
      pg_temp._try(format($q$insert into app.claim_service_line (tenant_id, claim_id, line_number, procedure_code, billed, balanced) values (%L, %L, 2, '99213', 10.00, true)$q$, t1, cl_a1)) = 'MR002');
    insert into app.payment_posting (payment_posting_id, tenant_id, line_id, kind, amount, reason) values (pp_rc, t1, ln1, 'recoupment', 15.00, 'Payer recoupment');
    r := pg_temp._add(r, 'recoupment is a negative payment and clears the balanced flag',
      (select paid = 55.00 and open_amount = 15.00 and not balanced from api.line_balance where line_id = ln1)
      and (select balanced_at is null from app.claim_service_line where claim_service_line_id = ln1));
    insert into app.payment_posting (tenant_id, line_id, kind, amount, reverses_posting_id) values (t1, ln1, 'reversal', 15.00, pp_rc);
    r := pg_temp._add(r, 'reversing a recoupment restores paid; line can be re-balanced',
      (select paid = 70.00 and open_amount = 0 from api.line_balance where line_id = ln1)
      and pg_temp._try(format('update app.claim_service_line set balanced = true where claim_service_line_id = %L', ln1)) = 'ok');

    -- ---------------------------------------------------------------- IV06: allocation <= deposit; allocations append-only
    insert into app.deposit_allocation (deposit_allocation_id, tenant_id, deposit_id, remittance_line_id, line_id, amount)
      values (al1, t1, dep_a, rl_a, ln1, 70.00);
    r := pg_temp._add(r, 'allocation within the deposit amount allowed',
      (select sum(amount) = 70.00 from app.deposit_allocation where deposit_id = dep_a));
    r := pg_temp._add(r, 'allocation over deposit refused (IV06)',
      pg_temp._try(format($q$insert into app.deposit_allocation (tenant_id, deposit_id, line_id, amount) values (%L, %L, %L, 40.00)$q$, t1, dep_a, ln1)) = 'MR002'
      and (select sum(amount) = 70.00 from app.deposit_allocation where deposit_id = dep_a));
    r := pg_temp._add(r, 'allocation update refused (IV04)',
      pg_temp._try(format('update app.deposit_allocation set amount = 1 where deposit_allocation_id = %L', al1)) = 'MR002');
    r := pg_temp._add(r, 'allocation delete refused (IV04)',
      pg_temp._try(format('delete from app.deposit_allocation where deposit_allocation_id = %L', al1)) = 'MR002');
    r := pg_temp._add(r, 'allocation truncate refused (IV04)', pg_temp._try('truncate app.deposit_allocation') = 'MR002');
    -- (the BEFORE INSERT validation trigger rejects a reversal whose amount is not -original before the CHECK runs)
    r := pg_temp._add(r, 'allocation with no target refused (23514); positive allocation marked as reversal refused (MR005)',
      pg_temp._try(format($q$insert into app.deposit_allocation (tenant_id, deposit_id, amount) values (%L, %L, 1.00)$q$, t1, dep_a)) = '23514'
      and pg_temp._try(format($q$insert into app.deposit_allocation (tenant_id, deposit_id, line_id, amount, reverses_allocation_id) values (%L, %L, %L, 1.00, %L)$q$, t1, dep_a, ln1, al1)) = 'MR005');

    -- ---------------------------------------------------------------- case blockers (before fixing)
    r := pg_temp._add(r, 'case_blockers lists patient balance, open dispute and deposit difference for case A (cash reconciled)',
      (select array_agg(blocker order by blocker) from api.case_blockers where case_id = cs_a)
        = array['Deposit allocation difference', 'Open patient dispute', 'Patient balance is open']);
    r := pg_temp._add(r, 'case_blockers lists cash not reconciled for case B (unbalanced line) plus its dispute and patient balance',
      (select array_agg(blocker order by blocker) from api.case_blockers where case_id = cs_b)
        = array['Cash is not reconciled yet', 'Open patient dispute', 'Patient balance is open']);

    insert into app.deposit_allocation (deposit_allocation_id, tenant_id, deposit_id, remittance_id, amount) values (al2, t1, dep_a, rem_a, 30.00);
    r := pg_temp._add(r, 'allocation up to exactly the deposit amount allowed (IV06 boundary)',
      (select sum(amount) = 100.00 from app.deposit_allocation where deposit_id = dep_a));
    r := pg_temp._add(r, 'one cent over a fully allocated deposit refused (IV06)',
      pg_temp._try(format($q$insert into app.deposit_allocation (tenant_id, deposit_id, line_id, amount) values (%L, %L, %L, 0.01)$q$, t1, dep_a, ln1)) = 'MR002');
    r := pg_temp._add(r, 'lowering the deposit amount below its allocations refused',
      pg_temp._try(format('update app.deposit set amount = 50.00 where deposit_id = %L', dep_a)) = 'MR002');
    r := pg_temp._add(r, 'allocation reversal with the wrong amount refused (MR005)',
      pg_temp._try(format($q$insert into app.deposit_allocation (tenant_id, deposit_id, remittance_id, amount, reverses_allocation_id) values (%L, %L, %L, -10.00, %L)$q$, t1, dep_a, rem_a, al2)) = 'MR005');
    res := pg_temp._try(format($q$insert into app.deposit_allocation (tenant_id, deposit_id, remittance_id, amount, reverses_allocation_id) values (%L, %L, %L, -30.00, %L)$q$, t1, dep_a, rem_a, al2));
    r := pg_temp._add(r, 'allocation reversal nets out',
      res = 'ok' and (select sum(amount) = 70.00 from app.deposit_allocation where deposit_id = dep_a));
    res := pg_temp._try(format($q$insert into app.deposit_allocation (tenant_id, deposit_id, remittance_id, amount) values (%L, %L, %L, 30.00)$q$, t1, dep_a, rem_a));
    r := pg_temp._add(r, 'reversed amount can be re-allocated up to the deposit',
      res = 'ok' and (select sum(amount) = 100.00 from app.deposit_allocation where deposit_id = dep_a));
    r := pg_temp._add(r, 'an allocation cannot be reversed twice',
      pg_temp._try(format($q$insert into app.deposit_allocation (tenant_id, deposit_id, remittance_id, amount, reverses_allocation_id) values (%L, %L, %L, -30.00, %L)$q$, t1, dep_a, rem_a, al2)) in ('MR002', '23505'));

    -- ---------------------------------------------------------------- case blockers (after fixing)
    insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method) values (t1, pat_a, resp_a, 15.00, 'card');
    update app.patient_dispute set status = 'resolved', resolution = 'Payment found', resolved_at = now() where patient_dispute_id = dp_a;
    r := pg_temp._add(r, 'case_blockers is empty for case A once patient balance, dispute and deposit are settled',
      not exists (select 1 from api.case_blockers where case_id = cs_a));
    r := pg_temp._add(r, 'case B still blocked (cash not reconciled)',
      exists (select 1 from api.case_blockers where case_id = cs_b and blocker = 'Cash is not reconciled yet'));

    -- ---------------------------------------------------------------- IV10: replacement claim
    r := pg_temp._add(r, 'claim cannot be its own replacement (IV10)',
      pg_temp._try(format('update app.claim set original_claim_id = claim_id where claim_id = %L', cl_a1)) = '23514'
      and pg_temp._try(format($q$insert into app.claim (claim_id, tenant_id, claim_number, patient_id, payer_id, original_claim_id) values (%L, %L, 'CLM-SELF', %L, %L, %L)$q$,
            cl_r, t1, pat_a, pay_a, cl_r)) = '23514');
    r := pg_temp._add(r, 'a replacement pointing at another claim is allowed (IV10 positive)',
      pg_temp._try(format($q$insert into app.claim (claim_id, tenant_id, claim_number, patient_id, payer_id, original_claim_id, frequency_code) values (%L, %L, 'CLM-A1-R', %L, %L, %L, '7')$q$,
            cl_r, t1, pat_a, pay_a, cl_a1)) = 'ok');
    r := pg_temp._add(r, 'replacement/void frequency code needs an original claim (23514)',
      pg_temp._try(format($q$insert into app.claim (tenant_id, claim_number, patient_id, payer_id, frequency_code) values (%L, 'CLM-F7', %L, %L, '7')$q$, t1, pat_a, pay_a)) = '23514');
    r := pg_temp._add(r, 'bill hold needs a reason (23514)',
      pg_temp._try(format('update app.claim set hold = true where claim_id = %L', cl_a2)) = '23514');

    -- ---------------------------------------------------------------- state machines (enforce_transition)
    r := pg_temp._add(r, 'claim draft -> paid refused (MR001)',
      pg_temp._try(format($q$update app.claim set status = 'paid' where claim_id = %L$q$, cl_a2)) = 'MR001');
    r := pg_temp._add(r, 'claim draft -> ready allowed',
      pg_temp._try(format($q$update app.claim set status = 'ready' where claim_id = %L$q$, cl_a2)) = 'ok');
    r := pg_temp._add(r, 'claim status outside the legal set refused (23514)',
      pg_temp._try(format($q$insert into app.claim (tenant_id, claim_number, patient_id, payer_id, status) values (%L, 'CLM-BAD', %L, %L, 'lost')$q$, t1, pat_a, pay_a)) = '23514');
    r := pg_temp._add(r, 'denial new -> recovered refused (MR001); new -> triaged allowed',
      pg_temp._try(format($q$update app.denial set status = 'recovered' where denial_id = %L$q$, den_a)) = 'MR001'
      and pg_temp._try(format($q$update app.denial set status = 'triaged' where denial_id = %L$q$, den_a)) = 'ok');
    r := pg_temp._add(r, 'appeal drafting -> filed refused (MR001); drafting -> pending_approval allowed',
      pg_temp._try(format($q$update app.appeal set status = 'filed' where appeal_id = %L$q$, ap_a2)) = 'MR001'
      and pg_temp._try(format($q$update app.appeal set status = 'pending_approval' where appeal_id = %L$q$, ap_a2)) = 'ok');
    -- (on UPDATE enforce_transition refuses first with MR001; the CHECK itself is proven on INSERT)
    r := pg_temp._add(r, 'case status outside open/closed refused (23514 on insert, MR001 on update)',
      pg_temp._try(format($q$insert into app."case" (tenant_id, case_number, patient_id, status) values (%L, 'CASE-BAD', %L, 'archived')$q$, t1, pat_b)) = '23514'
      and pg_temp._try(format($q$update app."case" set status = 'archived' where case_id = %L$q$, cs_b)) = 'MR001');

    -- transitions also work when run by a SECURITY DEFINER command invoked by a signed-in client
    perform pg_temp._claims(u_prov);
    set local role authenticated;
    r := pg_temp._add(r, 'enforce_transition works inside a definer command called by authenticated (legal move ok)',
      pg_temp._as_cmd(format($q$update app.claim set status = 'submitted' where claim_id = %L$q$, cl_a2)) = 'ok');
    r := pg_temp._add(r, 'enforce_transition works inside a definer command called by authenticated (illegal move MR001)',
      pg_temp._as_cmd(format($q$update app.claim set status = 'paid' where claim_id = %L$q$, cl_a2)) = 'MR001');
    r := pg_temp._add(r, 'case close through a definer command writes history with the caller as changed_by',
      pg_temp._as_cmd(format($q$update app."case" set status = 'closed', closed_at = now() where case_id = %L$q$, cs_a)) = 'ok');
    reset role;

    -- ---------------------------------------------------------------- case status history
    r := pg_temp._add(r, 'case_status_history written by trigger on insert and on status change',
      (select array_agg(coalesce(from_status, '-') || '>' || to_status order by changed_at, case_status_history_id)
         from app.case_status_history where case_id = cs_a) = array['->open', 'open>closed']
      and (select changed_by = u_prov from app.case_status_history where case_id = cs_a and to_status = 'closed'));
    update app."case" set title = 'Renamed' where case_id = cs_b;
    r := pg_temp._add(r, 'a non-status update writes no history row',
      (select count(*) = 1 from app.case_status_history where case_id = cs_b));
    r := pg_temp._add(r, 'case_status_history is append-only (update, delete refused MR002)',
      pg_temp._try(format($q$update app.case_status_history set to_status = 'open' where case_id = %L$q$, cs_a)) = 'MR002'
      and pg_temp._try(format('delete from app.case_status_history where case_id = %L', cs_a)) = 'MR002');

    -- ---------------------------------------------------------------- other data rules
    r := pg_temp._add(r, 'duplicate 835 trace for the same payer refused (23505); same trace for another payer allowed',
      pg_temp._try(format($q$insert into app.edi_interchange (tenant_id, clearinghouse_id, payer_id, direction, transaction_set, trace_number) values (%L, %L, %L, 'inbound', '835', 'TRN-1')$q$, t1, ch_a, pay_a)) = '23505'
      and pg_temp._try(format($q$insert into app.edi_interchange (tenant_id, clearinghouse_id, payer_id, direction, transaction_set, trace_number) values (%L, %L, %L, 'inbound', '835', 'TRN-1')$q$, t1, ch_b, pay_b)) = 'ok');
    r := pg_temp._add(r, 'claim_edit_result severity must be hard or soft (23514)',
      pg_temp._try(format($q$insert into app.claim_edit_result (tenant_id, claim_id, rule_code, severity, passed) values (%L, %L, 'X', 'fatal', false)$q$, t1, cl_a1)) = '23514');
    r := pg_temp._add(r, 'denial line must belong to the denial''s claim (23503)',
      pg_temp._try(format($q$insert into app.denial (tenant_id, claim_id, line_id) values (%L, %L, %L)$q$, t1, cl_a1, ln2)) = '23503');
    r := pg_temp._add(r, 'denial root cause must be a known code (23503)',
      pg_temp._try(format($q$insert into app.denial (tenant_id, claim_id, root_cause) values (%L, %L, 'NOPE')$q$, t1, cl_a1)) = '23503');
    r := pg_temp._add(r, 'triage override without a reason refused (23514); with a reason allowed',
      pg_temp._try(format($q$insert into app.denial_triage (tenant_id, denial_id, recommended_path, confirmed_path) values (%L, %L, 'appeal', 'write_off')$q$, t1, den_a)) = '23514'
      and pg_temp._try(format($q$insert into app.denial_triage (tenant_id, denial_id, recommended_path, confirmed_path, override_reason) values (%L, %L, 'appeal', 'write_off', 'Below threshold')$q$, t1, den_a)) = 'ok');
    r := pg_temp._add(r, 'appeal approver cannot be the author (23514); a different approver allowed',
      pg_temp._try(format('update app.appeal set approver_id = author_id where appeal_id = %L', ap_a2)) = '23514'
      and pg_temp._try(format('update app.appeal set approver_id = %L where appeal_id = %L', u_appr, ap_a2)) = 'ok');
    r := pg_temp._add(r, 'appeal statement without source must be flagged unsupported (23514); flagged one allowed',
      pg_temp._try(format($q$insert into app.appeal_statement (tenant_id, appeal_id, seq, text) values (%L, %L, 2, 'Unsourced claim')$q$, t1, ap_a2)) = '23514'
      and pg_temp._try(format($q$insert into app.appeal_statement (tenant_id, appeal_id, seq, text, unsupported) values (%L, %L, 2, 'Unsourced claim', true)$q$, t1, ap_a2)) = 'ok');
    r := pg_temp._add(r, 'patient dispute status outside open/resolved refused (23514)',
      pg_temp._try(format($q$update app.patient_dispute set status = 'escalated' where patient_dispute_id = %L$q$, dp_a)) = '23514');
    r := pg_temp._add(r, 'patient payment amount must be positive (23514)',
      pg_temp._try(format($q$insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method) values (%L, %L, %L, 0, 'card')$q$, t1, pat_a, resp_a)) = '23514');
    r := pg_temp._add(r, 'touch trigger stamps audit columns on the new tables',
      (select created_at is not null and updated_at is not null from app.claim where claim_id = cl_a1)
      and (select created_at is not null from app.payment_posting where payment_posting_id = pp1));

    -- ---------------------------------------------------------------- structure
    r := pg_temp._add(r, 'all 27 tables exist with RLS enabled',
      (select count(*) = 27 from pg_class cl join pg_namespace ns on ns.oid = cl.relnamespace
        where ns.nspname = 'app' and cl.relkind = 'r' and cl.relrowsecurity and cl.relname = any (new_tables)));
    r := pg_temp._add(r, 'every new table has a policy and app has only SELECT policies',
      (select count(*) = 0 from pg_class cl join pg_namespace ns on ns.oid = cl.relnamespace
        where ns.nspname = 'app' and cl.relname = any (new_tables)
          and not exists (select 1 from pg_policy p where p.polrelid = cl.oid))
      and (select count(*) = 0 from pg_policy p join pg_class cl on cl.oid = p.polrelid join pg_namespace ns on ns.oid = cl.relnamespace
        where ns.nspname = 'app' and p.polcmd <> 'r'));
    r := pg_temp._add(r, 'every new table has a uuid <table>_id primary key, tenant_id not null and audit columns',
      (select count(*) = 27 from (
        select c.table_name from information_schema.columns c
         where c.table_schema = 'app' and c.table_name = any (new_tables)
         group by c.table_name
        having count(*) filter (where c.column_name = 'tenant_id' and c.is_nullable = 'NO') = 1
           and count(*) filter (where c.column_name = c.table_name || '_id' and c.data_type = 'uuid') = 1
           and count(*) filter (where c.column_name in ('created_at','created_by','updated_at','updated_by')) = 4) x));
    r := pg_temp._add(r, 'every foreign-key column in the new tables is the leading column of an index',
      (select count(*) = 0 from pg_constraint k
        join pg_class cl on cl.oid = k.conrelid join pg_namespace ns on ns.oid = cl.relnamespace
        where k.contype = 'f' and ns.nspname = 'app' and cl.relname = any (new_tables)
          and not exists (select 1 from pg_index i where i.indrelid = k.conrelid and i.indkey[0] = k.conkey[1])));
    r := pg_temp._add(r, 'money columns are numeric(12,2)',
      (select count(*) = 0 from information_schema.columns c
        where c.table_schema = 'app' and c.table_name = any (new_tables)
          and c.column_name in ('billed','amount','paid','adjusted','patient_share','payment_amount','denied_amount','amount_due','decision_amount')
          and not (c.data_type = 'numeric' and c.numeric_precision = 12 and c.numeric_scale = 2)));
    r := pg_temp._add(r, 'no non-SELECT grant to client roles on app tables; anon holds nothing',
      (select count(*) = 0 from information_schema.role_table_grants
        where grantee in ('anon', 'authenticated', 'PUBLIC') and table_schema in ('app', 'api') and privilege_type <> 'SELECT')
      and (select count(*) = 0 from information_schema.role_table_grants where grantee in ('anon', 'PUBLIC') and table_schema in ('app', 'api')));
    r := pg_temp._add(r, 'enforce_transition attached to claim, denial, appeal, case',
      (select count(*) = 4 from pg_trigger t
        where t.tgfoid = 'app.enforce_transition()'::regprocedure and not t.tgisinternal
          and t.tgrelid in ('app.claim'::regclass, 'app.denial'::regclass, 'app.appeal'::regclass, 'app."case"'::regclass)));
    r := pg_temp._add(r, 'views are security_invoker and line_balance has the documented columns',
      (select bool_and(cl.reloptions @> array['security_invoker=true']) from pg_class cl
        where cl.oid in ('api.line_balance'::regclass, 'api.case_blockers'::regclass))
      and (select (array_agg(a.attname::text order by a.attnum))[1:7] from pg_attribute a
            where a.attrelid = 'api.line_balance'::regclass and a.attnum > 0 and not a.attisdropped)
          = array['line_id','billed','paid','adjusted','patient_share','patient_paid','open_amount']
      and (select array_agg(a.attname::text order by a.attnum) from pg_attribute a
            where a.attrelid = 'api.case_blockers'::regclass and a.attnum > 0 and not a.attisdropped) = array['case_id','blocker']);
    r := pg_temp._add(r, 'line_balance definition is documented in a view comment',
      (select d ~ 'reversal' and d ~ 'recoupment' and d ~ 'patient_payment' and d ~ 'open_amount'
         from obj_description('api.line_balance'::regclass, 'pg_class') d));
    r := pg_temp._add(r, 'new trigger functions are not executable by client roles',
      not has_function_privilege('authenticated', 'app.append_only()', 'execute')
      and not has_function_privilege('anon', 'app.append_only()', 'execute')
      and not has_function_privilege('authenticated', 'app.allocation_within_deposit()', 'execute'));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id in (t1, t2))
    and not exists (select 1 from auth.users where id in (u_prov, u_appr, u_prov2, u_payer, u_pat, u_prox, u_clr))
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\')
    and not exists (select 1 from app.claim where claim_id in (cl_a1, cl_a2, cl_b1, cl_d, cl_x, cl_r)));

  perform tests.assert((e->>'p')::boolean, e->>'m') from jsonb_array_elements(r) e;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._as_cmd(text);
drop function pg_temp._n(text);
drop function pg_temp._claims(uuid);

select tests.report();
