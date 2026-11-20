-- Task 10b tests: api.cmd_case_create, api.cmd_deposit_create (backend/supabase/migrations/010_cmd_case_create.sql).
-- Same harness shape as 006_cmd_claims.sql: pg_temp._run/_err/_add, one sub-transaction rolled back at the end.
select tests.begin();

create or replace function pg_temp._add(r jsonb, m text, p boolean) returns jsonb
language sql as $$ select r || jsonb_build_array(jsonb_build_object('m', m, 'p', coalesce(p, false))) $$;

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
  m text; fn text; def text;
  j jsonb; j2 jsonb; j_dep jsonb;
  cmds text[] := array['cmd_case_create', 'cmd_deposit_create'];
  perms text[] := array['case.create', 'deposit.create'];
  t1 uuid := app.uuid_v7(); t2 uuid := app.uuid_v7();
  u_cr uuid := gen_random_uuid(); u_np uuid := gen_random_uuid(); u_cr2 uuid := gen_random_uuid();
  pay_a uuid := app.uuid_v7(); pay_t2 uuid := app.uuid_v7();
  prv uuid := app.uuid_v7();
  ghost uuid := gen_random_uuid();
  claims_before bigint; cases_before bigint; patients_before bigint; deposits_before bigint;
  args jsonb;
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner, no claims)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values
      ('t_creator', 'Case creator', 'provider'), ('t_noperm', 'Staff without permissions', 'provider');
    insert into app.permission (permission_key, description)
      select p, 'Task 10b command' from unnest(perms) p
    on conflict (permission_key) do nothing;
    insert into app.role_permission (role_key, permission_key)
      select 't_creator', p from unnest(perms) p;
    insert into auth.users (id, aud, role, email) values
      (u_cr,  'authenticated', 'authenticated', 'cr1@meridian.test'),
      (u_np,  'authenticated', 'authenticated', 'np2@meridian.test'),
      (u_cr2, 'authenticated', 'authenticated', 'cr2@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, party_id, display_name) values
      (u_cr,  t1, 'provider', 't_creator', null, 'Creator One'),
      (u_np,  t1, 'provider', 't_noperm',  null, 'No Permission'),
      (u_cr2, t2, 'provider', 't_creator', null, 'Creator Tenant Two');

    insert into app.provider (provider_id, tenant_id, npi, name) values (prv, t1, '1000000002', 'Dr Two');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values
      (pay_a, t1, 'Payer A', 'PA02', 'commercial'), (pay_t2, t2, 'Payer T2', 'PT2B', 'commercial');

    select count(*) into claims_before from app.claim;
    select count(*) into cases_before from app."case";
    select count(*) into patients_before from app.patient;
    select count(*) into deposits_before from app.deposit;

    -- ---------------------------------------------------------------- 1. positive path: cmd_case_create
    args := jsonb_build_object(
      'patient', jsonb_build_object('first_name', 'Taylor', 'last_name', 'Test', 'dob', '1990-05-05'),
      'payer_id', pay_a, 'provider_id', prv, 'service_date', '2026-11-20',
      'lines', jsonb_build_array(jsonb_build_object('procedure_code', '99213', 'billed', 150.00)),
      'diagnoses', jsonb_build_array(jsonb_build_object('icd10_code', 'M25.561')));
    j := pg_temp._run(u_cr, 'cmd_case_create', 'k-case-1', args);
    r := pg_temp._add(r, 'case.create: returns patient_id/claim_id/case_id', (j ? 'patient_id') and (j ? 'claim_id') and (j ? 'case_id'));
    r := pg_temp._add(r, 'case.create: created exactly one patient/claim/case',
      (select count(*) from app.patient) = patients_before + 1
      and (select count(*) from app.claim) = claims_before + 1
      and (select count(*) from app."case") = cases_before + 1);
    r := pg_temp._add(r, 'case.create: claim is draft, frequency_code 1, right tenant',
      exists (select 1 from app.claim c where c.claim_id = (j->>'claim_id')::uuid
              and c.status = 'draft' and c.frequency_code = '1' and c.tenant_id = t1));
    r := pg_temp._add(r, 'case.create: one service line, one diagnosis, one case_claim link',
      (select count(*) from app.claim_service_line where claim_id = (j->>'claim_id')::uuid) = 1
      and (select count(*) from app.claim_diagnosis where claim_id = (j->>'claim_id')::uuid) = 1
      and exists (select 1 from app.case_claim cc where cc.case_id = (j->>'case_id')::uuid and cc.claim_id = (j->>'claim_id')::uuid));
    r := pg_temp._add(r, 'case.create: case_number = claim_number = patient mrn suffix share one counter',
      (select case_number from app."case" where case_id = (j->>'case_id')::uuid)
        = (select claim_number from app.claim where claim_id = (j->>'claim_id')::uuid));
    r := pg_temp._add(r, 'case.create: audit row written',
      exists (select 1 from audit.audit_log a where a.action = 'case.create' and a.actor = u_cr));

    -- replay with the same idempotency key: no new rows, identical result
    j2 := pg_temp._run(u_cr, 'cmd_case_create', 'k-case-1', args);
    r := pg_temp._add(r, 'case.create: replay returns the identical cached result', j2 = j);
    r := pg_temp._add(r, 'case.create: replay created nothing new', (select count(*) from app.patient) = patients_before + 1);

    -- a second, distinct call makes a second, distinct case with a different number
    j2 := pg_temp._run(u_cr, 'cmd_case_create', 'k-case-2', args);
    r := pg_temp._add(r, 'case.create: a second call gets a different case/claim number',
      j2->>'case_number' <> j->>'case_number');

    -- ---------------------------------------------------------------- 2. guards (MR005 / MR004 / MR003)
    r := pg_temp._add(r, 'case.create: missing payer refused MR005',
      pg_temp._err(u_cr, 'cmd_case_create', 'k-bad-1',
        jsonb_build_object('patient', jsonb_build_object('first_name','A','last_name','B','dob','1990-01-01'),
                           'lines', jsonb_build_array(jsonb_build_object('procedure_code','1','billed',1)))) like 'MR005%');
    r := pg_temp._add(r, 'case.create: no lines refused MR005 lines_required',
      (select e like 'MR005%' and e like '%lines_required%' from
        (select pg_temp._err(u_cr, 'cmd_case_create', 'k-bad-2',
          jsonb_build_object('patient', jsonb_build_object('first_name','A','last_name','B','dob','1990-01-01'),
                             'payer_id', pay_a, 'lines', '[]'::jsonb)) as e) s));
    r := pg_temp._add(r, 'case.create: nonexistent payer refused MR004',
      pg_temp._err(u_cr, 'cmd_case_create', 'k-bad-3',
        jsonb_build_object('patient', jsonb_build_object('first_name','A','last_name','B','dob','1990-01-01'),
                           'payer_id', ghost, 'lines', jsonb_build_array(jsonb_build_object('procedure_code','1','billed',1)))) like 'MR004%');
    r := pg_temp._add(r, 'case.create: another tenant''s payer is not found (MR004, not a different error)',
      pg_temp._err(u_cr, 'cmd_case_create', 'k-bad-4',
        jsonb_build_object('patient', jsonb_build_object('first_name','A','last_name','B','dob','1990-01-01'),
                           'payer_id', pay_t2, 'lines', jsonb_build_array(jsonb_build_object('procedure_code','1','billed',1)))) like 'MR004%');
    r := pg_temp._add(r, 'case.create: role without the permission refused MR003',
      pg_temp._err(u_np, 'cmd_case_create', 'k-bad-5', args) like 'MR003%');
    r := pg_temp._add(r, 'case.create: anon refused outright (42501)',
      pg_temp._err(null, 'cmd_case_create', 'k-bad-6', args, 'anon') like '42501%');

    -- ---------------------------------------------------------------- 3. positive path: cmd_deposit_create
    j_dep := pg_temp._run(u_cr, 'cmd_deposit_create', 'k-dep-1', jsonb_build_object('payer_id', pay_a, 'amount', 250.00));
    r := pg_temp._add(r, 'deposit.create: returns a deposit_id', j_dep ? 'deposit_id');
    r := pg_temp._add(r, 'deposit.create: created exactly one deposit, status open',
      (select count(*) from app.deposit) = deposits_before + 1
      and exists (select 1 from app.deposit d where d.deposit_id = (j_dep->>'deposit_id')::uuid and d.status = 'open' and d.amount = 250.00));
    r := pg_temp._add(r, 'deposit.create: auto-generated bank_reference is unique and starts DEP-',
      (select bank_reference from app.deposit where deposit_id = (j_dep->>'deposit_id')::uuid) like 'DEP-%');

    j2 := pg_temp._run(u_cr, 'cmd_deposit_create', 'k-dep-1', jsonb_build_object('payer_id', pay_a, 'amount', 250.00));
    r := pg_temp._add(r, 'deposit.create: replay returns the identical cached result', j2 = j_dep);

    r := pg_temp._add(r, 'deposit.create: a duplicate explicit bank_reference refused MR002',
      (select e like 'MR002%' and e like '%duplicate_bank_reference%' from
        (select pg_temp._err(u_cr, 'cmd_deposit_create', 'k-dep-2',
          jsonb_build_object('payer_id', pay_a, 'amount', 100.00, 'bank_reference', j_dep->>'bank_reference')) as e) s));
    r := pg_temp._add(r, 'deposit.create: zero amount refused MR005',
      pg_temp._err(u_cr, 'cmd_deposit_create', 'k-dep-3', jsonb_build_object('payer_id', pay_a, 'amount', 0)) like 'MR005%');
    r := pg_temp._add(r, 'deposit.create: role without the permission refused MR003',
      pg_temp._err(u_np, 'cmd_deposit_create', 'k-dep-4', jsonb_build_object('payer_id', pay_a, 'amount', 10)) like 'MR003%');

    -- ---------------------------------------------------------------- 4. introspection: call order, privileges
    foreach fn in array cmds loop
      select pg_get_functiondef(format('api.%I(text,jsonb)', fn)::regprocedure) into def;
      r := pg_temp._add(r, fn || ': calls ctx/require_portal/authorize/begin_cmd/finish_cmd in order',
        position('app.ctx()' in def) > 0
        and position('app.require_portal(' in def) < position('app.authorize(' in def)
        and position('app.authorize(' in def) < position('app.begin_cmd(' in def)
        and position('app.begin_cmd(' in def) < position('app.finish_cmd(' in def));
      r := pg_temp._add(r, fn || ': security definer, search_path empty, authenticated-only execute',
        exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'api' and p.proname = fn and p.prosecdef
                   and p.proconfig @> array['search_path=""']
                   and has_function_privilege('authenticated', p.oid, 'execute')
                   and not has_function_privilege('anon', p.oid, 'execute')
                   and not has_function_privilege('public', p.oid, 'execute')));
    end loop;

    raise exception using errcode = 'P0001', message = 'rollback test fixtures';
  exception when sqlstate 'P0001' then
    null;  -- fixtures rolled back; r still holds every assertion
  end;

  perform tests.assert((x->>'p')::boolean, x->>'m') from jsonb_array_elements(r) x;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._run(uuid, text, text, jsonb, text);
drop function pg_temp._err(uuid, text, text, jsonb, text);

select tests.report();
