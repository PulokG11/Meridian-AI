-- Task 5 fix round 1 tests (migration 005c_handover_fixes):
--  (1) approval guard: a deciding UPDATE cannot change amount / kind / requester / subject; decided rows are frozen;
--      the requester must belong to the request's tenant
--  (2) handover engine: a payload subject from another tenant (or a missing subject) is failed_check
--      'subject_tenant_mismatch' with one task and the check NOT run; ref.subject_tenant; per-event exception guard
-- Run with execute_sql (whole file in one call). Fixtures live in a rolled-back sub-transaction (no residue); the
-- tripwire / boom objects the test creates are rolled back with it.
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

do $$
declare
  r jsonb := '[]'::jsonb;
  m text;
  v_x text;
  v_h integer; v_t integer; v_q integer;
  t1 uuid := app.uuid_v7(); t2 uuid := app.uuid_v7();
  u_sup uuid := gen_random_uuid(); u_sup2 uuid := gen_random_uuid(); u_t2 uuid := gen_random_uuid();
  prv uuid := app.uuid_v7(); pat1 uuid := app.uuid_v7(); pay1 uuid := app.uuid_v7(); cov1 uuid := app.uuid_v7();
  pat2 uuid := app.uuid_v7(); pay2 uuid := app.uuid_v7();
  cl_ok uuid := app.uuid_v7(); cl_boom uuid := app.uuid_v7(); cl_t2 uuid := app.uuid_v7();
  rem1 uuid := app.uuid_v7(); den1 uuid := app.uuid_v7(); dep1 uuid := app.uuid_v7(); ei1 uuid := app.uuid_v7();
  cs1 uuid := app.uuid_v7(); rp1 uuid := app.uuid_v7(); rl1 uuid := app.uuid_v7();
  eq1 uuid := app.uuid_v7(); er1 uuid := app.uuid_v7(); eq2 uuid := app.uuid_v7(); er2 uuid := app.uuid_v7();
  ar_probe uuid := app.uuid_v7(); ar_req uuid := app.uuid_v7(); ar_kind uuid := app.uuid_v7(); ar_pend uuid := app.uuid_v7();
  ev_x uuid; ev_ok uuid; ev_unk uuid; ev_tx uuid; ev_tok uuid; ev_boom uuid; ev_after uuid;
  agg_rand uuid := gen_random_uuid(); agg_rand2 uuid := gen_random_uuid();
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values ('t_sup', 'Supervisor', 'provider');
    insert into auth.users (id, aud, role, email) values
      (u_sup,  'authenticated', 'authenticated', 's1@meridian.test'),
      (u_sup2, 'authenticated', 'authenticated', 's2@meridian.test'),
      (u_t2,   'authenticated', 'authenticated', 't2@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, display_name) values
      (u_sup,  t1, 'provider', 't_sup', 'Supervisor One'),
      (u_sup2, t1, 'provider', 't_sup', 'Supervisor Two'),
      (u_t2,   t2, 'provider', 't_sup', 'Supervisor Tenant Two');
    insert into app.approval_limit (tenant_id, role_key, kind, max_amount) values
      (t1, 't_sup', 'appeal', 2500.00), (t1, 't_sup', 'write_off', 100000.00), (t2, 't_sup', 'appeal', 2500.00);

    insert into app.provider (provider_id, tenant_id, npi, name) values (prv, t1, '1000000001', 'Dr One');
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values
      (pat1, t1, 'MRN-1', 'Ada', 'Alpha', date '1980-01-01'), (pat2, t2, 'MRN-2', 'Xena', 'Other', date '1990-03-03');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values
      (pay1, t1, 'Payer A', 'PA01', 'commercial'), (pay2, t2, 'Payer C', 'PC01', 'commercial');
    insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values
      (cov1, t1, pat1, pay1, 'MEM-1', date '2026-01-01', 'eligibility');
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status) values
      (cl_ok,   t1, 'C-OK',   pat1, prv, pay1, cov1, 'ready'),
      (cl_boom, t1, 'C-BOOM', pat1, prv, pay1, cov1, 'ready');
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, payer_id, status) values
      (cl_t2, t2, 'C-T2', pat2, pay2, 'submitted');   -- would PASS H14 if the check were tenant-blind
    insert into app.remittance (remittance_id, tenant_id, payer_id, trace_number, payment_amount) values (rem1, t1, pay1, 'TRN-1', 10.00);
    insert into app.denial (denial_id, tenant_id, claim_id, carc) values (den1, t1, cl_ok, '45');
    insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values (dep1, t1, pay1, 'BANK-1', 10.00);
    insert into app.edi_interchange (edi_interchange_id, tenant_id, payer_id, direction, transaction_set, trace_number) values
      (ei1, t1, pay1, 'inbound', '835', 'TRN-X');
    insert into app."case" (case_id, tenant_id, case_number, patient_id) values (cs1, t1, 'CASE-1', pat1);
    insert into app.rule_pack (rule_pack_id, tenant_id, name, version, effective_from) values (rp1, t1, 'Pack', 1, current_date);
    insert into app.rule (rule_id, tenant_id, rule_pack_id, rule_key, effective_from, owner) values (rl1, t1, rp1, 'k', current_date, u_sup);
    insert into app.eligibility_request (eligibility_request_id, tenant_id, patient_id, payer_id, service_date) values
      (eq1, t1, pat1, pay1, current_date), (eq2, t2, pat2, pay2, current_date);
    insert into app.eligibility_response (eligibility_response_id, tenant_id, eligibility_request_id, coverage_status) values
      (er1, t1, eq1, 'active'), (er2, t2, eq2, 'active');

    -- ---------------------------------------------------------------- (1) approval guard
    insert into app.approval_request (approval_request_id, tenant_id, kind, amount, requester_id, subject_type, subject_id) values
      (ar_probe, t1, 'appeal', 99999.00, u_sup, 'appeal', gen_random_uuid()),
      (ar_req,   t1, 'appeal',  1000.00, u_sup, 'appeal', gen_random_uuid()),
      (ar_kind,  t1, 'appeal',  5000.00, u_sup, 'appeal', gen_random_uuid()),
      (ar_pend,  t1, 'appeal',   100.00, u_sup, 'appeal', gen_random_uuid());

    v_x := pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L, amount = 1 where approval_request_id = %L$q$, u_sup2, ar_probe));
    r := pg_temp._add(r, 'the probe (99999 request approved with amount = 1 in the same UPDATE) is refused (MR002), amount and status unchanged',
      v_x = 'MR002' and (select status = 'pending' and amount = 99999.00 and approver_id is null from app.approval_request where approval_request_id = ar_probe));
    v_x := pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L, requester_id = %L where approval_request_id = %L$q$, u_sup, u_sup2, ar_req));
    r := pg_temp._add(r, 'changing requester_id in the deciding UPDATE (to make the approver look independent) is refused (MR002)',
      v_x = 'MR002' and (select status = 'pending' and requester_id = u_sup from app.approval_request where approval_request_id = ar_req));
    v_x := pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L, kind = 'write_off' where approval_request_id = %L$q$, u_sup2, ar_kind));
    r := pg_temp._add(r, 'changing kind to one with a higher limit in the deciding UPDATE is refused (MR002)',
      v_x = 'MR002' and (select status = 'pending' and kind = 'appeal' from app.approval_request where approval_request_id = ar_kind));
    r := pg_temp._add(r, 'amount, kind, requester, subject and tenant are immutable while pending, even without a decision (MR002)',
      pg_temp._try(format($q$update app.approval_request set amount = 1 where approval_request_id = %L$q$, ar_pend)) = 'MR002'
      and pg_temp._try(format($q$update app.approval_request set kind = 'write_off' where approval_request_id = %L$q$, ar_pend)) = 'MR002'
      and pg_temp._try(format($q$update app.approval_request set requester_id = %L where approval_request_id = %L$q$, u_sup2, ar_pend)) = 'MR002'
      and pg_temp._try(format($q$update app.approval_request set subject_id = gen_random_uuid() where approval_request_id = %L$q$, ar_pend)) = 'MR002'
      and pg_temp._try(format($q$update app.approval_request set subject_type = 'claim' where approval_request_id = %L$q$, ar_pend)) = 'MR002'
      and pg_temp._try(format($q$update app.approval_request set tenant_id = %L where approval_request_id = %L$q$, t2, ar_pend)) = 'MR002');
    r := pg_temp._add(r, 'the error names the rule approval_request_immutable_fields',
      (select pg_temp._try(format($q$update app.approval_request set amount = 2 where approval_request_id = %L$q$, ar_pend))) = 'MR002'
      and exists (select 1 from pg_proc where oid = 'app.approval_request_guard()'::regprocedure
                    and prosrc like '%approval_request_immutable_fields%'));
    r := pg_temp._add(r, 'reason and approver may still be set while the request is pending',
      pg_temp._try(format($q$update app.approval_request set reason = 'Please review' where approval_request_id = %L$q$, ar_pend)) = 'ok'
      and pg_temp._try(format($q$update app.approval_request set approver_id = %L where approval_request_id = %L$q$, u_sup2, ar_pend)) = 'ok');
    v_x := pg_temp._try(format($q$update app.approval_request set status = 'approved', approver_id = %L where approval_request_id = %L$q$, u_sup2, ar_req));
    r := pg_temp._add(r, 'a normal approval within the limit by another person still works',
      v_x = 'ok' and (select status = 'approved' and decided_at is not null and amount = 1000.00 from app.approval_request where approval_request_id = ar_req));
    r := pg_temp._add(r, 'a decided request is frozen in every column: reason, decided_at, requested_at, approver (MR002)',
      pg_temp._try(format($q$update app.approval_request set reason = 'edited later' where approval_request_id = %L$q$, ar_req)) = 'MR002'
      and pg_temp._try(format($q$update app.approval_request set decided_at = now() - interval '5 days' where approval_request_id = %L$q$, ar_req)) = 'MR002'
      and pg_temp._try(format($q$update app.approval_request set requested_at = now() - interval '5 days' where approval_request_id = %L$q$, ar_req)) = 'MR002'
      and pg_temp._try(format($q$update app.approval_request set approver_id = %L where approval_request_id = %L$q$, u_sup, ar_req)) = 'MR002');
    r := pg_temp._add(r, 'a decided request still refuses a status move (MR001) and an amount change (MR002)',
      pg_temp._try(format($q$update app.approval_request set status = 'rejected' where approval_request_id = %L$q$, ar_req)) = 'MR001'
      and pg_temp._try(format($q$update app.approval_request set amount = 5 where approval_request_id = %L$q$, ar_req)) = 'MR002');
    r := pg_temp._add(r, 'a request whose requester belongs to another tenant is refused on insert (MR005)',
      pg_temp._try(format($q$insert into app.approval_request (tenant_id, kind, amount, requester_id) values (%L, 'appeal', 10, %L)$q$, t1, u_t2)) = 'MR005'
      and pg_temp._try(format($q$insert into app.approval_request (tenant_id, kind, amount, requester_id) values (%L, 'appeal', 10, %L)$q$, t1, gen_random_uuid())) in ('MR005', '23503')
      and pg_temp._try(format($q$insert into app.approval_request (tenant_id, kind, amount, requester_id) values (%L, 'appeal', 10, %L)$q$, t1, u_sup2)) = 'ok');

    -- ---------------------------------------------------------------- (2) ref.subject_tenant
    r := pg_temp._add(r, 'ref.subject_tenant maps each handover to its subject table and returns the owning tenant',
      ref.subject_tenant('H13', cl_ok) = t1 and ref.subject_tenant('H14', cl_t2) = t2 and ref.subject_tenant('H19', cl_ok) = t1
      and ref.subject_tenant('H15', rem1) = t1 and ref.subject_tenant('H16', den1) = t1 and ref.subject_tenant('H17', den1) = t1
      and ref.subject_tenant('H18', ar_req) = t1
      and ref.subject_tenant('H20', dep1) = t1 and ref.subject_tenant('H20', rem1) = t1 and ref.subject_tenant('H20', ei1) = t1
      and ref.subject_tenant('H21', cs1) = t1
      and ref.subject_tenant('H22', rl1) = t1 and ref.subject_tenant('H22', rp1) = t1
      and ref.subject_tenant('H24', er1) = t1 and ref.subject_tenant('H24', eq1) = t1 and ref.subject_tenant('H24', er2) = t2);
    r := pg_temp._add(r, 'ref.subject_tenant is null for a missing subject, a subject of the wrong table, H23 and an unknown handover',
      ref.subject_tenant('H13', gen_random_uuid()) is null and ref.subject_tenant('H15', cl_ok) is null
      and ref.subject_tenant('H24', cl_ok) is null and ref.subject_tenant('H23', cl_ok) is null
      and ref.subject_tenant('H99', cl_ok) is null and ref.subject_tenant('H13', null) is null);
    r := pg_temp._add(r, 'ref.subject_tenant is definer, search_path empty, not executable by client roles or PUBLIC',
      exists (select 1 from pg_proc p where p.oid = 'ref.subject_tenant(text,uuid)'::regprocedure and p.prosecdef
                and p.proconfig @> array['search_path=""'])
      and not has_function_privilege('authenticated', 'ref.subject_tenant(text,uuid)', 'execute')
      and not has_function_privilege('anon', 'ref.subject_tenant(text,uuid)', 'execute')
      and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                       where a.grantee = 0 and p.oid = 'ref.subject_tenant(text,uuid)'::regprocedure));
    r := pg_temp._add(r, 'process_outbox keeps SECURITY DEFINER, FOR UPDATE SKIP LOCKED and stays closed to client roles',
      exists (select 1 from pg_proc p where p.oid = 'app.process_outbox()'::regprocedure and p.prosecdef
                and p.prorettype = 'integer'::regtype and p.proconfig @> array['search_path=""'])
      and (select pg_get_functiondef('app.process_outbox()'::regprocedure)) ~* 'for update of \w+ skip locked'
      and (select pg_get_functiondef('app.process_outbox()'::regprocedure)) like '%subject_tenant_mismatch%'
      and not has_function_privilege('authenticated', 'app.process_outbox()', 'execute')
      and not has_function_privilege('anon', 'app.process_outbox()', 'execute'));

    -- ---------------------------------------------------------------- (2) engine behaviour
    -- Tripwire: H24's check now raises, so a verdict mentioning it proves the check was (or was not) executed.
    execute $e$create or replace function ref.check_h24(p_subject uuid) returns boolean
      language plpgsql security definer set search_path = ''
      as $f$ begin raise exception 'tripwire'; end $f$ $e$;
    -- Boom: inserting a handover_event for cl_boom fails, standing in for an unexpected engine error.
    execute format($e$create function app.t5_boom() returns trigger language plpgsql
      as $b$ begin if new.subject_id = %L then raise exception 'boom'; end if; return new; end $b$ $e$, cl_boom);
    execute 'create trigger t5_boom before insert on app.handover_event for each row execute function app.t5_boom()';

    insert into audit.outbox_event (tenant_id, type, aggregate_id, payload)
      values (t1, 'claim.submitted', agg_rand, jsonb_build_object('subject_id', cl_t2)) returning event_id into ev_x;      -- other tenant's claim
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'claim.submitted', cl_ok) returning event_id into ev_ok;
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'claim.submitted', gen_random_uuid()) returning event_id into ev_unk;
    insert into audit.outbox_event (tenant_id, type, aggregate_id, payload)
      values (t1, 'eligibility.response_received', agg_rand2, jsonb_build_object('subject_id', er2)) returning event_id into ev_tx;
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'eligibility.response_received', er1) returning event_id into ev_tok;
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'claim.submitted', cl_boom) returning event_id into ev_boom;
    insert into audit.outbox_event (tenant_id, type, aggregate_id) values (t1, 'claim.ready', cl_ok) returning event_id into ev_after;

    perform app.process_outbox();

    r := pg_temp._add(r, 'cross-tenant payload subject: failed_check subject_tenant_mismatch, never passed, the check did not run',
      (select count(*) from app.handover_event where source_event_id = ev_x and handover_id = 'H14' and status = 'failed_check'
          and detail = 'subject_tenant_mismatch' and subject_id = cl_t2 and tenant_id = t1) = 1
      and not exists (select 1 from app.handover_event where subject_id = cl_t2 and status = 'passed')
      and not exists (select 1 from app.handover_event where tenant_id = t2)
      and (select processed_at is not null from audit.outbox_event where event_id = ev_x));
    r := pg_temp._add(r, 'cross-tenant payload subject creates exactly one task, in the event tenant''s hold queue',
      (select count(*) from app.task k join app.work_queue q on q.work_queue_id = k.queue_id
        where k.subject_id = cl_t2 and k.tenant_id = t1 and q.tenant_id = t1 and q.name = 'Rejection queue' and k.status = 'open') = 1
      and (select count(*) from app.task where subject_id = cl_t2) = 1
      and not exists (select 1 from app.task where tenant_id = t2) and not exists (select 1 from app.work_queue where tenant_id = t2));
    r := pg_temp._add(r, 'same-tenant subject still passes with no task',
      (select count(*) from app.handover_event where source_event_id = ev_ok and handover_id = 'H14' and status = 'passed' and detail is null) = 1
      and (select count(*) from app.handover_event where source_event_id = ev_after and handover_id = 'H13' and status = 'passed') = 1
      and not exists (select 1 from app.task where subject_id = cl_ok));
    r := pg_temp._add(r, 'unknown subject id (no row anywhere): failed_check subject_tenant_mismatch with one task',
      (select count(*) from app.handover_event h where h.source_event_id = ev_unk and h.status = 'failed_check' and h.detail = 'subject_tenant_mismatch') = 1
      and (select count(*) from app.task k join app.handover_event h on h.handover_event_id = k.source_handover_event_id where h.source_event_id = ev_unk) = 1);
    r := pg_temp._add(r, 'tripwire proof: cross-tenant subject got the mismatch verdict (check not run); same-tenant subject ran the check',
      (select detail from app.handover_event where source_event_id = ev_tx and handover_id = 'H24') = 'subject_tenant_mismatch'
      and (select status = 'failed_check' and detail like '%tripwire%' from app.handover_event where source_event_id = ev_tok and handover_id = 'H24'));
    r := pg_temp._add(r, 'per-event guard: an unexpected error marks that event processed with process_error and the batch moves on',
      (select processed_at is not null and process_error like '%boom%' from audit.outbox_event where event_id = ev_boom)
      and not exists (select 1 from app.handover_event where source_event_id = ev_boom)
      and not exists (select 1 from app.task where subject_id = cl_boom)
      and (select process_error is null from audit.outbox_event where event_id = ev_after)
      and not exists (select 1 from audit.outbox_event where tenant_id = t1 and processed_at is null));

    -- replay (IV27)
    select count(*) into v_h from app.handover_event where tenant_id = t1;
    select count(*) into v_t from app.task where tenant_id = t1;
    select count(*) into v_q from app.work_queue where tenant_id = t1;
    update audit.outbox_event set processed_at = null where tenant_id = t1;
    perform app.process_outbox();
    perform app.process_outbox();
    r := pg_temp._add(r, 'replay creates no second handover event, task or queue (mismatch verdicts included)',
      (select count(*) from app.handover_event where tenant_id = t1) = v_h
      and (select count(*) from app.task where tenant_id = t1) = v_t
      and (select count(*) from app.work_queue where tenant_id = t1) = v_q
      and v_h = 6 and v_t = 4
      and not exists (select 1 from audit.outbox_event where tenant_id = t1 and processed_at is null));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures, tripwire and boom objects rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id in (t1, t2))
    and not exists (select 1 from auth.users where id in (u_sup, u_sup2, u_t2))
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\')
    and not exists (select 1 from app.task where tenant_id in (t1, t2))
    and not exists (select 1 from app.handover_event where tenant_id in (t1, t2))
    and not exists (select 1 from app.work_queue where tenant_id in (t1, t2))
    and not exists (select 1 from audit.outbox_event where tenant_id in (t1, t2))
    and not exists (select 1 from pg_proc where proname = 't5_boom')
    and not exists (select 1 from pg_proc where oid = 'ref.check_h24(uuid)'::regprocedure and prosrc like '%tripwire%'));

  perform tests.assert((e->>'p')::boolean, e->>'m') from jsonb_array_elements(r) e;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);

select tests.report();
