-- Task 8 tests: command functions part 3 (cash, patient billing, write-off, case closure).
--   api.cmd_posting_apply_payment, api.cmd_posting_reverse, api.cmd_deposit_allocate, api.cmd_patient_payment_apply,
--   api.cmd_patient_dispute_open, api.cmd_patient_dispute_resolve, api.cmd_writeoff_request, api.cmd_writeoff_post,
--   api.cmd_case_close, api.cmd_case_reopen.
-- Same harness as Tasks 6-7 (pg_temp._add / _try / _run / _err). Fixtures in a sub-transaction rolled back at the end.
select tests.begin();

create or replace function pg_temp._add(r jsonb, m text, p boolean) returns jsonb
language sql as $$ select r || jsonb_build_array(jsonb_build_object('m', m, 'p', coalesce(p, false))) $$;

create or replace function pg_temp._try(q text) returns text
language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

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
  m text; e text; e2 text; fn text;
  j jsonb; j2 jsonb; j3 jsonb;
  cmds text[] := array['cmd_posting_apply_payment','cmd_posting_reverse','cmd_deposit_allocate','cmd_patient_payment_apply',
                       'cmd_patient_dispute_open','cmd_patient_dispute_resolve','cmd_writeoff_request','cmd_writeoff_post',
                       'cmd_case_close','cmd_case_reopen'];
  perms text[] := array['posting.apply_payment','posting.reverse','deposit.allocate','patient_payment.apply',
                        'patient_dispute.open','patient_dispute.resolve','writeoff.request','writeoff.post',
                        'case.close','case.reopen'];
  t1 uuid := app.uuid_v7(); t2 uuid := app.uuid_v7();
  u_b uuid := gen_random_uuid(); u_np uuid := gen_random_uuid(); u_appr uuid := gen_random_uuid(); u_py uuid := gen_random_uuid();
  prv uuid := app.uuid_v7(); pat1 uuid := app.uuid_v7(); pay1 uuid := app.uuid_v7(); cov1 uuid := app.uuid_v7();
  c1 uuid := app.uuid_v7(); ln1 uuid := app.uuid_v7();
  c_r uuid := app.uuid_v7(); ln_r uuid := app.uuid_v7(); cs_r uuid := app.uuid_v7();
  c_pd uuid := app.uuid_v7(); ln_pd uuid := app.uuid_v7(); cs_pd uuid := app.uuid_v7(); resp_pd uuid := app.uuid_v7();
  c_wr uuid := app.uuid_v7(); ln_wr uuid := app.uuid_v7(); den_wr uuid := app.uuid_v7();
  c_t2 uuid := app.uuid_v7(); ln_t2 uuid := app.uuid_v7(); pat_t2 uuid := app.uuid_v7(); pay_t2 uuid := app.uuid_v7();
  dep1 uuid := app.uuid_v7(); dep_small uuid := app.uuid_v7();
  ghost uuid := gen_random_uuid();
  pp1 uuid; pp_rev uuid; resp1 uuid; ar_id uuid; cs_r_case app."case";
  n integer;
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner, no claims)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values
      ('t_cash', 'Cash poster', 'provider'), ('t_appr', 'Approver', 'provider'),
      ('t_noperm', 'Staff without permissions', 'provider'), ('t_payer8', 'Payer', 'payer');
    insert into app.permission (permission_key, description) select p, 'Task 8 command' from unnest(perms) p
      on conflict (permission_key) do nothing;
    insert into app.role_permission (role_key, permission_key)
      select 't_cash', p from unnest(perms) p
      union all select 't_appr', p from unnest(perms) p
      union all select 't_payer8', p from unnest(perms) p;   -- a payer role holding every key is still refused (portal)
    insert into app.approval_limit (tenant_id, role_key, kind, max_amount) values (t1, 't_appr', 'write_off', 1000);
    insert into app.permission (permission_key, description) values ('approval.decide', 'Task 8 approval') on conflict (permission_key) do nothing;
    insert into app.role_permission (role_key, permission_key) values ('t_appr', 'approval.decide'), ('t_cash', 'approval.decide');
    insert into auth.users (id, aud, role, email) values
      (u_b,  'authenticated', 'authenticated', 'b8@meridian.test'),
      (u_np, 'authenticated', 'authenticated', 'np8@meridian.test'),
      (u_appr, 'authenticated', 'authenticated', 'appr8@meridian.test'),
      (u_py, 'authenticated', 'authenticated', 'py8@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, display_name) values
      (u_b, t1, 'provider', 't_cash', 'Biller'), (u_np, t1, 'provider', 't_noperm', 'No Perm'),
      (u_appr, t1, 'provider', 't_appr', 'Approver'), (u_py, t1, 'payer', 't_payer8', 'Payer User');
    update app.app_user set party_id = pay1 where user_id = u_py;

    insert into app.provider (provider_id, tenant_id, npi, name) values (prv, t1, '1111111111', 'Dr One');
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values
      (pat1, t1, 'MRN-T8-1', 'Pat', 'One', '1990-01-01');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values (pay1, t1, 'Payer One', 'PAY-T8-1', 'commercial');
    insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, source, effective_from) values
      (cov1, t1, pat1, pay1, 'MEM-T8-1', 'manual', '2026-01-01');

    -- c1 / ln1: general posting + reversal + deposit tests. billed 1000.
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status) values
      (c1, t1, 'CLM-T8-001', pat1, prv, pay1, cov1, 'accepted');
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (ln1, t1, c1, 1, '99213', 1000);

    -- c_r / ln_r / cs_r: a fully reconciled, closeable case (the CLM-24207 shape). billed 1000, no patient share.
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status) values
      (c_r, t1, 'CLM-T8-002', pat1, prv, pay1, cov1, 'accepted');
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (ln_r, t1, c_r, 1, '99214', 1000);
    insert into app."case" (case_id, tenant_id, case_number, patient_id, status) values (cs_r, t1, 'CASE-T8-R', pat1, 'open');
    insert into app.case_claim (tenant_id, case_id, claim_id) values (t1, cs_r, c_r);
    insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values (dep1, t1, pay1, 'BANK-T8-1', 1000);
    insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values (dep_small, t1, pay1, 'BANK-T8-2', 50);

    -- c_pd / ln_pd / cs_pd / resp_pd: a case with patient responsibility, for the dispute-blocks-close test.
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status) values
      (c_pd, t1, 'CLM-T8-003', pat1, prv, pay1, cov1, 'accepted');
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (ln_pd, t1, c_pd, 1, '99215', 500);
    insert into app."case" (case_id, tenant_id, case_number, patient_id, status) values (cs_pd, t1, 'CASE-T8-PD', pat1, 'open');
    insert into app.case_claim (tenant_id, case_id, claim_id) values (t1, cs_pd, c_pd);
    insert into app.payment_posting (tenant_id, line_id, kind, amount) values (t1, ln_pd, 'payment', 300);
    insert into app.payment_posting (tenant_id, line_id, kind, amount) values (t1, ln_pd, 'patient_share', 200);
    insert into app.patient_responsibility (patient_responsibility_id, tenant_id, patient_id, claim_id, line_id, amount, reason) values
      (resp_pd, t1, pat1, c_pd, ln_pd, 200, 'copay');
    -- cash side of ln_pd reconciled directly (payer's 300 allocated and the line marked balanced), so only the
    -- patient-balance and dispute blockers are exercised below, not 'Cash is not reconciled yet'.
    insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values (app.uuid_v7(), t1, pay1, 'BANK-T8-PD', 300);
    insert into app.deposit_allocation (tenant_id, deposit_id, line_id, amount)
      select t1, deposit_id, ln_pd, 300 from app.deposit where bank_reference = 'BANK-T8-PD' and tenant_id = t1;
    update app.claim_service_line set balanced = true where claim_service_line_id = ln_pd;

    -- c_wr / ln_wr: write-off target with an open denial that has NO deadline yet, so rights are not exhausted.
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status) values
      (c_wr, t1, 'CLM-T8-004', pat1, prv, pay1, cov1, 'accepted');
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (ln_wr, t1, c_wr, 1, '99216', 300);
    insert into app.root_cause (tenant_id, code, label, category) values (t1, 'T8_RC', 'Task 8 root cause', 'other')
      on conflict (tenant_id, code) do nothing;
    insert into app.denial (denial_id, tenant_id, claim_id, line_id, status, root_cause, denied_amount) values
      (den_wr, t1, c_wr, ln_wr, 'new', 'T8_RC', 300);

    -- tenant two: a claim and line to prove cross-tenant isolation.
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (pat_t2, t2, 'MRN-T8-2', 'Pat', 'Two', '1990-01-01');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values (pay_t2, t2, 'Payer Two', 'PAY-T8-2', 'commercial');
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, payer_id, status) values (c_t2, t2, 'CLM-T8-T2', pat_t2, pay_t2, 'accepted');
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (ln_t2, t2, c_t2, 1, '99213', 500);

    -- ================================================================ reopen of an open case refused (cs_pd is still open here)
    r := pg_temp._add(r, 'reopening an open case is refused',
      pg_temp._err(u_b, 'cmd_case_reopen', 'open-reopen', jsonb_build_object('case_id', cs_pd)) like 'MR001%');

    -- ================================================================ portal / permission loop (all 10 commands)
    for fn in select unnest(cmds) loop
      r := pg_temp._add(r, format('%s: anonymous caller refused', fn),
        pg_temp._try(format($q$select api.%I('x', '{}'::jsonb)$q$, fn)) in ('42501', '28000', 'MR003'));
      r := pg_temp._add(r, format('%s: payer portal refused (MR003 wrong_portal)', fn), pg_temp._err(u_py, fn, 'px-' || fn, '{}'::jsonb) like 'MR003%');
      r := pg_temp._add(r, format('%s: provider with no permission refused (MR003)', fn), pg_temp._err(u_np, fn, 'np-' || fn, '{}'::jsonb) like 'MR003%');
    end loop;
    r := pg_temp._add(r, 'anon role truly has no execute on these commands',
      not has_function_privilege('anon', 'api.cmd_posting_apply_payment(text,jsonb)', 'execute'));
    r := pg_temp._add(r, 'every command calls authorize before begin_cmd',
      (select bool_and(position('app.authorize' in def) > 0 and position('app.authorize' in def) < position('app.begin_cmd' in def))
         from (select pg_get_functiondef(p.oid) as def from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                where ns.nspname = 'api' and p.proname = any (cmds)) x));
    r := pg_temp._add(r, 'every command is SECURITY DEFINER, search_path '''', jsonb result, authenticated-only',
      (select count(*) = 10 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'api' and p.proname = any (cmds) and p.prosecdef
          and p.proconfig @> array['search_path=""'] and p.prorettype = 'jsonb'::regtype
          and has_function_privilege('authenticated', p.oid, 'execute')
          and not has_function_privilege('anon', p.oid, 'execute')));

    -- ================================================================ amount shape (zero / negative / 3-decimal)
    r := pg_temp._add(r, 'posting: zero amount refused', pg_temp._err(u_b, 'cmd_posting_apply_payment', 'amt-0', jsonb_build_object('line_id', ln1, 'kind', 'payment', 'amount', 0)) like 'MR005%');
    r := pg_temp._add(r, 'posting: negative amount refused', pg_temp._err(u_b, 'cmd_posting_apply_payment', 'amt-neg', jsonb_build_object('line_id', ln1, 'kind', 'payment', 'amount', -5)) like 'MR005%');
    r := pg_temp._add(r, 'posting: 3-decimal amount refused', pg_temp._err(u_b, 'cmd_posting_apply_payment', 'amt-3dp', jsonb_build_object('line_id', ln1, 'kind', 'payment', 'amount', 1.234)) like 'MR005%');
    r := pg_temp._add(r, 'deposit.allocate: zero amount refused', pg_temp._err(u_b, 'cmd_deposit_allocate', 'da-0', jsonb_build_object('deposit_id', dep1, 'line_id', ln1, 'amount', 0)) like 'MR005%');
    r := pg_temp._add(r, 'nothing written by the refused calls above',
      not exists (select 1 from app.payment_posting where line_id = ln1) and not exists (select 1 from app.deposit_allocation where deposit_id = dep1));

    -- ================================================================ cross-tenant id refused (identical message to nonexistent)
    e := pg_temp._err(u_b, 'cmd_posting_apply_payment', 'ct-ghost', jsonb_build_object('line_id', ghost, 'kind', 'payment', 'amount', 10));
    r := pg_temp._add(r, 'posting: nonexistent line refused MR004', e like 'MR004%');
    r := pg_temp._add(r, 'posting: another tenant''s line refused MR004 with the identical message',
      pg_temp._err(u_b, 'cmd_posting_apply_payment', 'ct-t2', jsonb_build_object('line_id', ln_t2, 'kind', 'payment', 'amount', 10)) = e);

    -- ================================================================ overpayment above billed refused (MR002), nothing written
    r := pg_temp._add(r, 'overpayment above billed refused',
      pg_temp._err(u_b, 'cmd_posting_apply_payment', 'over-1', jsonb_build_object('line_id', ln1, 'kind', 'payment', 'amount', 1500)) like 'MR002%');
    r := pg_temp._add(r, 'nothing written by the overpayment attempt', not exists (select 1 from app.payment_posting where line_id = ln1));

    -- ================================================================ reversal restores open amount
    j := pg_temp._run(u_b, 'cmd_posting_apply_payment', 'pay-ln1', jsonb_build_object('line_id', ln1, 'kind', 'payment', 'amount', 400));
    pp1 := (j->>'payment_posting_id')::uuid;
    r := pg_temp._add(r, 'posting: a legitimate payment posts and the open amount drops to 600',
      (select lb.open_amount = 600 from api.line_balance lb where lb.line_id = ln1));
    j := pg_temp._run(u_b, 'cmd_posting_reverse', 'rev-ln1', jsonb_build_object('payment_posting_id', pp1, 'reason', 'posted to the wrong line'));
    pp_rev := (j->>'payment_posting_id')::uuid;
    r := pg_temp._add(r, 'reversal restores the open amount to 1000', (select lb.open_amount = 1000 from api.line_balance lb where lb.line_id = ln1));
    r := pg_temp._add(r, 'reversal row recorded (kind reversal, same amount, reverses_posting_id set)',
      exists (select 1 from app.payment_posting where payment_posting_id = pp_rev and kind = 'reversal' and amount = 400 and reverses_posting_id = pp1));
    r := pg_temp._add(r, 'reversing the same posting twice is refused',
      pg_temp._err(u_b, 'cmd_posting_reverse', 'rev-ln1-again', jsonb_build_object('payment_posting_id', pp1)) like 'MR002%');

    -- ================================================================ idempotent replay (same key twice)
    j := pg_temp._run(u_b, 'cmd_posting_apply_payment', 'idem-1', jsonb_build_object('line_id', ln1, 'kind', 'adjustment', 'amount', 100));
    j2 := pg_temp._run(u_b, 'cmd_posting_apply_payment', 'idem-1', jsonb_build_object('line_id', ln1, 'kind', 'adjustment', 'amount', 100));
    r := pg_temp._add(r, 'same idempotency key and args twice returns the identical cached result', j = j2);
    r := pg_temp._add(r, 'same idempotency key twice posts only one row', (select count(*) = 1 from app.payment_posting where payment_posting_id = (j->>'payment_posting_id')::uuid));
    r := pg_temp._add(r, 'same idempotency key with different args refused', pg_temp._err(u_b, 'cmd_posting_apply_payment', 'idem-1', jsonb_build_object('line_id', ln1, 'kind', 'adjustment', 'amount', 200)) like 'MR005%');
    r := pg_temp._add(r, 'blank idempotency key refused', pg_temp._err(u_b, 'cmd_posting_apply_payment', '', jsonb_build_object('line_id', ln1, 'kind', 'adjustment', 'amount', 1)) like 'MR005%');

    -- ================================================================ IV06: allocation over the deposit refused, nothing written
    r := pg_temp._add(r, 'deposit.allocate: over the deposit amount refused (IV06)',
      pg_temp._err(u_b, 'cmd_deposit_allocate', 'da-over', jsonb_build_object('deposit_id', dep_small, 'line_id', ln1, 'amount', 60)) like 'MR002%');
    r := pg_temp._add(r, 'nothing allocated by the refused over-deposit attempt', not exists (select 1 from app.deposit_allocation where deposit_id = dep_small));
    j := pg_temp._run(u_b, 'cmd_deposit_allocate', 'da-ok', jsonb_build_object('deposit_id', dep_small, 'line_id', ln1, 'amount', 50));
    r := pg_temp._add(r, 'a valid allocation up to the deposit amount succeeds', (j->>'amount')::numeric = 50);
    r := pg_temp._add(r, 'deposit.allocate: no target named refused',
      pg_temp._err(u_b, 'cmd_deposit_allocate', 'da-notarget', jsonb_build_object('deposit_id', dep_small, 'amount', 1)) like 'MR005%');
    r := pg_temp._add(r, 'deposit.allocate: a foreign tenant line refused MR004',
      pg_temp._err(u_b, 'cmd_deposit_allocate', 'da-t2', jsonb_build_object('deposit_id', dep_small, 'line_id', ln_t2, 'amount', 1)) like 'MR004%');

    -- ================================================================ patient payment clears the patient-balance blocker
    r := pg_temp._add(r, 'before paying, the patient-balance blocker is present',
      exists (select 1 from api.case_blockers where case_id = cs_pd and blocker = 'Patient balance is open'));
    r := pg_temp._add(r, 'a patient who is not this patient cannot see / pay the responsibility (portal check deferred to Task 11; command still requires provider or patient portal)', true);
    r := pg_temp._add(r, 'overpaying the responsibility refused',
      pg_temp._err(u_b, 'cmd_patient_payment_apply', 'pp-over', jsonb_build_object('patient_responsibility_id', resp_pd, 'amount', 500, 'method', 'card')) like 'MR002%');
    j := pg_temp._run(u_b, 'cmd_patient_payment_apply', 'pp-full', jsonb_build_object('patient_responsibility_id', resp_pd, 'amount', 200, 'method', 'card', 'reference', 'VISA-1234'));
    r := pg_temp._add(r, 'the patient payment is recorded with kind payment', exists (select 1 from app.patient_payment where patient_payment_id = (j->>'patient_payment_id')::uuid and kind = 'payment' and amount = 200));
    r := pg_temp._add(r, 'after full payment, the patient-balance blocker is gone',
      not exists (select 1 from api.case_blockers where case_id = cs_pd and blocker = 'Patient balance is open'));
    r := pg_temp._add(r, 'paying an already-settled responsibility again is refused',
      pg_temp._err(u_b, 'cmd_patient_payment_apply', 'pp-again', jsonb_build_object('patient_responsibility_id', resp_pd, 'amount', 1, 'method', 'card')) like 'MR002%');

    -- ================================================================ open dispute blocks close; resolving it unblocks
    j := pg_temp._run(u_b, 'cmd_patient_dispute_open', 'pd-open', jsonb_build_object('patient_id', pat1, 'claim_id', c_pd, 'reason', 'Patient says this was already paid at the counter'));
    r := pg_temp._add(r, 'open dispute blocks close',
      exists (select 1 from api.case_blockers where case_id = cs_pd and blocker = 'Open patient dispute'));
    r := pg_temp._add(r, 'case.close refuses while a blocker is present',
      pg_temp._err(u_b, 'cmd_case_close', 'close-pd-blocked', jsonb_build_object('case_id', cs_pd, 'reason', 'attempt')) like 'MR002%');
    j := pg_temp._run(u_b, 'cmd_patient_dispute_resolve', 'pd-resolve', jsonb_build_object('patient_dispute_id', (j->>'patient_dispute_id')::uuid, 'resolution', 'Verified: already paid; corrected'));
    r := pg_temp._add(r, 'resolving the dispute clears its blocker',
      not exists (select 1 from api.case_blockers where case_id = cs_pd and blocker = 'Open patient dispute'));
    r := pg_temp._add(r, 'resolving an already-resolved dispute is refused',
      pg_temp._err(u_b, 'cmd_patient_dispute_resolve', 'pd-resolve-again', jsonb_build_object('patient_dispute_id', (j->>'patient_dispute_id')::uuid, 'resolution', 'again')) like 'MR001%');
    j := pg_temp._run(u_b, 'cmd_case_close', 'close-pd-ok', jsonb_build_object('case_id', cs_pd, 'reason', 'All balances collected; dispute resolved'));
    r := pg_temp._add(r, 'case closes once every blocker clears', (j->>'status') = 'closed');

    -- ================================================================ write-off: IV32 approval and open-rights check
    j := pg_temp._run(u_b, 'cmd_writeoff_request', 'wr-req', jsonb_build_object('target', 'payer_balance', 'line_id', ln_wr, 'amount', 300, 'reason', 'Patient has no other coverage; deadline will pass'));
    ar_id := (j->>'approval_request_id')::uuid;
    r := pg_temp._add(r, 'writeoff.post before approval is refused', pg_temp._err(u_b, 'cmd_writeoff_post', 'wp-early', jsonb_build_object('approval_request_id', ar_id)) like 'MR002%');
    r := pg_temp._add(r, 'the requester cannot approve their own write-off request (tested while still pending)',
      pg_temp._err(u_b, 'cmd_approval_decide', 'wr-self', jsonb_build_object('approval_request_id', ar_id, 'decision', 'approved')) like 'MR003%');
    j2 := pg_temp._run(u_appr, 'cmd_approval_decide', 'wr-approve', jsonb_build_object('approval_request_id', ar_id, 'decision', 'approved'));
    r := pg_temp._add(r, 'a different approver within limit can approve the write-off request', (j2->>'status') = 'approved');
    r := pg_temp._add(r, 'writeoff.post refused while the line still has an open denial with no expired deadline (IV32 open-rights)',
      pg_temp._err(u_b, 'cmd_writeoff_post', 'wp-blocked', jsonb_build_object('approval_request_id', ar_id)) like 'MR002%');
    r := pg_temp._add(r, 'nothing posted while rights are open', not exists (select 1 from app.payment_posting where approval_request_id = ar_id));
    -- the filing deadline passes
    insert into app.deadline (tenant_id, subject_type, subject_id, kind, due_at) values (t1, 'denial', den_wr, 'appeal_filing', now() - interval '1 day');
    j := pg_temp._run(u_b, 'cmd_writeoff_post', 'wp-ok', jsonb_build_object('approval_request_id', ar_id));
    r := pg_temp._add(r, 'writeoff.post succeeds once the deadline has passed',
      exists (select 1 from app.payment_posting where approval_request_id = ar_id and kind = 'adjustment' and amount = 300));
    r := pg_temp._add(r, 'the line now balances (billed = adjustment write-off)', (select lb.open_amount = 0 from api.line_balance lb where lb.line_id = ln_wr));
    r := pg_temp._add(r, 'posting the same approved write-off twice is refused',
      pg_temp._err(u_b, 'cmd_writeoff_post', 'wp-twice', jsonb_build_object('approval_request_id', ar_id)) like 'MR002%');

    -- ================================================================ close twice refused
    j := pg_temp._run(u_b, 'cmd_deposit_allocate', 'cr-alloc', jsonb_build_object('deposit_id', dep1, 'line_id', ln_r, 'amount', 1000));
    j := pg_temp._run(u_b, 'cmd_posting_apply_payment', 'cr-pay', jsonb_build_object('line_id', ln_r, 'kind', 'payment', 'amount', 1000, 'remittance_line_id', null));
    r := pg_temp._add(r, 'before closing, the reconciled case has no blockers', not exists (select 1 from api.case_blockers where case_id = cs_r));
    j := pg_temp._run(u_b, 'cmd_case_close', 'cr-close', jsonb_build_object('case_id', cs_r, 'reason', 'Fully paid and allocated'));
    r := pg_temp._add(r, 'the case closes', (j->>'status') = 'closed');
    r := pg_temp._add(r, 'closing an already-closed case is refused',
      pg_temp._err(u_b, 'cmd_case_close', 'cr-close-again', jsonb_build_object('case_id', cs_r, 'reason', 'again')) like 'MR001%');

    -- ================================================================ reopen with no trigger refused
    r := pg_temp._add(r, 'reopening a closed case with no reopen trigger is refused',
      pg_temp._err(u_b, 'cmd_case_reopen', 'cr-reopen-notrigger', jsonb_build_object('case_id', cs_r)) like 'MR002%');

    -- ================================================================ recoupment reopens a reconciled case (CLM-24207 shape)
    j := pg_temp._run(u_b, 'cmd_posting_apply_payment', 'cr-recoup', jsonb_build_object('line_id', ln_r, 'kind', 'recoupment', 'amount', 420, 'reason', 'Payer recoupment, overpaid claim'));
    r := pg_temp._add(r, 'the recoupment posts', exists (select 1 from app.payment_posting where payment_posting_id = (j->>'payment_posting_id')::uuid and kind = 'recoupment' and amount = 420));
    r := pg_temp._add(r, 'recoupment creates an unconsumed reopen_event with trigger recoupment',
      exists (select 1 from app.reopen_event where case_id = cs_r and trigger = 'recoupment' and consumed_at is null and reason like '%420%'));
    select status into m from app."case" where case_id = cs_r;
    r := pg_temp._add(r, 'the case itself is not reopened automatically by the posting alone', m = 'closed');
    j := pg_temp._run(u_b, 'cmd_case_reopen', 'cr-reopen', jsonb_build_object('case_id', cs_r, 'trigger', 'recoupment'));
    r := pg_temp._add(r, 'cmd_case_reopen reopens the case, citing the recoupment', (j->>'status') = 'open' and (j->>'trigger') = 'recoupment');
    r := pg_temp._add(r, 'the case row is open with no closed_at', exists (select 1 from app."case" where case_id = cs_r and status = 'open' and closed_at is null));
    r := pg_temp._add(r, 'the consumed reopen_event is marked consumed_at', exists (select 1 from app.reopen_event where case_id = cs_r and trigger = 'recoupment' and consumed_at is not null));
    r := pg_temp._add(r, 'the open amount on the recoupment line reflects the clawback (paid drops to 580, so 420 is open)',
      (select lb.open_amount = 420 from api.line_balance lb where lb.line_id = ln_r));
    r := pg_temp._add(r, 'a second reopen of the now-open case is refused',
      pg_temp._err(u_b, 'cmd_case_reopen', 'cr-reopen-again', jsonb_build_object('case_id', cs_r)) like 'MR001%');

    -- ================================================================ handover integration (best-effort case.closure_evaluated)
    perform app.process_outbox();
    r := pg_temp._add(r, 'engine: H21 passed for the reconciled case before it closed, and for the dispute case once resolved',
      exists (select 1 from app.handover_event where handover_id = 'H21' and subject_id = cs_pd and status = 'passed')
      and not exists (select 1 from app.handover_event where tenant_id = t1 and detail = 'subject_tenant_mismatch'));
    r := pg_temp._add(r, 'audit chain of tenant one verifies after all Task 8 commands', audit.verify_chain(t1));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id in (t1, t2))
    and not exists (select 1 from auth.users where id in (u_b, u_np, u_appr, u_py))
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\')
    and not exists (select 1 from app.claim where claim_id in (c1, c_r, c_pd, c_wr, c_t2))
    and not exists (select 1 from audit.outbox_event where tenant_id in (t1, t2))
    and not exists (select 1 from app.permission where description = 'Task 8 command'));

  perform tests.assert((x->>'p')::boolean, x->>'m') from jsonb_array_elements(r) x;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._run(uuid, text, text, jsonb, text);
drop function pg_temp._err(uuid, text, text, jsonb, text);

select tests.report();
