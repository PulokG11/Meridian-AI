-- Task 6 review fix round 1 tests (migration 006b_cmd_claims_fixes):
--  (1) a claim can no longer be reported submitted without an outbound 837: trace uniqueness per direction and
--      transaction set, cmd_claim_submit refuses a foreign interchange on its trace (MR002 submit_interchange_conflict),
--      cmd_remittance_receive refuses the reserved '837-' trace namespace (MR005); IV37 duplicate 835 still refused
--  (2) claim status across several remittances, driven through the real commands (release, submit, receive, post,
--      triage, confirm_path): submitted -> accepted -> partially_paid -> paid; denied -> paid; denied -> partially_paid;
--      nothing paid + open lines + no denial leaves the status alone
-- Run with execute_sql (whole file in one call). Fixtures live in a rolled-back sub-transaction (no residue).
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

-- Calls api.<fn>(key, args) as user u under role authenticated and returns the result.
create or replace function pg_temp._run(u uuid, fn text, k text, a jsonb) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  execute format('select api.%I($1, $2)', fn) into v using k, a;
  reset role;
  return v;
end $$;

create or replace function pg_temp._err(u uuid, fn text, k text, a jsonb) returns text
language plpgsql as $$
begin
  perform pg_temp._run(u, fn, k, a);
  return 'ok';
exception when others then
  return sqlstate || ' ' || sqlerrm;
end $$;

-- receive (one line) + post as user u; returns the post result
create or replace function pg_temp._remit(u uuid, k text, trace text, payer uuid, claim uuid, line uuid,
                                         paid numeric, adj numeric, denied numeric, carc text) returns jsonb
language plpgsql as $$
declare j jsonb;
begin
  j := pg_temp._run(u, 'cmd_remittance_receive', 'rcv-' || k, jsonb_build_object('interchange_trace', trace, 'payer_id', payer,
         'control_total', paid, 'lines', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('claim_id', claim, 'line_id', line,
         'paid', paid, 'adjustment', adj, 'denied', denied, 'group_code', 'CO', 'carc', carc)))));
  return pg_temp._run(u, 'cmd_remittance_post', 'post-' || k, jsonb_build_object('remittance_id', j->>'remittance_id'));
end $$;

do $$
declare
  r jsonb := '[]'::jsonb;
  m text; e text; j jsonb; j2 jsonb;
  perms text[] := array['remittance.receive','remittance.post','denial.triage','denial.confirm_path',
                        'claim.create_replacement','claim.release','claim.submit'];
  t1 uuid := app.uuid_v7(); u_b uuid := gen_random_uuid();
  prv uuid := app.uuid_v7(); pat uuid := app.uuid_v7(); pay_a uuid := app.uuid_v7(); cov uuid := app.uuid_v7();
  ch1 uuid := app.uuid_v7();
  c_probe uuid := app.uuid_v7(); c_legacy uuid := app.uuid_v7(); c_misc uuid := app.uuid_v7();
  c_flow uuid := app.uuid_v7(); c_den uuid := app.uuid_v7(); c_den2 uuid := app.uuid_v7();
  c_noop uuid := app.uuid_v7(); c_nsub uuid := app.uuid_v7();
  l_probe uuid := app.uuid_v7(); l_legacy uuid := app.uuid_v7(); l_misc uuid := app.uuid_v7();
  f1 uuid := app.uuid_v7(); f2 uuid := app.uuid_v7(); l_den uuid := app.uuid_v7(); l_den2 uuid := app.uuid_v7();
  l_noop uuid := app.uuid_v7(); l_nsub uuid := app.uuid_v7();
  tr_probe text; tr_legacy text; d_den uuid; d_den2 uuid;
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One');
    insert into app.role (role_key, label, portal) values ('t_biller', 'Biller', 'provider');
    insert into app.permission (permission_key, description) select p, 'Task 6b command' from unnest(perms) p
      on conflict (permission_key) do nothing;
    insert into app.role_permission (role_key, permission_key) select 't_biller', p from unnest(perms) p;
    insert into auth.users (id, aud, role, email) values (u_b, 'authenticated', 'authenticated', 'b6b@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, display_name) values (u_b, t1, 'provider', 't_biller', 'Biller');
    insert into app.provider (provider_id, tenant_id, npi, name) values (prv, t1, '1000000001', 'Dr One');
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (pat, t1, 'MRN-1', 'Ada', 'Alpha', date '1980-01-01');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values (pay_a, t1, 'Payer A', 'PA01', 'commercial');
    insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values
      (cov, t1, pat, pay_a, 'MEM-A', date '2026-01-01', 'eligibility');
    insert into app.clearinghouse (clearinghouse_id, tenant_id, name, clearinghouse_code) values (ch1, t1, 'CH One', 'CH1');
    insert into app.clearinghouse_connection (tenant_id, clearinghouse_id, payer_id, protocol, endpoint_label, status)
      values (t1, ch1, pay_a, 'x12', 'CH1 to Payer A (synthetic)', 'active');
    insert into app.payer_config (tenant_id, payer_id, timely_filing_days, appeal_levels, records_request_days, effective_from)
      values (t1, pay_a, 90, 2, 30, date '2026-01-01');
    insert into app.root_cause (tenant_id, code, label, category) values (t1, 'CODING', 'Coding error', 'coding');
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status) values
      (c_probe,  t1, 'C-PROBE',  pat, prv, pay_a, cov, 'draft'),
      (c_legacy, t1, 'C-LEGACY', pat, prv, pay_a, cov, 'ready'),
      (c_misc,   t1, 'C-MISC',   pat, prv, pay_a, cov, 'accepted'),
      (c_flow,   t1, 'C-FLOW',   pat, prv, pay_a, cov, 'draft'),
      (c_den,    t1, 'C-DEN',    pat, prv, pay_a, cov, 'draft'),
      (c_den2,   t1, 'C-DEN2',   pat, prv, pay_a, cov, 'draft'),
      (c_noop,   t1, 'C-NOOP',   pat, prv, pay_a, cov, 'accepted'),
      (c_nsub,   t1, 'C-NSUB',   pat, prv, pay_a, cov, 'submitted');
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (l_probe, t1, c_probe, 1, '99213', 100.00), (l_legacy, t1, c_legacy, 1, '99213', 100.00),
      (l_misc, t1, c_misc, 1, '99213', 100.00),
      (f1, t1, c_flow, 1, '99213', 100.00), (f2, t1, c_flow, 2, '99214', 50.00),
      (l_den, t1, c_den, 1, '99213', 100.00), (l_den2, t1, c_den2, 1, '99213', 100.00),
      (l_noop, t1, c_noop, 1, '99213', 100.00), (l_nsub, t1, c_nsub, 1, '99213', 100.00);
    tr_probe  := '837-' || replace(c_probe::text, '-', '');
    tr_legacy := '837-' || replace(c_legacy::text, '-', '');

    -- ================================================================ 1. submission vs interchange namespace
    r := pg_temp._add(r, 'edi_interchange_trace_unique is (tenant_id, payer_id, direction, transaction_set, trace_number)',
      (select array_agg(a.attname::text order by x.ord) from pg_constraint k
          cross join lateral unnest(k.conkey) with ordinality x(attnum, ord)
          join pg_attribute a on a.attrelid = k.conrelid and a.attnum = x.attnum
        where k.conrelid = 'app.edi_interchange'::regclass and k.conname = 'edi_interchange_trace_unique')
      = array['tenant_id','payer_id','direction','transaction_set','trace_number']);

    perform pg_temp._run(u_b, 'cmd_claim_release', 'rel-probe', jsonb_build_object('claim_id', c_probe));
    e := pg_temp._err(u_b, 'cmd_remittance_receive', 'rcv-probe', jsonb_build_object('interchange_trace', tr_probe,
      'payer_id', pay_a, 'control_total', 10, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_misc, 'line_id', l_misc, 'paid', 10))));
    r := pg_temp._add(r, 'reviewer probe step 1: receiving an 835 with trace 837-<claim hex> is refused MR005 reserved_trace_prefix',
      e like 'MR005%' and e like '%reserved_trace_prefix%'
      and not exists (select 1 from app.edi_interchange where tenant_id = t1 and trace_number = tr_probe)
      and not exists (select 1 from app.remittance where tenant_id = t1 and trace_number = tr_probe));
    r := pg_temp._add(r, 'the reserved prefix check ignores case (837-abc refused too)',
      pg_temp._err(u_b, 'cmd_remittance_receive', 'rcv-probe2', jsonb_build_object('interchange_trace', '837-ABC',
        'payer_id', pay_a, 'control_total', 10, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_misc, 'line_id', l_misc, 'paid', 10))))
      like 'MR005%');

    j := pg_temp._run(u_b, 'cmd_claim_submit', 'sub-probe', jsonb_build_object('claim_id', c_probe));
    r := pg_temp._add(r, 'reviewer probe step 2: submit queues a real outbound 837 for the claim and reports it',
      (select status from app.claim where claim_id = c_probe) = 'submitted'
      and (select count(*) = 1 and bool_and(direction = 'outbound' and transaction_set = '837' and status = 'queued'
                                            and edi_interchange_id = (j->>'edi_interchange_id')::uuid)
             from app.edi_interchange where tenant_id = t1 and trace_number = tr_probe));
    j2 := pg_temp._run(u_b, 'cmd_claim_submit', 'sub-probe', jsonb_build_object('claim_id', c_probe));
    r := pg_temp._add(r, 'submit replay with the same idem key is idempotent (identical result, still one outbound 837, one event)',
      j2 = j
      and (select count(*) = 1 from app.edi_interchange where tenant_id = t1 and trace_number = tr_probe)
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'claim.submitted' and aggregate_id = c_probe));

    -- a foreign interchange already on the claim's trace (pre-006b data, or any path bypassing receive)
    insert into app.edi_interchange (tenant_id, clearinghouse_id, payer_id, direction, transaction_set, trace_number, status)
      values (t1, ch1, pay_a, 'inbound', '835', tr_legacy, 'received');
    e := pg_temp._err(u_b, 'cmd_claim_submit', 'sub-legacy', jsonb_build_object('claim_id', c_legacy));
    r := pg_temp._add(r, 'an inbound 835 holding the claim''s 837 trace makes submit refuse MR002 submit_interchange_conflict',
      e like 'MR002%' and e like '%submit_interchange_conflict%');
    r := pg_temp._add(r, 'the conflicting submit marks nothing: claim stays ready, no outbound 837, no event, no idempotency row',
      (select status = 'ready' and submitted_at is null from app.claim where claim_id = c_legacy)
      and not exists (select 1 from app.edi_interchange where tenant_id = t1 and trace_number = tr_legacy and direction = 'outbound')
      and not exists (select 1 from audit.outbox_event where tenant_id = t1 and type = 'claim.submitted' and aggregate_id = c_legacy)
      and not exists (select 1 from app.idempotency_key where tenant_id = t1 and key = 'sub-legacy'));

    j := pg_temp._run(u_b, 'cmd_remittance_receive', 'rcv-dup1', jsonb_build_object('interchange_trace', 'TRN-DUP', 'payer_id', pay_a,
      'control_total', 10, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_misc, 'line_id', l_misc, 'paid', 10))));
    e := pg_temp._err(u_b, 'cmd_remittance_receive', 'rcv-dup2', jsonb_build_object('interchange_trace', 'TRN-DUP', 'payer_id', pay_a,
      'control_total', 10, 'lines', jsonb_build_array(jsonb_build_object('claim_id', c_misc, 'line_id', l_misc, 'paid', 10))));
    r := pg_temp._add(r, 'IV37 unchanged: a duplicate inbound 835 trace is still refused MR002 duplicate_interchange',
      e like 'MR002%' and e like '%duplicate_interchange%'
      and (select count(*) = 1 from app.edi_interchange where tenant_id = t1 and trace_number = 'TRN-DUP')
      and (select count(*) = 1 from app.remittance where tenant_id = t1 and trace_number = 'TRN-DUP'));
    r := pg_temp._add(r, 'at table level a second inbound 835 with the same trace is still 23505; an outbound 837 may share it',
      pg_temp._try(format($q$insert into app.edi_interchange (tenant_id, payer_id, direction, transaction_set, trace_number)
                             values (%L, %L, 'inbound', '835', 'TRN-DUP')$q$, t1, pay_a)) = '23505'
      and pg_temp._try(format($q$insert into app.edi_interchange (tenant_id, payer_id, direction, transaction_set, trace_number)
                             values (%L, %L, 'outbound', '837', 'TRN-DUP')$q$, t1, pay_a)) = 'ok');

    -- ================================================================ 2. claim status over several remittances
    r := pg_temp._add(r, 'claim transitions partially_paid -> paid, denied -> paid, denied -> partially_paid exist (and no others added)',
      ref.transition_ok('claim', 'partially_paid', 'paid') and ref.transition_ok('claim', 'denied', 'paid')
      and ref.transition_ok('claim', 'denied', 'partially_paid')
      and not ref.transition_ok('claim', 'paid', 'partially_paid') and not ref.transition_ok('claim', 'partially_paid', 'denied')
      and (select count(*) = 10 from ref.state_transition where entity = 'claim'));

    -- (a) submitted -> accepted -> partially_paid, then a second remittance clears every line -> paid
    perform pg_temp._run(u_b, 'cmd_claim_release', 'rel-flow', jsonb_build_object('claim_id', c_flow));
    perform pg_temp._run(u_b, 'cmd_claim_submit', 'sub-flow', jsonb_build_object('claim_id', c_flow));
    j := pg_temp._remit(u_b, 'f1', 'TRN-F1', pay_a, c_flow, f1, 60.00, 40.00, null, '45');
    r := pg_temp._add(r, 'flow: first remittance (line 1 closed, line 2 untouched) moves submitted -> accepted -> partially_paid',
      (select status from app.claim where claim_id = c_flow) = 'partially_paid'
      and j->'claims'->0->>'status' = 'partially_paid'
      and not exists (select 1 from app.denial where claim_id = c_flow));
    j := pg_temp._remit(u_b, 'f2', 'TRN-F2', pay_a, c_flow, f2, 50.00, null, null, null);
    r := pg_temp._add(r, 'flow: second remittance clears the last line -> paid (partially_paid -> paid), both lines balanced',
      (select status from app.claim where claim_id = c_flow) = 'paid'
      and j->'claims'->0->>'status' = 'paid'
      and (select bool_and(balanced) from app.claim_service_line where claim_id = c_flow)
      and (select count(*) = 2 from audit.outbox_event where tenant_id = t1 and type = 'payment.posted' and aggregate_id = c_flow));

    -- (b) all denied -> denied; the denial is worked and recovered; a later remittance pays -> paid
    perform pg_temp._run(u_b, 'cmd_claim_release', 'rel-den', jsonb_build_object('claim_id', c_den));
    perform pg_temp._run(u_b, 'cmd_claim_submit', 'sub-den', jsonb_build_object('claim_id', c_den));
    j := pg_temp._remit(u_b, 'd1', 'TRN-D1', pay_a, c_den, l_den, 0, null, 100.00, '50');
    d_den := (j->'denial_ids'->>0)::uuid;
    r := pg_temp._add(r, 'denied path: a remittance denying the only line moves the claim to denied with one open denial',
      (select status from app.claim where claim_id = c_den) = 'denied'
      and (select count(*) = 1 from app.denial where claim_id = c_den and status = 'new'));
    perform pg_temp._run(u_b, 'cmd_denial_triage', 'tri-den', jsonb_build_object('denial_id', d_den, 'root_cause', 'CODING', 'recommended_path', 'appeal'));
    perform pg_temp._run(u_b, 'cmd_denial_confirm_path', 'cp-den', jsonb_build_object('denial_id', d_den, 'path', 'appeal'));
    update app.denial set status = 'recovered', resolved_at = now() where denial_id = d_den;   -- stands in for the Task 7/8 recovery
    j := pg_temp._remit(u_b, 'd2', 'TRN-D2', pay_a, c_den, l_den, 90.00, 10.00, null, '45');
    r := pg_temp._add(r, 'denied path: once the denial is recovered, a remittance that clears the line moves denied -> paid',
      (select status from app.claim where claim_id = c_den) = 'paid'
      and (select open_amount = 0 and balanced from api.line_balance where line_id = l_den));

    -- (c) all denied -> denied; a later payment while the denial is still open -> partially_paid (never paid)
    perform pg_temp._run(u_b, 'cmd_claim_release', 'rel-den2', jsonb_build_object('claim_id', c_den2));
    perform pg_temp._run(u_b, 'cmd_claim_submit', 'sub-den2', jsonb_build_object('claim_id', c_den2));
    j := pg_temp._remit(u_b, 'e1', 'TRN-E1', pay_a, c_den2, l_den2, 0, null, 100.00, '50');
    r := pg_temp._add(r, 'second denied claim is denied after its first remittance',
      (select status from app.claim where claim_id = c_den2) = 'denied');
    j := pg_temp._remit(u_b, 'e2', 'TRN-E2', pay_a, c_den2, l_den2, 100.00, null, null, null);
    r := pg_temp._add(r, 'denied -> partially_paid: the line is fully paid but the denial is still open, so not paid',
      (select status from app.claim where claim_id = c_den2) = 'partially_paid'
      and (select open_amount = 0 from api.line_balance where line_id = l_den2)
      and exists (select 1 from app.denial where claim_id = c_den2 and status = 'new'));

    -- (d) nothing paid, line still open, no denial: status unchanged (no denied without a denial row)
    j := pg_temp._remit(u_b, 'n1', 'TRN-N1', pay_a, c_noop, l_noop, 0, 30.00, null, '45');
    r := pg_temp._add(r, 'nothing paid, open line, no denial: an accepted claim stays accepted (not denied)',
      (select status from app.claim where claim_id = c_noop) = 'accepted'
      and j->'claims'->0->>'status' = 'accepted'
      and not exists (select 1 from app.denial where claim_id = c_noop)
      and (select count(*) = 1 from app.payment_posting where line_id = l_noop and kind = 'adjustment'));
    j := pg_temp._remit(u_b, 'n2', 'TRN-N2', pay_a, c_nsub, l_nsub, 0, 30.00, null, '45');
    r := pg_temp._add(r, 'same for a submitted claim: only the 835 acknowledgement step (submitted -> accepted), no outcome',
      (select status from app.claim where claim_id = c_nsub) = 'accepted');

    r := pg_temp._add(r, 'cmd_remittance_post and cmd_claim_submit keep definer, empty search_path and authenticated-only execute',
      (select count(*) = 3 from pg_proc p
        where p.oid in ('api.cmd_remittance_post(text,jsonb)'::regprocedure, 'api.cmd_claim_submit(text,jsonb)'::regprocedure,
                        'api.cmd_remittance_receive(text,jsonb)'::regprocedure)
          and p.prosecdef and p.proconfig @> array['search_path=""']
          and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
          and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)));
    r := pg_temp._add(r, 'audit chain verifies after the flows', audit.verify_chain(t1));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id = t1)
    and not exists (select 1 from auth.users where id = u_b)
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\')
    and not exists (select 1 from audit.outbox_event where tenant_id = t1)
    and not exists (select 1 from app.permission where description = 'Task 6b command'));

  perform tests.assert((x->>'p')::boolean, x->>'m') from jsonb_array_elements(r) x;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._run(uuid, text, text, jsonb);
drop function pg_temp._err(uuid, text, text, jsonb);
drop function pg_temp._remit(uuid, text, text, uuid, uuid, uuid, numeric, numeric, numeric, text);

select tests.report();
