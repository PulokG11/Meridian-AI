-- Task 7 tests: command functions part 2 (evidence, appeals, approvals, AI review, records requests).
--   provider portal: api.cmd_evidence_assemble, api.cmd_appeal_draft, api.cmd_appeal_request_approval,
--                    api.cmd_approval_decide, api.cmd_appeal_file, api.cmd_records_request_respond,
--                    api.cmd_ai_review, api.cmd_ai_interaction_record
--   payer portal:    api.cmd_appeal_record_decision, api.cmd_records_request_decide
-- Every command is called for real: `set local role authenticated` + request.jwt.claims sub per user (or anon).
-- The appeal flow is driven through the commands (confirm path -> draft -> request approval -> decide -> file ->
-- payer decision); only the starting denials, a records request and tenant-two rows are inserted as fixtures.
-- Run with execute_sql (whole file in one call). All fixtures live in a sub-transaction rolled back at the end.
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

-- The statement id of an appeal at a sequence number.
create or replace function pg_temp._st(p_appeal uuid, p_seq integer) returns uuid
language sql as $$ select appeal_statement_id from app.appeal_statement where appeal_id = p_appeal and seq = p_seq $$;

do $$
declare
  r jsonb := '[]'::jsonb;
  m text; e text; e2 text; fn text; def text;
  j jsonb; j2 jsonb; ok boolean;
  prov_cmds text[] := array['cmd_evidence_assemble','cmd_appeal_draft','cmd_appeal_request_approval','cmd_approval_decide',
                            'cmd_appeal_file','cmd_records_request_respond','cmd_ai_review','cmd_ai_interaction_record'];
  payer_cmds text[] := array['cmd_appeal_record_decision','cmd_records_request_decide'];
  cmds text[];
  perms text[] := array['evidence.assemble','appeal.draft','appeal.request_approval','approval.decide','appeal.file',
                        'records_request.respond','ai.review','ai.interaction_record',
                        'appeal.record_decision','records_request.decide'];
  t1 uuid := app.uuid_v7(); t2 uuid := app.uuid_v7();
  u_a uuid := gen_random_uuid(); u_e uuid := gen_random_uuid(); u_m uuid := gen_random_uuid(); u_s uuid := gen_random_uuid();
  u_np uuid := gen_random_uuid(); u_pa uuid := gen_random_uuid(); u_pb uuid := gen_random_uuid(); u_b2 uuid := gen_random_uuid();
  prv uuid := app.uuid_v7(); pat uuid := app.uuid_v7(); pay_a uuid := app.uuid_v7(); pay_b uuid := app.uuid_v7();
  c_a uuid := app.uuid_v7(); c_b uuid := app.uuid_v7(); c_late uuid := app.uuid_v7(); c_ev uuid := app.uuid_v7();
  d_a uuid := app.uuid_v7(); d_b uuid := app.uuid_v7(); d_late uuid := app.uuid_v7(); d_ev uuid := app.uuid_v7();
  d_new uuid := app.uuid_v7(); rr1 uuid := app.uuid_v7();
  pat2 uuid := app.uuid_v7(); pay_t2 uuid := app.uuid_v7(); c_t2 uuid := app.uuid_v7(); d_t2 uuid := app.uuid_v7();
  ap_t2 uuid := app.uuid_v7(); ai_t2 uuid := app.uuid_v7(); ev_t2 uuid := app.uuid_v7();
  ev_a7 uuid := app.uuid_v7();   -- 007b: a real evidence row so source_refs are typed references (IV15)
  ghost uuid := gen_random_uuid();
  ai1 uuid; ap_a uuid; ap_a2 uuid; ap_b uuid; ap_late uuid;
  ar1 uuid; ar2 uuid; ar_b uuid; ar_l uuid; ar_a2 uuid;
  ev1 uuid; ev2 uuid; ev3 uuid; dl_a uuid; dl_ev uuid;
begin
  cmds := prov_cmds || payer_cmds;
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values
      ('t_author', 'Appeal author', 'provider'), ('t_mgr', 'Manager', 'provider'), ('t_sup', 'Supervisor', 'provider'),
      ('t_noperm', 'Staff without permissions', 'provider'), ('t_payer', 'Payer', 'payer');
    insert into app.permission (permission_key, description)
      select p, 'Task 7 command' from unnest(perms || array['denial.confirm_path']) p
    on conflict (permission_key) do nothing;
    insert into app.role_permission (role_key, permission_key)
      select rk, p from unnest(array['t_author','t_mgr','t_sup']) rk, unnest(perms || array['denial.confirm_path']) p
      union all select 't_payer', p from unnest(perms) p;   -- a payer holding every key is still refused provider commands
    insert into auth.users (id, aud, role, email) values
      (u_a,  'authenticated', 'authenticated', 'a7@meridian.test'),
      (u_e,  'authenticated', 'authenticated', 'e7@meridian.test'),
      (u_m,  'authenticated', 'authenticated', 'm7@meridian.test'),
      (u_s,  'authenticated', 'authenticated', 's7@meridian.test'),
      (u_np, 'authenticated', 'authenticated', 'np7@meridian.test'),
      (u_pa, 'authenticated', 'authenticated', 'pa7@meridian.test'),
      (u_pb, 'authenticated', 'authenticated', 'pb7@meridian.test'),
      (u_b2, 'authenticated', 'authenticated', 'b27@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, party_id, display_name) values
      (u_a,  t1, 'provider', 't_author', null,  'Author One'),
      (u_e,  t1, 'provider', 't_author', null,  'Editor Two'),
      (u_m,  t1, 'provider', 't_mgr',    null,  'Manager'),
      (u_s,  t1, 'provider', 't_sup',    null,  'Supervisor'),
      (u_np, t1, 'provider', 't_noperm', null,  'No Permission'),
      (u_pa, t1, 'payer',    't_payer',  pay_a, 'Payer A user'),
      (u_pb, t1, 'payer',    't_payer',  pay_b, 'Payer B user'),
      (u_b2, t2, 'provider', 't_author', null,  'Author Tenant Two');
    -- the author role has a high limit so a self-approval refusal is segregation of duties, not the limit
    insert into app.approval_limit (tenant_id, role_key, kind, max_amount) values
      (t1, 't_author', 'appeal', 10000.00), (t1, 't_mgr', 'appeal', 5000.00), (t1, 't_sup', 'appeal', 100.00);

    insert into app.provider (provider_id, tenant_id, npi, name) values (prv, t1, '1000000007', 'Dr Seven');
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values
      (pat, t1, 'MRN-7', 'Ada', 'Alpha', date '1980-01-01'),
      (pat2, t2, 'MRN-72', 'Bea', 'Beta', date '1981-02-02');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values
      (pay_a, t1, 'Payer A', 'PA07', 'commercial'), (pay_b, t1, 'Payer B', 'PB07', 'medicaid'),
      (pay_t2, t2, 'Payer T2', 'PT207', 'commercial');
    insert into app.payer_config (tenant_id, payer_id, timely_filing_days, appeal_levels, records_request_days, effective_from) values
      (t1, pay_a, 90, 2, 30, date '2026-01-01'),     -- two appeal levels
      (t1, pay_b, 90, 1, 30, date '2026-01-01');     -- one appeal level
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, status) values
      (c_a,    t1, 'CL-A7',    pat, prv, pay_a, 'accepted'),
      (c_b,    t1, 'CL-B7',    pat, prv, pay_b, 'accepted'),
      (c_late, t1, 'CL-LATE7', pat, prv, pay_a, 'accepted'),
      (c_ev,   t1, 'CL-EV7',   pat, prv, pay_a, 'accepted'),
      (c_t2,   t2, 'CL-T27',   pat2, null, pay_t2, 'accepted');
    insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, denied_amount, received_at) values
      (d_a,    t1, c_a,    'triaged', 'CO', '50',  300.00, now() - interval '5 days'),
      (d_b,    t1, c_b,    'triaged', 'CO', '50',   80.00, now() - interval '5 days'),
      (d_late, t1, c_late, 'triaged', 'CO', '50',  120.00, now() - interval '200 days'),   -- appeal window already closed
      (d_ev,   t1, c_ev,   'triaged', 'CO', '252',  60.00, now() - interval '2 days'),
      (d_new,  t1, c_ev,   'new',     'CO', '16',   10.00, now()),
      (d_t2,   t2, c_t2,   'in_appeal', 'CO', '50', 100.00, now());
    insert into app.denial_triage (tenant_id, denial_id, recommended_path, confidence) values
      (t1, d_a, 'appeal', 0.900), (t1, d_b, 'appeal', 0.800), (t1, d_late, 'appeal', 0.700), (t1, d_ev, 'evidence', 0.850);
    insert into app.records_request (records_request_id, tenant_id, claim_id, denial_id, requested_items, due_at) values
      (rr1, t1, c_ev, d_ev, 'Office notes and the authorization for the date of service', now() + interval '30 days');
    insert into app.evidence_item (evidence_item_id, tenant_id, claim_id, denial_id, kind, title) values
      (ev_a7, t1, c_a, d_a, 'authorization', 'Authorization AUTH-7781');
    -- tenant two (never touched by tenant-one callers)
    insert into app.appeal (appeal_id, tenant_id, claim_id, denial_id, level, status, author_id, amount) values
      (ap_t2, t2, c_t2, d_t2, 1, 'approved', u_b2, 100.00);
    insert into app.ai_interaction (ai_interaction_id, tenant_id, task, subject_type, subject_id, output) values
      (ai_t2, t2, 'appeal.draft', 'denial', d_t2, '{"draft":"t2"}'::jsonb);
    insert into app.evidence_item (evidence_item_id, tenant_id, claim_id, denial_id, kind, title) values
      (ev_t2, t2, c_t2, d_t2, 'medical_record', 'Tenant two record');

    -- ================================================================ schema additions
    r := pg_temp._add(r, 'appeal transition pending_approval -> drafting (rejected approval) exists',
      ref.transition_ok('appeal', 'pending_approval', 'drafting'));
    r := pg_temp._add(r, 'records_request transitions open->responded, responded->accepted|rejected exist, open->accepted does not',
      ref.transition_ok('records_request', 'open', 'responded') and ref.transition_ok('records_request', 'responded', 'accepted')
      and ref.transition_ok('records_request', 'responded', 'rejected') and not ref.transition_ok('records_request', 'open', 'accepted'));
    r := pg_temp._add(r, 'appeal.ai_interaction_id is an indexed FK to app.ai_interaction',
      exists (select 1 from pg_constraint where conrelid = 'app.appeal'::regclass and contype = 'f'
                 and confrelid = 'app.ai_interaction'::regclass)
      and exists (select 1 from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
                   where i.indrelid = 'app.appeal'::regclass and a.attname = 'ai_interaction_id'));

    -- ================================================================ setup through commands: confirm the paths
    perform pg_temp._run(u_a, 'cmd_denial_confirm_path', 'cp-a', jsonb_build_object('denial_id', d_a, 'path', 'appeal'));
    perform pg_temp._run(u_a, 'cmd_denial_confirm_path', 'cp-b', jsonb_build_object('denial_id', d_b, 'path', 'appeal'));
    perform pg_temp._run(u_a, 'cmd_denial_confirm_path', 'cp-l', jsonb_build_object('denial_id', d_late, 'path', 'appeal'));
    perform pg_temp._run(u_a, 'cmd_denial_confirm_path', 'cp-e', jsonb_build_object('denial_id', d_ev, 'path', 'evidence'));
    select deadline_id into dl_a from app.deadline where subject_type = 'denial' and subject_id = d_a and kind = 'appeal_filing';
    select deadline_id into dl_ev from app.deadline where subject_type = 'denial' and subject_id = d_ev and kind = 'records_response';
    r := pg_temp._add(r, 'setup: denials in_appeal / in_evidence with deadlines (late one already passed)',
      (select count(*) = 3 from app.denial where denial_id in (d_a, d_b, d_late) and status = 'in_appeal')
      and (select status from app.denial where denial_id = d_ev) = 'in_evidence'
      and dl_a is not null and dl_ev is not null
      and (select due_at < now() from app.deadline where subject_id = d_late and kind = 'appeal_filing'));

    -- ================================================================ ai.interaction_record
    j := pg_temp._run(u_a, 'cmd_ai_interaction_record', 'ai-1', jsonb_build_object(
      'task', 'appeal.draft', 'subject_type', 'denial', 'subject_id', d_a, 'model_version', 'appeal-draft-sim-0.1',
      'input_ref', 'denial:' || d_a, 'output', jsonb_build_object('statements', 2, 'template', 'medical-necessity')));
    ai1 := (j->>'ai_interaction_id')::uuid;
    r := pg_temp._add(r, 'ai.interaction_record: row with task, subject, model_version, output, label Simulated, status suggested',
      (select task = 'appeal.draft' and subject_type = 'denial' and subject_id = d_a and model_version = 'appeal-draft-sim-0.1'
              and output->>'template' = 'medical-necessity' and label = 'Simulated' and status = 'suggested' and created_by = u_a
         from app.ai_interaction where ai_interaction_id = ai1)
      and j->>'label' = 'Simulated');
    r := pg_temp._add(r, 'ai.interaction_record: outbox ai.interaction_recorded (aggregate = interaction) and audit',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'ai.interaction_recorded' and aggregate_id = ai1)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'ai.interaction_record' and object_id = ai1 and actor = u_a));
    e := pg_temp._err(u_a, 'cmd_ai_interaction_record', 'ai-bad', jsonb_build_object('task', 'appeal.draft', 'model_version', 'x',
      'output', '{}'::jsonb, 'label', 'Production'));
    e2 := pg_temp._err(u_a, 'cmd_ai_interaction_record', 'ai-bad2', jsonb_build_object('task', 'appeal.draft', 'model_version', 'x',
      'output', '"text"'::jsonb));
    r := pg_temp._add(r, 'ai.interaction_record: a label other than Simulated or a non-object output is refused MR005',
      e like 'MR005%' and e2 like 'MR005%');
    e := pg_temp._err(u_a, 'cmd_ai_interaction_record', 'ai-t2', jsonb_build_object('task', 'appeal.draft', 'model_version', 'x',
      'output', '{}'::jsonb, 'subject_type', 'denial', 'subject_id', d_t2));
    e2 := pg_temp._err(u_a, 'cmd_ai_interaction_record', 'ai-gh', jsonb_build_object('task', 'appeal.draft', 'model_version', 'x',
      'output', '{}'::jsonb, 'subject_type', 'denial', 'subject_id', ghost));
    r := pg_temp._add(r, 'ai.interaction_record: a foreign subject and a nonexistent subject give identical MR004', e like 'MR004%' and e = e2);

    -- ================================================================ appeal.draft (AI-drafted, one unsupported statement)
    j := pg_temp._run(u_a, 'cmd_appeal_draft', 'dr-a1', jsonb_build_object('denial_id', d_a, 'ai_interaction_id', ai1,
      'statements', jsonb_build_array(
        jsonb_build_object('text', 'Claim CL-A7 was billed for an office visit on the date of service.', 'source_ref', 'claim:' || c_a),
        jsonb_build_object('text', 'The payer authorized the visit in advance.'))));
    ap_a := (j->>'appeal_id')::uuid;
    r := pg_temp._add(r, 'draft: appeal drafting, level 1, amount = denied amount, author from ctx, linked to the AI interaction',
      (select status = 'drafting' and level = 1 and parent_appeal_id is null and amount = 300.00 and author_id = u_a
              and claim_id = c_a and denial_id = d_a and ai_interaction_id = ai1
         from app.appeal where appeal_id = ap_a)
      and j->>'status' = 'drafting' and j->>'mode' = 'created');
    r := pg_temp._add(r, 'draft: statement 1 sourced, statement 2 without a source is flagged unsupported',
      (select count(*) = 2 from app.appeal_statement where appeal_id = ap_a)
      and (select not unsupported and source_ref = 'claim:' || c_a from app.appeal_statement where appeal_id = ap_a and seq = 1)
      and (select unsupported and source_ref is null from app.appeal_statement where appeal_id = ap_a and seq = 2)
      and (j->>'unsupported_count')::int = 1
      and j->'unsupported_statement_ids' = jsonb_build_array(pg_temp._st(ap_a, 2)));
    r := pg_temp._add(r, 'draft: outbox appeal.drafted (aggregate appeal) and audit appeal.draft',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'appeal.drafted' and aggregate_id = ap_a)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'appeal.draft' and object_id = ap_a and actor = u_a));
    j2 := pg_temp._run(u_a, 'cmd_appeal_draft', 'dr-a1', jsonb_build_object('denial_id', d_a, 'ai_interaction_id', ai1,
      'statements', jsonb_build_array(
        jsonb_build_object('text', 'Claim CL-A7 was billed for an office visit on the date of service.', 'source_ref', 'claim:' || c_a),
        jsonb_build_object('text', 'The payer authorized the visit in advance.'))));
    r := pg_temp._add(r, 'draft: same idempotency key twice acts once (identical result, one appeal, one event)',
      j2 = j and (select count(*) = 1 from app.appeal where denial_id = d_a)
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'appeal.drafted'));
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-a1-dup', jsonb_build_object('denial_id', d_a,
      'statements', jsonb_build_array(jsonb_build_object('text', 'x', 'source_ref', 'claim:' || c_a))));
    r := pg_temp._add(r, 'draft: a second level-1 appeal for the same denial is refused MR002 appeal_exists',
      e like 'MR002%' and e like '%appeal_exists%');
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-bad1', jsonb_build_object('denial_id', d_b,
      'statements', jsonb_build_array(jsonb_build_object('text', 'No source', 'unsupported', false))));
    e2 := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-bad2', jsonb_build_object('denial_id', d_b, 'amount', 80.01,
      'statements', jsonb_build_array(jsonb_build_object('text', 'x', 'source_ref', 'claim:' || c_b))));
    r := pg_temp._add(r, 'draft: a statement marked supported without a source, or an amount above the denied amount, is MR005',
      e like 'MR005%' and e like '%statement_source_required%' and e2 like 'MR005%'
      and not exists (select 1 from app.appeal where denial_id = d_b));
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-bad3', jsonb_build_object('denial_id', d_b, 'appeal_id', ap_a,
      'statements', jsonb_build_array(jsonb_build_object('text', 'x', 'source_ref', 'claim:' || c_b))));
    e2 := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-bad4', jsonb_build_object('denial_id', d_b, 'statements', '[]'::jsonb));
    r := pg_temp._add(r, 'draft: two targets at once, or no statements, are MR005', e like 'MR005%' and e2 like 'MR005%');
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-new', jsonb_build_object('denial_id', d_new,
      'statements', jsonb_build_array(jsonb_build_object('text', 'x', 'source_ref', 'claim:' || c_ev))));
    r := pg_temp._add(r, 'draft: a denial whose appeal path is not confirmed is refused MR002 denial_not_in_appeal',
      e like 'MR002%' and e like '%denial_not_in_appeal%');
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-ait2', jsonb_build_object('denial_id', d_b, 'ai_interaction_id', ai_t2,
      'statements', jsonb_build_array(jsonb_build_object('text', 'x', 'source_ref', 'claim:' || c_b))));
    e2 := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-aigh', jsonb_build_object('denial_id', d_b, 'ai_interaction_id', ghost,
      'statements', jsonb_build_array(jsonb_build_object('text', 'x', 'source_ref', 'claim:' || c_b))));
    r := pg_temp._add(r, 'draft: a foreign ai_interaction_id and a nonexistent one give identical MR004', e like 'MR004%' and e = e2);

    -- ================================================================ appeal.request_approval refused while unsupported (IV14)
    e := pg_temp._err(u_a, 'cmd_appeal_request_approval', 'rq-a0', jsonb_build_object('appeal_id', ap_a));
    r := pg_temp._add(r, 'request_approval refused MR002 IV14_unsupported_statement, naming statement 2 and its id',
      e like 'MR002%' and e like '%IV14_unsupported_statement%' and e like '%statement 2 %'
      and e like '%' || pg_temp._st(ap_a, 2)::text || '%' and e not like '%statement 1 %');
    r := pg_temp._add(r, 'the IV14 refusal changed nothing: appeal drafting, no approval request, no event, no idempotency row',
      (select status from app.appeal where appeal_id = ap_a) = 'drafting'
      and not exists (select 1 from app.approval_request where subject_id = ap_a)
      and not exists (select 1 from audit.outbox_event where tenant_id = t1 and type = 'approval.requested')
      and not exists (select 1 from app.idempotency_key where tenant_id = t1 and key = 'rq-a0'));

    -- fix: another staff member amends the draft (same appeal), statement 2 now has a source
    j := pg_temp._run(u_e, 'cmd_appeal_draft', 'dr-a1-fix', jsonb_build_object('appeal_id', ap_a,
      'statements', jsonb_build_array(
        jsonb_build_object('text', 'Claim CL-A7 was billed for an office visit on the date of service.', 'source_ref', 'claim:' || c_a),
        jsonb_build_object('text', 'The payer authorized the visit in advance (AUTH-7781).', 'source_ref', 'evidence_item:' || ev_a7))));
    r := pg_temp._add(r, 'amend: same appeal, mode amended, no unsupported statement, AI link kept, author = the amender',
      j->>'appeal_id' = ap_a::text and j->>'mode' = 'amended' and (j->>'unsupported_count')::int = 0
      and (select author_id = u_e and ai_interaction_id = ai1 and status = 'drafting' from app.appeal where appeal_id = ap_a)
      and (select not unsupported and source_ref = 'evidence_item:' || ev_a7 from app.appeal_statement where appeal_id = ap_a and seq = 2)
      and (select count(*) = 2 from app.appeal_statement where appeal_id = ap_a));

    j := pg_temp._run(u_e, 'cmd_appeal_request_approval', 'rq-a1', jsonb_build_object('appeal_id', ap_a));
    ar1 := (j->>'approval_request_id')::uuid;
    r := pg_temp._add(r, 'request_approval after the fix: appeal pending_approval; approval_request kind appeal, amount = disputed, requester from ctx',
      (select status from app.appeal where appeal_id = ap_a) = 'pending_approval'
      and (select kind = 'appeal' and amount = 300.00 and requester_id = u_e and status = 'pending'
              and subject_type = 'appeal' and subject_id = ap_a
         from app.approval_request where approval_request_id = ar1)
      and j->>'subject_id' = ar1::text);
    r := pg_temp._add(r, 'request_approval: outbox approval.requested (aggregate = approval request) and audit',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'approval.requested' and aggregate_id = ar1
                                                     and payload->>'appeal_id' = ap_a::text)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'appeal.request_approval' and actor = u_e));
    j2 := pg_temp._run(u_e, 'cmd_appeal_request_approval', 'rq-a1', jsonb_build_object('appeal_id', ap_a));
    r := pg_temp._add(r, 'request_approval: same key twice acts once',
      j2 = j and (select count(*) = 1 from app.approval_request where subject_id = ap_a));
    e := pg_temp._err(u_e, 'cmd_appeal_request_approval', 'rq-a1b', jsonb_build_object('appeal_id', ap_a));
    r := pg_temp._add(r, 'request_approval again while pending_approval is MR001', e like 'MR001%');

    -- ================================================================ approval.decide refusals (IV13, limit, permission)
    e := pg_temp._err(u_e, 'cmd_approval_decide', 'ad-self1', jsonb_build_object('approval_request_id', ar1, 'decision', 'approved'));
    e2 := pg_temp._err(u_a, 'cmd_approval_decide', 'ad-self2', jsonb_build_object('approval_request_id', ar1, 'decision', 'approved'));
    r := pg_temp._add(r, 'approving your own appeal is refused MR003 IV13_self_approval (the author, and an earlier drafter)',
      e like 'MR003%' and e like '%IV13_self_approval%' and e2 like 'MR003%' and e2 like '%IV13_self_approval%');
    e := pg_temp._err(u_s, 'cmd_approval_decide', 'ad-lim', jsonb_build_object('approval_request_id', ar1, 'decision', 'approved'));
    r := pg_temp._add(r, 'approving over your limit is refused MR003 IV13_approval_limit_exceeded by the command (not the trigger)',
      e like 'MR003%' and e like '%IV13_approval_limit_exceeded%' and e like '%100%');
    e := pg_temp._err(u_np, 'cmd_approval_decide', 'ad-np', jsonb_build_object('approval_request_id', ar1, 'decision', 'approved'));
    r := pg_temp._add(r, 'a user without approval.decide is refused MR003 permission_required', e like 'MR003%' and e like '%permission_required%');
    r := pg_temp._add(r, 'the refused decisions changed nothing: request pending, appeal pending_approval, no event, no idempotency row',
      (select status = 'pending' and approver_id is null from app.approval_request where approval_request_id = ar1)
      and (select status = 'pending_approval' and approver_id is null from app.appeal where appeal_id = ap_a)
      and not exists (select 1 from audit.outbox_event where tenant_id = t1 and type = 'approval.decided')
      and not exists (select 1 from app.idempotency_key where tenant_id = t1 and key in ('ad-self1', 'ad-self2', 'ad-lim', 'ad-np')));

    -- filing before approval
    e := pg_temp._err(u_a, 'cmd_appeal_file', 'fl-early', jsonb_build_object('appeal_id', ap_a));
    r := pg_temp._add(r, 'filing before approval is refused MR001 and the deadline stays open',
      e like 'MR001%' and (select status from app.appeal where appeal_id = ap_a) = 'pending_approval'
      and (select met_at is null from app.deadline where deadline_id = dl_a));

    -- rejection returns the appeal to drafting
    e := pg_temp._err(u_m, 'cmd_approval_decide', 'ad-rej0', jsonb_build_object('approval_request_id', ar1, 'decision', 'rejected'));
    r := pg_temp._add(r, 'a rejection without a reason is MR005', e like 'MR005%');
    j := pg_temp._run(u_m, 'cmd_approval_decide', 'ad-rej', jsonb_build_object('approval_request_id', ar1, 'decision', 'rejected',
      'reason', 'Attach the authorization letter'));
    r := pg_temp._add(r, 'rejected approval: request rejected by the caller, appeal back to drafting without an approver',
      (select status = 'rejected' and approver_id = u_m and reason = 'Attach the authorization letter' and decided_at is not null
         from app.approval_request where approval_request_id = ar1)
      and (select status = 'drafting' and approver_id is null from app.appeal where appeal_id = ap_a)
      and j->>'subject_id' = ar1::text and j->>'decision' = 'rejected' and j->'next'->>'status' = 'drafting');
    r := pg_temp._add(r, 'rejected approval: outbox approval.decided with aggregate = payload subject_id = the approval request',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'approval.decided'
                                                     and aggregate_id = ar1 and payload->>'subject_id' = ar1::text));
    e := pg_temp._err(u_a, 'cmd_appeal_file', 'fl-draft', jsonb_build_object('appeal_id', ap_a));
    r := pg_temp._add(r, 'filing a drafting appeal is refused MR001', e like 'MR001%');

    j := pg_temp._run(u_e, 'cmd_appeal_request_approval', 'rq-a2', jsonb_build_object('appeal_id', ap_a));
    ar2 := (j->>'approval_request_id')::uuid;
    j := pg_temp._run(u_m, 'cmd_approval_decide', 'ad-ok', jsonb_build_object('approval_request_id', ar2, 'decision', 'approved',
      'reason', 'Sources verified'));
    r := pg_temp._add(r, 'approval within limit by someone else: request approved, appeal approved with approver from ctx',
      ar2 <> ar1
      and (select status = 'approved' and approver_id = u_m from app.approval_request where approval_request_id = ar2)
      and (select status = 'approved' and approver_id = u_m from app.appeal where appeal_id = ap_a)
      and (j->>'within_limit')::boolean and j->>'decided_by' = u_m::text and j->'next'->>'status' = 'approved');
    j2 := pg_temp._run(u_m, 'cmd_approval_decide', 'ad-ok', jsonb_build_object('approval_request_id', ar2, 'decision', 'approved',
      'reason', 'Sources verified'));
    e := pg_temp._err(u_m, 'cmd_approval_decide', 'ad-ok2', jsonb_build_object('approval_request_id', ar2, 'decision', 'approved'));
    r := pg_temp._add(r, 'approval: replay returns the same result (one event); deciding again with a new key is MR001',
      j2 = j and e like 'MR001%'
      and (select count(*) = 2 from audit.outbox_event where tenant_id = t1 and type = 'approval.decided'));

    -- ================================================================ appeal.file and the AI review gate (IV16)
    e := pg_temp._err(u_a, 'cmd_appeal_file', 'fl-a0', jsonb_build_object('appeal_id', ap_a));
    r := pg_temp._add(r, 'AI-drafted appeal without a review cannot be filed (MR002 IV16_ai_review_required)',
      e like 'MR002%' and e like '%IV16_ai_review_required%'
      and (select status from app.appeal where appeal_id = ap_a) = 'approved'
      and (select met_at is null from app.deadline where deadline_id = dl_a));
    e := pg_temp._err(u_s, 'cmd_ai_review', 'rv-0', jsonb_build_object('ai_interaction_id', ai1, 'decision', 'approved'));
    r := pg_temp._add(r, 'ai.review without a reason is MR005', e like 'MR005%');
    j := pg_temp._run(u_s, 'cmd_ai_review', 'rv-1', jsonb_build_object('ai_interaction_id', ai1, 'decision', 'rejected',
      'reason', 'Statement 2 cites the wrong authorization'));
    r := pg_temp._add(r, 'ai.review rejected: ai_review row with reviewer from ctx; interaction rejected; event ai.reviewed',
      (select decision = 'rejected' and reviewer_id = u_s and reason like 'Statement 2%' from app.ai_review where ai_review_id = (j->>'ai_review_id')::uuid)
      and (select status from app.ai_interaction where ai_interaction_id = ai1) = 'rejected'
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'ai.reviewed' and aggregate_id = ai1));
    e := pg_temp._err(u_a, 'cmd_appeal_file', 'fl-a1', jsonb_build_object('appeal_id', ap_a));
    r := pg_temp._add(r, 'a rejecting review does not open the gate (still MR002 IV16)', e like 'MR002%' and e like '%IV16_ai_review_required%');
    e := pg_temp._err(u_s, 'cmd_ai_review', 'rv-t2', jsonb_build_object('ai_interaction_id', ai_t2, 'decision', 'approved', 'reason', 'x'));
    e2 := pg_temp._err(u_s, 'cmd_ai_review', 'rv-gh', jsonb_build_object('ai_interaction_id', ghost, 'decision', 'approved', 'reason', 'x'));
    r := pg_temp._add(r, 'ai.review of a foreign or nonexistent interaction gives identical MR004', e like 'MR004%' and e = e2);
    j := pg_temp._run(u_m, 'cmd_ai_review', 'rv-2', jsonb_build_object('ai_interaction_id', ai1, 'decision', 'approved',
      'reason', 'Corrected authorization verified against AUTH-7781'));
    r := pg_temp._add(r, 'ai.review approved: interaction accepted', j->>'decision' = 'approved'
      and (select status from app.ai_interaction where ai_interaction_id = ai1) = 'accepted');

    j := pg_temp._run(u_a, 'cmd_appeal_file', 'fl-a', jsonb_build_object('appeal_id', ap_a, 'submission_ref', 'PORTAL-RCPT-0007'));
    r := pg_temp._add(r, 'after an approving review the AI-drafted appeal files: filed, filed_at, receipt stored, deadline met',
      (select status = 'filed' and filed_at is not null and submission_ref = 'PORTAL-RCPT-0007' from app.appeal where appeal_id = ap_a)
      and (select met_at is not null from app.deadline where deadline_id = dl_a)
      and j->>'deadline_id' = dl_a::text and j->>'status' = 'filed');
    r := pg_temp._add(r, 'file: outbox appeal.filed (aggregate appeal) and audit appeal.file',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'appeal.filed' and aggregate_id = ap_a)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'appeal.file' and object_id = ap_a and actor = u_a));
    j2 := pg_temp._run(u_a, 'cmd_appeal_file', 'fl-a', jsonb_build_object('appeal_id', ap_a, 'submission_ref', 'PORTAL-RCPT-0007'));
    e := pg_temp._err(u_a, 'cmd_appeal_file', 'fl-a-again', jsonb_build_object('appeal_id', ap_a));
    r := pg_temp._add(r, 'file: same key twice acts once (one event); filing again with a new key is MR001',
      j2 = j and e like 'MR001%' and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'appeal.filed'));

    -- ================================================================ payer decision (upheld -> next level when the rule allows)
    e := pg_temp._err(u_pb, 'cmd_appeal_record_decision', 'pd-x', jsonb_build_object('appeal_id', ap_a, 'decision', 'upheld'));
    e2 := pg_temp._err(u_pb, 'cmd_appeal_record_decision', 'pd-gh', jsonb_build_object('appeal_id', ghost, 'decision', 'upheld'));
    r := pg_temp._add(r, 'payer B cannot decide payer A''s appeal: MR004 identical to a nonexistent appeal',
      e like 'MR004%' and e = e2 and (select status from app.appeal where appeal_id = ap_a) = 'filed');
    e := pg_temp._err(u_pa, 'cmd_appeal_record_decision', 'pd-amt', jsonb_build_object('appeal_id', ap_a, 'decision', 'upheld', 'amount', 10));
    r := pg_temp._add(r, 'an upheld decision with an amount is MR005', e like 'MR005%');
    j := pg_temp._run(u_pa, 'cmd_appeal_record_decision', 'pd-a', jsonb_build_object('appeal_id', ap_a, 'decision', 'upheld',
      'reason', 'Documentation does not support medical necessity'));
    ap_a2 := (j->>'next_appeal_id')::uuid;
    r := pg_temp._add(r, 'upheld: appeal decided by the payer user, decision upheld, no expected payment',
      (select status = 'decided' and decision = 'upheld' and decision_amount = 0 and expected_payment is null
              and decided_at is not null and decided_by = u_pa
         from app.appeal where appeal_id = ap_a));
    r := pg_temp._add(r, 'upheld and payer_config allows 2 levels: a level-2 appeal (drafting, parent = level 1) opens with its own deadline',
      ap_a2 is not null and (j->'next_level'->>'opened')::boolean
      and (select status = 'drafting' and level = 2 and parent_appeal_id = ap_a and denial_id = d_a and claim_id = c_a and amount = 300.00
              and ai_interaction_id is null
         from app.appeal where appeal_id = ap_a2)
      and (select count(*) = 1 from app.deadline where subject_type = 'appeal' and subject_id = ap_a2 and kind = 'appeal_filing'
                                                  and met_at is null and due_at > now()));
    r := pg_temp._add(r, 'upheld: events appeal.decided (level 1) and appeal.drafted (level 2) share the command''s correlation id',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'appeal.decided' and aggregate_id = ap_a)
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'appeal.drafted' and aggregate_id = ap_a2)
      and (select count(distinct correlation_id) = 1 from audit.outbox_event
            where tenant_id = t1 and ((type = 'appeal.decided' and aggregate_id = ap_a) or (type = 'appeal.drafted' and aggregate_id = ap_a2)))
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'appeal.record_decision' and object_id = ap_a and actor = u_pa));
    e := pg_temp._err(u_pa, 'cmd_appeal_record_decision', 'pd-a-again', jsonb_build_object('appeal_id', ap_a, 'decision', 'overturned'));
    r := pg_temp._add(r, 'deciding a decided appeal again is MR001', e like 'MR001%');
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-next-dup', jsonb_build_object('parent_appeal_id', ap_a,
      'statements', jsonb_build_array(jsonb_build_object('text', 'x', 'source_ref', 'claim:' || c_a))));
    r := pg_temp._add(r, 'draft for the next level when it is already open is MR002 next_level_exists',
      e like 'MR002%' and e like '%next_level_exists%');

    -- level 2 through the commands, then upheld again: payer_config allows no level 3
    perform pg_temp._run(u_a, 'cmd_appeal_draft', 'dr-a2', jsonb_build_object('appeal_id', ap_a2,
      'statements', jsonb_build_array(jsonb_build_object('text', 'Peer-reviewed guideline supports the visit.', 'source_ref', 'claim:' || c_a))));
    j := pg_temp._run(u_a, 'cmd_appeal_request_approval', 'rq-a2l2', jsonb_build_object('appeal_id', ap_a2));
    ar_a2 := (j->>'approval_request_id')::uuid;
    perform pg_temp._run(u_m, 'cmd_approval_decide', 'ad-a2', jsonb_build_object('approval_request_id', ar_a2, 'decision', 'approved'));
    j := pg_temp._run(u_a, 'cmd_appeal_file', 'fl-a2', jsonb_build_object('appeal_id', ap_a2));
    r := pg_temp._add(r, 'level 2 files against its own deadline (no AI link, so no review needed)',
      (select status from app.appeal where appeal_id = ap_a2) = 'filed'
      and (select met_at is not null from app.deadline where subject_type = 'appeal' and subject_id = ap_a2)
      and j->>'deadline_id' = (select deadline_id::text from app.deadline where subject_type = 'appeal' and subject_id = ap_a2));
    j := pg_temp._run(u_pa, 'cmd_appeal_record_decision', 'pd-a2', jsonb_build_object('appeal_id', ap_a2, 'decision', 'upheld'));
    r := pg_temp._add(r, 'upheld at the last level payer_config allows: no next level (reason appeal_levels_exhausted)',
      not (j->'next_level'->>'opened')::boolean and j->'next_level'->>'reason' = 'appeal_levels_exhausted'
      and j->>'next_appeal_id' is null
      and not exists (select 1 from app.appeal where parent_appeal_id = ap_a2)
      and (select count(*) = 2 from app.appeal where denial_id = d_a));

    -- ================================================================ payer B: no AI, partial overturn, cash not posted
    perform pg_temp._run(u_a, 'cmd_appeal_draft', 'dr-b', jsonb_build_object('denial_id', d_b,
      'statements', jsonb_build_array(jsonb_build_object('text', 'The service was covered under the plan.', 'source_ref', 'claim:' || c_b))));
    select appeal_id into ap_b from app.appeal where denial_id = d_b;
    j := pg_temp._run(u_a, 'cmd_appeal_request_approval', 'rq-b', jsonb_build_object('appeal_id', ap_b));
    ar_b := (j->>'approval_request_id')::uuid;
    perform pg_temp._run(u_s, 'cmd_approval_decide', 'ad-b', jsonb_build_object('approval_request_id', ar_b, 'decision', 'approved'));
    j := pg_temp._run(u_a, 'cmd_appeal_file', 'fl-b', jsonb_build_object('appeal_id', ap_b));
    r := pg_temp._add(r, 'payer B appeal: amount 80 within the supervisor limit 100, approved and filed without an AI review',
      (select status = 'filed' and approver_id = u_s and amount = 80.00 from app.appeal where appeal_id = ap_b));
    e := pg_temp._err(u_pa, 'cmd_appeal_record_decision', 'pd-ba', jsonb_build_object('appeal_id', ap_b, 'decision', 'overturned'));
    r := pg_temp._add(r, 'payer A cannot decide payer B''s appeal: MR004 identical to a nonexistent appeal', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_pb, 'cmd_appeal_record_decision', 'pd-b1', jsonb_build_object('appeal_id', ap_b, 'decision', 'overturned_in_part', 'amount', 80));
    e2 := pg_temp._err(u_pb, 'cmd_appeal_record_decision', 'pd-b2', jsonb_build_object('appeal_id', ap_b, 'decision', 'overturned_in_part', 'amount', 40.005));
    r := pg_temp._add(r, 'a partial overturn for the full amount, or with 3 decimals, is MR005', e like 'MR005%' and e2 like 'MR005%');
    j := pg_temp._run(u_pb, 'cmd_appeal_record_decision', 'pd-b', jsonb_build_object('appeal_id', ap_b, 'decision', 'overturned_in_part', 'amount', 40.00));
    r := pg_temp._add(r, 'overturned in part: decided, decision amount and expected payment 40, no next level',
      (select status = 'decided' and decision = 'overturned_in_part' and decision_amount = 40.00 and expected_payment = 40.00
         from app.appeal where appeal_id = ap_b)
      and not (j->'next_level'->>'opened')::boolean and (j->>'expected_payment')::numeric = 40.00
      and not exists (select 1 from app.appeal where parent_appeal_id = ap_b));
    r := pg_temp._add(r, 'an overturn records the expected payment but posts no cash (no posting, denial still in_appeal, claim unchanged)',
      not exists (select 1 from app.payment_posting p join app.claim_service_line l on l.claim_service_line_id = p.line_id where l.claim_id = c_b)
      and (select status from app.denial where denial_id = d_b) = 'in_appeal'
      and (select status from app.claim where claim_id = c_b) = 'accepted');
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-b-next', jsonb_build_object('parent_appeal_id', ap_b,
      'statements', jsonb_build_array(jsonb_build_object('text', 'x', 'source_ref', 'claim:' || c_b))));
    r := pg_temp._add(r, 'a next level on an appeal that was not upheld is MR002 parent_not_upheld', e like 'MR002%' and e like '%parent_not_upheld%');

    -- ================================================================ filing after the deadline
    perform pg_temp._run(u_a, 'cmd_appeal_draft', 'dr-l', jsonb_build_object('denial_id', d_late,
      'statements', jsonb_build_array(jsonb_build_object('text', 'Late but sourced.', 'source_ref', 'claim:' || c_late))));
    select appeal_id into ap_late from app.appeal where denial_id = d_late;
    j := pg_temp._run(u_a, 'cmd_appeal_request_approval', 'rq-l', jsonb_build_object('appeal_id', ap_late));
    ar_l := (j->>'approval_request_id')::uuid;
    perform pg_temp._run(u_m, 'cmd_approval_decide', 'ad-l', jsonb_build_object('approval_request_id', ar_l, 'decision', 'approved'));
    e := pg_temp._err(u_a, 'cmd_appeal_file', 'fl-l', jsonb_build_object('appeal_id', ap_late));
    r := pg_temp._add(r, 'filing after the deadline is refused MR002 appeal_deadline_passed; appeal stays approved, deadline not met',
      e like 'MR002%' and e like '%appeal_deadline_passed%'
      and (select status from app.appeal where appeal_id = ap_late) = 'approved'
      and (select met_at is null from app.deadline where subject_id = d_late and kind = 'appeal_filing')
      and not exists (select 1 from app.idempotency_key where tenant_id = t1 and key = 'fl-l'));

    -- ================================================================ evidence.assemble
    j := pg_temp._run(u_a, 'cmd_evidence_assemble', 'ev-1', jsonb_build_object('denial_id', d_ev,
      'required_kinds', jsonb_build_array('medical_record', 'authorization'),
      'items', jsonb_build_array(
        jsonb_build_object('kind', 'medical_record', 'title', 'Office note for the date of service', 'source_ref', 'chart:note-1'),
        jsonb_build_object('kind', 'correspondence', 'title', 'Payer letter'))));
    ev1 := (j->'created_ids'->>0)::uuid; ev2 := (j->'created_ids'->>1)::uuid;
    r := pg_temp._add(r, 'evidence.assemble: items created on the denial''s claim; completeness reports authorization missing',
      (select count(*) = 2 from app.evidence_item where denial_id = d_ev and claim_id = c_ev and tenant_id = t1)
      and not (j->'completeness'->>'complete')::boolean
      and j->'completeness'->'missing' = '["authorization"]'::jsonb);
    r := pg_temp._add(r, 'evidence.assemble: outbox evidence.assembled (aggregate denial) and audit',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'evidence.assembled' and aggregate_id = d_ev)
      and exists (select 1 from audit.audit_log where tenant_id = t1 and action = 'evidence.assemble' and object_id = d_ev));
    j := pg_temp._run(u_a, 'cmd_evidence_assemble', 'ev-2', jsonb_build_object('denial_id', d_ev,
      'required_kinds', jsonb_build_array('medical_record', 'authorization'),
      'items', jsonb_build_array(jsonb_build_object('kind', 'authorization', 'title', 'Authorization AUTH-9001', 'source_ref', 'auth:9001'))));
    ev3 := (j->'created_ids'->>0)::uuid;
    r := pg_temp._add(r, 'evidence.assemble again with the authorization: complete', (j->'completeness'->>'complete')::boolean
      and j->'completeness'->'missing' = '[]'::jsonb);
    e := pg_temp._err(u_a, 'cmd_evidence_assemble', 'ev-t2', jsonb_build_object('denial_id', d_ev, 'evidence_item_ids', jsonb_build_array(ev_t2)));
    e2 := pg_temp._err(u_a, 'cmd_evidence_assemble', 'ev-gh', jsonb_build_object('denial_id', d_ev, 'evidence_item_ids', jsonb_build_array(ghost)));
    r := pg_temp._add(r, 'evidence.assemble: a foreign and a nonexistent evidence item id give identical MR004 (nested ids tenant-checked)',
      e like 'MR004%' and e = e2 and (select denial_id from app.evidence_item where evidence_item_id = ev_t2) = d_t2);
    e := pg_temp._err(u_a, 'cmd_evidence_assemble', 'ev-new', jsonb_build_object('denial_id', d_new,
      'items', jsonb_build_array(jsonb_build_object('kind', 'other', 'title', 'x'))));
    e2 := pg_temp._err(u_a, 'cmd_evidence_assemble', 'ev-none', jsonb_build_object('denial_id', d_ev));
    r := pg_temp._add(r, 'evidence.assemble: denial without an evidence/appeal path is MR002; nothing to assemble is MR005',
      e like 'MR002%' and e2 like 'MR005%');

    -- ================================================================ records requests
    j := pg_temp._run(u_a, 'cmd_records_request_respond', 'rr-1', jsonb_build_object('records_request_id', rr1,
      'evidence_item_ids', jsonb_build_array(ev1, ev3), 'note', 'Notes and authorization attached'));
    r := pg_temp._add(r, 'records_request.respond: open -> responded by the caller; items linked; records deadline met',
      (select status = 'responded' and responded_at is not null and responded_by = u_a and response_note = 'Notes and authorization attached'
         from app.records_request where records_request_id = rr1)
      and (select count(*) = 2 from app.evidence_item where records_request_id = rr1 and evidence_item_id in (ev1, ev3))
      and (select met_at is not null from app.deadline where deadline_id = dl_ev)
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'records_request.responded' and aggregate_id = rr1));
    e := pg_temp._err(u_a, 'cmd_records_request_respond', 'rr-2', jsonb_build_object('records_request_id', rr1,
      'evidence_item_ids', jsonb_build_array(ev2)));
    r := pg_temp._add(r, 'responding again is MR001', e like 'MR001%');
    e := pg_temp._err(u_pb, 'cmd_records_request_decide', 'rd-x', jsonb_build_object('records_request_id', rr1, 'decision', 'accepted'));
    e2 := pg_temp._err(u_pb, 'cmd_records_request_decide', 'rd-gh', jsonb_build_object('records_request_id', ghost, 'decision', 'accepted'));
    r := pg_temp._add(r, 'payer B cannot decide payer A''s records request: MR004 identical to a nonexistent one', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_pa, 'cmd_records_request_decide', 'rd-0', jsonb_build_object('records_request_id', rr1, 'decision', 'rejected'));
    r := pg_temp._add(r, 'rejecting a records response without a reason is MR005', e like 'MR005%');
    j := pg_temp._run(u_pa, 'cmd_records_request_decide', 'rd-1', jsonb_build_object('records_request_id', rr1, 'decision', 'accepted',
      'reason', 'Complete'));
    r := pg_temp._add(r, 'records_request.decide: responded -> accepted by the payer user; event records_request.decided',
      (select status = 'accepted' and decided_by = u_pa and decided_at is not null and decision_reason = 'Complete'
         from app.records_request where records_request_id = rr1)
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'records_request.decided' and aggregate_id = rr1));
    e := pg_temp._err(u_pa, 'cmd_records_request_decide', 'rd-2', jsonb_build_object('records_request_id', rr1, 'decision', 'rejected', 'reason', 'x'));
    r := pg_temp._add(r, 'deciding again is MR001; the records_request state machine refuses accepted -> open',
      e like 'MR001%'
      and pg_temp._try(format($q$update app.records_request set status = 'open' where records_request_id = %L$q$, rr1)) = 'MR001');

    -- ================================================================ portals and permissions (loop over all commands)
    ok := true;
    foreach fn in array prov_cmds loop
      e := pg_temp._err(u_pa, fn, 'portal-' || fn, '{}'::jsonb);
      if not (e like 'MR003%' and e like '%wrong_portal%') then ok := false; raise notice 'payer -> % gave %', fn, e; end if;
    end loop;
    r := pg_temp._add(r, 'a payer user (holding every key) calling any provider command gets MR003 wrong_portal', ok);
    ok := true;
    foreach fn in array payer_cmds loop
      e := pg_temp._err(u_a, fn, 'portal-' || fn, '{}'::jsonb);
      if not (e like 'MR003%' and e like '%wrong_portal%') then ok := false; raise notice 'provider -> % gave %', fn, e; end if;
    end loop;
    r := pg_temp._add(r, 'a provider user calling any payer command gets MR003 wrong_portal', ok);
    ok := true;
    foreach fn in array prov_cmds loop
      e := pg_temp._err(u_np, fn, 'perm-' || fn, '{}'::jsonb);
      if not (e like 'MR003%' and e like '%permission_required%') then ok := false; raise notice 'noperm -> % gave %', fn, e; end if;
    end loop;
    r := pg_temp._add(r, 'a provider user without the permission gets MR003 permission_required for every provider command', ok);
    ok := true;
    foreach fn in array cmds loop
      if split_part(pg_temp._err(null, fn, 'nosess', '{}'::jsonb), ' ', 1) <> 'MR003' then ok := false; end if;
      if split_part(pg_temp._err(null, fn, 'anon', '{}'::jsonb, 'anon'), ' ', 1) <> '42501' then ok := false; end if;
    end loop;
    r := pg_temp._add(r, 'no session gets MR003 and the anon role gets 42501 for all 10 commands', ok);
    r := pg_temp._add(r, 'none of the portal / permission refusals wrote an idempotency row',
      not exists (select 1 from app.idempotency_key where key like 'portal-%' or key like 'perm-%' or key in ('nosess', 'anon')));

    -- ================================================================ tenant scope
    e := pg_temp._err(u_b2, 'cmd_appeal_file', 'sc-1', jsonb_build_object('appeal_id', ap_late));
    e2 := pg_temp._err(u_b2, 'cmd_appeal_file', 'sc-2', jsonb_build_object('appeal_id', ghost));
    r := pg_temp._add(r, 'tenant two filing tenant one''s appeal: MR004 identical to a nonexistent appeal', e like 'MR004%' and e = e2);
    e := pg_temp._err(u_a, 'cmd_appeal_file', 'sc-3', jsonb_build_object('appeal_id', ap_t2));
    e2 := pg_temp._err(u_a, 'cmd_appeal_request_approval', 'sc-4', jsonb_build_object('appeal_id', ap_t2));
    r := pg_temp._add(r, 'tenant one filing / requesting approval on tenant two''s appeal: MR004 with the not-found message',
      e like 'MR004%' and e2 like 'MR004%' and e = pg_temp._err(u_a, 'cmd_appeal_file', 'sc-5', jsonb_build_object('appeal_id', ghost)));
    r := pg_temp._add(r, 'tenant two saw nothing change',
      (select status from app.appeal where appeal_id = ap_t2) = 'approved'
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
      (select count(*) = 10 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'api' and p.proname = any (cmds) and p.prosecdef
          and p.proconfig @> array['search_path=""'] and p.prorettype = 'jsonb'::regtype
          and pg_get_function_identity_arguments(p.oid) = 'p_idem text, p_args jsonb'
          and has_function_privilege('authenticated', p.oid, 'execute')
          and not has_function_privilege('anon', p.oid, 'execute')
          and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)));
    r := pg_temp._add(r, 'payer commands name the payer portal; provider commands the provider portal',
      (select bool_and(pg_get_functiondef(format('api.%I(text,jsonb)', x)::regprocedure) like '%app.require_portal(''payer'')%') from unnest(payer_cmds) x)
      and (select bool_and(pg_get_functiondef(format('api.%I(text,jsonb)', x)::regprocedure) like '%app.require_portal(''provider'')%') from unnest(prov_cmds) x));

    -- ================================================================ handovers see the right subjects
    perform app.process_outbox();
    r := pg_temp._add(r, 'engine: H18 passed for the approved request and held (returned to author) for the rejected one',
      exists (select 1 from app.handover_event where handover_id = 'H18' and subject_id = ar2 and status = 'passed')
      and exists (select 1 from app.handover_event where handover_id = 'H18' and subject_id = ar1 and status = 'held')
      and exists (select 1 from app.handover_event where handover_id = 'H18' and subject_id = ar_b and status = 'passed')
      and not exists (select 1 from app.handover_event where tenant_id = t1 and detail = 'subject_tenant_mismatch'));
    r := pg_temp._add(r, 'audit chain of tenant one verifies after all commands', audit.verify_chain(t1));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id in (t1, t2))
    and not exists (select 1 from auth.users where id in (u_a, u_e, u_m, u_s, u_np, u_pa, u_pb, u_b2))
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\')
    and not exists (select 1 from app.appeal)
    and not exists (select 1 from app.ai_interaction)
    and not exists (select 1 from audit.outbox_event where tenant_id in (t1, t2))
    and not exists (select 1 from app.permission where description = 'Task 7 command'));

  perform tests.assert((x->>'p')::boolean, x->>'m') from jsonb_array_elements(r) x;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._run(uuid, text, text, jsonb, text);
drop function pg_temp._err(uuid, text, text, jsonb, text);
drop function pg_temp._st(uuid, integer);

select tests.report();
