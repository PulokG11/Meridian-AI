-- Task 2 tests: platform core, audit chain, idempotency, outbox, permissions, access model.
-- Run with execute_sql (whole file in one call). Starts by clearing tests.result.
-- All fixture data lives inside a sub-transaction that is rolled back at the end of the DO block,
-- so the tests (including the tamper test, which disables the audit trigger) leave no residue.
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
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid(); ghost uuid := gen_random_uuid();
  party uuid := gen_random_uuid();
  agg uuid := gen_random_uuid(); rid uuid := gen_random_uuid();
  c app.ctx_t;
  j jsonb; j2 jsonb;
  n_org1 bigint; n_org2 bigint; n_ten bigint; n_aud bigint; n_pat bigint;
  anon_org text; anon_ctx text; auth_ins text; auth_upd text;
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner, no claims)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One'), (t2, 'Tenant Two');
    insert into app.role (role_key, label, portal) values
      ('t_prov_admin', 'Provider admin', 'provider'), ('t_patient', 'Patient', 'patient');
    insert into app.permission (permission_key, description) values
      ('claim.submit', 'Submit claims'), ('case.close', 'Close cases');
    insert into app.role_permission (role_key, permission_key) values ('t_prov_admin', 'claim.submit');
    insert into auth.users (id, aud, role, email) values
      (u1, 'authenticated', 'authenticated', 'u1@meridian.test'),
      (u2, 'authenticated', 'authenticated', 'u2@meridian.test'),
      (u3, 'authenticated', 'authenticated', 'u3@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, party_id, display_name) values
      (u1, t1, 'provider', 't_prov_admin', null, 'U One'),
      (u2, t1, 'patient',  't_patient',    party, 'U Two'),
      (u3, t2, 'provider', 't_prov_admin', null, 'U Three');
    insert into app.org_unit (tenant_id, name) values (t1, 'Org T1'), (t2, 'Org T2');
    insert into app.approval_limit (tenant_id, role_key, kind, max_amount) values (t1, 't_prov_admin', 'writeoff', 500.00);
    insert into app.user_role (tenant_id, user_id, role_key) values (t1, u1, 't_prov_admin');

    r := pg_temp._add(r, 'approval_limit stores numeric(12,2)',
      (select max_amount = 500.00 from app.approval_limit where tenant_id = t1));
    r := pg_temp._add(r, 'approval_limit refuses negative amount',
      pg_temp._try(format($q$insert into app.approval_limit (tenant_id, role_key, kind, max_amount) values (%L, 't_patient', 'x', -1)$q$, t1)) = '23514');
    r := pg_temp._add(r, 'app_user portal outside the allowed set refused',
      pg_temp._try(format($q$insert into app.app_user (user_id, tenant_id, portal, role_key, display_name) values (%L, %L, 'hacker', 't_patient', 'x')$q$, gen_random_uuid(), t1)) in ('23514', '23503'));

    -- ---------------------------------------------------------------- app.ctx()
    perform pg_temp._claims(null);
    r := pg_temp._add(r, 'ctx() raises MR003 with no claims', pg_temp._try('select app.ctx()') = 'MR003');
    perform pg_temp._claims(ghost);
    r := pg_temp._add(r, 'ctx() raises MR003 for a sub with no app_user row', pg_temp._try('select app.ctx()') = 'MR003');
    perform pg_temp._claims(u1);
    c := app.ctx();
    r := pg_temp._add(r, 'ctx() resolves tenant, user, portal, role for a provider',
      c.tenant_id = t1 and c.user_id = u1 and c.portal = 'provider' and c.role_key = 't_prov_admin' and c.party_id is null);
    perform pg_temp._claims(u2);
    c := app.ctx();
    r := pg_temp._add(r, 'ctx() resolves party_id for a patient', c.party_id = party and c.portal = 'patient');

    -- ---------------------------------------------------------------- app.authorize()
    perform pg_temp._claims(u1);
    r := pg_temp._add(r, 'authorize passes when role has the permission', pg_temp._try($q$select app.authorize('claim.submit')$q$) = 'ok');
    r := pg_temp._add(r, 'authorize raises MR003 when role lacks the permission', pg_temp._try($q$select app.authorize('case.close')$q$) = 'MR003');
    r := pg_temp._add(r, 'authorize raises MR003 for an unknown permission', pg_temp._try($q$select app.authorize('nope.nothing')$q$) = 'MR003');
    perform pg_temp._claims(u2);
    r := pg_temp._add(r, 'authorize raises MR003 for another role', pg_temp._try($q$select app.authorize('claim.submit')$q$) = 'MR003');
    perform pg_temp._claims(null);
    r := pg_temp._add(r, 'authorize raises MR003 with no claims', pg_temp._try($q$select app.authorize('claim.submit')$q$) = 'MR003');

    -- ---------------------------------------------------------------- audit chain
    r := pg_temp._add(r, 'verify_chain is true for a tenant with no rows', audit.verify_chain(t1));
    perform pg_temp._claims(u1);
    perform audit.write('claim.create', 'claim', agg, '{"k":1}');
    perform audit.write('claim.update', 'claim', agg, '{"k":2}');
    perform audit.write('claim.submit', 'claim', null, '{}');
    r := pg_temp._add(r, 'audit chain verifies after 3 writes', audit.verify_chain(t1));
    r := pg_temp._add(r, 'audit rows numbered 1..3 per tenant',
      (select array_agg(n order by n) = array[1,2,3]::bigint[] from audit.audit_log where tenant_id = t1));
    r := pg_temp._add(r, 'first row links to the genesis hash',
      (select prev_hash = '00000000' from audit.audit_log where tenant_id = t1 and n = 1));
    r := pg_temp._add(r, 'each row links to the previous hash',
      (select count(*) = 2 from audit.audit_log a join audit.audit_log b
        on b.tenant_id = a.tenant_id and b.n = a.n + 1 and b.prev_hash = a.hash where a.tenant_id = t1));
    r := pg_temp._add(r, 'audit row records actor, portal and tenant from ctx',
      (select actor = u1 and portal = 'provider' from audit.audit_log where tenant_id = t1 and n = 1));
    r := pg_temp._add(r, 'audit.write holds the per-tenant advisory lock until commit',
      exists (select 1 from pg_locks
              where locktype = 'advisory' and pid = pg_backend_pid()
                and objid::text::bigint = (hashtext(t1::text)::bigint & 4294967295)
                and classid::text::bigint = ((hashtext(t1::text)::bigint >> 32) & 4294967295)));
    r := pg_temp._add(r, 'a second row with the same (tenant, n) is refused, so the chain cannot fork',
      pg_temp._try(format($q$insert into audit.audit_log (tenant_id, n, at, actor, action, prev_hash, hash)
                              values (%L, 3, now(), %L, 'fork', 'x', 'y')$q$, t1, u1)) = '23505');
    perform pg_temp._claims(u3);
    perform audit.write('claim.create', 'claim', agg, '{}');
    r := pg_temp._add(r, 'chains are per tenant: second tenant starts at n = 1 and verifies',
      (select n = 1 and prev_hash = '00000000' from audit.audit_log where tenant_id = t2) and audit.verify_chain(t2));
    r := pg_temp._add(r, 'other tenant writes did not disturb the first chain', audit.verify_chain(t1));
    perform pg_temp._claims(null);
    r := pg_temp._add(r, 'audit.write raises MR003 with no claims', pg_temp._try($q$select audit.write('x','y',null,'{}')$q$) = 'MR003');

    -- append-only
    r := pg_temp._add(r, 'update on audit_log refused (MR002)',
      pg_temp._try(format($q$update audit.audit_log set action = 'x' where tenant_id = %L$q$, t1)) = 'MR002');
    r := pg_temp._add(r, 'delete on audit_log refused (MR002)',
      pg_temp._try(format($q$delete from audit.audit_log where tenant_id = %L$q$, t1)) = 'MR002');
    r := pg_temp._add(r, 'truncate on audit_log refused (MR002)', pg_temp._try('truncate audit.audit_log') = 'MR002');
    r := pg_temp._add(r, 'refused update left the chain intact', audit.verify_chain(t1));

    -- tamper: disable the trigger as owner, change a row, expect false, restore
    alter table audit.audit_log disable trigger audit_log_no_modify;
    update audit.audit_log set action = 'claim.TAMPERED' where tenant_id = t1 and n = 2;
    r := pg_temp._add(r, 'tampering with action breaks verify_chain', not audit.verify_chain(t1));
    update audit.audit_log set action = 'claim.update' where tenant_id = t1 and n = 2;
    r := pg_temp._add(r, 'restoring the action makes the chain verify again', audit.verify_chain(t1));
    update audit.audit_log set detail = '{"k":99}' where tenant_id = t1 and n = 1;
    r := pg_temp._add(r, 'tampering with detail breaks verify_chain', not audit.verify_chain(t1));
    update audit.audit_log set detail = '{"k":1}' where tenant_id = t1 and n = 1;
    delete from audit.audit_log where tenant_id = t1 and n = 2;
    r := pg_temp._add(r, 'deleting a middle row breaks verify_chain', not audit.verify_chain(t1));
    r := pg_temp._add(r, 'tampering in tenant one does not affect tenant two', audit.verify_chain(t2));
    alter table audit.audit_log enable trigger audit_log_no_modify;
    r := pg_temp._add(r, 'trigger restored and enabled',
      (select tgenabled = 'O' from pg_trigger where tgrelid = 'audit.audit_log'::regclass and tgname = 'audit_log_no_modify'));

    -- ---------------------------------------------------------------- idempotency + outbox
    perform pg_temp._claims(u3);   -- fresh, untampered tenant for command tests
    j := app.begin_cmd('cmd_x', 'k1', '{"a":1,"b":2}');
    r := pg_temp._add(r, 'begin_cmd returns null for a new key', j is null);
    r := pg_temp._add(r, 'begin_cmd again before finish (in flight) is refused (MR005)',
      pg_temp._try($q$select app.begin_cmd('cmd_x','k1','{"a":1,"b":2}')$q$) = 'MR005');
    j := app.finish_cmd('cmd_x', 'k1', '{"b":2,"a":1}',
      jsonb_build_object('case_id', rid, 'note', 'free text', 'line_ids', jsonb_build_array(rid)), 'case.opened', agg);
    r := pg_temp._add(r, 'finish_cmd returns the result it was given', j->>'case_id' = rid::text);
    j2 := app.begin_cmd('cmd_x', 'k1', '{"b":2,"a":1}');
    r := pg_temp._add(r, 'begin_cmd returns cached result for same key and args (key order irrelevant)',
      j2 = j and j2->>'note' = 'free text');
    r := pg_temp._add(r, 'begin_cmd refuses same key with different args (MR005)',
      pg_temp._try($q$select app.begin_cmd('cmd_x','k1','{"a":1,"b":3}')$q$) = 'MR005');
    r := pg_temp._add(r, 'begin_cmd refuses a null key (MR005)', pg_temp._try($q$select app.begin_cmd('cmd_x', null, '{}')$q$) = 'MR005');
    r := pg_temp._add(r, 'begin_cmd refuses a blank key (MR005)', pg_temp._try($q$select app.begin_cmd('cmd_x', '   ', '{}')$q$) = 'MR005');
    r := pg_temp._add(r, 'same key on another command is independent', app.begin_cmd('cmd_y', 'k1', '{"a":1,"b":2}') is null);
    perform pg_temp._claims(u1);
    r := pg_temp._add(r, 'same key and command in another tenant is independent', app.begin_cmd('cmd_x', 'k1', '{"a":9}') is null);
    r := pg_temp._add(r, 'finish_cmd for a key never begun is refused (MR005)',
      pg_temp._try($q$select app.finish_cmd('cmd_z','nokey','{}','{}','e.v',null)$q$) = 'MR005');
    perform app.finish_cmd('cmd_x', 'k1', '{"a":9}', '{"id":"abc"}', 'thing.done', null);
    r := pg_temp._add(r, 'finish_cmd twice for the same key is refused (MR005)',
      pg_temp._try($q$select app.finish_cmd('cmd_x','k1','{"a":9}','{"id":"abc"}','thing.done',null)$q$) = 'MR005');
    perform pg_temp._claims(null);
    r := pg_temp._add(r, 'begin_cmd raises MR003 with no claims', pg_temp._try($q$select app.begin_cmd('cmd_x','k9','{}')$q$) = 'MR003');
    r := pg_temp._add(r, 'finish_cmd raises MR003 with no claims', pg_temp._try($q$select app.finish_cmd('cmd_x','k9','{}','{}','e.v',null)$q$) = 'MR003');

    r := pg_temp._add(r, 'finish_cmd wrote one outbox row with type and aggregate',
      (select count(*) = 1 and bool_and(type = 'case.opened' and aggregate_id = agg and processed_at is null)
       from audit.outbox_event where tenant_id = t2));
    r := pg_temp._add(r, 'outbox payload carries ids only',
      (select payload = jsonb_build_object('case_id', rid, 'line_ids', jsonb_build_array(rid))
       from audit.outbox_event where tenant_id = t2));
    r := pg_temp._add(r, 'outbox rows are tenant-scoped',
      (select count(*) = 1 from audit.outbox_event where tenant_id = t1 and type = 'thing.done'));
    r := pg_temp._add(r, 'finish_cmd wrote an audit row named for the command',
      exists (select 1 from audit.audit_log where tenant_id = t2 and action = 'cmd_x' and object_id = agg));
    r := pg_temp._add(r, 'audit chain still verifies after command audit rows', audit.verify_chain(t2));
    r := pg_temp._add(r, 'idempotency row holds result and args hash',
      (select result->>'case_id' = rid::text and args_hash = md5('{"a": 1, "b": 2}')
       from app.idempotency_key where tenant_id = t2 and command = 'cmd_x' and key = 'k1'));

    -- ---------------------------------------------------------------- access model and RLS
    perform pg_temp._claims(u1);
    set local role authenticated;
    select count(*) into n_org1 from app.org_unit;
    select count(*) into n_ten from app.tenant;
    select count(*) into n_aud from audit.audit_log;
    auth_ins := pg_temp._try(format($q$insert into app.org_unit (tenant_id, name) values (%L, 'sneaky')$q$, t1));
    auth_upd := pg_temp._try(format($q$update app.org_unit set name = 'x' where tenant_id = %L$q$, t1));
    c := app.ctx();
    reset role;
    r := pg_temp._add(r, 'provider sees only own tenant org units', n_org1 = 1);
    r := pg_temp._add(r, 'provider sees only own tenant row', n_ten = 1);
    r := pg_temp._add(r, 'provider sees only own tenant audit rows', n_aud = (select count(*) from audit.audit_log where tenant_id = t1));
    r := pg_temp._add(r, 'authenticated cannot insert into app tables (42501)', auth_ins = '42501');
    r := pg_temp._add(r, 'authenticated cannot update app tables (42501)', auth_upd = '42501');
    r := pg_temp._add(r, 'authenticated can execute ctx()', c.tenant_id = t1);

    perform pg_temp._claims(u2);
    set local role authenticated;
    select count(*) into n_pat from app.org_unit;
    reset role;
    r := pg_temp._add(r, 'patient portal sees no staff rows (party policies are Task 3)', n_pat = 0);

    perform pg_temp._claims(null);
    set local role anon;
    anon_org := pg_temp._try('select count(*) from app.org_unit');
    anon_ctx := pg_temp._try('select app.ctx()');
    reset role;
    r := pg_temp._add(r, 'anon cannot read app tables (42501)', anon_org = '42501');
    r := pg_temp._add(r, 'anon cannot execute ctx() (42501)', anon_ctx = '42501');
    perform pg_temp._claims(ghost);
    set local role authenticated;
    anon_ctx := pg_temp._try('select count(*) from app.org_unit');
    reset role;
    r := pg_temp._add(r, 'authenticated with no app_user row is refused (MR003)', anon_ctx = 'MR003');

    r := pg_temp._add(r, 'no DML or TRUNCATE grant to anon/authenticated on app, ref, audit tables',
      (select count(*) = 0 from information_schema.role_table_grants
        where grantee in ('anon', 'authenticated', 'PUBLIC') and table_schema in ('app', 'ref', 'audit')
          and privilege_type <> 'SELECT'));
    r := pg_temp._add(r, 'anon holds no table privilege at all in app, ref, audit',
      (select count(*) = 0 from information_schema.role_table_grants
        where grantee in ('anon', 'PUBLIC') and table_schema in ('app', 'ref', 'audit')));
    r := pg_temp._add(r, 'RLS enabled on every table in app, ref, audit',
      (select count(*) = 0 from pg_class cl join pg_namespace ns on ns.oid = cl.relnamespace
        where cl.relkind in ('r', 'p') and ns.nspname in ('app', 'ref', 'audit') and not cl.relrowsecurity));
    r := pg_temp._add(r, 'every RLS-enabled table in app and audit has at least one policy',
      (select count(*) = 0 from pg_class cl join pg_namespace ns on ns.oid = cl.relnamespace
        where cl.relkind in ('r', 'p') and ns.nspname in ('app', 'audit')
          and not exists (select 1 from pg_policy p where p.polrelid = cl.oid)));
    r := pg_temp._add(r, 'ctx() executable by authenticated, not anon',
      has_function_privilege('authenticated', 'app.ctx()', 'execute') and not has_function_privilege('anon', 'app.ctx()', 'execute'));
    r := pg_temp._add(r, 'helper functions not executable by client roles',
      not has_function_privilege('authenticated', 'audit.write(text,text,uuid,jsonb)', 'execute')
      and not has_function_privilege('authenticated', 'app.begin_cmd(text,text,jsonb)', 'execute')
      and not has_function_privilege('authenticated', 'app.finish_cmd(text,text,jsonb,jsonb,text,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'app.authorize(text)', 'execute')
      and not has_function_privilege('authenticated', 'audit.verify_chain(uuid)', 'execute')
      and not has_function_privilege('anon', 'audit.write(text,text,uuid,jsonb)', 'execute'));
    r := pg_temp._add(r, 'no custom_access_token_hook (controller ruling)',
      not exists (select 1 from pg_proc where proname = 'custom_access_token_hook'));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  -- sub-transaction rolled back: nothing from the fixtures remains
  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id in (t1, t2))
    and not exists (select 1 from audit.audit_log where tenant_id in (t1, t2))
    and not exists (select 1 from auth.users where id in (u1, u2, u3))
    and (select tgenabled = 'O' from pg_trigger where tgrelid = 'audit.audit_log'::regclass and tgname = 'audit_log_no_modify'));

  perform tests.assert((e->>'p')::boolean, e->>'m') from jsonb_array_elements(r) e;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._claims(uuid);

select tests.report();
