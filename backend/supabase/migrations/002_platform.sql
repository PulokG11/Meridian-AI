-- 002_platform: tenancy, users, roles/permissions, hash-chained audit log, outbox, idempotency, access model.

-- ---------------------------------------------------------------- shared trigger: audit columns
create function app.touch() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if TG_OP = 'INSERT' then
    new.created_at := now();
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_at := now();
    new.updated_by := coalesce(new.updated_by, auth.uid());
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := auth.uid();
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------- platform tables
create table app.tenant (
  tenant_id  uuid primary key default app.uuid_v7(),
  name       text not null,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create table app.org_unit (
  org_unit_id uuid primary key default app.uuid_v7(),
  tenant_id   uuid not null references app.tenant (tenant_id),
  parent_id   uuid references app.org_unit (org_unit_id),
  name        text not null,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
create index org_unit_tenant_idx on app.org_unit (tenant_id);
create index org_unit_parent_idx on app.org_unit (parent_id);

-- Roles and permissions are platform-wide reference data (not tenant-owned).
create table app.role (
  role_key   text primary key,
  label      text not null,
  portal     text not null check (portal in ('provider','patient','payer','clearinghouse','platform')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create table app.permission (
  permission_key text primary key,
  description    text not null default '',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);

create table app.role_permission (
  role_key       text not null references app.role (role_key) on delete cascade,
  permission_key text not null references app.permission (permission_key) on delete cascade,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (role_key, permission_key)
);
create index role_permission_permission_idx on app.role_permission (permission_key);

create table app.app_user (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  tenant_id    uuid not null references app.tenant (tenant_id),
  portal       text not null check (portal in ('provider','patient','payer','clearinghouse','platform')),
  role_key     text not null references app.role (role_key),
  party_id     uuid,
  display_name text not null,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid
);
create index app_user_tenant_idx on app.app_user (tenant_id);
create index app_user_role_idx on app.app_user (role_key);

create table app.user_role (
  tenant_id  uuid not null references app.tenant (tenant_id),
  user_id    uuid not null references app.app_user (user_id) on delete cascade,
  role_key   text not null references app.role (role_key),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (user_id, role_key)
);
create index user_role_tenant_idx on app.user_role (tenant_id);
create index user_role_role_idx on app.user_role (role_key);

create table app.approval_limit (
  tenant_id  uuid not null references app.tenant (tenant_id),
  role_key   text not null references app.role (role_key),
  kind       text not null,
  max_amount numeric(12,2) not null check (max_amount >= 0),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (tenant_id, role_key, kind)
);
create index approval_limit_role_idx on app.approval_limit (role_key);

create table app.idempotency_key (
  tenant_id  uuid not null references app.tenant (tenant_id),
  command    text not null,
  key        text not null,
  args_hash  text not null,
  result     jsonb,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (tenant_id, command, key)
);

do $$
declare t text;
begin
  foreach t in array array['tenant','org_unit','role','permission','role_permission','app_user','user_role','approval_limit','idempotency_key']
  loop
    execute format('create trigger %I before insert or update on app.%I for each row execute function app.touch()', t || '_touch', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- audit tables
-- n is a per-tenant sequence (1,2,3...) assigned inside audit.write under a per-tenant advisory lock.
-- The primary key (tenant_id, n) makes a forked chain impossible even if the lock were bypassed.
create table audit.audit_log (
  n           bigint not null,
  tenant_id   uuid not null references app.tenant (tenant_id),
  at          timestamptz not null,
  actor       uuid not null,
  portal      text,
  action      text not null,
  object_type text,
  object_id   uuid,
  detail      jsonb not null default '{}'::jsonb,
  prev_hash   text not null,
  hash        text not null,
  primary key (tenant_id, n)
);

create table audit.outbox_event (
  event_id       uuid primary key default app.uuid_v7(),
  tenant_id      uuid not null references app.tenant (tenant_id),
  type           text not null,
  aggregate_id   uuid,
  payload        jsonb not null default '{}'::jsonb,
  correlation_id uuid,
  created_at     timestamptz not null default now(),
  processed_at   timestamptz
);
create index outbox_event_tenant_idx on audit.outbox_event (tenant_id);
create index outbox_event_pending_idx on audit.outbox_event (created_at) where processed_at is null;

-- ---------------------------------------------------------------- context and permissions
create type app.ctx_t as (tenant_id uuid, user_id uuid, portal text, role_key text, party_id uuid);

-- Resolves the caller from the JWT sub (auth.uid()) via app.app_user. MR003 when there is no session or no user row.
create function app.ctx() returns app.ctx_t
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r app.ctx_t;
begin
  if v_uid is null then
    perform app.refuse('MR003', 'no_session', 'session', 'Sign in to continue');
  end if;
  select u.tenant_id, u.user_id, u.portal, u.role_key, u.party_id
    into r
    from app.app_user u
   where u.user_id = v_uid;
  if not found then
    perform app.refuse('MR003', 'no_user', 'session', 'Your account is not set up for this application');
  end if;
  return r;
end;
$$;

create function app.authorize(p_permission text) returns void
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_ctx app.ctx_t := app.ctx();
begin
  if not exists (
    select 1 from app.role_permission rp
     where rp.role_key = v_ctx.role_key and rp.permission_key = p_permission
  ) then
    perform app.refuse('MR003', 'permission_required', coalesce(p_permission, ''),
      format('Your role (%s) does not have the %s permission', v_ctx.role_key, coalesce(p_permission, '?')));
  end if;
end;
$$;

-- ---------------------------------------------------------------- audit chain
-- hash = md5(prev_hash | n | at (UTC, microseconds) | actor | action | object_type | object_id | detail)
-- Fields are '|'-delimited and the timestamp is rendered in UTC so the hash does not depend on session TimeZone.
create function audit.row_hash(p_prev text, p_n bigint, p_at timestamptz, p_actor uuid, p_action text,
                               p_object_type text, p_object_id uuid, p_detail jsonb) returns text
language sql immutable
set search_path = ''
as $$
  select md5(concat_ws('|',
    p_prev,
    p_n::text,
    to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
    coalesce(p_actor::text, ''),
    coalesce(p_action, ''),
    coalesce(p_object_type, ''),
    coalesce(p_object_id::text, ''),
    coalesce(p_detail::text, '')))
$$;

create function audit.write(p_action text, p_object_type text, p_object_id uuid, p_detail jsonb) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ctx  app.ctx_t := app.ctx();
  v_n    bigint;
  v_prev text;
  v_at   timestamptz := clock_timestamp();
  v_det  jsonb := coalesce(p_detail, '{}'::jsonb);
begin
  -- Serialise writers per tenant so two concurrent transactions cannot both extend the same tip.
  perform pg_advisory_xact_lock(hashtext(v_ctx.tenant_id::text));
  select a.n, a.hash into v_n, v_prev
    from audit.audit_log a
   where a.tenant_id = v_ctx.tenant_id
   order by a.n desc
   limit 1;
  if not found then
    v_n := 1;
    v_prev := '00000000';
  else
    v_n := v_n + 1;
  end if;
  insert into audit.audit_log (n, tenant_id, at, actor, portal, action, object_type, object_id, detail, prev_hash, hash)
  values (v_n, v_ctx.tenant_id, v_at, v_ctx.user_id, v_ctx.portal, p_action, p_object_type, p_object_id, v_det, v_prev,
          audit.row_hash(v_prev, v_n, v_at, v_ctx.user_id, p_action, p_object_type, p_object_id, v_det));
end;
$$;

-- Recomputes the chain for one tenant: n must run 1..k, each prev_hash must equal the prior hash, each hash must recompute.
-- Administrative (owner / service role); not exposed to client roles.
create function audit.verify_chain(p_tenant uuid) returns boolean
language plpgsql stable
set search_path = ''
as $$
declare
  rec    record;
  v_i    bigint := 0;
  v_prev text := '00000000';
begin
  for rec in select * from audit.audit_log where tenant_id = p_tenant order by n loop
    v_i := v_i + 1;
    if rec.n <> v_i
       or rec.prev_hash <> v_prev
       or rec.hash <> audit.row_hash(rec.prev_hash, rec.n, rec.at, rec.actor, rec.action, rec.object_type, rec.object_id, rec.detail)
    then
      return false;
    end if;
    v_prev := rec.hash;
  end loop;
  return true;
end;
$$;

create function audit.no_modify() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform app.refuse('MR002', 'append_only', 'audit_log',
    'The audit log is append-only; record a correction as a new entry');
  return null;
end;
$$;

create trigger audit_log_no_modify before update or delete on audit.audit_log
  for each row execute function audit.no_modify();
create trigger audit_log_no_truncate before truncate on audit.audit_log
  for each statement execute function audit.no_modify();

-- ---------------------------------------------------------------- idempotency + outbox
-- begin_cmd: null if the key is new (a reservation row is created), the cached result if it was already finished
-- with the same args, MR005 for a blank key, the same key with different args, or a key still in flight.
create function app.begin_cmd(p_cmd text, p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ctx  app.ctx_t := app.ctx();
  v_hash text := md5(coalesce(p_args, '{}'::jsonb)::text);
  v_row  app.idempotency_key;
  v_new  boolean;
begin
  if p_idem is null or btrim(p_idem) = '' then
    perform app.refuse('MR005', 'idempotency_key_required', coalesce(p_cmd, ''), 'Send an idempotency key with every command');
  end if;
  if p_cmd is null or btrim(p_cmd) = '' then
    perform app.refuse('MR005', 'command_required', '', 'Command name is required');
  end if;

  insert into app.idempotency_key (tenant_id, command, key, args_hash)
  values (v_ctx.tenant_id, p_cmd, p_idem, v_hash)
  on conflict (tenant_id, command, key) do nothing
  returning true into v_new;
  if v_new then
    return null;
  end if;

  select * into v_row from app.idempotency_key k
   where k.tenant_id = v_ctx.tenant_id and k.command = p_cmd and k.key = p_idem;
  if v_row.args_hash <> v_hash then
    perform app.refuse('MR005', 'idempotency_key_reused', p_cmd,
      'This idempotency key was already used with different arguments; use a new key');
  end if;
  if v_row.result is null then
    perform app.refuse('MR005', 'command_in_flight', p_cmd, 'This command is still being processed');
  end if;
  return v_row.result;
end;
$$;

create function app.finish_cmd(p_cmd text, p_idem text, p_args jsonb, p_result jsonb, p_event text, p_aggregate uuid)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ctx     app.ctx_t := app.ctx();
  v_hash    text := md5(coalesce(p_args, '{}'::jsonb)::text);
  v_result  jsonb := coalesce(p_result, '{}'::jsonb);
  v_payload jsonb := '{}'::jsonb;
begin
  if p_idem is null or btrim(p_idem) = '' or p_event is null or btrim(p_event) = '' then
    perform app.refuse('MR005', 'finish_cmd_arguments', coalesce(p_cmd, ''), 'Idempotency key and event name are required');
  end if;

  update app.idempotency_key k
     set result = v_result
   where k.tenant_id = v_ctx.tenant_id and k.command = p_cmd and k.key = p_idem
     and k.args_hash = v_hash and k.result is null;
  if not found then
    perform app.refuse('MR005', 'finish_without_begin', coalesce(p_cmd, ''),
      'Call begin_cmd first with the same key and arguments, and finish only once');
  end if;

  -- Outbox payload carries identifiers only (id, *_id strings and *_ids arrays), never free text.
  if jsonb_typeof(v_result) = 'object' then
    select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) into v_payload
      from jsonb_each(v_result) e
     where (e.key = 'id' or e.key like '%\_id' escape '\') and jsonb_typeof(e.value) = 'string'
        or (e.key like '%\_ids' escape '\') and jsonb_typeof(e.value) = 'array';
  end if;

  insert into audit.outbox_event (tenant_id, type, aggregate_id, payload, correlation_id)
  values (v_ctx.tenant_id, p_event, p_aggregate, v_payload,
          md5(v_ctx.tenant_id::text || '|' || p_cmd || '|' || p_idem)::uuid);

  perform audit.write(p_cmd, split_part(p_event, '.', 1), p_aggregate,
    jsonb_build_object('event', p_event, 'idempotency_key', p_idem, 'args_hash', v_hash));

  return v_result;
end;
$$;

-- ---------------------------------------------------------------- RLS
alter table app.tenant           enable row level security;
alter table app.org_unit         enable row level security;
alter table app.role             enable row level security;
alter table app.permission       enable row level security;
alter table app.role_permission  enable row level security;
alter table app.app_user         enable row level security;
alter table app.user_role        enable row level security;
alter table app.approval_limit   enable row level security;
alter table app.idempotency_key  enable row level security;
alter table audit.audit_log      enable row level security;
alter table audit.outbox_event   enable row level security;

-- Tenant staff (provider / platform) read their own tenant's rows. Party-scoped policies for payer,
-- clearinghouse and patient portals are added per table in Task 3. No INSERT/UPDATE/DELETE policies.
create policy tenant_staff_select on app.tenant for select to authenticated
  using (tenant_id = (select tenant_id from app.ctx()) and (select portal from app.ctx()) in ('provider','platform'));
create policy tenant_staff_select on app.org_unit for select to authenticated
  using (tenant_id = (select tenant_id from app.ctx()) and (select portal from app.ctx()) in ('provider','platform'));
create policy tenant_staff_select on app.app_user for select to authenticated
  using (tenant_id = (select tenant_id from app.ctx()) and (select portal from app.ctx()) in ('provider','platform'));
create policy tenant_staff_select on app.user_role for select to authenticated
  using (tenant_id = (select tenant_id from app.ctx()) and (select portal from app.ctx()) in ('provider','platform'));
create policy tenant_staff_select on app.approval_limit for select to authenticated
  using (tenant_id = (select tenant_id from app.ctx()) and (select portal from app.ctx()) in ('provider','platform'));
create policy tenant_staff_select on audit.audit_log for select to authenticated
  using (tenant_id = (select tenant_id from app.ctx()) and (select portal from app.ctx()) in ('provider','platform'));
-- Internal plumbing: platform staff only.
create policy platform_select on app.idempotency_key for select to authenticated
  using (tenant_id = (select tenant_id from app.ctx()) and (select portal from app.ctx()) = 'platform');
create policy platform_select on audit.outbox_event for select to authenticated
  using (tenant_id = (select tenant_id from app.ctx()) and (select portal from app.ctx()) = 'platform');
-- Roles and permissions are platform-wide reference data, readable by any signed-in user.
create policy reference_select on app.role for select to authenticated using ((select auth.uid()) is not null);
create policy reference_select on app.permission for select to authenticated using ((select auth.uid()) is not null);
create policy reference_select on app.role_permission for select to authenticated using ((select auth.uid()) is not null);

-- Task 1 left RLS off on the (unexposed) test-result table; close that advisor finding.
alter table tests.result enable row level security;

-- ---------------------------------------------------------------- grants
-- authenticated: usage on schemas and SELECT on tables only (RLS decides rows). anon: nothing.
revoke all on all tables    in schema app, audit from public, anon, authenticated;
revoke all on all sequences in schema app, audit from public, anon, authenticated;
revoke all on all functions in schema app, audit from public, anon, authenticated;
grant usage on schema app, audit, api to authenticated;
grant select on all tables in schema app, audit to authenticated;

-- Functions: explicit revokes (default privileges do not cover new functions); only ctx() is client-callable.
revoke all on function app.touch() from public, anon, authenticated;
revoke all on function app.ctx() from public, anon, authenticated;
revoke all on function app.authorize(text) from public, anon, authenticated;
revoke all on function app.begin_cmd(text, text, jsonb) from public, anon, authenticated;
revoke all on function app.finish_cmd(text, text, jsonb, jsonb, text, uuid) from public, anon, authenticated;
revoke all on function audit.row_hash(text, bigint, timestamptz, uuid, text, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function audit.write(text, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function audit.verify_chain(uuid) from public, anon, authenticated;
revoke all on function audit.no_modify() from public, anon, authenticated;
grant execute on function app.ctx() to authenticated;
