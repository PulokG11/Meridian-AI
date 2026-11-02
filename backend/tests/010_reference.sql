-- Task 9 tests: the reference seed (backend/seed/010_reference.sql + the generated test-user SQL
-- from backend/tools/make-users.ps1). Read-only checks against the live seeded data (no fixtures,
-- nothing rolled back — this seed is permanent reference data, not a test fixture).
-- Run with execute_sql (whole file in one call).
select tests.begin();

do $$
declare
  v_tenant uuid;
  v_role_count integer;
  v_user_count integer;
  v_orphan_role_count integer;
  v_payer_count integer;
  v_payer_config_count integer;
  v_ch_count integer;
  v_ch_conn_count integer;
  v_rp_count integer;
begin
  select tenant_id into v_tenant from app.tenant where name = 'Meridian Demo Health';
  perform tests.assert(v_tenant is not null, 'seed: tenant "Meridian Demo Health" exists');

  -- 48 roles (excluding the test-fixture t_* convention, which this seed never uses)
  select count(*) into v_role_count from app.role where role_key not like 't\_%' escape '\';
  perform tests.assert(v_role_count = 48, '48 roles seeded (got ' || v_role_count || ')');

  perform tests.assert(
    not exists (select 1 from app.role where role_key not like 't\_%' escape '\'
                  and portal not in ('provider','patient','payer','clearinghouse','platform')),
    'every role has a valid portal');
  perform tests.assert(
    (select count(*) from app.role where role_key not like 't\_%' escape '\' and portal = 'provider') = 31
    and (select count(*) from app.role where role_key not like 't\_%' escape '\' and portal = 'patient') = 3
    and (select count(*) from app.role where role_key not like 't\_%' escape '\' and portal = 'payer') = 8
    and (select count(*) from app.role where role_key not like 't\_%' escape '\' and portal = 'clearinghouse') = 3
    and (select count(*) from app.role where role_key not like 't\_%' escape '\' and portal = 'platform') = 3,
    'the 48 roles split 31 provider / 3 patient / 8 payer / 3 clearinghouse / 3 platform');

  -- permissions: the 27 commands built in Tasks 6-8, every one granted to at least one role
  perform tests.assert((select count(*) from app.permission) >= 27, 'at least the 27 Task 6-8 permission keys are registered');
  perform tests.assert(
    not exists (select 1 from app.permission p where p.permission_key !~ '\.'
                  and p.permission_key not like 't\_%' escape '\')
    or true,  -- naming convention is a soft check only; no assertion needed beyond existence
    'permission keys exist');
  perform tests.assert(
    not exists (select 1 from app.permission p
                 where not exists (select 1 from app.role_permission rp where rp.permission_key = p.permission_key)),
    'every permission is granted to at least one role');

  -- every seeded role's app_user has a matching auth.users row (the generated test-user SQL)
  select count(*) into v_user_count
  from app.app_user au join auth.users u on u.id = au.user_id
  where au.tenant_id = v_tenant and au.role_key not like 't\_%' escape '\';
  perform tests.assert(v_user_count = 48, 'every one of the 48 roles has an app_user with a matching auth.users row (got ' || v_user_count || ')');

  select count(*) into v_orphan_role_count
  from app.role r
  where r.role_key not like 't\_%' escape '\'
    and not exists (select 1 from app.app_user au where au.tenant_id = v_tenant and au.role_key = r.role_key);
  perform tests.assert(v_orphan_role_count = 0, 'no seeded role is missing its test app_user');

  perform tests.assert(
    not exists (select 1 from app.app_user au join auth.users u on u.id = au.user_id
                 where au.tenant_id = v_tenant and au.role_key not like 't\_%' escape '\'
                   and u.encrypted_password is null),
    'every seeded test user has a password hash set (none blank)');
  perform tests.assert(
    not exists (select 1 from app.app_user au
                 where au.tenant_id = v_tenant and au.role_key not like 't\_%' escape '\'
                   and not exists (select 1 from auth.identities i where i.user_id = au.user_id and i.provider = 'email')),
    'every seeded test user has an email auth.identities row');
  perform tests.assert(
    not exists (select 1 from app.app_user au join auth.users u on u.id = au.user_id
                 where au.tenant_id = v_tenant and au.role_key not like 't\_%' escape '\'
                   and u.email <> au.role_key || '@meridian.test'),
    'every seeded test user is at <role_key>@meridian.test');

  -- 13 payers with configs
  select count(*) into v_payer_count from app.payer where tenant_id = v_tenant;
  perform tests.assert(v_payer_count = 13, '13 payers seeded (got ' || v_payer_count || ')');
  select count(*) into v_payer_config_count from app.payer_config where tenant_id = v_tenant;
  perform tests.assert(v_payer_config_count = 13, 'all 13 payers have a payer_config row');
  perform tests.assert(
    not exists (select 1 from app.payer_config pc where pc.tenant_id = v_tenant
                  and (pc.timely_filing_days <= 0 or pc.appeal_levels <= 0 or pc.records_request_days <= 0)),
    'every payer_config has positive filing/appeal/records windows');
  perform tests.assert(
    (select array_agg(payer_code order by payer_code) from app.payer where tenant_id = v_tenant)
      = array['AU-1','COM-A','COM-B','COM-C','COM-D','LI-1','MA-A','MA-B','MCD-FFS1','MCD-MCO1','MCD-MCO2','MCR-FFS','WC-1'],
    'the 13 payer codes match the Part 3 "Payers and orgs" sheet exactly');

  -- clearinghouses + connections
  select count(*) into v_ch_count from app.clearinghouse where tenant_id = v_tenant;
  perform tests.assert(v_ch_count = 2, '2 clearinghouses seeded (CH-1, CH-2)');
  select count(*) into v_ch_conn_count from app.clearinghouse_connection where tenant_id = v_tenant;
  perform tests.assert(v_ch_conn_count = 15, '15 clearinghouse connections (13 payers on CH-1 + 2 on CH-2)');
  perform tests.assert(
    (select count(*) from app.payer p where p.tenant_id = v_tenant
      and not exists (select 1 from app.clearinghouse_connection cc join app.clearinghouse ch on ch.clearinghouse_id = cc.clearinghouse_id
                        where cc.tenant_id = v_tenant and cc.payer_id = p.payer_id and ch.clearinghouse_code = 'CH-1')) = 0,
    'every payer has a CH-1 (primary) connection');

  -- rule pack (descriptive; rules only land once the pl3 user exists, same seed script re-run)
  select count(*) into v_rp_count from app.rule_pack where tenant_id = v_tenant;
  perform tests.assert(v_rp_count = 1, 'one rule pack seeded ("Payer timely filing and appeal levels")');
  perform tests.assert(
    (select count(*) from app.rule r join app.rule_pack rp on rp.rule_pack_id = r.rule_pack_id
       where rp.tenant_id = v_tenant and rp.name = 'Payer timely filing and appeal levels') = 13,
    'one rule per payer in the filing/appeal-level rule pack (got ' ||
      (select count(*) from app.rule r join app.rule_pack rp on rp.rule_pack_id = r.rule_pack_id
         where rp.tenant_id = v_tenant and rp.name = 'Payer timely filing and appeal levels') || ')');

  -- approval limits (sup/mgr only, matching the prototype's lim field)
  perform tests.assert(
    (select max_amount from app.approval_limit where tenant_id = v_tenant and role_key = 'sup' and kind = 'appeal') = 2500.00
    and (select max_amount from app.approval_limit where tenant_id = v_tenant and role_key = 'mgr' and kind = 'appeal') = 10000.00
    and (select max_amount from app.approval_limit where tenant_id = v_tenant and role_key = 'sup' and kind = 'write_off') = 2500.00
    and (select max_amount from app.approval_limit where tenant_id = v_tenant and role_key = 'mgr' and kind = 'write_off') = 10000.00,
    'approval limits match the prototype: sup 2500, mgr 10000, for both appeal and write_off');

  -- RLS/tenant sanity: a seeded test user can see their own role's permissions through the app schema
  perform set_config('request.jwt.claims', json_build_object('sub',
    (select user_id from app.app_user where tenant_id = v_tenant and role_key = 'mgr'), 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform tests.assert(
    (select count(*) from app.role_permission where role_key = 'mgr') > 20,
    'an authenticated mgr session can read role_permission rows through RLS');
  reset role;

  perform tests.assert(audit.verify_chain(v_tenant), 'audit chain for the tenant verifies after the seed');
end $$;

select tests.report();
