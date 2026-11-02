-- Task 6 tests: command functions part 1 (remittance, denial, claim) and their shared helpers.
--   api.cmd_remittance_receive, api.cmd_remittance_post, api.cmd_denial_triage, api.cmd_denial_confirm_path,
--   api.cmd_claim_create_replacement, api.cmd_claim_release, api.cmd_claim_submit;
--   app.valid_amount, app.require_portal, app.scoped_row, app.emit_event.
-- Every command is called for real: `set local role authenticated` + request.jwt.claims sub per user (or anon).
-- Run with execute_sql (whole file in one call). Starts by clearing tests.result.
-- All fixtures live in a sub-transaction rolled back at the end of the DO block, so nothing remains.
select tests.begin();

create or replace function pg_temp._add(r jsonb, m text, p boolean) returns jsonb
language sql as $$ select r || jsonb_build_array(jsonb_build_object('m', m, 'p', coalesce(p, false))) $$;

-- Runs one statement (as the current role) and returns 'ok' or the SQLSTATE it raised.
create or replace function pg_temp._try(q text) returns text
language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- Calls api.<fn>(key, args) as user u (null = no session) under the given client role and returns the result.
create or replace function pg_temp._run(u uuid, fn text, k text, a jsonb, rl text default 'authenticated') returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims',
    case when u is null then '{}' else json_build_object('sub', u, 'role', 'authenticated')::text end, true);
  if rl = 'anon' then set local role anon; else set local role authenticated; end if;
  execute format('select api.%I($1, $2)', fn) into v using k, a;
  reset role;
  return v;
end $$;

-- Same, but returns 'ok' or '<SQLSTATE> <message>' (the call's writes are rolled back on error, role restored).
create or replace function pg_temp._err(u uuid, fn text, k text, a jsonb, rl text default 'authenticated') returns text
language plpgsql as $$
begin
  perform pg_temp._run(u, fn, k, a, rl);
  return 'ok';
exception when others then
  return sqlstate || ' ' || sqlerrm;
end $$;

do $$
declare
  r jsonb := '[]'::jsonb;
  m text; e text; e2 text; fn text; def text;
  j jsonb; j2 jsonb; j_rcv jsonb; j_post jsonb; j_bad jsonb; j_rep jsonb;
  n bigint; n2 bigint; ok boolean;
  cmds text[] := array['cmd_remittance_receive','cmd_remittance_post','cmd_denial_triage','cmd_denial_confirm_path',
                       'cmd_claim_create_replacement','cmd_claim_release','cmd_claim_submit'];
  perms text[] := array['remittance.receive','remittance.post','denial.triage','denial.confirm_path',
                        'claim.create_replacement','claim.release','claim.submit'];
  t1 uuid := app.uuid_v7(); t2 uuid := app.uuid_v7();
  u_b uuid := gen_random_uuid(); u_np uuid := gen_random_uuid(); u_ch uuid := gen_random_uuid();
  u_py uuid := gen_random_uuid(); u_b2 uuid := gen_random_uuid();
  prv uuid := app.uuid_v7(); pat uuid := app.uuid_v7(); pay_a uuid := app.uuid_v7(); pay_b uuid := app.uuid_v7();
  cov uuid := app.uuid_v7(); cov_b uuid := app.uuid_v7(); ch1 uuid := app.uuid_v7(); ch_conn uuid := app.uuid_v7();
  c_new uuid := app.uuid_v7(); c_hold uuid := app.uuid_v7(); c_hard uuid := app.uuid_v7(); c_acc uuid := app.uuid_v7();
  c_bal uuid := app.uuid_v7(); c_part uuid := app.uuid_v7(); c_payb uuid := app.uuid_v7(); c_empty uuid := app.uuid_v7();
  ln1 uuid := app.uuid_v7(); ln2 uuid := app.uuid_v7(); ln_h uuid := app.uuid_v7(); ln_x uuid := app.uuid_v7();
  ln_acc uuid := app.uuid_v7(); ln_bal uuid := app.uuid_v7(); ln_part uuid := app.uuid_v7(); ln_b uuid := app.uuid_v7();
  d_nocarc uuid := app.uuid_v7(); d_tri uuid := app.uuid_v7(); c_dfx uuid := app.uuid_v7(); ln_dfx uuid := app.uuid_v7();
  pat2 uuid := app.uuid_v7(); pay_t2 uuid := app.uuid_v7(); c_t2 uuid := app.uuid_v7(); ln_t2 uuid := app.uuid_v7();
  d_t2 uuid := app.uuid_v7(); r_t2 uuid := app.uuid_v7();
  ghost uuid := gen_random_uuid();
  rem1 uuid; rem_bad uuid; rem_ok2 uuid; rem_bal uuid; d1 uuid; c_rep uuid; ix_out uuid;
  claims_before bigint;
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner, no claims)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values
      ('t_biller', 'Biller', 'provider'), ('t_noperm', 'Staff without permissions', 'provider'),
      ('t_clr', 'Clearinghouse', 'clearinghouse'), ('t_payer', 'Payer', 'payer');
    insert into app.permission (permission_key, description)
      select p, 'Task 6 command' from unnest(perms) p
    on conflict (permission_key) do nothing;
    insert into app.role_permission (role_key, permission_key)
      select 't_biller', p from unnest(perms) p
      union all select 't_payer', p from unnest(perms) p      -- a payer role holding every key is still refused (portal)
      union all select 't_clr', 'remittance.receive';
    insert into auth.users (id, aud, role, email) values
      (u_b,  'authenticated', 'authenticated', 'b1@meridian.test'),
      (u_np, 'authenticated', 'authenticated', 'np@meridian.test'),
      (u_ch, 'authenticated', 'authenticated', 'ch@meridian.test'),
      (u_py, 'authenticated', 'authenticated', 'py@meridian.test'),
      (u_b2, 'authenticated', 'authenticated', 'b2@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, party_id, display_name) values
      (u_b,  t1, 'provider',      't_biller', null,  'Biller One'),
      (u_np, t1, 'provider',      't_noperm', null,  'No Permission'),
      (u_ch, t1, 'clearinghouse', 't_clr',    ch1,   'Clearinghouse user'),
      (u_py, t1, 'payer',         't_payer',  pay_a, 'Payer A user'),
      (u_b2, t2, 'provider',      't_biller', null,  'Biller Tenant Two');

    insert into app.provider (provider_id, tenant_id, npi, name) values (prv, t1, '1000000001', 'Dr One');
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values
      (pat, t1, 'MRN-1', 'Ada', 'Alpha', date '1980-01-01'),
      (pat2, t2, 'MRN-2', 'Bea', 'Beta', date '1981-02-02');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values
      (pay_a, t1, 'Payer A', 'PA01', 'commercial'), (pay_b, t1, 'Payer B', 'PB01', 'medicaid'),
      (pay_t2, t2, 'Payer T2', 'PT2', 'commercial');
    insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values
      (cov, t1, pat, pay_a, 'MEM-A', date '2026-01-01', 'eligibility'),
      (cov_b, t1, pat, pay_b, 'MEM-B', date '2026-01-01', 'manual');
    insert into app.clearinghouse (clearinghouse_id, tenant_id, name, clearinghouse_code) values (ch1, t1, 'Clearinghouse One', 'CH1');
    insert into app.clearinghouse_connection (clearinghouse_connection_id, tenant_id, clearinghouse_id, payer_id, protocol, endpoint_label, status)
      values (ch_conn, t1, ch1, pay_a, 'x12', 'CH1 to Payer A (synthetic)', 'active');
    insert into app.payer_config (tenant_id, payer_id, timely_filing_days, appeal_levels, records_request_days, effective_from) values
      (t1, pay_a, 90, 2, 30, date '2026-01-01');
    insert into app.root_cause (tenant_id, code, label, category) values
      (t1, 'CODING', 'Coding error', 'coding'), (t1, 'COB', 'Coordination of benefits', 'front_end'),
      (t2, 'CODING', 'Coding error', 'coding');

    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, hold, hold_reason, service_from, service_to) values
      (c_new,   t1, 'C-NEW',   pat, prv, pay_a, cov,   'draft',    false, null, date '2026-10-01', date '2026-10-01'),
      (c_hold,  t1, 'C-HOLD',  pat, prv, pay_a, cov,   'draft',    true,  'Missing signature', null, null),
      (c_hard,  t1, 'C-HARD',  pat, prv, pay_a, cov,   'draft',    false, null, null, null),
      (c_acc,   t1, 'C-ACC',   pat, prv, pay_a, cov,   'accepted', false, null, date '2026-09-01', date '2026-09-01'),
      (c_bal,   t1, 'C-BAL',   pat, prv, pay_a, cov,   'accepted', false, null, null, null),
      (c_part,  t1, 'C-PART',  pat, prv, pay_a, cov,   'accepted', false, null, null, null),
      (c_payb,  t1, 'C-PAYB',  pat, prv, pay_b, cov_b, 'ready',    false, null, null, null),
      (c_empty, t1, 'C-EMPTY', pat, prv, pay_a, cov,   'draft',    false, null, null, null),
      (c_dfx,   t1, 'C-DFX',   pat, prv, pay_a, cov,   'accepted', false, null, null, null),   -- carries the triage fixture denials
      (c_t2,    t2, 'C-T2',    pat2, null, pay_t2, null, 'draft',  false, null, null, null);
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (ln1,     t1, c_new,  1, '99213', 100.00),
      (ln2,     t1, c_new,  2, '99214',  50.00),
      (ln_h,    t1, c_hold, 1, '99213',  80.00),
      (ln_x,    t1, c_hard, 1, '99213',  80.00),
      (ln_acc,  t1, c_acc,  1, '99215', 200.00),
      (ln_bal,  t1, c_bal,  1, '99213', 100.00),
      (ln_part, t1, c_part, 1, '99213', 100.00),
      (ln_b,    t1, c_payb, 1, '99213',  90.00),
      (ln_dfx,  t1, c_dfx,  1, '99213', 100.00),
      (ln_t2,   t2, c_t2,   1, '99213', 100.00);
    insert into app.claim_diagnosis (tenant_id, claim_id, sequence, icd10_code) values
      (t1, c_new, 1, 'E11.9'), (t1, c_new, 2, 'I10'), (t1, c_acc, 1, 'J45.909');
    insert into app.claim_edit_result (tenant_id, claim_id, rule_code, severity, passed, checked_at) values
      (t1, c_new,  'NCCI-01', 'hard', true,  now()),
      (t1, c_new,  'FMT-02',  'soft', false, now()),
      (t1, c_hard, 'NCCI-01', 'hard', false, now());
    insert into app.payment_posting (tenant_id, line_id, kind, amount) values
      (t1, ln_bal, 'payment', 70.00), (t1, ln_bal, 'adjustment', 10.00), (t1, ln_bal, 'patient_share', 20.00),
      (t1, ln_part, 'payment', 40.00);
    update app.claim_service_line set balanced = true where claim_service_line_id = ln_bal;
    insert into app.denial (denial_id, tenant_id, claim_id, line_id, status, carc, denied_amount) values
      (d_nocarc, t1, c_dfx, ln_dfx, 'new',      null, 20.00),
      (d_tri,    t1, c_dfx, ln_dfx, 'triaged', '16',  30.00),
      (d_t2,     t2, c_t2,  ln_t2,  'new',     '50', 100.00);
    insert into app.denial_triage (tenant_id, denial_id, root_cause, recommended_path, confidence) values
      (t1, d_tri, 'CODING', 'evidence', 0.700);
    insert into app.remittance (remittance_id, tenant_id, payer_id, trace_number, payment_amount) values
      (r_t2, t2, pay_t2, 'T2-TRN', 0.00);

    -- ================================================================ helpers
    r := pg_temp._add(r, 'valid_amount refuses zero, negative, 3 decimals, null and over max (MR005)',
      pg_temp._try('select app.valid_amount(0)') = 'MR005'
      and pg_temp._try('select app.valid_amount(-1)') = 'MR005'
      and pg_temp._try('select app.valid_amount(1.005)') = 'MR005'
      and pg_temp._try('select app.valid_amount(null)') = 'MR005'
      and pg_temp._try('select app.valid_amount(100.01, 100)') = 'MR005'
      and pg_temp._try('select app.valid_amount(10000000000.00)') = 'MR005');
    r := pg_temp._add(r, 'valid_amount returns the amount when valid (0.01, 100 within max 100, 10.50)',
      app.valid_amount(0.01) = 0.01 and app.valid_amount(100, 100) = 100 and app.valid_amount(10.50) = 10.50);

    -- ================================================================ claim.release (positive)
    j := pg_temp._run(u_b, 'cmd_claim_release', 'rel-1', jsonb_build_object('claim_id', c_new));
    r := pg_temp._add(r, 'release: result names the claim and status ready',
      j->>'claim_id' = c_new::text and j->>'status' = 'ready');
    r := pg_temp._add(r, 'release: claim moved draft -> ready (a failed SOFT edit does not block)',
      (select status from app.claim where claim_id = c_new) = 'ready');
    r := pg_temp._add(r, 'release: outbox claim.ready with aggregate = claim and payload claim_id',
      (select count(*) = 1 and bool_and(aggregate_id = c_new and payload->>'claim_id' = c_new::text)
         from audit.outbox_event where tenant_id = t1 and type = 'claim.ready'));
    r := pg_temp._add(r, 'release: audit row claim.release on the claim, actor from ctx',
      exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'claim.release' and object_id = c_new and actor = u_b));
    r := pg_temp._add(r, 'release again (claim is ready, not draft) refused MR001',
      split_part(pg_temp._err(u_b, 'cmd_claim_release', 'rel-again', jsonb_build_object('claim_id', c_new)), ' ', 1) = 'MR001');

    -- ================================================================ claim.release refusals (IV11 / IV12)
    e := pg_temp._err(u_b, 'cmd_claim_release', 'rel-h', jsonb_build_object('claim_id', c_hold));
    r := pg_temp._add(r, 'release refused while a bill hold is active (MR002 IV12_bill_hold_active)',
      split_part(e, ' ', 1) = 'MR002' and e like '%IV12_bill_hold_active%');
    e := pg_temp._err(u_b, 'cmd_claim_release', 'rel-x', jsonb_build_object('claim_id', c_hard));
    r := pg_temp._add(r, 'release refused while a hard edit failed (MR002 IV11_hard_edit_failed)',
      split_part(e, ' ', 1) = 'MR002' and e like '%IV11_hard_edit_failed%');
    e := pg_temp._err(u_b, 'cmd_claim_release', 'rel-e', jsonb_build_object('claim_id', c_empty));
    r := pg_temp._add(r, 'release refused for a claim with no service lines (MR002)', split_part(e, ' ', 1) = 'MR002');
    r := pg_temp._add(r, 'refused releases left the claims in draft, no claim.ready event and no idempotency row',
      (select count(*) = 3 from app.claim where claim_id in (c_hold, c_hard, c_empty) and status = 'draft')
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'claim.ready')
      and not exists (select 1 from app.idempotency_key where tenant_id = t1 and key in ('rel-h', 'rel-x', 'rel-e')));

    -- ================================================================ claim.submit
    j := pg_temp._run(u_b, 'cmd_claim_submit', 'sub-1', jsonb_build_object('claim_id', c_new));
    ix_out := (j->>'edi_interchange_id')::uuid;
    r := pg_temp._add(r, 'submit: claim ready -> submitted with submitted_at',
      (select status = 'submitted' and submitted_at is not null from app.claim where claim_id = c_new));
    r := pg_temp._add(r, 'submit: outbound 837 interchange queued via the up clearinghouse connection, deterministic trace',
      (select direction = 'outbound' and transaction_set = '837' and status = 'queued' and payer_id = pay_a
              and clearinghouse_id = ch1 and trace_number = '837-' || replace(c_new::text, '-', '')
         from app.edi_interchange where edi_interchange_id = ix_out)
      and j->>'clearinghouse_connection_id' = ch_conn::text);
    r := pg_temp._add(r, 'submit: outbox claim.submitted (aggregate claim) and audit claim.submit',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'claim.submitted' and aggregate_id = c_new)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'claim.submit' and object_id = c_new));
    j2 := pg_temp._run(u_b, 'cmd_claim_submit', 'sub-1', jsonb_build_object('claim_id', c_new));
    r := pg_temp._add(r, 'submit replay with the same key returns the identical result and creates nothing',
      j2 = j
      and (select count(*) = 1 from app.edi_interchange where tenant_id = t1 and direction = 'outbound')
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'claim.submitted'));
    e := pg_temp._err(u_b, 'cmd_claim_submit', 'sub-b', jsonb_build_object('claim_id', c_payb));
    r := pg_temp._add(r, 'submit refused when no up clearinghouse connection serves the payer (MR002), claim stays ready',
      split_part(e, ' ', 1) = 'MR002' and e like '%clearinghouse_unreachable%'
      and (select status from app.claim where claim_id = c_payb) = 'ready'
      and not exists (select 1 from app.edi_interchange where tenant_id = t1 and payer_id = pay_b));

    -- ================================================================ remittance.receive (clearinghouse portal)
    j_rcv := pg_temp._run(u_ch, 'cmd_remittance_receive', 'rcv-1', jsonb_build_object(
      'interchange_trace', 'TRN-1001', 'payer_id', pay_a, 'control_total', 210.00, 'paid_date', '2026-10-20',
      'lines', jsonb_build_array(
        jsonb_build_object('claim_id', c_new, 'line_id', ln1, 'paid', 60.00, 'adjustment', 20.00, 'patient_share', 20.00, 'group_code', 'CO', 'carc', '45'),
        jsonb_build_object('claim_id', c_new, 'line_id', ln2, 'paid', 0, 'denied', 50.00, 'group_code', 'CO', 'carc', '50', 'rarc', 'N115'),
        jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 150.00, 'adjustment', 50.00, 'group_code', 'CO', 'carc', '45'))));
    rem1 := (j_rcv->>'remittance_id')::uuid;
    r := pg_temp._add(r, 'receive: remittance stored with control total, trace and status received',
      (select payer_id = pay_a and trace_number = 'TRN-1001' and payment_amount = 210.00 and status = 'received'
              and paid_date = date '2026-10-20' and edi_interchange_id = (j_rcv->>'edi_interchange_id')::uuid
         from app.remittance where remittance_id = rem1));
    r := pg_temp._add(r, 'receive: inbound 835 interchange through the caller''s clearinghouse (defaulted from ctx party)',
      (select direction = 'inbound' and transaction_set = '835' and clearinghouse_id = ch1 and trace_number = 'TRN-1001'
         from app.edi_interchange where edi_interchange_id = (j_rcv->>'edi_interchange_id')::uuid));
    r := pg_temp._add(r, 'receive: 3 remittance lines with billed copied, denied amount and codes kept',
      (select count(*) = 3 from app.remittance_line where remittance_id = rem1)
      and jsonb_array_length(j_rcv->'remittance_line_ids') = 3
      and (select billed = 50.00 and paid = 0 and denied_amount = 50.00 and carc = '50' and rarc = 'N115' and group_code = 'CO'
             from app.remittance_line where remittance_id = rem1 and line_id = ln2));
    r := pg_temp._add(r, 'receive: outbox remittance.received (aggregate remittance), audit remittance.receive, nothing posted yet',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'remittance.received' and aggregate_id = rem1)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'remittance.receive' and object_id = rem1 and actor = u_ch)
      and not exists (select 1 from app.payment_posting where line_id in (ln1, ln2, ln_acc)));

    j2 := pg_temp._run(u_ch, 'cmd_remittance_receive', 'rcv-1', jsonb_build_object(
      'interchange_trace', 'TRN-1001', 'payer_id', pay_a, 'control_total', 210.00, 'paid_date', '2026-10-20',
      'lines', jsonb_build_array(
        jsonb_build_object('claim_id', c_new, 'line_id', ln1, 'paid', 60.00, 'adjustment', 20.00, 'patient_share', 20.00, 'group_code', 'CO', 'carc', '45'),
        jsonb_build_object('claim_id', c_new, 'line_id', ln2, 'paid', 0, 'denied', 50.00, 'group_code', 'CO', 'carc', '50', 'rarc', 'N115'),
        jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 150.00, 'adjustment', 50.00, 'group_code', 'CO', 'carc', '45'))));
    r := pg_temp._add(r, 'receive replay with the same key returns the identical result, one remittance and interchange',
      j2 = j_rcv
      and (select count(*) = 1 from app.remittance where tenant_id = t1 and trace_number = 'TRN-1001')
      and (select count(*) = 1 from app.edi_interchange where tenant_id = t1 and trace_number = 'TRN-1001'));

    e := pg_temp._err(u_ch, 'cmd_remittance_receive', 'rcv-2', jsonb_build_object(
      'interchange_trace', 'TRN-1001', 'payer_id', pay_a, 'control_total', 60.00,
      'lines', jsonb_build_array(jsonb_build_object('claim_id', c_new, 'line_id', ln1, 'paid', 60.00))));
    r := pg_temp._add(r, 'duplicate 835 trace (new key) refused MR002 duplicate_interchange (IV37), still one remittance',
      split_part(e, ' ', 1) = 'MR002' and e like '%duplicate_interchange%'
      and (select count(*) = 1 from app.remittance where tenant_id = t1 and trace_number = 'TRN-1001')
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'remittance.received'));

    e := pg_temp._err(u_ch, 'cmd_remittance_receive', 'rcv-1', jsonb_build_object(
      'interchange_trace', 'TRN-1001', 'payer_id', pay_a, 'control_total', 211.00, 'paid_date', '2026-10-20',
      'lines', jsonb_build_array(jsonb_build_object('claim_id', c_new, 'line_id', ln1, 'paid', 60.00))));
    r := pg_temp._add(r, 'same idempotency key with different args refused MR005', split_part(e, ' ', 1) = 'MR005' and e like '%idempotency_key_reused%');
    r := pg_temp._add(r, 'blank and null idempotency keys refused MR005',
      split_part(pg_temp._err(u_ch, 'cmd_remittance_receive', '   ', jsonb_build_object(
        'interchange_trace', 'TRN-K', 'payer_id', pay_a, 'control_total', 1,
        'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1)))), ' ', 1) = 'MR005'
      and split_part(pg_temp._err(u_ch, 'cmd_remittance_receive', null, jsonb_build_object(
        'interchange_trace', 'TRN-K', 'payer_id', pay_a, 'control_total', 1,
        'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1)))), ' ', 1) = 'MR005'
      and not exists (select 1 from app.remittance where tenant_id = t1 and trace_number = 'TRN-K'));

    -- ================================================================ amounts (MR005, nothing written)
    r := pg_temp._add(r, 'receive refuses a line whose amounts are all zero (MR005)',
      pg_temp._err(u_b, 'cmd_remittance_receive', 'amt-1', jsonb_build_object('interchange_trace', 'TRN-AMT', 'payer_id', pay_a,
        'clearinghouse_id', ch1, 'control_total', 0,
        'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 0)))) like 'MR005%');
    r := pg_temp._add(r, 'receive refuses a negative paid amount (MR005)',
      pg_temp._err(u_b, 'cmd_remittance_receive', 'amt-2', jsonb_build_object('interchange_trace', 'TRN-AMT', 'payer_id', pay_a,
        'control_total', 0, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', -5)))) like 'MR005%');
    r := pg_temp._add(r, 'receive refuses a 3-decimal amount (MR005)',
      pg_temp._err(u_b, 'cmd_remittance_receive', 'amt-3', jsonb_build_object('interchange_trace', 'TRN-AMT', 'payer_id', pay_a,
        'control_total', 10.01, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 10.005)))) like 'MR005%');
    e := pg_temp._err(u_b, 'cmd_remittance_receive', 'amt-4', jsonb_build_object('interchange_trace', 'TRN-AMT', 'payer_id', pay_a,
        'control_total', 150, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_new, 'line_id', ln1, 'paid', 150))));
    r := pg_temp._add(r, 'receive refuses amounts above the line''s billed amount (MR005 amount_exceeds_billed)',
      e like 'MR005%' and e like '%amount_exceeds_billed%');
    r := pg_temp._add(r, 'receive refuses a 3-decimal or negative control total (MR005)',
      pg_temp._err(u_b, 'cmd_remittance_receive', 'amt-5', jsonb_build_object('interchange_trace', 'TRN-AMT', 'payer_id', pay_a,
        'control_total', 1.005, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1)))) like 'MR005%'
      and pg_temp._err(u_b, 'cmd_remittance_receive', 'amt-6', jsonb_build_object('interchange_trace', 'TRN-AMT', 'payer_id', pay_a,
        'control_total', -1, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1)))) like 'MR005%');
    r := pg_temp._add(r, 'receive refuses a missing lines array, a non-uuid id and a repeated line (MR005)',
      pg_temp._err(u_b, 'cmd_remittance_receive', 'amt-7', jsonb_build_object('interchange_trace', 'TRN-AMT', 'payer_id', pay_a, 'control_total', 0)) like 'MR005%'
      and pg_temp._err(u_b, 'cmd_remittance_receive', 'amt-8', jsonb_build_object('interchange_trace', 'TRN-AMT', 'payer_id', 'not-a-uuid',
        'control_total', 1, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1)))) like 'MR005%'
      and pg_temp._err(u_b, 'cmd_remittance_receive', 'amt-9', jsonb_build_object('interchange_trace', 'TRN-AMT', 'payer_id', pay_a,
        'control_total', 2, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1),
                                                      jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1)))) like 'MR005%');
    r := pg_temp._add(r, 'refused amounts wrote no remittance, interchange, line, idempotency or outbox row',
      not exists (select 1 from app.remittance where tenant_id = t1 and trace_number = 'TRN-AMT')
      and not exists (select 1 from app.edi_interchange where tenant_id = t1 and trace_number = 'TRN-AMT')
      and (select count(*) = 3 from app.remittance_line where tenant_id = t1)
      and not exists (select 1 from app.idempotency_key where tenant_id = t1 and key like 'amt-%')
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'remittance.received'));

    -- ================================================================ remittance.post (positive)
    j_post := pg_temp._run(u_b, 'cmd_remittance_post', 'post-1', jsonb_build_object('remittance_id', rem1));
    d1 := (j_post->'denial_ids'->>0)::uuid;
    r := pg_temp._add(r, 'post: 5 postings (payment, adjustment, patient_share on ln1; payment, adjustment on ln_acc; none on denied ln2)',
      (select count(*) = 5 from app.payment_posting p join app.remittance_line rl on rl.remittance_line_id = p.remittance_line_id
        where rl.remittance_id = rem1)
      and jsonb_array_length(j_post->'payment_posting_ids') = 5
      and (select array_agg(kind::text order by kind) from app.payment_posting where line_id = ln1) = array['adjustment','patient_share','payment']
      and not exists (select 1 from app.payment_posting where line_id = ln2));
    r := pg_temp._add(r, 'post: balancing lines re-marked balanced (IV01), the denied line stays open',
      (select balanced from app.claim_service_line where claim_service_line_id = ln1)
      and (select balanced from app.claim_service_line where claim_service_line_id = ln_acc)
      and not (select balanced from app.claim_service_line where claim_service_line_id = ln2)
      and (select open_amount = 50.00 from api.line_balance where line_id = ln2));
    r := pg_temp._add(r, 'post: submitted claim moved through accepted to partially_paid; accepted claim to paid',
      (select status from app.claim where claim_id = c_new) = 'partially_paid'
      and (select status from app.claim where claim_id = c_acc) = 'paid');
    r := pg_temp._add(r, 'post: one denial (status new) for the denied line with codes and amount',
      jsonb_array_length(j_post->'denial_ids') = 1
      and (select status = 'new' and claim_id = c_new and line_id = ln2 and carc = '50' and rarc = 'N115' and group_code = 'CO'
              and denied_amount = 50.00 and remittance_line_id is not null
         from app.denial where denial_id = d1));
    r := pg_temp._add(r, 'post: remittance posted and its interchange processed',
      (select status from app.remittance where remittance_id = rem1) = 'posted'
      and (select status from app.edi_interchange where edi_interchange_id = (j_rcv->>'edi_interchange_id')::uuid) = 'processed');
    r := pg_temp._add(r, 'post: payment.posted once per claim, aggregate = claim and payload subject_id = claim id',
      (select count(*) = 2 and bool_and(aggregate_id = (payload->>'subject_id')::uuid and payload->>'remittance_id' = rem1::text)
              and bool_or(aggregate_id = c_new) and bool_or(aggregate_id = c_acc)
         from audit.outbox_event where tenant_id = t1 and type = 'payment.posted')
      and (select jsonb_array_length(payload->'payment_posting_ids') = 3 from audit.outbox_event
            where tenant_id = t1 and type = 'payment.posted' and aggregate_id = c_new));
    r := pg_temp._add(r, 'post: denial.created once per denial (aggregate denial), remittance.posted once, events share a correlation id',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'denial.created' and aggregate_id = d1)
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'remittance.posted' and aggregate_id = rem1)
      and (select count(distinct correlation_id) = 1 and bool_and(correlation_id is not null) from audit.outbox_event
            where tenant_id = t1 and type in ('payment.posted', 'denial.created', 'remittance.posted')));
    r := pg_temp._add(r, 'post: audit row remittance.post on the remittance with the poster as actor',
      exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'remittance.post' and object_id = rem1 and actor = u_b));

    j2 := pg_temp._run(u_b, 'cmd_remittance_post', 'post-1', jsonb_build_object('remittance_id', rem1));
    r := pg_temp._add(r, 'same idem key twice posts once and returns the identical result',
      j2 = j_post
      and (select count(*) = 5 from app.payment_posting p join app.remittance_line rl on rl.remittance_line_id = p.remittance_line_id
            where rl.remittance_id = rem1)
      and (select count(*) = 2 from audit.outbox_event where tenant_id = t1 and type = 'payment.posted')
      and (select count(*) = 1 from app.denial where claim_id = c_new));
    e := pg_temp._err(u_b, 'cmd_remittance_post', 'post-2', jsonb_build_object('remittance_id', rem1));
    r := pg_temp._add(r, 'posting an already posted remittance with a new key refused MR001, no second posting',
      split_part(e, ' ', 1) = 'MR001'
      and (select count(*) = 5 from app.payment_posting p join app.remittance_line rl on rl.remittance_line_id = p.remittance_line_id
            where rl.remittance_id = rem1));

    -- ================================================================ control totals (IV01)
    j_bad := pg_temp._run(u_b, 'cmd_remittance_receive', 'rcv-bad', jsonb_build_object('interchange_trace', 'TRN-BAD', 'payer_id', pay_a,
      'clearinghouse_id', ch1, 'control_total', 99.00,
      'lines', jsonb_build_array(jsonb_build_object('claim_id', c_part, 'line_id', ln_part, 'paid', 30.00, 'adjustment', 30.00))));
    rem_bad := (j_bad->>'remittance_id')::uuid;
    r := pg_temp._add(r, 'a provider user may also receive a remittance (with an explicit clearinghouse)',
      (select clearinghouse_id = ch1 from app.edi_interchange where edi_interchange_id = (j_bad->>'edi_interchange_id')::uuid));
    e := pg_temp._err(u_b, 'cmd_remittance_post', 'post-bad', jsonb_build_object('remittance_id', rem_bad));
    r := pg_temp._add(r, 'posting with mismatched control total refused MR002 IV01_control_total_mismatch and nothing written',
      split_part(e, ' ', 1) = 'MR002' and e like '%IV01_control_total_mismatch%'
      and (select count(*) = 1 from app.payment_posting where line_id = ln_part)
      and (select status from app.remittance where remittance_id = rem_bad) = 'received'
      and (select status from app.claim where claim_id = c_part) = 'accepted'
      and not exists (select 1 from audit.outbox_event where tenant_id = t1 and type = 'payment.posted' and aggregate_id = c_part)
      and not exists (select 1 from app.idempotency_key where tenant_id = t1 and key = 'post-bad'));

    j := pg_temp._run(u_b, 'cmd_remittance_receive', 'rcv-ok2', jsonb_build_object('interchange_trace', 'TRN-OK2', 'payer_id', pay_a,
      'control_total', 30.00,
      'lines', jsonb_build_array(jsonb_build_object('claim_id', c_part, 'line_id', ln_part, 'paid', 30.00, 'adjustment', 30.00))));
    rem_ok2 := (j->>'remittance_id')::uuid;
    j := pg_temp._run(u_b, 'cmd_remittance_post', 'post-ok2', jsonb_build_object('remittance_id', rem_ok2));
    r := pg_temp._add(r, 'a second remittance completing a partly paid line re-marks it balanced; claim paid',
      (select balanced from app.claim_service_line where claim_service_line_id = ln_part)
      and (select count(*) = 3 from app.payment_posting where line_id = ln_part)
      and (select status from app.claim where claim_id = c_part) = 'paid'
      and jsonb_array_length(j->'denial_ids') = 0);

    -- ================================================================ posting over a line already balanced
    j := pg_temp._run(u_b, 'cmd_remittance_receive', 'rcv-bal', jsonb_build_object('interchange_trace', 'TRN-BAL', 'payer_id', pay_a,
      'control_total', 10.00, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_bal, 'line_id', ln_bal, 'paid', 10.00))));
    rem_bal := (j->>'remittance_id')::uuid;
    e := pg_temp._err(u_b, 'cmd_remittance_post', 'post-bal', jsonb_build_object('remittance_id', rem_bal));
    r := pg_temp._add(r, 'posting onto a balanced line refused MR002 IV01_line_overposted; line stays balanced, no posting',
      split_part(e, ' ', 1) = 'MR002' and e like '%IV01_line_overposted%'
      and (select balanced from app.claim_service_line where claim_service_line_id = ln_bal)
      and (select count(*) = 3 from app.payment_posting where line_id = ln_bal)
      and (select status from app.remittance where remittance_id = rem_bal) = 'received');

    -- ================================================================ denial.triage
    j := pg_temp._run(u_b, 'cmd_denial_triage', 'tri-1', jsonb_build_object('denial_id', d1, 'root_cause', 'CODING',
      'recommended_path', 'correction', 'confidence', 0.85,
      'reasons', jsonb_build_array('CARC 50 on line 2', 'Similar denials were recovered by a corrected claim')));
    r := pg_temp._add(r, 'triage: denial new -> triaged with root cause recorded',
      (select status = 'triaged' and root_cause = 'CODING' from app.denial where denial_id = d1));
    r := pg_temp._add(r, 'triage: denial_triage row with path, confidence and reasons',
      (select recommended_path = 'correction' and confidence = 0.850 and jsonb_array_length(reasons) = 2
              and confirmed_path is null and denial_triage_id = (j->>'denial_triage_id')::uuid
         from app.denial_triage where denial_id = d1));
    r := pg_temp._add(r, 'triage: outbox denial.triaged (aggregate denial) and audit denial.triage',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'denial.triaged' and aggregate_id = d1)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'denial.triage' and object_id = d1));
    r := pg_temp._add(r, 'triage of an already triaged denial refused MR001',
      split_part(pg_temp._err(u_b, 'cmd_denial_triage', 'tri-2', jsonb_build_object('denial_id', d1, 'root_cause', 'CODING',
        'recommended_path', 'appeal')), ' ', 1) = 'MR001');
    e := pg_temp._err(u_b, 'cmd_denial_triage', 'tri-3', jsonb_build_object('denial_id', d_nocarc, 'root_cause', 'CODING',
        'recommended_path', 'appeal'));
    r := pg_temp._add(r, 'triage refused while the CARC is not parsed (MR002 codes_not_parsed), denial stays new',
      split_part(e, ' ', 1) = 'MR002' and e like '%codes_not_parsed%'
      and (select status from app.denial where denial_id = d_nocarc) = 'new'
      and not exists (select 1 from app.denial_triage where denial_id = d_nocarc));
    r := pg_temp._add(r, 'triage validates path, confidence and reasons (MR005)',
      pg_temp._err(u_b, 'cmd_denial_triage', 'tri-4', jsonb_build_object('denial_id', d_nocarc, 'root_cause', 'CODING', 'recommended_path', 'pray')) like 'MR005%'
      and pg_temp._err(u_b, 'cmd_denial_triage', 'tri-5', jsonb_build_object('denial_id', d_nocarc, 'root_cause', 'CODING',
            'recommended_path', 'appeal', 'confidence', 1.5)) like 'MR005%'
      and pg_temp._err(u_b, 'cmd_denial_triage', 'tri-6', jsonb_build_object('denial_id', d_nocarc, 'root_cause', 'CODING',
            'recommended_path', 'appeal', 'reasons', 'not an array')) like 'MR005%');

    -- ================================================================ denial.confirm_path
    e := pg_temp._err(u_b, 'cmd_denial_confirm_path', 'cp-1', jsonb_build_object('denial_id', d1, 'path', 'appeal'));
    e2 := pg_temp._err(u_b, 'cmd_denial_confirm_path', 'cp-2', jsonb_build_object('denial_id', d1, 'path', 'appeal', 'reason', '   '));
    r := pg_temp._add(r, 'confirm_path override without (or with a blank) reason refused MR005 override_reason_required',
      e like 'MR005%' and e like '%override_reason_required%' and e2 like 'MR005%' and e2 like '%override_reason_required%');
    r := pg_temp._add(r, 'refused overrides changed nothing (still triaged, unconfirmed, no deadline, no event)',
      (select status from app.denial where denial_id = d1) = 'triaged'
      and (select confirmed_path is null from app.denial_triage where denial_id = d1)
      and not exists (select 1 from app.deadline where subject_id = d1)
      and not exists (select 1 from audit.outbox_event where tenant_id = t1 and type = 'denial.path_confirmed'));
    r := pg_temp._add(r, 'confirm_path refuses write_off (needs an approved write-off, Task 8) and unknown paths (MR005)',
      pg_temp._err(u_b, 'cmd_denial_confirm_path', 'cp-w', jsonb_build_object('denial_id', d1, 'path', 'write_off', 'reason', 'x')) like 'MR005%'
      and pg_temp._err(u_b, 'cmd_denial_confirm_path', 'cp-u', jsonb_build_object('denial_id', d1, 'path', 'nope', 'reason', 'x')) like 'MR005%');

    j := pg_temp._run(u_b, 'cmd_denial_confirm_path', 'cp-3', jsonb_build_object('denial_id', d1, 'path', 'appeal',
      'reason', 'Records show medical necessity'));
    r := pg_temp._add(r, 'confirm_path override with a reason: triaged -> in_appeal, triage confirmed by the caller (ctx)',
      (select status from app.denial where denial_id = d1) = 'in_appeal'
      and (select confirmed_path = 'appeal' and confirmed_by = u_b and confirmed_at is not null
                  and override_reason = 'Records show medical necessity'
             from app.denial_triage where denial_id = d1)
      and (j->>'overridden')::boolean);
    r := pg_temp._add(r, 'confirm_path: appeal_filing deadline from payer_config (90 days from the denial)',
      (select count(*) = 1 and bool_and(dl.kind = 'appeal_filing' and dl.subject_type = 'denial'
                  and dl.due_at = d.received_at + interval '90 days' and dl.deadline_id = (j->>'deadline_id')::uuid)
         from app.deadline dl join app.denial d on d.denial_id = dl.subject_id where dl.subject_id = d1));
    r := pg_temp._add(r, 'confirm_path: outbox denial.path_confirmed (aggregate denial) and audit denial.confirm_path',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'denial.path_confirmed' and aggregate_id = d1)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'denial.confirm_path' and object_id = d1));
    j := pg_temp._run(u_b, 'cmd_denial_confirm_path', 'cp-4', jsonb_build_object('denial_id', d_tri, 'path', 'evidence'));
    r := pg_temp._add(r, 'confirm_path agreeing with the recommendation needs no reason: in_evidence, records_response deadline (30 days)',
      (select status from app.denial where denial_id = d_tri) = 'in_evidence'
      and not (j->>'overridden')::boolean
      and (select dl.kind = 'records_response' and dl.due_at = d.received_at + interval '30 days'
             from app.deadline dl join app.denial d on d.denial_id = dl.subject_id where dl.subject_id = d_tri));
    r := pg_temp._add(r, 'confirm_path on a denial that is not triaged refused MR001',
      split_part(pg_temp._err(u_b, 'cmd_denial_confirm_path', 'cp-5', jsonb_build_object('denial_id', d1, 'path', 'appeal', 'reason', 'x')), ' ', 1) = 'MR001');

    -- ================================================================ claim.create_replacement (IV10)
    select count(*) into claims_before from app.claim where tenant_id = t1;
    j_rep := pg_temp._run(u_b, 'cmd_claim_create_replacement', 'rep-1', jsonb_build_object('original_claim_id', c_acc));
    c_rep := (j_rep->>'claim_id')::uuid;
    r := pg_temp._add(r, 'replacement: a NEW draft claim pointing at the original (frequency 7, numbered from the original)',
      c_rep <> c_acc
      and (select status = 'draft' and original_claim_id = c_acc and frequency_code = '7' and claim_number = 'C-ACC-R1'
                  and payer_id = pay_a and patient_id = pat and coverage_id = cov and not hold
             from app.claim where claim_id = c_rep)
      and (select count(*) = claims_before + 1 from app.claim where tenant_id = t1));
    r := pg_temp._add(r, 'replacement: lines (unbalanced, no postings) and diagnoses copied; original unchanged',
      (select count(*) = 1 and bool_and(billed = 200.00 and procedure_code = '99215' and not balanced)
         from app.claim_service_line where claim_id = c_rep)
      and (select array_agg(icd10_code) = array['J45.909'] from app.claim_diagnosis where claim_id = c_rep)
      and (select status from app.claim where claim_id = c_acc) = 'paid'
      and (j_rep->>'line_count')::int = 1);
    r := pg_temp._add(r, 'replacement: outbox claim.replacement_drafted (aggregate = new claim, payload original_claim_id) and audit',
      (select count(*) = 1 and bool_and(payload->>'original_claim_id' = c_acc::text) from audit.outbox_event
        where tenant_id = t1 and type = 'claim.replacement_drafted' and aggregate_id = c_rep)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'claim.create_replacement' and object_id = c_rep));
    e := pg_temp._err(u_b, 'cmd_claim_create_replacement', 'rep-2', jsonb_build_object('original_claim_id', c_rep));
    r := pg_temp._add(r, 'claim cannot be its own replacement: replacing the draft replacement itself refused MR002',
      split_part(e, ' ', 1) = 'MR002' and e like '%original_not_submitted%');
    r := pg_temp._add(r, 'claim cannot be its own replacement: IV10 table check refuses original_claim_id = claim_id (23514)',
      pg_temp._try(format('update app.claim set original_claim_id = claim_id where claim_id = %L', c_rep)) = '23514');
    e := pg_temp._err(u_b, 'cmd_claim_create_replacement', 'rep-3', jsonb_build_object('original_claim_id', c_acc));
    r := pg_temp._add(r, 'a second replacement while one is still in draft refused MR002 replacement_in_progress',
      split_part(e, ' ', 1) = 'MR002' and e like '%replacement_in_progress%'
      and (select count(*) = claims_before + 1 from app.claim where tenant_id = t1));

    -- ================================================================ portals and permissions (MR003)
    ok := true;
    foreach fn in array cmds loop
      e := pg_temp._err(u_py, fn, 'p-' || fn, '{}'::jsonb);
      if not (e like 'MR003%' and e like '%wrong_portal%') then ok := false; raise notice 'payer % -> %', fn, e; end if;
    end loop;
    r := pg_temp._add(r, 'a payer-portal user (whose role holds every key) is refused MR003 wrong_portal by all 7 commands', ok);
    ok := true;
    foreach fn in array cmds loop
      e := pg_temp._err(null, fn, 'a-' || fn, '{}'::jsonb);
      if not (e like 'MR003%') then ok := false; raise notice 'no session % -> %', fn, e; end if;
    end loop;
    r := pg_temp._add(r, 'an authenticated caller with no session (no sub) is refused MR003 by all 7 commands', ok);
    ok := true;
    foreach fn in array cmds loop
      e := pg_temp._err(null, fn, 'an-' || fn, '{}'::jsonb, 'anon');
      if not (e like '42501%') then ok := false; raise notice 'anon % -> %', fn, e; end if;
    end loop;
    r := pg_temp._add(r, 'the anon role cannot call any of the 7 commands at all (42501, no schema usage or execute)', ok);
    ok := true;
    foreach fn in array cmds loop
      e := pg_temp._err(u_np, fn, 'np-' || fn, '{}'::jsonb);
      if not (e like 'MR003%' and e like '%permission_required%') then ok := false; raise notice 'noperm % -> %', fn, e; end if;
    end loop;
    r := pg_temp._add(r, 'a provider user whose role lacks the permission is refused MR003 permission_required by all 7', ok);
    ok := true;
    foreach fn in array cmds[2:7] loop
      e := pg_temp._err(u_ch, fn, 'ch-' || fn, '{}'::jsonb);
      if not (e like 'MR003%' and e like '%wrong_portal%') then ok := false; raise notice 'clearinghouse % -> %', fn, e; end if;
    end loop;
    r := pg_temp._add(r, 'a clearinghouse user may only receive remittances (other 6 commands MR003 wrong_portal)', ok);
    r := pg_temp._add(r, 'refused callers wrote no idempotency row',
      not exists (select 1 from app.idempotency_key where tenant_id = t1 and (key like 'p-%' or key like 'np-%' or key like 'ch-%' or key like 'a-%')));

    -- ================================================================ tenant scope (MR004, same message as a non-existent id)
    e := pg_temp._err(u_b, 'cmd_claim_release', 's1', jsonb_build_object('claim_id', c_t2));
    e2 := pg_temp._err(u_b, 'cmd_claim_release', 's2', jsonb_build_object('claim_id', ghost));
    r := pg_temp._add(r, 'release: foreign tenant claim id and nonexistent id both MR004 with identical messages',
      e like 'MR004%' and e = e2);
    e := pg_temp._err(u_b, 'cmd_claim_submit', 's3', jsonb_build_object('claim_id', c_t2));
    e2 := pg_temp._err(u_b, 'cmd_claim_submit', 's4', jsonb_build_object('claim_id', ghost));
    r := pg_temp._add(r, 'submit: foreign claim and nonexistent claim give identical MR004', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_b, 'cmd_claim_create_replacement', 's5', jsonb_build_object('original_claim_id', c_t2));
    e2 := pg_temp._err(u_b, 'cmd_claim_create_replacement', 's6', jsonb_build_object('original_claim_id', ghost));
    r := pg_temp._add(r, 'create_replacement: foreign and nonexistent original give identical MR004', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_b, 'cmd_denial_triage', 's7', jsonb_build_object('denial_id', d_t2, 'root_cause', 'CODING', 'recommended_path', 'appeal'));
    e2 := pg_temp._err(u_b, 'cmd_denial_triage', 's8', jsonb_build_object('denial_id', ghost, 'root_cause', 'CODING', 'recommended_path', 'appeal'));
    r := pg_temp._add(r, 'triage: foreign denial and nonexistent denial give identical MR004', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_b, 'cmd_denial_confirm_path', 's9', jsonb_build_object('denial_id', d_t2, 'path', 'appeal', 'reason', 'x'));
    e2 := pg_temp._err(u_b, 'cmd_denial_confirm_path', 's10', jsonb_build_object('denial_id', ghost, 'path', 'appeal', 'reason', 'x'));
    r := pg_temp._add(r, 'confirm_path: foreign denial and nonexistent denial give identical MR004', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_b, 'cmd_remittance_post', 's11', jsonb_build_object('remittance_id', r_t2));
    e2 := pg_temp._err(u_b, 'cmd_remittance_post', 's12', jsonb_build_object('remittance_id', ghost));
    r := pg_temp._add(r, 'post: foreign remittance and nonexistent remittance give identical MR004', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_b, 'cmd_remittance_receive', 's13', jsonb_build_object('interchange_trace', 'TRN-S', 'payer_id', pay_t2,
      'control_total', 1, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1))));
    e2 := pg_temp._err(u_b, 'cmd_remittance_receive', 's14', jsonb_build_object('interchange_trace', 'TRN-S', 'payer_id', ghost,
      'control_total', 1, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1))));
    r := pg_temp._add(r, 'receive: foreign payer and nonexistent payer give identical MR004', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_b, 'cmd_remittance_receive', 's15', jsonb_build_object('interchange_trace', 'TRN-S', 'payer_id', pay_a,
      'control_total', 1, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_t2, 'line_id', ln_t2, 'paid', 1))));
    e2 := pg_temp._err(u_b, 'cmd_remittance_receive', 's16', jsonb_build_object('interchange_trace', 'TRN-S', 'payer_id', pay_a,
      'control_total', 1, 'lines', jsonb_build_array(jsonb_build_object('claim_id', ghost, 'line_id', ln_t2, 'paid', 1))));
    r := pg_temp._add(r, 'receive: foreign claim and nonexistent claim in a line give identical MR004', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_ch, 'cmd_remittance_receive', 's17', jsonb_build_object('interchange_trace', 'TRN-S', 'payer_id', pay_a,
      'clearinghouse_id', gen_random_uuid(), 'control_total', 1,
      'lines', jsonb_build_array(jsonb_build_object('claim_id', c_acc, 'line_id', ln_acc, 'paid', 1))));
    r := pg_temp._add(r, 'a clearinghouse user naming another clearinghouse is refused MR004', e like 'MR004%');
    r := pg_temp._add(r, 'tenant two saw nothing change',
      (select status from app.claim where claim_id = c_t2) = 'draft'
      and (select status from app.denial where denial_id = d_t2) = 'new'
      and (select status from app.remittance where remittance_id = r_t2) = 'received'
      and not exists (select 1 from audit.outbox_event where tenant_id = t2)
      and not exists (select 1 from app.idempotency_key where tenant_id = t2));

    -- ================================================================ function definitions
    ok := true;
    foreach fn in array cmds loop
      def := pg_get_functiondef(format('api.%I(text,jsonb)', fn)::regprocedure);
      if not (position('app.ctx()' in def) > 0
              and position('app.ctx()' in def) < position('app.require_portal(' in def)
              and position('app.require_portal(' in def) < position('app.authorize(' in def)
              and position('app.authorize(' in def) < position('app.begin_cmd(' in def)
              and position('app.begin_cmd(' in def) < position('app.finish_cmd(' in def)) then
        ok := false; raise notice 'order wrong in %', fn;
      end if;
    end loop;
    r := pg_temp._add(r, 'every command calls ctx, require_portal, authorize, begin_cmd, finish_cmd in that order (authorize before begin_cmd)', ok);
    r := pg_temp._add(r, 'every command is SECURITY DEFINER with search_path '''', jsonb result, executable by authenticated only',
      (select count(*) = 7 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'api' and p.proname = any (cmds) and p.prosecdef
          and p.proconfig @> array['search_path=""'] and p.prorettype = 'jsonb'::regtype
          and pg_get_function_identity_arguments(p.oid) = 'p_idem text, p_args jsonb'
          and has_function_privilege('authenticated', p.oid, 'execute')
          and not has_function_privilege('anon', p.oid, 'execute')
          and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)));
    r := pg_temp._add(r, 'helpers are not executable by client roles',
      not has_function_privilege('authenticated', 'app.valid_amount(numeric,numeric)', 'execute')
      and not has_function_privilege('authenticated', 'app.require_portal(text[])', 'execute')
      and not has_function_privilege('authenticated', 'app.scoped_row(text,uuid,boolean)', 'execute')
      and not has_function_privilege('authenticated', 'app.emit_event(text,uuid,jsonb,text,text)', 'execute')
      and not has_function_privilege('anon', 'app.valid_amount(numeric,numeric)', 'execute'));
    r := pg_temp._add(r, 'remittance status changes follow the state machine (received -> posted only)',
      pg_temp._try(format($q$update app.remittance set status = 'received' where remittance_id = %L$q$, rem1)) = 'MR001');

    -- ================================================================ handovers see the right subjects
    perform app.process_outbox();
    r := pg_temp._add(r, 'engine: H13 passed on claim.ready and H14 passed on claim.submitted for the released claim',
      exists (select 1 from app.handover_event where handover_id = 'H13' and subject_id = c_new and status = 'passed')
      and exists (select 1 from app.handover_event where handover_id = 'H14' and subject_id = c_new and status = 'passed'));
    r := pg_temp._add(r, 'engine: H15 passed for the matched remittance, held for the control-total mismatch',
      exists (select 1 from app.handover_event where handover_id = 'H15' and subject_id = rem1 and status = 'passed')
      and exists (select 1 from app.handover_event where handover_id = 'H15' and subject_id = rem_bad and status = 'held'));
    r := pg_temp._add(r, 'engine: H16 passed for the created denial, H17 passed for the confirmed paths',
      exists (select 1 from app.handover_event where handover_id = 'H16' and subject_id = d1 and status = 'passed')
      and exists (select 1 from app.handover_event where handover_id = 'H17' and subject_id = d1 and status = 'passed')
      and exists (select 1 from app.handover_event where handover_id = 'H17' and subject_id = d_tri and status = 'passed'));
    r := pg_temp._add(r, 'engine: H19 (payment.posted, subject claim) passed for the fully paid claim, held for the one with a denial',
      exists (select 1 from app.handover_event where handover_id = 'H19' and subject_id = c_acc and status = 'passed')
      and exists (select 1 from app.handover_event where handover_id = 'H19' and subject_id = c_new and status = 'held')
      and not exists (select 1 from app.handover_event where tenant_id = t1 and detail = 'subject_tenant_mismatch'));
    r := pg_temp._add(r, 'audit chain of tenant one verifies after all commands', audit.verify_chain(t1));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id in (t1, t2))
    and not exists (select 1 from auth.users where id in (u_b, u_np, u_ch, u_py, u_b2))
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\')
    and not exists (select 1 from app.claim where claim_id in (c_new, c_acc, c_t2))
    and not exists (select 1 from audit.outbox_event where tenant_id in (t1, t2))
    and not exists (select 1 from app.permission where description = 'Task 6 command'));

  perform tests.assert((x->>'p')::boolean, x->>'m') from jsonb_array_elements(r) x;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._run(uuid, text, text, jsonb, text);
drop function pg_temp._err(uuid, text, text, jsonb, text);

select tests.report();
