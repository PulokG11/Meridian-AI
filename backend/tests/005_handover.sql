-- Task 5 tests: workflow tables, rules & AI tables, approval trigger (IV13), handover definitions H13-H24,
-- ready checks ref.check_hNN, the handover engine app.process_outbox() (IV26 hold = one task, IV27 replay = nothing new),
-- per-aggregate ordering, inactive handover (H23), RLS and grants, the pg_cron job.
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
  v_ret integer;
  v_h integer; v_t integer; v_q integer; v_x text;
  new_tables text[] := array['work_queue','task','approval_request','handover_event','rule_pack','rule',
                             'ai_model_version','ai_interaction','ai_review'];
  t1 uuid := app.uuid_v7(); t2 uuid := app.uuid_v7();
  u_sup uuid := gen_random_uuid(); u_sup2 uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid();
  u_nolimit uuid := gen_random_uuid(); u_t2 uuid := gen_random_uuid(); u_payer uuid := gen_random_uuid();
  prv uuid := app.uuid_v7(); pat_a uuid := app.uuid_v7(); pay_a uuid := app.uuid_v7(); cov_a uuid := app.uuid_v7();
  cl_ok uuid := app.uuid_v7(); cl_hold uuid := app.uuid_v7(); cl_nocov uuid := app.uuid_v7(); cl_hard uuid := app.uuid_v7();
  cl_fixed uuid := app.uuid_v7(); cl_soft uuid := app.uuid_v7(); cl_bal uuid := app.uuid_v7(); cl_open uuid := app.uuid_v7();
  ln_bal uuid := app.uuid_v7(); ln_open uuid := app.uuid_v7();
  rem_ok uuid := app.uuid_v7(); rem_unm uuid := app.uuid_v7(); rem_short uuid := app.uuid_v7(); rem_empty uuid := app.uuid_v7();
  dep_ok uuid := app.uuid_v7(); dep_alloc uuid := app.uuid_v7(); dep_empty uuid := app.uuid_v7();
  den_a uuid := app.uuid_v7(); den_b uuid := app.uuid_v7(); den_c uuid := app.uuid_v7(); den_d uuid := app.uuid_v7(); den_e uuid := app.uuid_v7();
  ar_ok uuid := app.uuid_v7(); ar_pend uuid := app.uuid_v7(); ar_big uuid := app.uuid_v7(); ar_self uuid := app.uuid_v7();
  ar_cancel uuid := app.uuid_v7(); ar_rej uuid := app.uuid_v7(); ar_x uuid := app.uuid_v7();
  cs_empty uuid := app.uuid_v7(); cs_open uuid := app.uuid_v7();
  rp1 uuid := app.uuid_v7(); rp2 uuid := app.uuid_v7(); rl_ok uuid := app.uuid_v7(); rl_no uuid := app.uuid_v7(); rl_ok2 uuid := app.uuid_v7();
  eq_ok uuid := app.uuid_v7(); eq_unk uuid := app.uuid_v7(); er_ok uuid := app.uuid_v7(); er_unk uuid := app.uuid_v7();
  mv uuid := app.uuid_v7(); ai1 uuid := app.uuid_v7(); rv1 uuid := app.uuid_v7();
  ev_ok uuid; ev_hold uuid; ev_nocov uuid; ev_a uuid; ev_b uuid; ev_pl uuid; ev_h23 uuid; ev_noise uuid; ev_t uuid;
  agg_other uuid := gen_random_uuid();
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner, no claims)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values
      ('t_sup', 'Supervisor', 'provider'), ('t_mgr', 'Manager', 'provider'),
      ('t_prov', 'Provider staff', 'provider'), ('t_payer', 'Payer', 'payer');
    insert into auth.users (id, aud, role, email) values
      (u_sup,     'authenticated', 'authenticated', 's1@meridian.test'),
      (u_sup2,    'authenticated', 'authenticated', 's2@meridian.test'),
      (u_mgr,     'authenticated', 'authenticated', 'm1@meridian.test'),
      (u_nolimit, 'authenticated', 'authenticated', 'n1@meridian.test'),
      (u_t2,      'authenticated', 'authenticated', 't2@meridian.test'),
      (u_payer,   'authenticated', 'authenticated', 'py@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, party_id, display_name) values
      (u_sup,     t1, 'provider', 't_sup',   null,  'Supervisor One'),
      (u_sup2,    t1, 'provider', 't_sup',   null,  'Supervisor Two'),
      (u_mgr,     t1, 'provider', 't_mgr',   null,  'Manager One'),
      (u_nolimit, t1, 'provider', 't_prov',  null,  'Staff No Limit'),
      (u_t2,      t2, 'provider', 't_sup',   null,  'Supervisor Tenant Two'),
      (u_payer,   t1, 'payer',    't_payer', pay_a, 'Payer A user');
    insert into app.approval_limit (tenant_id, role_key, kind, max_amount) values
      (t1, 't_sup', 'appeal', 2500.00), (t1, 't_mgr', 'appeal', 10000.00), (t2, 't_sup', 'appeal', 2500.00);

    insert into app.provider (provider_id, tenant_id, npi, name) values (prv, t1, '1000000001', 'Dr One');
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values
      (pat_a, t1, 'MRN-A', 'Ada', 'Alpha', date '1980-01-01');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values (pay_a, t1, 'Payer A', 'PA01', 'commercial');
    insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values
      (cov_a, t1, pat_a, pay_a, 'MEM-A', date '2026-01-01', 'eligibility');

    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, hold, hold_reason) values
      (cl_ok,    t1, 'C-OK',    pat_a, prv, pay_a, cov_a, 'ready', false, null),
      (cl_hold,  t1, 'C-HOLD',  pat_a, prv, pay_a, cov_a, 'ready', true,  'Missing signature'),
      (cl_nocov, t1, 'C-NOCOV', pat_a, prv, pay_a, null,  'ready', false, null),
      (cl_hard,  t1, 'C-HARD',  pat_a, prv, pay_a, cov_a, 'ready', false, null),
      (cl_fixed, t1, 'C-FIXED', pat_a, prv, pay_a, cov_a, 'ready', false, null),
      (cl_soft,  t1, 'C-SOFT',  pat_a, prv, pay_a, cov_a, 'ready', false, null),
      (cl_bal,   t1, 'C-BAL',   pat_a, prv, pay_a, cov_a, 'accepted', false, null),
      (cl_open,  t1, 'C-OPEN',  pat_a, prv, pay_a, cov_a, 'accepted', false, null);
    insert into app.claim_edit_result (tenant_id, claim_id, rule_code, severity, passed, checked_at) values
      (t1, cl_ok,    'NCCI-01', 'hard', true,  now()),
      (t1, cl_hard,  'NCCI-01', 'hard', false, now()),
      (t1, cl_fixed, 'NCCI-01', 'hard', false, now() - interval '2 days'),
      (t1, cl_fixed, 'NCCI-01', 'hard', true,  now() - interval '1 day'),
      (t1, cl_soft,  'FMT-02',  'soft', false, now());
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (ln_bal,  t1, cl_bal,  1, '99213', 100.00),
      (ln_open, t1, cl_open, 1, '99214', 100.00);
    insert into app.payment_posting (tenant_id, line_id, kind, amount) values
      (t1, ln_bal, 'payment', 70.00), (t1, ln_bal, 'adjustment', 10.00), (t1, ln_bal, 'patient_share', 20.00),
      (t1, ln_open, 'payment', 50.00);

    insert into app.remittance (remittance_id, tenant_id, payer_id, trace_number, payment_amount) values
      (rem_ok,    t1, pay_a, 'TRN-OK',    70.00),
      (rem_unm,   t1, pay_a, 'TRN-UNM',   10.00),
      (rem_short, t1, pay_a, 'TRN-SH',   100.00),
      (rem_empty, t1, pay_a, 'TRN-EMPTY', 0.00);
    insert into app.remittance_line (tenant_id, remittance_id, claim_id, paid) values
      (t1, rem_ok,    cl_ok, 70.00),
      (t1, rem_unm,   null,  10.00),
      (t1, rem_short, cl_ok, 40.00);
    insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values
      (dep_ok,    t1, pay_a, 'TRN-OK', 70.00),
      (dep_alloc, t1, pay_a, 'BANK-9', 100.00),
      (dep_empty, t1, pay_a, 'BANK-0',  5.00);
    insert into app.deposit_allocation (tenant_id, deposit_id, remittance_id, amount) values
      (t1, dep_alloc, rem_short, 40.00);

    insert into app.denial (denial_id, tenant_id, claim_id, carc, rarc, denied_amount) values
      (den_a, t1, cl_ok, '45',  'N54', 10.00),
      (den_b, t1, cl_ok, null,  null,  10.00),
      (den_c, t1, cl_ok, '197', null,  10.00),
      (den_d, t1, cl_ok, '50',  null,  10.00),
      (den_e, t1, cl_ok, '50',  null,  10.00);
    insert into app.denial_triage (tenant_id, denial_id, recommended_path, confirmed_path, override_reason, confirmed_by, confirmed_at) values
      (t1, den_c, 'appeal', 'appeal',     null,         u_sup, now()),
      (t1, den_d, 'appeal', 'correction', 'Wrong code', u_sup, now());
    insert into app.denial_triage (tenant_id, denial_id, recommended_path) values (t1, den_e, 'appeal');

    insert into app."case" (case_id, tenant_id, case_number, patient_id) values
      (cs_empty, t1, 'CASE-E', pat_a), (cs_open, t1, 'CASE-O', pat_a);
    insert into app.case_claim (tenant_id, case_id, claim_id) values (t1, cs_open, cl_open);

    insert into app.eligibility_request (eligibility_request_id, tenant_id, patient_id, payer_id, service_date) values
      (eq_ok, t1, pat_a, pay_a, current_date), (eq_unk, t1, pat_a, pay_a, current_date);
    insert into app.eligibility_response (eligibility_response_id, tenant_id, eligibility_request_id, coverage_status) values
      (er_ok, t1, eq_ok, 'active'), (er_unk, t1, eq_unk, 'unknown');

    -- ---------------------------------------------------------------- tables, RLS, grants, FK
    r := pg_temp._add(r, 'new workflow / rules / AI tables exist with tenant_id, RLS and no client write grants',
      (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'app' and c.relname = any (new_tables) and c.relrowsecurity) = 9
      and (select count(*) from information_schema.columns where table_schema = 'app' and table_name = any (new_tables)
              and column_name = 'tenant_id' and is_nullable = 'NO') = 9
      and not exists (select 1 from unnest(new_tables) t
                       where has_table_privilege('authenticated', 'app.' || t, 'insert')
                          or has_table_privilege('authenticated', 'app.' || t, 'update')
                          or has_table_privilege('authenticated', 'app.' || t, 'delete')
                          or has_table_privilege('anon', 'app.' || t, 'select'))
      and not exists (select 1 from unnest(new_tables) t where not has_table_privilege('authenticated', 'app.' || t, 'select')));
    r := pg_temp._add(r, 'every new table has a SELECT policy and the audit-column trigger',
      (select count(distinct tablename) from pg_policies where schemaname = 'app' and tablename = any (new_tables) and cmd = 'SELECT') = 9
      and (select count(distinct c.relname) from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgfoid = 'app.touch()'::regprocedure and not t.tgisinternal and c.relname = any (new_tables)) = 9);
    r := pg_temp._add(r, 'patient_payment.approval_request_id now has an FK to approval_request',
      exists (select 1 from pg_constraint where conrelid = 'app.patient_payment'::regclass
               and confrelid = 'app.approval_request'::regclass and contype = 'f'));
    r := pg_temp._add(r, 'handover_event has the unique key (handover_id, subject_id, source_event_id) and the status check',
      exists (select 1 from pg_constraint k where k.conrelid = 'app.handover_event'::regclass and k.contype = 'u'
               and (select array_agg(a.attname::text order by a.attname::text) from unnest(k.conkey) x
                      join pg_attribute a on a.attrelid = k.conrelid and a.attnum = x) = array['handover_id','source_event_id','subject_id'])
      and pg_temp._try(format($q$insert into app.handover_event (tenant_id, handover_id, subject_id, source_event_id, status)
                              values (%L, 'H13', %L, %L, 'bogus')$q$, t1, cl_ok, gen_random_uuid())) in ('23514', '23503'));

    -- ---------------------------------------------------------------- handover definitions (spec 5.4 and 5.2)
    r := pg_temp._add(r, 'ref.handover_def holds exactly H13..H24 with the spec events',
      (select array_agg(handover_id || '=' || trigger_event order by handover_id) from ref.handover_def where handover_id ~ '^H(1[3-9]|2[0-4])$')
        = array['H13=claim.ready','H14=claim.submitted','H15=remittance.received','H16=denial.created',
                'H17=denial.path_confirmed','H18=approval.decided','H19=payment.posted','H20=deposit.allocated',
                'H21=case.closure_evaluated','H22=rule.published','H23=authorization.requested',
                'H24=eligibility.response_received']
      and (select count(*) from ref.handover_def where handover_id !~ '^H(1[3-9]|2[0-4])$' ) = 0);
    r := pg_temp._add(r, 'H23 is inactive, every other handover is active',
      (select array_agg(handover_id) from ref.handover_def where not active) = array['H23']);
    r := pg_temp._add(r, 'hold queues and ready checks are the spec text',
      (select hold_queue from ref.handover_def where handover_id = 'H13') = 'Back to the holding queue'
      and (select hold_queue from ref.handover_def where handover_id = 'H14') = 'Rejection queue'
      and (select hold_queue from ref.handover_def where handover_id = 'H15') = 'Unmatched remit queue'
      and (select hold_queue from ref.handover_def where handover_id = 'H20') = 'Break log'
      and (select ready_check from ref.handover_def where handover_id = 'H18') = 'Approved by a reviewer within limit'
      and (select ready_check from ref.handover_def where handover_id = 'H20') = 'A deposit exists for the trace'
      and not exists (select 1 from ref.handover_def where nullif(btrim(route), '') is null or nullif(btrim(ready_check), '') is null
                                                       or nullif(btrim(hold_queue), '') is null));

    -- ---------------------------------------------------------------- ready checks, one at a time
    r := pg_temp._add(r, 'H13: coverage set, no hold and no failed hard edit passes; hold / no coverage / failed hard edit fail',
      ref.check_h13(cl_ok) and ref.check_h13(cl_fixed) and ref.check_h13(cl_soft)
      and not ref.check_h13(cl_hold) and not ref.check_h13(cl_nocov) and not ref.check_h13(cl_hard)
      and not ref.check_h13(gen_random_uuid()));
    r := pg_temp._add(r, 'H14: passes edits (a later passing result clears an earlier failure; soft failures do not block)',
      ref.check_h14(cl_ok) and ref.check_h14(cl_fixed) and ref.check_h14(cl_soft) and ref.check_h14(cl_hold)
      and not ref.check_h14(cl_hard) and not ref.check_h14(gen_random_uuid()));
    r := pg_temp._add(r, 'H15: remittance complete (lines add up to the control total) and matched to claims',
      ref.check_h15(rem_ok) and not ref.check_h15(rem_unm) and not ref.check_h15(rem_short)
      and not ref.check_h15(rem_empty) and not ref.check_h15(gen_random_uuid()));
    r := pg_temp._add(r, 'H16: denial has a parsed CARC (RARC optional)',
      ref.check_h16(den_a) and ref.check_h16(den_c) and not ref.check_h16(den_b) and not ref.check_h16(gen_random_uuid()));
    r := pg_temp._add(r, 'H17: latest triage confirmed (override needs a reason); unconfirmed or no triage fails',
      ref.check_h17(den_c) and ref.check_h17(den_d) and not ref.check_h17(den_e) and not ref.check_h17(den_a));
    r := pg_temp._add(r, 'H19: every line of the claim has a zero payer-side open amount',
      ref.check_h19(cl_bal) and not ref.check_h19(cl_open) and not ref.check_h19(cl_ok) and not ref.check_h19(gen_random_uuid()));
    r := pg_temp._add(r, 'H20: a deposit exists for the trace (bank reference or net-positive allocation)',
      ref.check_h20(rem_ok) and ref.check_h20(rem_short) and not ref.check_h20(rem_unm)
      and ref.check_h20(dep_alloc) and not ref.check_h20(dep_empty) and not ref.check_h20(gen_random_uuid()));
    r := pg_temp._add(r, 'H21: no case_blockers rows passes; any blocker fails',
      ref.check_h21(cs_empty) and not ref.check_h21(cs_open) and not ref.check_h21(gen_random_uuid()));
    r := pg_temp._add(r, 'H24: eligibility response parsed (by response or request); unknown does not count',
      ref.check_h24(er_ok) and ref.check_h24(eq_ok) and not ref.check_h24(er_unk) and not ref.check_h24(eq_unk)
      and not ref.check_h24(gen_random_uuid()));
    r := pg_temp._add(r, 'H23 check exists and returns false (inactive: no authorization table in release 1)',
      not ref.check_h23(cl_ok) and not ref.check_h23(gen_random_uuid()));
    r := pg_temp._add(r, 'all twelve check functions exist, take uuid and return boolean',
      (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'ref' and p.proname ~ '^check_h(1[3-9]|2[0-4])$' and p.prorettype = 'boolean'::regtype
          and p.pronargs = 1 and p.proargtypes[0] = 'uuid'::regtype::oid) = 12);

    -- ---------------------------------------------------------------- rules and AI tables
    insert into app.rule_pack (rule_pack_id, tenant_id, name, version, effective_from, status) values
      (rp1, t1, 'Payer rules', 1, current_date, 'active'), (rp2, t1, 'Coding rules', 1, current_date, 'active');
    insert into app.rule (rule_id, tenant_id, rule_pack_id, rule_key, payload, effective_from, owner, approved_by, approved_at) values
      (rl_ok,  t1, rp1, 'timely_filing', '{"days":90}'::jsonb, current_date, u_sup, u_mgr, now()),
      (rl_no,  t1, rp1, 'appeal_levels', '{"levels":2}'::jsonb, current_date, u_sup, null, null),
      (rl_ok2, t1, rp2, 'ncci',          '{"on":true}'::jsonb, current_date, u_sup, u_mgr, now());
    r := pg_temp._add(r, 'H22: approved rule passes, unapproved fails; a pack passes only when all its rules are approved',
      ref.check_h22(rl_ok) and not ref.check_h22(rl_no) and ref.check_h22(rp2) and not ref.check_h22(rp1)
      and not ref.check_h22(gen_random_uuid()));
    r := pg_temp._add(r, 'rule approval columns come as a pair',
      pg_temp._try(format($q$insert into app.rule (tenant_id, rule_pack_id, rule_key, payload, effective_from, owner, approved_by)
                          values (%L, %L, 'bad', '{}'::jsonb, current_date, %L, %L)$q$, t1, rp1, u_sup, u_mgr)) = '23514');
    insert into app.ai_model_version (ai_model_version_id, tenant_id, name, version, purpose, status) values
      (mv, t1, 'triage-sim', '1.0', 'Denial triage (simulated)', 'approved');
    insert into app.ai_interaction (ai_interaction_id, tenant_id, task, subject_type, subject_id, model_version_id, input_ref, output) values
      (ai1, t1, 'denial_triage', 'denial', den_a, mv, 'denial:' || den_a, '{"path":"appeal"}'::jsonb);
    insert into app.ai_review (ai_review_id, tenant_id, ai_interaction_id, reviewer_id, decision, reason, reviewed_at) values
      (rv1, t1, ai1, u_sup, 'accepted', 'Looks right', now());
    r := pg_temp._add(r, 'ai_interaction defaults its label to Simulated; ai_review decision is constrained',
      (select label from app.ai_interaction where ai_interaction_id = ai1) = 'Simulated'
      and pg_temp._try(format($q$insert into app.ai_review (tenant_id, ai_interaction_id, reviewer_id, decision, reviewed_at)
                              values (%L, %L, %L, 'maybe', now())$q$, t1, ai1, u_sup)) = '23514');

    -- ---------------------------------------------------------------- approval trigger (IV13)
    insert into app.approval_request (approval_request_id, tenant_id, kind, amount, requester_id, subject_type, subject_id) values
      (ar_ok,     t1, 'appeal', 1000.00, u_sup, 'appeal', gen_random_uuid()),
      (ar_pend,   t1, 'appeal',  500.00, u_sup, 'appeal', gen_random_uuid()),
      (ar_big,    t1, 'appeal', 5000.00, u_sup, 'appeal', gen_random_uuid()),
      (ar_self,   t1, 'appeal',  100.00, u_sup, 'appeal', gen_random_uuid()),
      (ar_cancel, t1, 'appeal',  100.00, u_sup, 'appeal', gen_random_uuid()),
      (ar_rej,    t1, 'appeal',  100.00, u_sup, 'appeal', gen_random_uuid());
    r := pg_temp._add(r, 'approval_request starts pending (default) and cannot be inserted already decided (MR002)',
      (select status from app.approval_request where approval_request_id = ar_ok) = 'pending'
      and pg_temp._try(format($q$insert into app.approval_request (tenant_id, kind, amount, requester_id, approver_id, status)
                              values (%L, 'appeal', 10, %L, %L, 'approved')$q$, t1, u_sup, u_sup2)) = 'MR002');
    v_x := pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L where approval_request_id = %L$q$, u_sup, ar_self));
    r := pg_temp._add(r, 'IV13: requester cannot approve their own request (MR003), state unchanged',
      v_x = 'MR003' and (select status from app.approval_request where approval_request_id = ar_self) = 'pending');
    r := pg_temp._add(r, 'approval needs an approver (MR002)',
      pg_temp._try(format($q$update app.approval_request set status = 'approved' where approval_request_id = %L$q$, ar_ok)) = 'MR002');
    r := pg_temp._add(r, 'approver from another tenant is refused (MR003)',
      pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L where approval_request_id = %L$q$, u_t2, ar_ok)) = 'MR003');
    r := pg_temp._add(r, 'approver whose role has no limit for the kind is refused (MR003)',
      pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L where approval_request_id = %L$q$, u_nolimit, ar_ok)) = 'MR003'
      and pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L where approval_request_id = %L$q$, u_payer, ar_ok)) = 'MR003');
    v_x := pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L where approval_request_id = %L$q$, u_sup2, ar_big));
    r := pg_temp._add(r, 'approving over the approver limit is refused (MR003), state unchanged',
      v_x = 'MR003' and (select status from app.approval_request where approval_request_id = ar_big) = 'pending');
    v_x := pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L where approval_request_id = %L$q$, u_sup2, ar_ok));
    r := pg_temp._add(r, 'approving within the limit by another person works and stamps decided_at',
      v_x = 'ok' and (select status = 'approved' and decided_at is not null from app.approval_request where approval_request_id = ar_ok));
    v_x := pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L where approval_request_id = %L$q$, u_mgr, ar_big));
    r := pg_temp._add(r, 'a manager with a higher limit approves the large request',
      v_x = 'ok' and (select status from app.approval_request where approval_request_id = ar_big) = 'approved');
    r := pg_temp._add(r, 'a decided request is final: other status (MR001) or changed amount (MR002) refused',
      pg_temp._try(format($q$update app.approval_request set status = 'rejected' where approval_request_id = %L$q$, ar_ok)) = 'MR001'
      and pg_temp._try(format($q$update app.approval_request set status = 'pending' where approval_request_id = %L$q$, ar_ok)) = 'MR001'
      and pg_temp._try(format($q$update app.approval_request set amount = 1 where approval_request_id = %L$q$, ar_ok)) = 'MR002');
    r := pg_temp._add(r, 'reject needs a non-requester approver; cancel needs none',
      pg_temp._try(format($q$update app.approval_request set status = 'rejected', approver_id = %L where approval_request_id = %L$q$, u_sup, ar_rej)) = 'MR003'
      and pg_temp._try(format($q$update app.approval_request set status = 'rejected', approver_id = %L where approval_request_id = %L$q$, u_sup2, ar_rej)) = 'ok'
      and pg_temp._try(format($q$update app.approval_request set status = 'cancelled' where approval_request_id = %L$q$, ar_cancel)) = 'ok');
    r := pg_temp._add(r, 'H18: approved by a different person within limit passes; pending, rejected fail',
      ref.check_h18(ar_ok) and ref.check_h18(ar_big)
      and not ref.check_h18(ar_pend) and not ref.check_h18(ar_rej) and not ref.check_h18(ar_cancel)
      and not ref.check_h18(gen_random_uuid()));
    -- the trigger is the only gate: even a direct bypass attempt of the check constraint fails
    r := pg_temp._add(r, 'approval_request has the approver <> requester check as a backstop',
      exists (select 1 from pg_constraint where conrelid = 'app.approval_request'::regclass and contype = 'c'
               and pg_get_constraintdef(oid) ~ 'approver_id <> requester_id'));

    -- ---------------------------------------------------------------- engine: static properties
    r := pg_temp._add(r, 'process_outbox is SECURITY DEFINER with an empty search_path, returns integer, uses FOR UPDATE SKIP LOCKED',
      exists (select 1 from pg_proc p where p.oid = 'app.process_outbox()'::regprocedure and p.prosecdef
                and p.prorettype = 'integer'::regtype and p.proconfig @> array['search_path=""'])
      and (select pg_get_functiondef('app.process_outbox()'::regprocedure)) ~* 'for update of \w+ skip locked');
    r := pg_temp._add(r, 'process_outbox and the checks are not executable by client roles or PUBLIC',
      not has_function_privilege('authenticated', 'app.process_outbox()', 'execute')
      and not has_function_privilege('anon', 'app.process_outbox()', 'execute')
      and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                       where a.grantee = 0 and (p.oid = 'app.process_outbox()'::regprocedure
                         or (p.pronamespace = 'ref'::regnamespace and p.proname like 'check\_h%')))
      and not has_function_privilege('authenticated', 'ref.check_h13(uuid)', 'execute')
      and not has_function_privilege('anon', 'ref.check_h21(uuid)', 'execute'));
    r := pg_temp._add(r, 'pg_cron job process_outbox_every_minute runs app.process_outbox() every minute',
      exists (select 1 from cron.job j where j.jobname = 'process_outbox_every_minute'
                and j.schedule = '* * * * *' and j.command ~* 'app\.process_outbox\(\)' and j.active));

    -- ---------------------------------------------------------------- engine: behaviour
    insert into ref.handover_def (handover_id, route, trigger_event, ready_check, hold_queue, active)
      values ('H99', 'Test to Test', 'test.event', 'No such check function', 'Test queue', true);

    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'claim.ready', cl_ok) returning event_id into ev_ok;
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'claim.ready', cl_hold) returning event_id into ev_hold;
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'claim.ready', cl_nocov) returning event_id into ev_nocov;
    -- two events for one aggregate; the first has the LARGER event_id, so only the sequence gives the right order
    insert into audit.outbox_event (event_id, tenant_id, type, aggregate_id)
      values ('ffffffff-ffff-7fff-bfff-fffffffffff0', t1, 'claim.ready', cl_hard) returning event_id into ev_a;
    insert into audit.outbox_event (event_id, tenant_id, type, aggregate_id)
      values ('00000000-0000-7000-8000-000000000001', t1, 'claim.submitted', cl_hard) returning event_id into ev_b;
    -- subject named in the payload wins over the aggregate
    insert into audit.outbox_event (tenant_id, type, aggregate_id, payload)
      values (t1, 'claim.submitted', agg_other, jsonb_build_object('subject_id', cl_ok)) returning event_id into ev_pl;
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'authorization.requested', cl_ok) returning event_id into ev_h23;
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'noise.happened', cl_ok) returning event_id into ev_noise;
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'test.event', cl_ok) returning event_id into ev_t;

    v_ret := app.process_outbox();
    r := pg_temp._add(r, 'process_outbox returns the number of events processed and marks them all processed',
      v_ret >= 9 and not exists (select 1 from audit.outbox_event where tenant_id = t1 and processed_at is null));

    r := pg_temp._add(r, 'passing check yields a passed handover and no task',
      (select count(*) from app.handover_event where source_event_id = ev_ok and handover_id = 'H13' and subject_id = cl_ok and status = 'passed') = 1
      and not exists (select 1 from app.task where tenant_id = t1 and subject_id = cl_ok and subject_type = 'claim'));
    r := pg_temp._add(r, 'IV26: failing check yields a held handover and exactly one task in the named queue',
      (select count(*) from app.handover_event where source_event_id = ev_hold and handover_id = 'H13' and subject_id = cl_hold and status = 'held') = 1
      and (select count(*) from app.task k join app.work_queue q on q.work_queue_id = k.queue_id
            where k.subject_id = cl_hold and q.name = 'Back to the holding queue' and q.tenant_id = t1 and k.tenant_id = t1
              and k.status = 'open') = 1
      and (select count(*) from app.task where subject_id = cl_hold) = 1);
    r := pg_temp._add(r, 'the work queue is created on first use, once per tenant and name',
      (select count(*) from app.work_queue where tenant_id = t1 and name = 'Back to the holding queue') = 1
      and (select count(*) from app.task k join app.work_queue q on q.work_queue_id = k.queue_id
            where q.name = 'Back to the holding queue' and k.subject_id in (cl_hold, cl_nocov)) = 2);
    r := pg_temp._add(r, 'events for one aggregate are processed in sequence order (not event_id order)',
      (select h.checked_at from app.handover_event h where h.source_event_id = ev_a)
        < (select h.checked_at from app.handover_event h where h.source_event_id = ev_b)
      and (select o.processed_at from audit.outbox_event o where o.event_id = ev_a)
        < (select o.processed_at from audit.outbox_event o where o.event_id = ev_b)
      and (select count(*) from app.handover_event where subject_id = cl_hard and status = 'held') = 2
      and (select count(*) from app.task k join app.work_queue q on q.work_queue_id = k.queue_id
            where k.subject_id = cl_hard and q.name in ('Back to the holding queue', 'Rejection queue')) = 2);
    r := pg_temp._add(r, 'a subject_id in the payload replaces the aggregate as the subject',
      (select count(*) from app.handover_event where source_event_id = ev_pl and subject_id = cl_ok and handover_id = 'H14' and status = 'passed') = 1
      and not exists (select 1 from app.handover_event where source_event_id = ev_pl and subject_id = agg_other));
    r := pg_temp._add(r, 'inactive handover H23 and unknown events are skipped but marked processed',
      not exists (select 1 from app.handover_event where source_event_id in (ev_h23, ev_noise))
      and (select count(*) from audit.outbox_event where event_id in (ev_h23, ev_noise) and processed_at is not null) = 2);
    r := pg_temp._add(r, 'a check that cannot be evaluated records failed_check and still creates one task',
      (select count(*) from app.handover_event where source_event_id = ev_t and handover_id = 'H99' and status = 'failed_check') = 1
      and (select count(*) from app.task k join app.work_queue q on q.work_queue_id = k.queue_id
            where q.name = 'Test queue' and q.tenant_id = t1) = 1);

    -- replay (IV27): mark every event unprocessed again and run twice more
    select count(*) into v_h from app.handover_event where tenant_id = t1;
    select count(*) into v_t from app.task where tenant_id = t1;
    select count(*) into v_q from app.work_queue where tenant_id = t1;
    update audit.outbox_event set processed_at = null where tenant_id = t1;
    perform app.process_outbox();
    perform app.process_outbox();
    r := pg_temp._add(r, 'IV27: processing the same outbox events again creates no second handover event, task or queue',
      (select count(*) from app.handover_event where tenant_id = t1) = v_h
      and (select count(*) from app.task where tenant_id = t1) = v_t
      and (select count(*) from app.work_queue where tenant_id = t1) = v_q
      and not exists (select 1 from audit.outbox_event where tenant_id = t1 and processed_at is null)
      and v_h = 7 and v_t = 5);
    r := pg_temp._add(r, 'a replay does not change an earlier held verdict',
      (select status from app.handover_event where source_event_id = ev_hold and handover_id = 'H13') = 'held');

    -- ---------------------------------------------------------------- RLS
    perform pg_temp._claims(u_sup);
    set local role authenticated;
    r := pg_temp._add(r, 'tenant staff see their own handover events, tasks, queues, approvals, rules and AI rows',
      pg_temp._n('select count(*) from app.handover_event') = v_h
      and pg_temp._n('select count(*) from app.task') = v_t
      and pg_temp._n('select count(*) from app.work_queue') = v_q
      and pg_temp._n('select count(*) from app.approval_request') = 6
      and pg_temp._n('select count(*) from app.rule_pack') = 2 and pg_temp._n('select count(*) from app.rule') = 3
      and pg_temp._n('select count(*) from app.ai_model_version') = 1 and pg_temp._n('select count(*) from app.ai_interaction') = 1
      and pg_temp._n('select count(*) from app.ai_review') = 1);
    r := pg_temp._add(r, 'clients cannot write to the new tables or call the engine (42501)',
      pg_temp._try(format($q$insert into app.task (tenant_id, queue_id, subject_type, subject_id) select tenant_id, work_queue_id, 'claim', %L from app.work_queue limit 1$q$, cl_ok)) = '42501'
      and pg_temp._try(format($q$update app.handover_event set status = 'passed' where tenant_id = %L$q$, t1)) = '42501'
      and pg_temp._try(format($q$delete from app.approval_request where tenant_id = %L$q$, t1)) = '42501'
      and pg_temp._try('select app.process_outbox()') = '42501'
      and pg_temp._try('select ref.check_h13(gen_random_uuid())') = '42501');
    reset role;

    perform pg_temp._claims(u_t2);
    set local role authenticated;
    r := pg_temp._add(r, 'another tenant sees none of these rows',
      pg_temp._n('select count(*) from app.handover_event') = 0 and pg_temp._n('select count(*) from app.task') = 0
      and pg_temp._n('select count(*) from app.work_queue') = 0 and pg_temp._n('select count(*) from app.approval_request') = 0
      and pg_temp._n('select count(*) from app.rule_pack') = 0 and pg_temp._n('select count(*) from app.rule') = 0
      and pg_temp._n('select count(*) from app.ai_model_version') = 0 and pg_temp._n('select count(*) from app.ai_interaction') = 0
      and pg_temp._n('select count(*) from app.ai_review') = 0);
    reset role;

    perform pg_temp._claims(u_payer);
    set local role authenticated;
    r := pg_temp._add(r, 'a payer sees none of these rows',
      pg_temp._n('select count(*) from app.handover_event') = 0 and pg_temp._n('select count(*) from app.task') = 0
      and pg_temp._n('select count(*) from app.work_queue') = 0 and pg_temp._n('select count(*) from app.approval_request') = 0
      and pg_temp._n('select count(*) from app.rule') = 0 and pg_temp._n('select count(*) from app.ai_interaction') = 0);
    reset role;

    set local role anon;
    r := pg_temp._add(r, 'anon cannot read the new tables (42501)',
      pg_temp._try('select count(*) from app.task') = '42501' and pg_temp._try('select count(*) from app.handover_event') = '42501');
    reset role;

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id in (t1, t2))
    and not exists (select 1 from auth.users where id in (u_sup, u_sup2, u_mgr, u_nolimit, u_t2, u_payer))
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\')
    and not exists (select 1 from app.task where tenant_id in (t1, t2))
    and not exists (select 1 from app.handover_event where tenant_id in (t1, t2))
    and not exists (select 1 from app.work_queue where tenant_id in (t1, t2))
    and not exists (select 1 from audit.outbox_event where tenant_id in (t1, t2))
    and not exists (select 1 from ref.handover_def where handover_id = 'H99'));

  perform tests.assert((e->>'p')::boolean, e->>'m') from jsonb_array_elements(r) e;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._n(text);
drop function pg_temp._claims(uuid);

select tests.report();
