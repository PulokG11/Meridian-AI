-- Task 7 review fix round 1 tests (migration 007b_cmd_appeals_fixes), driven through the real commands:
--  1. IV13: append-only app.appeal_contributor; the A creates / B rewrites / C re-sends unchanged and requests probe
--     now refuses B (and A, C); an uninvolved D approves; replay acts once
--  2. IV16: the recorder / drafter cannot review the AI output; filing needs an independent approval after any
--     rejection; the AI link is immutable; a null-subject, other-subject or wrong-task interaction cannot be linked
--  3. IV15: source_ref is '<type>:<uuid>' resolving to a row of the appeal's claim in the caller's tenant
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

-- one statement {text, source_ref}
create or replace function pg_temp._st(t text, ref text) returns jsonb
language sql as $$ select jsonb_strip_nulls(jsonb_build_object('text', t, 'source_ref', ref)) $$;

do $$
declare
  r jsonb := '[]'::jsonb;
  m text; e text; e2 text; e3 text; j jsonb; j2 jsonb; ok boolean; fn text; def text;
  perms text[] := array['evidence.assemble','appeal.draft','appeal.request_approval','approval.decide','appeal.file',
                        'records_request.respond','ai.review','ai.interaction_record','denial.confirm_path'];
  t1 uuid := app.uuid_v7(); t2 uuid := app.uuid_v7();
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid(); u_c uuid := gen_random_uuid();
  u_d uuid := gen_random_uuid(); u_s uuid := gen_random_uuid();
  pat uuid := app.uuid_v7(); pat2 uuid := app.uuid_v7(); pay_a uuid := app.uuid_v7(); pay_t2 uuid := app.uuid_v7();
  cov_a uuid := app.uuid_v7();
  c_a uuid := app.uuid_v7(); c_x uuid := app.uuid_v7(); c_o uuid := app.uuid_v7(); c_t2 uuid := app.uuid_v7();
  d_a uuid := app.uuid_v7(); d_x uuid := app.uuid_v7(); d_t2 uuid := app.uuid_v7();
  ev_o uuid := app.uuid_v7(); ev_t2 uuid := app.uuid_v7(); ai_t2 uuid := app.uuid_v7();
  ghost uuid := gen_random_uuid();
  ev_a uuid; ev_x uuid; ap_a uuid; ap_x uuid; ar1 uuid; ar_x uuid;
  ai_x uuid; ai_y uuid; ai_n uuid; ai_w uuid; ai_o uuid;
  stmts_b jsonb;
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values ('t_staff', 'Appeals staff', 'provider');
    insert into app.permission (permission_key, description) select p, 'Task 7b command' from unnest(perms) p
      on conflict (permission_key) do nothing;
    insert into app.role_permission (role_key, permission_key) select 't_staff', p from unnest(perms) p;
    insert into auth.users (id, aud, role, email) values
      (u_a, 'authenticated', 'authenticated', 'a7b@meridian.test'), (u_b, 'authenticated', 'authenticated', 'b7b@meridian.test'),
      (u_c, 'authenticated', 'authenticated', 'c7b@meridian.test'), (u_d, 'authenticated', 'authenticated', 'd7b@meridian.test'),
      (u_s, 'authenticated', 'authenticated', 's7b@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, display_name) values
      (u_a, t1, 'provider', 't_staff', 'A drafter'), (u_b, t1, 'provider', 't_staff', 'B editor'),
      (u_c, t1, 'provider', 't_staff', 'C editor'), (u_d, t1, 'provider', 't_staff', 'D uninvolved'),
      (u_s, t1, 'provider', 't_staff', 'S reviewer');
    -- everyone holds a high limit, so every refusal below is segregation of duties, not the limit
    insert into app.approval_limit (tenant_id, role_key, kind, max_amount) values (t1, 't_staff', 'appeal', 10000.00);
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values
      (pat, t1, 'MRN-7B', 'Ada', 'Alpha', date '1980-01-01'), (pat2, t2, 'MRN-7B2', 'Bea', 'Beta', date '1981-02-02');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values
      (pay_a, t1, 'Payer A', 'PA7B', 'commercial'), (pay_t2, t2, 'Payer T2', 'PT7B', 'commercial');
    insert into app.payer_config (tenant_id, payer_id, timely_filing_days, appeal_levels, records_request_days, effective_from) values
      (t1, pay_a, 90, 2, 30, date '2026-01-01');
    insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values
      (cov_a, t1, pat, pay_a, 'MEM-7B', date '2026-01-01', 'eligibility');
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, payer_id, coverage_id, status) values
      (c_a, t1, 'CL-7B-A', pat, pay_a, cov_a, 'accepted'), (c_x, t1, 'CL-7B-X', pat, pay_a, cov_a, 'accepted'),
      (c_o, t1, 'CL-7B-O', pat, pay_a, cov_a, 'accepted'), (c_t2, t2, 'CL-7B-T2', pat2, pay_t2, null, 'accepted');
    insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, denied_amount, received_at) values
      (d_a, t1, c_a, 'triaged', 'CO', '50', 300.00, now() - interval '5 days'),
      (d_x, t1, c_x, 'triaged', 'CO', '50', 200.00, now() - interval '5 days'),
      (d_t2, t2, c_t2, 'in_appeal', 'CO', '50', 100.00, now());
    insert into app.denial_triage (tenant_id, denial_id, recommended_path, confidence) values
      (t1, d_a, 'appeal', 0.900), (t1, d_x, 'appeal', 0.900);
    insert into app.evidence_item (evidence_item_id, tenant_id, claim_id, denial_id, kind, title) values
      (ev_o,  t1, c_o,  null, 'medical_record', 'Record of another claim'),
      (ev_t2, t2, c_t2, d_t2, 'medical_record', 'Tenant two record');
    insert into app.ai_interaction (ai_interaction_id, tenant_id, task, subject_type, subject_id, output) values
      (ai_t2, t2, 'appeal.draft', 'denial', d_t2, '{}'::jsonb);

    perform pg_temp._run(u_a, 'cmd_denial_confirm_path', 'cp-a', jsonb_build_object('denial_id', d_a, 'path', 'appeal'));
    perform pg_temp._run(u_a, 'cmd_denial_confirm_path', 'cp-x', jsonb_build_object('denial_id', d_x, 'path', 'appeal'));
    j := pg_temp._run(u_a, 'cmd_evidence_assemble', 'ev-a', jsonb_build_object('denial_id', d_a,
      'items', jsonb_build_array(jsonb_build_object('kind', 'authorization', 'title', 'Authorization AUTH-7B'))));
    ev_a := (j->'created_ids'->>0)::uuid;
    j := pg_temp._run(u_a, 'cmd_evidence_assemble', 'ev-x', jsonb_build_object('denial_id', d_x,
      'items', jsonb_build_array(jsonb_build_object('kind', 'medical_record', 'title', 'Office note X'))));
    ev_x := (j->'created_ids'->>0)::uuid;

    -- ================================================================ structure
    r := pg_temp._add(r, 'app.appeal_contributor: RLS with a SELECT policy, authenticated may read but not write, anon nothing',
      (select relrowsecurity from pg_class where oid = 'app.appeal_contributor'::regclass)
      and exists (select 1 from pg_policy where polrelid = 'app.appeal_contributor'::regclass and polcmd = 'r')
      and has_table_privilege('authenticated', 'app.appeal_contributor', 'select')
      and not has_table_privilege('authenticated', 'app.appeal_contributor', 'insert')
      and not has_table_privilege('authenticated', 'app.appeal_contributor', 'update')
      and not has_table_privilege('authenticated', 'app.appeal_contributor', 'delete')
      and not has_table_privilege('anon', 'app.appeal_contributor', 'select'));
    r := pg_temp._add(r, 'app.appeal_contributor has unique (appeal_id, user_id, role) and the role check',
      exists (select 1 from pg_constraint where conrelid = 'app.appeal_contributor'::regclass and contype = 'u'
                and conname = 'appeal_contributor_once')
      and exists (select 1 from pg_constraint where conrelid = 'app.appeal_contributor'::regclass and contype = 'c'
                    and pg_get_constraintdef(oid) like '%author%editor%requester%'));

    -- ================================================================ 3. IV15 typed source references
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 's-bad1', jsonb_build_object('denial_id', d_a,
      'statements', jsonb_build_array(pg_temp._st('Made up', 'made-up-ref'))));
    e2 := pg_temp._err(u_a, 'cmd_appeal_draft', 's-bad2', jsonb_build_object('denial_id', d_a,
      'statements', jsonb_build_array(pg_temp._st('Sourced', 'claim:' || c_a), pg_temp._st('Zzz', 'zzz'))));
    r := pg_temp._add(r, 'IV15: source_ref ''made-up-ref'' and ''zzz'' are refused MR005 IV15_source_unresolved naming the statement',
      e like 'MR005%' and e like '%IV15_source_unresolved%' and e like '%Statement 1%'
      and e2 like 'MR005%' and e2 like '%IV15_source_unresolved%' and e2 like '%Statement 2%'
      and not exists (select 1 from app.appeal where denial_id = d_a)
      and not exists (select 1 from app.idempotency_key where tenant_id = t1 and key in ('s-bad1', 's-bad2')));
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 's-t2', jsonb_build_object('denial_id', d_a,
      'statements', jsonb_build_array(pg_temp._st('Foreign', 'evidence_item:' || ev_t2))));
    e2 := pg_temp._err(u_a, 'cmd_appeal_draft', 's-oth', jsonb_build_object('denial_id', d_a,
      'statements', jsonb_build_array(pg_temp._st('Other claim', 'evidence_item:' || ev_o))));
    e3 := pg_temp._err(u_a, 'cmd_appeal_draft', 's-gh', jsonb_build_object('denial_id', d_a,
      'statements', jsonb_build_array(pg_temp._st('Missing', 'evidence_item:' || ghost))));
    r := pg_temp._add(r, 'IV15: another tenant''s, another claim''s and a nonexistent evidence item give identical MR005 refusals',
      e like 'MR005%' and e like '%IV15_source_unresolved%' and e = e2 and e = e3
      and not exists (select 1 from app.appeal where denial_id = d_a));
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 's-cl', jsonb_build_object('denial_id', d_a,
      'statements', jsonb_build_array(pg_temp._st('Wrong claim', 'claim:' || c_o))));
    e2 := pg_temp._err(u_a, 'cmd_appeal_draft', 's-ln', jsonb_build_object('denial_id', d_a,
      'statements', jsonb_build_array(pg_temp._st('No such line', 'claim_service_line:' || ghost))));
    r := pg_temp._add(r, 'IV15: a claim ref to another claim and a service line that does not exist are refused MR005',
      e like 'MR005%' and e like '%IV15_source_unresolved%' and e2 like 'MR005%' and e2 like '%IV15_source_unresolved%');

    j := pg_temp._run(u_a, 'cmd_appeal_draft', 'dr-a', jsonb_build_object('denial_id', d_a,
      'statements', jsonb_build_array(
        pg_temp._st('Authorization was on file.', 'EVIDENCE_ITEM:' || upper(ev_a::text)),
        pg_temp._st('The claim was billed as documented.', 'claim:' || c_a),
        pg_temp._st('The patient was eligible.', null))));
    ap_a := (j->>'appeal_id')::uuid;
    r := pg_temp._add(r, 'IV15: valid evidence_item and claim refs pass, are stored normalised and count as supported; a null ref is unsupported',
      ap_a is not null and (j->>'unsupported_count')::int = 1
      and (select source_ref = 'evidence_item:' || ev_a and not unsupported from app.appeal_statement where appeal_id = ap_a and seq = 1)
      and (select source_ref = 'claim:' || c_a and not unsupported from app.appeal_statement where appeal_id = ap_a and seq = 2)
      and (select source_ref is null and unsupported from app.appeal_statement where appeal_id = ap_a and seq = 3));
    e := pg_temp._err(u_a, 'cmd_appeal_request_approval', 'rq-a0', jsonb_build_object('appeal_id', ap_a));
    r := pg_temp._add(r, 'IV14: a statement with a null source_ref still blocks request_approval, naming statement 3',
      e like 'MR002%' and e like '%IV14_unsupported_statement%' and e like '%statement 3 %'
      and (select status from app.appeal where appeal_id = ap_a) = 'drafting');

    -- ================================================================ 1. IV13 contributors: the A / B / C probe
    stmts_b := jsonb_build_array(
      pg_temp._st('B: the authorization letter covers the visit.', 'evidence_item:' || ev_a),
      pg_temp._st('B: the claim matches the record.', 'claim:' || c_a),
      pg_temp._st('B: coverage was active on the date of service.', 'coverage:' || cov_a));
    perform pg_temp._run(u_b, 'cmd_appeal_draft', 'dr-b', jsonb_build_object('appeal_id', ap_a, 'statements', stmts_b));
    perform pg_temp._run(u_c, 'cmd_appeal_draft', 'dr-c', jsonb_build_object('appeal_id', ap_a, 'statements', stmts_b));
    j := pg_temp._run(u_c, 'cmd_appeal_request_approval', 'rq-c', jsonb_build_object('appeal_id', ap_a));
    ar1 := (j->>'approval_request_id')::uuid;
    r := pg_temp._add(r, 'probe setup: B rewrote every statement (coverage ref accepted), C re-sent B''s text unchanged and requested approval',
      (select count(*) = 3 and bool_and(text like 'B:%' and not unsupported) from app.appeal_statement where appeal_id = ap_a and removed_at is null)
      and (select status from app.appeal where appeal_id = ap_a) = 'pending_approval'
      and (select requester_id from app.approval_request where approval_request_id = ar1) = u_c
      and (select author_id from app.appeal where appeal_id = ap_a) = u_c);
    r := pg_temp._add(r, 'app.appeal_contributor recorded A author, B editor, C editor and requester',
      exists (select 1 from app.appeal_contributor where appeal_id = ap_a and user_id = u_a and role = 'author')
      and exists (select 1 from app.appeal_contributor where appeal_id = ap_a and user_id = u_b and role = 'editor')
      and exists (select 1 from app.appeal_contributor where appeal_id = ap_a and user_id = u_c and role = 'editor')
      and exists (select 1 from app.appeal_contributor where appeal_id = ap_a and user_id = u_c and role = 'requester')
      and not exists (select 1 from app.appeal_contributor where appeal_id = ap_a and user_id in (u_d, u_s))
      and (select array_agg(x order by x) from unnest(app.appeal_contributors(ap_a)) x)
          = (select array_agg(x order by x) from unnest(array[u_a, u_b, u_c]) x));
    e := pg_temp._err(u_b, 'cmd_approval_decide', 'ad-b', jsonb_build_object('approval_request_id', ar1, 'decision', 'approved'));
    r := pg_temp._add(r, 'the reviewer''s probe: B, who rewrote the content, can no longer approve it (MR003 IV13_self_approval)',
      e like 'MR003%' and e like '%IV13_self_approval%');
    e := pg_temp._err(u_a, 'cmd_approval_decide', 'ad-a', jsonb_build_object('approval_request_id', ar1, 'decision', 'approved'));
    e2 := pg_temp._err(u_c, 'cmd_approval_decide', 'ad-c', jsonb_build_object('approval_request_id', ar1, 'decision', 'approved'));
    r := pg_temp._add(r, 'the original author A and the last editor / requester C are refused too; nothing changed',
      e like 'MR003%' and e like '%IV13_self_approval%' and e2 like 'MR003%' and e2 like '%IV13_self_approval%'
      and (select status from app.approval_request where approval_request_id = ar1) = 'pending'
      and (select status from app.appeal where appeal_id = ap_a) = 'pending_approval'
      and not exists (select 1 from audit.outbox_event where tenant_id = t1 and type = 'approval.decided'));
    j := pg_temp._run(u_d, 'cmd_approval_decide', 'ad-d', jsonb_build_object('approval_request_id', ar1, 'decision', 'approved'));
    j2 := pg_temp._run(u_d, 'cmd_approval_decide', 'ad-d', jsonb_build_object('approval_request_id', ar1, 'decision', 'approved'));
    r := pg_temp._add(r, 'D, never involved, approves; the replay with the same key returns the same result and acts once',
      (select status = 'approved' and approver_id = u_d from app.approval_request where approval_request_id = ar1)
      and (select status = 'approved' and approver_id = u_d from app.appeal where appeal_id = ap_a)
      and j2 = j
      and (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'approval.decided' and aggregate_id = ar1));
    e3 := pg_temp._try('truncate app.appeal_contributor');   -- alone: a TRUNCATE next to a read of the table is 55006
    r := pg_temp._add(r, 'app.appeal_contributor is append-only (update, delete, truncate refused MR002)',
      pg_temp._try(format($q$update app.appeal_contributor set role = 'requester' where appeal_id = %L and user_id = %L$q$, ap_a, u_b)) = 'MR002'
      and pg_temp._try(format($q$delete from app.appeal_contributor where appeal_id = %L$q$, ap_a)) = 'MR002'
      and e3 = 'MR002'
      and exists (select 1 from app.appeal_contributor where appeal_id = ap_a and user_id = u_b));
    perform set_config('request.jwt.claims', json_build_object('sub', u_b, 'role', 'authenticated')::text, true);
    set local role authenticated;
    e := pg_temp._try(format($q$delete from app.appeal_contributor where appeal_id = %L and user_id = %L$q$, ap_a, u_b));
    e2 := pg_temp._try(format($q$insert into app.appeal_contributor (tenant_id, appeal_id, user_id, role) values (%L, %L, %L, 'editor')$q$, t1, ap_a, u_s));
    reset role;
    r := pg_temp._add(r, 'a client cannot erase or add contributor rows (42501)', e = '42501' and e2 = '42501');

    -- ================================================================ 2. IV16 link checks
    ai_x := (pg_temp._run(u_a, 'cmd_ai_interaction_record', 'ai-x', jsonb_build_object('task', 'appeal.draft', 'subject_type', 'denial',
      'subject_id', d_x, 'model_version', 'appeal-draft-sim-0.1', 'output', '{"draft":"x"}'::jsonb))->>'ai_interaction_id')::uuid;
    ai_y := (pg_temp._run(u_a, 'cmd_ai_interaction_record', 'ai-y', jsonb_build_object('task', 'appeal.draft', 'subject_type', 'denial',
      'subject_id', d_x, 'model_version', 'appeal-draft-sim-0.1', 'output', '{"draft":"y"}'::jsonb))->>'ai_interaction_id')::uuid;
    ai_n := (pg_temp._run(u_a, 'cmd_ai_interaction_record', 'ai-n', jsonb_build_object('task', 'appeal.draft',
      'model_version', 'appeal-draft-sim-0.1', 'output', '{"draft":"n"}'::jsonb))->>'ai_interaction_id')::uuid;
    ai_w := (pg_temp._run(u_a, 'cmd_ai_interaction_record', 'ai-w', jsonb_build_object('task', 'denial.triage', 'subject_type', 'denial',
      'subject_id', d_x, 'model_version', 'triage-sim-0.3', 'output', '{"path":"appeal"}'::jsonb))->>'ai_interaction_id')::uuid;
    ai_o := (pg_temp._run(u_a, 'cmd_ai_interaction_record', 'ai-o', jsonb_build_object('task', 'appeal.draft', 'subject_type', 'denial',
      'subject_id', d_a, 'model_version', 'appeal-draft-sim-0.1', 'output', '{"draft":"o"}'::jsonb))->>'ai_interaction_id')::uuid;
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 'lk-n', jsonb_build_object('denial_id', d_x, 'ai_interaction_id', ai_n,
      'statements', jsonb_build_array(pg_temp._st('X', 'evidence_item:' || ev_x))));
    e2 := pg_temp._err(u_a, 'cmd_appeal_draft', 'lk-o', jsonb_build_object('denial_id', d_x, 'ai_interaction_id', ai_o,
      'statements', jsonb_build_array(pg_temp._st('X', 'evidence_item:' || ev_x))));
    e3 := pg_temp._err(u_a, 'cmd_appeal_draft', 'lk-w', jsonb_build_object('denial_id', d_x, 'ai_interaction_id', ai_w,
      'statements', jsonb_build_array(pg_temp._st('X', 'evidence_item:' || ev_x))));
    r := pg_temp._add(r, 'IV16: an interaction with no subject or another denial''s subject (MR005 subject mismatch), or a non-draft task (MR005 wrong task), cannot be linked',
      e like 'MR005%' and e like '%ai_interaction_subject_mismatch%'
      and e2 like 'MR005%' and e2 like '%ai_interaction_subject_mismatch%'
      and e3 like 'MR005%' and e3 like '%ai_interaction_wrong_task%'
      and not exists (select 1 from app.appeal where denial_id = d_x));
    j := pg_temp._run(u_a, 'cmd_appeal_draft', 'dr-x', jsonb_build_object('denial_id', d_x, 'ai_interaction_id', ai_x,
      'statements', jsonb_build_array(pg_temp._st('Office note supports the visit.', 'evidence_item:' || ev_x))));
    ap_x := (j->>'appeal_id')::uuid;
    e := pg_temp._err(u_a, 'cmd_appeal_draft', 'dr-x-swap', jsonb_build_object('appeal_id', ap_x, 'ai_interaction_id', ai_y,
      'statements', jsonb_build_array(pg_temp._st('Office note supports the visit.', 'evidence_item:' || ev_x))));
    r := pg_temp._add(r, 'IV16: swapping the AI link on amend is refused MR002 IV16_ai_link_immutable; the link stays',
      e like 'MR002%' and e like '%IV16_ai_link_immutable%'
      and (select ai_interaction_id from app.appeal where appeal_id = ap_x) = ai_x);
    j := pg_temp._run(u_a, 'cmd_appeal_draft', 'dr-x-same', jsonb_build_object('appeal_id', ap_x, 'ai_interaction_id', ai_x,
      'statements', jsonb_build_array(pg_temp._st('Office note supports the visit.', 'evidence_item:' || ev_x))));
    r := pg_temp._add(r, 'IV16: re-sending the same AI link on amend is accepted',
      j->>'mode' = 'amended' and j->>'ai_interaction_id' = ai_x::text);
    r := pg_temp._add(r, 'IV16 backstop: the table refuses changing or clearing a set AI link (MR002)',
      pg_temp._try(format('update app.appeal set ai_interaction_id = %L where appeal_id = %L', ai_y, ap_x)) = 'MR002'
      and pg_temp._try(format('update app.appeal set ai_interaction_id = null where appeal_id = %L', ap_x)) = 'MR002');

    -- ================================================================ 2. IV16 reviewer independence and the filing gate
    j := pg_temp._run(u_a, 'cmd_appeal_request_approval', 'rq-x', jsonb_build_object('appeal_id', ap_x));
    ar_x := (j->>'approval_request_id')::uuid;
    perform pg_temp._run(u_d, 'cmd_approval_decide', 'ad-x', jsonb_build_object('approval_request_id', ar_x, 'decision', 'approved'));
    perform pg_temp._run(u_s, 'cmd_ai_review', 'rv-s1', jsonb_build_object('ai_interaction_id', ai_x, 'decision', 'rejected',
      'reason', 'The draft overstates the note'));
    e := pg_temp._err(u_a, 'cmd_ai_review', 'rv-a', jsonb_build_object('ai_interaction_id', ai_x, 'decision', 'approved',
      'reason', 'Looks fine to me'));
    r := pg_temp._add(r, 'the reviewer''s probe: A (recorder and drafter) approving the AI output after S rejected it is refused MR003 IV16_reviewer_not_independent',
      e like 'MR003%' and e like '%IV16_reviewer_not_independent%'
      and not exists (select 1 from app.ai_review where ai_interaction_id = ai_x and reviewer_id = u_a)
      and (select status from app.ai_interaction where ai_interaction_id = ai_x) = 'rejected');
    e := pg_temp._err(u_a, 'cmd_appeal_file', 'fl-x0', jsonb_build_object('appeal_id', ap_x));
    r := pg_temp._add(r, 'filing stays blocked after the rejection (MR002 IV16_ai_review_required)',
      e like 'MR002%' and e like '%IV16_ai_review_required%' and (select status from app.appeal where appeal_id = ap_x) = 'approved');
    -- a review row written around the command (stands in for any bypass): latest = approved, but by the drafter
    insert into app.ai_review (tenant_id, ai_interaction_id, reviewer_id, decision, reason, reviewed_at)
    values (t1, ai_x, u_a, 'approved', 'self-approval', clock_timestamp());
    e := pg_temp._err(u_a, 'cmd_appeal_file', 'fl-x1', jsonb_build_object('appeal_id', ap_x));
    r := pg_temp._add(r, 'even when the latest review is an approval, filing needs an independent approval after the rejection (MR002)',
      e like 'MR002%' and e like '%IV16_ai_review_required%');
    e := pg_temp._err(u_s, 'cmd_ai_review', 'rv-t2', jsonb_build_object('ai_interaction_id', ai_t2, 'decision', 'approved', 'reason', 'x'));
    e2 := pg_temp._err(u_s, 'cmd_ai_review', 'rv-gh', jsonb_build_object('ai_interaction_id', ghost, 'decision', 'approved', 'reason', 'x'));
    r := pg_temp._add(r, 'reviewing another tenant''s interaction is still MR004, identical to a nonexistent one', e like 'MR004%' and e = e2);
    perform pg_temp._run(u_s, 'cmd_ai_review', 'rv-s2', jsonb_build_object('ai_interaction_id', ai_x, 'decision', 'approved',
      'reason', 'Corrected draft checked against the note'));
    j := pg_temp._run(u_a, 'cmd_appeal_file', 'fl-x', jsonb_build_object('appeal_id', ap_x));
    r := pg_temp._add(r, 'an independent approval after the rejection lets the appeal file',
      j->>'status' = 'filed' and (select status from app.appeal where appeal_id = ap_x) = 'filed');

    -- ================================================================ definitions
    ok := true;
    foreach fn in array array['cmd_appeal_draft', 'cmd_appeal_file', 'cmd_ai_review'] loop
      def := pg_get_functiondef(format('api.%I(text,jsonb)', fn)::regprocedure);
      if not (position('app.ctx()' in def) > 0
              and position('app.ctx()' in def) < position('app.require_portal(' in def)
              and position('app.require_portal(' in def) < position('app.authorize(' in def)
              and position('app.authorize(' in def) < position('app.begin_cmd(' in def)
              and position('app.begin_cmd(' in def) < position('app.finish_cmd(' in def)) then
        ok := false;
      end if;
    end loop;
    r := pg_temp._add(r, 'the replaced commands keep ctx < require_portal < authorize < begin_cmd < finish_cmd', ok);
    r := pg_temp._add(r, 'the replaced commands stay definer, search_path '''', authenticated-only, no PUBLIC entry',
      (select count(*) = 3 from pg_proc p
        where p.oid in ('api.cmd_appeal_draft(text,jsonb)'::regprocedure, 'api.cmd_appeal_file(text,jsonb)'::regprocedure,
                        'api.cmd_ai_review(text,jsonb)'::regprocedure)
          and p.prosecdef and p.proconfig @> array['search_path=""']
          and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
          and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)));
    r := pg_temp._add(r, 'the new helpers are not executable by client roles',
      not has_function_privilege('authenticated', 'app.source_ref_resolves(text,app.appeal)', 'execute')
      and not has_function_privilege('authenticated', 'app.appeal_contributors(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'app.appeal_contributor_author()', 'execute')
      and not has_function_privilege('authenticated', 'app.appeal_ai_link_guard()', 'execute'));
    r := pg_temp._add(r, 'audit chain of tenant one verifies', audit.verify_chain(t1));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id in (t1, t2))
    and not exists (select 1 from auth.users where id in (u_a, u_b, u_c, u_d, u_s))
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\')
    and not exists (select 1 from app.appeal_contributor)
    and not exists (select 1 from app.appeal)
    and not exists (select 1 from app.permission where description = 'Task 7b command'));

  perform tests.assert((x->>'p')::boolean, x->>'m') from jsonb_array_elements(r) x;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._run(uuid, text, text, jsonb);
drop function pg_temp._err(uuid, text, text, jsonb);
drop function pg_temp._st(text, text);

select tests.report();
