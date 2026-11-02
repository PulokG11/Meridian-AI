-- 003_parties_coverage: parties (patient, provider, proxy), payers and coverage, eligibility, clearinghouses,
-- plus app.in_scope() and party-scoped SELECT policies. All data synthetic.

-- ---------------------------------------------------------------- parties
create table app.patient (
  patient_id uuid primary key default app.uuid_v7(),
  tenant_id  uuid not null references app.tenant (tenant_id),
  mrn        text not null,
  first_name text not null,
  last_name  text not null,
  dob        date not null,
  sex        text check (sex in ('female','male','other','unknown')),
  status     text not null default 'active' check (status in ('active','inactive','deceased')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (tenant_id, mrn)
);

create table app.provider (
  provider_id uuid primary key default app.uuid_v7(),
  tenant_id   uuid not null references app.tenant (tenant_id),
  npi         text not null check (npi ~ '^[0-9]{10}$'),
  name        text not null,
  specialty   text,
  status      text not null default 'active' check (status in ('active','inactive')),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  unique (tenant_id, npi)
);

create table app.patient_relationship (
  patient_relationship_id uuid primary key default app.uuid_v7(),
  tenant_id         uuid not null references app.tenant (tenant_id),
  patient_id        uuid not null references app.patient (patient_id),
  related_patient_id uuid not null references app.patient (patient_id),
  relationship_type text not null check (relationship_type in ('guardian','parent','child','spouse','caregiver','other')),
  effective_from    date,
  effective_to      date,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  check (patient_id <> related_patient_id),
  check (effective_to is null or effective_from is null or effective_to >= effective_from)
);

-- A proxy (proxy_patient_id) may act for a dependent (patient_id) while the row is active:
-- active = true and today within [effective_from, effective_to] (effective_to null = open ended).
create table app.proxy_access (
  proxy_access_id  uuid primary key default app.uuid_v7(),
  tenant_id        uuid not null references app.tenant (tenant_id),
  patient_id       uuid not null references app.patient (patient_id),
  proxy_patient_id uuid not null references app.patient (patient_id),
  scope            text not null default 'full' check (scope in ('full','billing','read_only')),
  active           boolean not null default true,
  effective_from   date not null default current_date,
  effective_to     date,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  check (patient_id <> proxy_patient_id),
  check (effective_to is null or effective_to >= effective_from)
);

-- ---------------------------------------------------------------- payers
create table app.payer (
  payer_id   uuid primary key default app.uuid_v7(),
  tenant_id  uuid not null references app.tenant (tenant_id),
  name       text not null,
  payer_code text not null,
  payer_type text not null check (payer_type in ('commercial','medicare','medicaid','self_pay','other')),
  status     text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (tenant_id, payer_code)
);

create table app.payer_plan (
  payer_plan_id uuid primary key default app.uuid_v7(),
  tenant_id     uuid not null references app.tenant (tenant_id),
  payer_id      uuid not null references app.payer (payer_id),
  plan_name     text not null,
  plan_type     text not null check (plan_type in ('ppo','hmo','epo','pos','hdhp','government','other')),
  status        text not null default 'active' check (status in ('active','inactive')),
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);

-- Payer rules pack fields used by the prototype.
create table app.payer_config (
  payer_config_id      uuid primary key default app.uuid_v7(),
  tenant_id            uuid not null references app.tenant (tenant_id),
  payer_id             uuid not null references app.payer (payer_id),
  timely_filing_days   integer not null check (timely_filing_days > 0),
  appeal_levels        integer not null check (appeal_levels between 1 and 5),
  records_request_days integer not null check (records_request_days > 0),
  effective_from       date not null default current_date,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  unique (payer_id, effective_from)
);

-- ---------------------------------------------------------------- clearinghouses
create table app.clearinghouse (
  clearinghouse_id   uuid primary key default app.uuid_v7(),
  tenant_id          uuid not null references app.tenant (tenant_id),
  name               text not null,
  clearinghouse_code text not null,
  status             text not null default 'active' check (status in ('active','inactive')),
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  unique (tenant_id, clearinghouse_code)
);

-- endpoint_label is a human label only; no credentials or secrets are ever stored here.
create table app.clearinghouse_connection (
  clearinghouse_connection_id uuid primary key default app.uuid_v7(),
  tenant_id        uuid not null references app.tenant (tenant_id),
  clearinghouse_id uuid not null references app.clearinghouse (clearinghouse_id),
  payer_id         uuid references app.payer (payer_id),
  protocol         text not null check (protocol in ('x12','api','sftp')),
  endpoint_label   text not null,
  status           text not null default 'active' check (status in ('active','inactive','error')),
  last_checked_at  timestamptz,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid
);

-- ---------------------------------------------------------------- coverage and eligibility
create table app.coverage (
  coverage_id     uuid primary key default app.uuid_v7(),
  tenant_id       uuid not null references app.tenant (tenant_id),
  patient_id      uuid not null references app.patient (patient_id),
  payer_id        uuid not null references app.payer (payer_id),
  payer_plan_id   uuid references app.payer_plan (payer_plan_id),
  member_id       text not null,
  group_number    text,
  priority        integer not null default 1 check (priority between 1 and 9),
  effective_from  date not null,
  effective_to    date,
  source          text not null check (source in ('manual','eligibility','ehr','import')),
  verified_at     timestamptz,
  status          text not null default 'active' check (status in ('active','inactive','terminated')),
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  check (effective_to is null or effective_to >= effective_from)
);

create table app.eligibility_request (
  eligibility_request_id uuid primary key default app.uuid_v7(),
  tenant_id        uuid not null references app.tenant (tenant_id),
  patient_id       uuid not null references app.patient (patient_id),
  coverage_id      uuid references app.coverage (coverage_id),
  payer_id         uuid not null references app.payer (payer_id),
  clearinghouse_id uuid references app.clearinghouse (clearinghouse_id),
  service_date     date not null,
  status           text not null default 'pending' check (status in ('pending','sent','answered','failed')),
  requested_at     timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid
);

create table app.eligibility_response (
  eligibility_response_id uuid primary key default app.uuid_v7(),
  tenant_id              uuid not null references app.tenant (tenant_id),
  eligibility_request_id uuid not null references app.eligibility_request (eligibility_request_id),
  coverage_status        text not null check (coverage_status in ('active','inactive','unknown')),
  copay_amount           numeric(12,2) check (copay_amount >= 0),
  deductible_amount      numeric(12,2) check (deductible_amount >= 0),
  deductible_remaining   numeric(12,2) check (deductible_remaining >= 0),
  plan_begin             date,
  plan_end               date,
  received_at            timestamptz not null default now(),
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  updated_by             uuid
);

-- ---------------------------------------------------------------- indexes (tenant, every FK, policy columns)
create index patient_tenant_idx on app.patient (tenant_id);
create index provider_tenant_idx on app.provider (tenant_id);
create index patient_relationship_tenant_idx on app.patient_relationship (tenant_id);
create index patient_relationship_patient_idx on app.patient_relationship (patient_id);
create index patient_relationship_related_idx on app.patient_relationship (related_patient_id);
create index proxy_access_tenant_idx on app.proxy_access (tenant_id);
create index proxy_access_patient_idx on app.proxy_access (patient_id);
create index proxy_access_proxy_idx on app.proxy_access (proxy_patient_id, patient_id) where active;
create index payer_tenant_idx on app.payer (tenant_id);
create index payer_plan_tenant_idx on app.payer_plan (tenant_id);
create index payer_plan_payer_idx on app.payer_plan (payer_id);
create index payer_config_tenant_idx on app.payer_config (tenant_id);
create index clearinghouse_tenant_idx on app.clearinghouse (tenant_id);
create index clearinghouse_connection_tenant_idx on app.clearinghouse_connection (tenant_id);
create index clearinghouse_connection_ch_idx on app.clearinghouse_connection (clearinghouse_id);
create index clearinghouse_connection_payer_idx on app.clearinghouse_connection (payer_id);
create index coverage_tenant_idx on app.coverage (tenant_id);
create index coverage_patient_idx on app.coverage (patient_id);
create index coverage_payer_idx on app.coverage (payer_id);
create index coverage_plan_idx on app.coverage (payer_plan_id);
create index eligibility_request_tenant_idx on app.eligibility_request (tenant_id);
create index eligibility_request_patient_idx on app.eligibility_request (patient_id);
create index eligibility_request_coverage_idx on app.eligibility_request (coverage_id);
create index eligibility_request_payer_idx on app.eligibility_request (payer_id);
create index eligibility_request_ch_idx on app.eligibility_request (clearinghouse_id);
create index eligibility_response_tenant_idx on app.eligibility_response (tenant_id);
create index eligibility_response_request_idx on app.eligibility_response (eligibility_request_id);
-- payer_config(payer_id) is the leading column of its unique index; provider/patient natural keys lead with tenant_id.

-- ---------------------------------------------------------------- audit-column trigger
do $$
declare t text;
begin
  foreach t in array array['patient','provider','patient_relationship','proxy_access','payer','payer_plan','payer_config',
                           'clearinghouse','clearinghouse_connection','coverage','eligibility_request','eligibility_response']
  loop
    execute format('create trigger %I before insert or update on app.%I for each row execute function app.touch()', t || '_touch', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- scope helper
-- true when the caller (from app.ctx(), i.e. the JWT sub) may see a row of the given tenant and parties:
--   provider / platform : any row of the caller's own tenant;
--   payer               : p_payer = ctx.party_id (a row with no payer is never visible);
--   clearinghouse       : p_clearinghouse = ctx.party_id;
--   patient             : p_patient = ctx.party_id, or a dependent reachable through an ACTIVE proxy_access row.
-- Every portal is also confined to its own tenant. Raises MR003 (via ctx) for callers with no app_user row.
create function app.in_scope(p_tenant uuid, p_payer uuid default null, p_clearinghouse uuid default null, p_patient uuid default null)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
  c app.ctx_t := app.ctx();
begin
  if p_tenant is null or p_tenant is distinct from c.tenant_id then
    return false;
  end if;
  if c.portal in ('provider', 'platform') then
    return true;
  elsif c.portal = 'payer' then
    return p_payer is not null and p_payer = c.party_id;
  elsif c.portal = 'clearinghouse' then
    return p_clearinghouse is not null and p_clearinghouse = c.party_id;
  elsif c.portal = 'patient' then
    if p_patient is null or c.party_id is null then
      return false;
    end if;
    return p_patient = c.party_id
      or exists (
        select 1 from app.proxy_access pa
         where pa.tenant_id = p_tenant
           and pa.proxy_patient_id = c.party_id
           and pa.patient_id = p_patient
           and pa.active
           and pa.effective_from <= current_date
           and (pa.effective_to is null or pa.effective_to >= current_date));
  end if;
  return false;
end;
$$;

-- ---------------------------------------------------------------- RLS (SELECT only; no write policies)
alter table app.patient                  enable row level security;
alter table app.provider                 enable row level security;
alter table app.patient_relationship     enable row level security;
alter table app.proxy_access             enable row level security;
alter table app.payer                    enable row level security;
alter table app.payer_plan               enable row level security;
alter table app.payer_config             enable row level security;
alter table app.clearinghouse            enable row level security;
alter table app.clearinghouse_connection enable row level security;
alter table app.coverage                 enable row level security;
alter table app.eligibility_request      enable row level security;
alter table app.eligibility_response     enable row level security;

create policy scope_select on app.patient for select to authenticated
  using (app.in_scope(tenant_id, null, null, patient_id));
create policy scope_select on app.patient_relationship for select to authenticated
  using (app.in_scope(tenant_id, null, null, patient_id));
create policy scope_select on app.proxy_access for select to authenticated
  using (app.in_scope(tenant_id, null, null, patient_id));
create policy tenant_staff_select on app.provider for select to authenticated
  using (app.in_scope(tenant_id));
create policy scope_select on app.payer for select to authenticated
  using (app.in_scope(tenant_id, payer_id));
create policy scope_select on app.payer_plan for select to authenticated
  using (app.in_scope(tenant_id, payer_id));
create policy scope_select on app.payer_config for select to authenticated
  using (app.in_scope(tenant_id, payer_id));
create policy scope_select on app.clearinghouse for select to authenticated
  using (app.in_scope(tenant_id, null, clearinghouse_id));
create policy scope_select on app.clearinghouse_connection for select to authenticated
  using (app.in_scope(tenant_id, null, clearinghouse_id));
create policy scope_select on app.coverage for select to authenticated
  using (app.in_scope(tenant_id, payer_id, null, patient_id));
create policy scope_select on app.eligibility_request for select to authenticated
  using (app.in_scope(tenant_id, payer_id, clearinghouse_id));
-- A response is visible exactly when its request is (the subselect is itself filtered by the request policy).
create policy scope_select on app.eligibility_response for select to authenticated
  using (exists (
    select 1 from app.eligibility_request q
     where q.eligibility_request_id = eligibility_response.eligibility_request_id
       and q.tenant_id = eligibility_response.tenant_id));

-- ---------------------------------------------------------------- grants
revoke all on all tables in schema app from public, anon, authenticated;
grant select on all tables in schema app to authenticated;

revoke all on function app.in_scope(uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function app.in_scope(uuid, uuid, uuid, uuid) to authenticated;
