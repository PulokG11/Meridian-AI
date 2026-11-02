-- Task 3 tests: parties, payers, coverage, clearinghouse tables and party-scoped RLS (app.in_scope).
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
  t1 uuid := app.uuid_v7(); t2 uuid := app.uuid_v7();
  u_prov1 uuid := gen_random_uuid(); u_prov2 uuid := gen_random_uuid();
  u_payer uuid := gen_random_uuid(); u_pat uuid := gen_random_uuid();
  u_prox uuid := gen_random_uuid(); u_clr uuid := gen_random_uuid();
  pay_a uuid := app.uuid_v7(); pay_b uuid := app.uuid_v7(); pay_c uuid := app.uuid_v7();
  pat_a uuid := app.uuid_v7(); pat_p uuid := app.uuid_v7(); pat_d uuid := app.uuid_v7(); pat_x uuid := app.uuid_v7();
  ch_a uuid := app.uuid_v7(); ch_b uuid := app.uuid_v7(); ch_c uuid := app.uuid_v7();
  cov_a uuid := app.uuid_v7(); cov_p uuid := app.uuid_v7(); cov_d uuid := app.uuid_v7(); cov_x uuid := app.uuid_v7();
  req_a uuid := app.uuid_v7(); req_b uuid := app.uuid_v7();
  pa_id uuid := app.uuid_v7();
  tbl text;
  n bigint;
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner, no claims)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values
      ('t_prov', 'Provider', 'provider'), ('t_payer', 'Payer', 'payer'),
      ('t_pat', 'Patient', 'patient'), ('t_clr', 'Clearinghouse', 'clearinghouse');
    insert into auth.users (id, aud, role, email) values
      (u_prov1, 'authenticated', 'authenticated', 'p1@meridian.test'),
      (u_prov2, 'authenticated', 'authenticated', 'p2@meridian.test'),
      (u_payer, 'authenticated', 'authenticated', 'py@meridian.test'),
      (u_pat,   'authenticated', 'authenticated', 'pt@meridian.test'),
      (u_prox,  'authenticated', 'authenticated', 'px@meridian.test'),
      (u_clr,   'authenticated', 'authenticated', 'ch@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, party_id, display_name) values
      (u_prov1, t1, 'provider',      't_prov',  null,  'Prov One'),
      (u_prov2, t2, 'provider',      't_prov',  null,  'Prov Two'),
      (u_payer, t1, 'payer',         't_payer', pay_a, 'Payer A user'),
      (u_pat,   t1, 'patient',       't_pat',   pat_a, 'Patient A user'),
      (u_prox,  t1, 'patient',       't_pat',   pat_p, 'Proxy user'),
      (u_clr,   t1, 'clearinghouse', 't_clr',   ch_a,  'Clearinghouse A user');

    insert into app.provider (provider_id, tenant_id, npi, name, specialty) values
      (app.uuid_v7(), t1, '1000000001', 'Dr One', 'cardiology'),
      (app.uuid_v7(), t2, '1000000002', 'Dr Two', 'oncology');
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values
      (pat_a, t1, 'MRN-A', 'Ada',  'Alpha', date '1980-01-01'),
      (pat_p, t1, 'MRN-P', 'Pia',  'Proxy', date '1975-05-05'),
      (pat_d, t1, 'MRN-D', 'Dan',  'Proxy', date '2012-09-09'),
      (pat_x, t2, 'MRN-X', 'Xena', 'Other', date '1990-03-03');
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values
      (pay_a, t1, 'Payer A', 'PA01', 'commercial'),
      (pay_b, t1, 'Payer B', 'PB01', 'medicare'),
      (pay_c, t2, 'Payer C', 'PC01', 'commercial');
    insert into app.payer_plan (payer_plan_id, tenant_id, payer_id, plan_name, plan_type) values
      (app.uuid_v7(), t1, pay_a, 'A Gold', 'ppo'),
      (app.uuid_v7(), t1, pay_b, 'B Std',  'hmo'),
      (app.uuid_v7(), t2, pay_c, 'C Std',  'ppo');
    insert into app.payer_config (payer_config_id, tenant_id, payer_id, timely_filing_days, appeal_levels, records_request_days) values
      (app.uuid_v7(), t1, pay_a, 90, 2, 30),
      (app.uuid_v7(), t1, pay_b, 365, 3, 45),
      (app.uuid_v7(), t2, pay_c, 120, 2, 30);
    insert into app.clearinghouse (clearinghouse_id, tenant_id, name, clearinghouse_code) values
      (ch_a, t1, 'CH A', 'CHA'), (ch_b, t1, 'CH B', 'CHB'), (ch_c, t2, 'CH C', 'CHC');
    insert into app.clearinghouse_connection (clearinghouse_connection_id, tenant_id, clearinghouse_id, payer_id, protocol, endpoint_label) values
      (app.uuid_v7(), t1, ch_a, pay_a, 'x12', 'sandbox-a'),
      (app.uuid_v7(), t1, ch_b, pay_b, 'api', 'sandbox-b'),
      (app.uuid_v7(), t2, ch_c, pay_c, 'x12', 'sandbox-c');
    insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, effective_to, source, verified_at) values
      (cov_a, t1, pat_a, pay_a, 'MEM-A', date '2026-01-01', null,              'eligibility', now()),
      (cov_p, t1, pat_p, pay_b, 'MEM-P', date '2026-01-01', date '2026-12-31', 'manual',      null),
      (cov_d, t1, pat_d, pay_a, 'MEM-D', date '2026-01-01', null,              'import',      null),
      (cov_x, t2, pat_x, pay_c, 'MEM-X', date '2026-01-01', null,              'manual',      null);
    insert into app.eligibility_request (eligibility_request_id, tenant_id, patient_id, coverage_id, payer_id, clearinghouse_id, service_date) values
      (req_a, t1, pat_a, cov_a, pay_a, ch_a, date '2026-11-01'),
      (req_b, t1, pat_p, cov_p, pay_b, ch_b, date '2026-11-01');
    insert into app.eligibility_response (eligibility_response_id, tenant_id, eligibility_request_id, coverage_status, copay_amount, deductible_amount) values
      (app.uuid_v7(), t1, req_a, 'active', 25.00, 500.00),
      (app.uuid_v7(), t1, req_b, 'active', 40.00, 1000.00);
    insert into app.patient_relationship (patient_relationship_id, tenant_id, patient_id, related_patient_id, relationship_type) values
      (app.uuid_v7(), t1, pat_d, pat_p, 'guardian');
    insert into app.proxy_access (proxy_access_id, tenant_id, patient_id, proxy_patient_id, scope, active, effective_from) values
      (pa_id, t1, pat_d, pat_p, 'full', true, current_date - 30);

    -- ---------------------------------------------------------------- data rules (as owner)
    r := pg_temp._add(r, 'coverage refuses effective_to before effective_from',
      pg_temp._try(format($q$insert into app.coverage (tenant_id, patient_id, payer_id, member_id, effective_from, effective_to, source)
        values (%L, %L, %L, 'M', date '2026-06-01', date '2026-05-01', 'manual')$q$, t1, pat_a, pay_a)) = '23514');
    r := pg_temp._add(r, 'coverage refuses an unknown source',
      pg_temp._try(format($q$insert into app.coverage (tenant_id, patient_id, payer_id, member_id, effective_from, source)
        values (%L, %L, %L, 'M', date '2026-06-01', 'guess')$q$, t1, pat_a, pay_a)) = '23514');
    r := pg_temp._add(r, 'payer_config refuses non-positive timely filing days',
      pg_temp._try(format($q$insert into app.payer_config (tenant_id, payer_id, timely_filing_days, appeal_levels, records_request_days)
        values (%L, %L, 0, 2, 30)$q$, t1, pay_b)) = '23514');
    r := pg_temp._add(r, 'proxy_access refuses a patient being their own proxy',
      pg_temp._try(format($q$insert into app.proxy_access (tenant_id, patient_id, proxy_patient_id, scope, effective_from)
        values (%L, %L, %L, 'full', current_date)$q$, t1, pat_a, pat_a)) = '23514');
    r := pg_temp._add(r, 'touch trigger stamped audit columns',
      (select created_at is not null and updated_at is not null from app.payer where payer_id = pay_a));
    r := pg_temp._add(r, 'coverage references real patient and payer (FK)',
      pg_temp._try(format($q$insert into app.coverage (tenant_id, patient_id, payer_id, member_id, effective_from, source)
        values (%L, %L, %L, 'M', date '2026-06-01', 'manual')$q$, t1, gen_random_uuid(), pay_a)) = '23503');

    -- ---------------------------------------------------------------- provider: own tenant only
    perform pg_temp._claims(u_prov1);
    set local role authenticated;
    r := pg_temp._add(r, 'provider sees own tenant payers', pg_temp._n('select count(*) from app.payer') = 2);
    r := pg_temp._add(r, 'provider sees own tenant patients', pg_temp._n('select count(*) from app.patient') = 3);
    r := pg_temp._add(r, 'provider sees own tenant coverage', pg_temp._n('select count(*) from app.coverage') = 3);
    r := pg_temp._add(r, 'provider sees own tenant clearinghouses and connections',
      pg_temp._n('select count(*) from app.clearinghouse') = 2 and pg_temp._n('select count(*) from app.clearinghouse_connection') = 2);
    r := pg_temp._add(r, 'provider sees own tenant providers, plans, configs',
      pg_temp._n('select count(*) from app.provider') = 1 and pg_temp._n('select count(*) from app.payer_plan') = 2
      and pg_temp._n('select count(*) from app.payer_config') = 2);
    r := pg_temp._add(r, 'provider sees own tenant eligibility, relationships, proxy rows',
      pg_temp._n('select count(*) from app.eligibility_request') = 2 and pg_temp._n('select count(*) from app.eligibility_response') = 2
      and pg_temp._n('select count(*) from app.patient_relationship') = 1 and pg_temp._n('select count(*) from app.proxy_access') = 1);
    n := 0;
    foreach tbl in array array['patient','patient_relationship','proxy_access','provider','payer','payer_plan','payer_config',
                               'coverage','eligibility_request','eligibility_response','clearinghouse','clearinghouse_connection']
    loop
      n := n + pg_temp._n(format('select count(*) from app.%I where tenant_id = %L', tbl, t2));
    end loop;
    r := pg_temp._add(r, 'provider sees zero rows of the other tenant (all 12 tables)', n = 0);
    r := pg_temp._add(r, 'provider cannot read another tenant payer by id',
      pg_temp._n(format('select count(*) from app.payer where payer_id = %L', pay_c)) = 0);
    r := pg_temp._add(r, 'in_scope true for own tenant, false for another tenant (provider)',
      app.in_scope(t1) and not app.in_scope(t2) and not app.in_scope(t2, pay_c));
    r := pg_temp._add(r, 'authenticated cannot insert into payer (42501)',
      pg_temp._try(format($q$insert into app.payer (tenant_id, name, payer_code, payer_type) values (%L, 'x', 'X', 'commercial')$q$, t1)) = '42501');
    r := pg_temp._add(r, 'authenticated cannot update coverage (42501)',
      pg_temp._try(format($q$update app.coverage set member_id = 'hack' where tenant_id = %L$q$, t1)) = '42501');
    r := pg_temp._add(r, 'authenticated cannot delete patient (42501)',
      pg_temp._try(format($q$delete from app.patient where tenant_id = %L$q$, t1)) = '42501');
    reset role;

    perform pg_temp._claims(u_prov2);
    set local role authenticated;
    r := pg_temp._add(r, 'second tenant provider sees exactly its own payer',
      pg_temp._n('select count(*) from app.payer') = 1 and pg_temp._n(format('select count(*) from app.payer where payer_id = %L', pay_c)) = 1);
    r := pg_temp._add(r, 'second tenant provider sees none of tenant one',
      pg_temp._n(format('select count(*) from app.patient where tenant_id = %L', t1)) = 0
      and pg_temp._n(format('select count(*) from app.coverage where tenant_id = %L', t1)) = 0);
    reset role;

    -- ---------------------------------------------------------------- payer: only its own payer id
    perform pg_temp._claims(u_payer);
    set local role authenticated;
    r := pg_temp._add(r, 'payer sees only its own payer row',
      pg_temp._n('select count(*) from app.payer') = 1 and pg_temp._n(format('select count(*) from app.payer where payer_id = %L', pay_a)) = 1);
    r := pg_temp._add(r, 'payer sees only coverage for its payer_id',
      pg_temp._n('select count(*) from app.coverage') = 2
      and pg_temp._n(format('select count(*) from app.coverage where payer_id <> %L', pay_a)) = 0);
    r := pg_temp._add(r, 'payer sees only its plans and config',
      pg_temp._n('select count(*) from app.payer_plan') = 1 and pg_temp._n(format('select count(*) from app.payer_plan where payer_id <> %L', pay_a)) = 0
      and pg_temp._n('select count(*) from app.payer_config') = 1 and pg_temp._n(format('select count(*) from app.payer_config where payer_id <> %L', pay_a)) = 0);
    r := pg_temp._add(r, 'payer sees only eligibility requests and responses for its payer',
      pg_temp._n('select count(*) from app.eligibility_request') = 1
      and pg_temp._n(format('select count(*) from app.eligibility_request where payer_id <> %L', pay_a)) = 0
      and pg_temp._n('select count(*) from app.eligibility_response') = 1
      and pg_temp._n(format('select count(*) from app.eligibility_response where eligibility_request_id = %L', req_b)) = 0);
    r := pg_temp._add(r, 'payer cannot see patients rows at all',
      pg_temp._n('select count(*) from app.patient') = 0
      and pg_temp._n('select count(*) from app.patient_relationship') = 0
      and pg_temp._n('select count(*) from app.proxy_access') = 0);
    r := pg_temp._add(r, 'payer cannot see providers or clearinghouses',
      pg_temp._n('select count(*) from app.provider') = 0 and pg_temp._n('select count(*) from app.clearinghouse') = 0
      and pg_temp._n('select count(*) from app.clearinghouse_connection') = 0);
    r := pg_temp._add(r, 'in_scope for payer: own payer true; other payer, null payer, other tenant false',
      app.in_scope(t1, pay_a) and not app.in_scope(t1, pay_b) and not app.in_scope(t1) and not app.in_scope(t2, pay_a)
      and not app.in_scope(t1, null, null, pat_a));
    reset role;

    -- ---------------------------------------------------------------- patient: own row only
    perform pg_temp._claims(u_pat);
    set local role authenticated;
    r := pg_temp._add(r, 'patient sees only own patient row',
      pg_temp._n('select count(*) from app.patient') = 1 and pg_temp._n(format('select count(*) from app.patient where patient_id = %L', pat_a)) = 1);
    r := pg_temp._add(r, 'patient sees only own coverage',
      pg_temp._n('select count(*) from app.coverage') = 1 and pg_temp._n(format('select count(*) from app.coverage where patient_id = %L', pat_a)) = 1);
    r := pg_temp._add(r, 'patient sees no payers, providers, clearinghouses, plans, config',
      pg_temp._n('select count(*) from app.payer') = 0 and pg_temp._n('select count(*) from app.provider') = 0
      and pg_temp._n('select count(*) from app.clearinghouse') = 0 and pg_temp._n('select count(*) from app.payer_plan') = 0
      and pg_temp._n('select count(*) from app.payer_config') = 0 and pg_temp._n('select count(*) from app.eligibility_request') = 0);
    r := pg_temp._add(r, 'in_scope for patient: self true; another patient and null patient false',
      app.in_scope(t1, null, null, pat_a) and not app.in_scope(t1, null, null, pat_p) and not app.in_scope(t1)
      and not app.in_scope(t1, pay_a));
    reset role;

    -- ---------------------------------------------------------------- proxy: dependent only while active
    perform pg_temp._claims(u_prox);
    set local role authenticated;
    r := pg_temp._add(r, 'proxy sees self and dependent while proxy_access active',
      pg_temp._n('select count(*) from app.patient') = 2
      and pg_temp._n(format('select count(*) from app.patient where patient_id = %L', pat_d)) = 1
      and pg_temp._n('select count(*) from app.coverage') = 2);
    r := pg_temp._add(r, 'proxy sees the proxy_access row and relationship while active',
      pg_temp._n('select count(*) from app.proxy_access') = 1 and pg_temp._n('select count(*) from app.patient_relationship') = 1);
    reset role;

    update app.proxy_access set active = false where proxy_access_id = pa_id;
    set local role authenticated;
    r := pg_temp._add(r, 'proxy sees dependent only while proxy_access active (ended: active = false)',
      pg_temp._n('select count(*) from app.patient') = 1
      and pg_temp._n(format('select count(*) from app.patient where patient_id = %L', pat_d)) = 0
      and pg_temp._n(format('select count(*) from app.coverage where patient_id = %L', pat_d)) = 0
      and not app.in_scope(t1, null, null, pat_d) and app.in_scope(t1, null, null, pat_p));
    reset role;

    update app.proxy_access set active = true, effective_to = current_date - 1 where proxy_access_id = pa_id;
    set local role authenticated;
    r := pg_temp._add(r, 'proxy loses dependent after effective_to has passed',
      pg_temp._n(format('select count(*) from app.patient where patient_id = %L', pat_d)) = 0);
    reset role;

    update app.proxy_access set effective_from = current_date + 5, effective_to = null where proxy_access_id = pa_id;
    set local role authenticated;
    r := pg_temp._add(r, 'proxy does not see dependent before effective_from',
      pg_temp._n(format('select count(*) from app.patient where patient_id = %L', pat_d)) = 0);
    reset role;

    update app.proxy_access set effective_from = current_date - 5, effective_to = current_date where proxy_access_id = pa_id;
    set local role authenticated;
    r := pg_temp._add(r, 'proxy sees dependent again when reinstated (effective_to = today inclusive)',
      pg_temp._n(format('select count(*) from app.patient where patient_id = %L', pat_d)) = 1
      and pg_temp._n(format('select count(*) from app.coverage where patient_id = %L', pat_d)) = 1);
    reset role;

    -- the dependent's own account (no user here) is not made visible to the unrelated patient A
    perform pg_temp._claims(u_pat);
    set local role authenticated;
    r := pg_temp._add(r, 'unrelated patient does not inherit a proxy relationship',
      pg_temp._n(format('select count(*) from app.patient where patient_id in (%L, %L)', pat_p, pat_d)) = 0);
    reset role;

    -- ---------------------------------------------------------------- clearinghouse: only its own
    perform pg_temp._claims(u_clr);
    set local role authenticated;
    r := pg_temp._add(r, 'clearinghouse caller sees only its connection',
      pg_temp._n('select count(*) from app.clearinghouse_connection') = 1
      and pg_temp._n(format('select count(*) from app.clearinghouse_connection where clearinghouse_id = %L', ch_a)) = 1);
    r := pg_temp._add(r, 'clearinghouse caller sees only its own clearinghouse row',
      pg_temp._n('select count(*) from app.clearinghouse') = 1
      and pg_temp._n(format('select count(*) from app.clearinghouse where clearinghouse_id = %L', ch_a)) = 1);
    r := pg_temp._add(r, 'clearinghouse caller sees only eligibility routed through it',
      pg_temp._n('select count(*) from app.eligibility_request') = 1
      and pg_temp._n(format('select count(*) from app.eligibility_request where clearinghouse_id = %L', ch_a)) = 1
      and pg_temp._n('select count(*) from app.eligibility_response') = 1);
    r := pg_temp._add(r, 'clearinghouse caller sees no patients, payers, coverage, providers',
      pg_temp._n('select count(*) from app.patient') = 0 and pg_temp._n('select count(*) from app.payer') = 0
      and pg_temp._n('select count(*) from app.coverage') = 0 and pg_temp._n('select count(*) from app.provider') = 0);
    r := pg_temp._add(r, 'in_scope for clearinghouse: own true; other and null false',
      app.in_scope(t1, null, ch_a) and not app.in_scope(t1, null, ch_b) and not app.in_scope(t1) and not app.in_scope(t2, null, ch_a));
    reset role;

    -- ---------------------------------------------------------------- anon and unprovisioned callers
    perform pg_temp._claims(null);
    set local role anon;
    r := pg_temp._add(r, 'anon cannot read patient (42501)', pg_temp._try('select count(*) from app.patient') = '42501');
    r := pg_temp._add(r, 'anon cannot read payer or coverage (42501)',
      pg_temp._try('select count(*) from app.payer') = '42501' and pg_temp._try('select count(*) from app.coverage') = '42501');
    r := pg_temp._add(r, 'anon cannot execute in_scope (42501)', pg_temp._try('select app.in_scope(null)') = '42501');
    reset role;
    perform pg_temp._claims(gen_random_uuid());
    set local role authenticated;
    r := pg_temp._add(r, 'authenticated with no app_user row is refused (MR003)', pg_temp._try('select count(*) from app.patient') = 'MR003');
    reset role;

    -- ---------------------------------------------------------------- structure
    r := pg_temp._add(r, 'RLS enabled on all 12 new tables',
      (select count(*) = 12 from pg_class cl join pg_namespace ns on ns.oid = cl.relnamespace
        where ns.nspname = 'app' and cl.relrowsecurity and cl.relname in ('patient','patient_relationship','proxy_access','provider','payer','payer_plan',
          'payer_config','coverage','eligibility_request','eligibility_response','clearinghouse','clearinghouse_connection')));
    r := pg_temp._add(r, 'every new table has at least one policy and only SELECT policies',
      (select count(*) = 0 from pg_class cl join pg_namespace ns on ns.oid = cl.relnamespace
        where ns.nspname = 'app' and cl.relname in ('patient','patient_relationship','proxy_access','provider','payer','payer_plan',
          'payer_config','coverage','eligibility_request','eligibility_response','clearinghouse','clearinghouse_connection')
          and not exists (select 1 from pg_policy p where p.polrelid = cl.oid))
      and (select count(*) = 0 from pg_policy p join pg_class cl on cl.oid = p.polrelid join pg_namespace ns on ns.oid = cl.relnamespace
        where ns.nspname = 'app' and p.polcmd <> 'r'));
    r := pg_temp._add(r, 'no non-SELECT grant to client roles on app tables; anon holds nothing',
      (select count(*) = 0 from information_schema.role_table_grants
        where grantee in ('anon', 'authenticated', 'PUBLIC') and table_schema = 'app' and privilege_type <> 'SELECT')
      and (select count(*) = 0 from information_schema.role_table_grants where grantee in ('anon', 'PUBLIC') and table_schema = 'app'));
    r := pg_temp._add(r, 'every new table has tenant_id not null and audit columns',
      (select count(*) = 12 from (
        select c.table_name from information_schema.columns c
         where c.table_schema = 'app' and c.table_name in ('patient','patient_relationship','proxy_access','provider','payer','payer_plan',
          'payer_config','coverage','eligibility_request','eligibility_response','clearinghouse','clearinghouse_connection')
         group by c.table_name
        having count(*) filter (where c.column_name = 'tenant_id' and c.is_nullable = 'NO') = 1
           and count(*) filter (where c.column_name in ('created_at','created_by','updated_at','updated_by')) = 4) x));
    r := pg_temp._add(r, 'in_scope is security definer, executable by authenticated, not anon',
      (select prosecdef from pg_proc where oid = 'app.in_scope(uuid,uuid,uuid,uuid)'::regprocedure)
      and has_function_privilege('authenticated', 'app.in_scope(uuid,uuid,uuid,uuid)', 'execute')
      and not has_function_privilege('anon', 'app.in_scope(uuid,uuid,uuid,uuid)', 'execute'));
    r := pg_temp._add(r, 'every foreign-key column in the new tables is the leading column of an index',
      (select count(*) = 0 from pg_constraint k
        join pg_class cl on cl.oid = k.conrelid join pg_namespace ns on ns.oid = cl.relnamespace
        where k.contype = 'f' and ns.nspname = 'app' and cl.relname in ('patient','patient_relationship','proxy_access','provider','payer','payer_plan',
          'payer_config','coverage','eligibility_request','eligibility_response','clearinghouse','clearinghouse_connection')
          and not exists (select 1 from pg_index i where i.indrelid = k.conrelid and i.indkey[0] = k.conkey[1])));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id in (t1, t2))
    and not exists (select 1 from auth.users where id in (u_prov1, u_prov2, u_payer, u_pat, u_prox, u_clr))
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\'));

  perform tests.assert((e->>'p')::boolean, e->>'m') from jsonb_array_elements(r) e;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._n(text);
drop function pg_temp._claims(uuid);

select tests.report();
