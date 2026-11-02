-- 001_schemas_ref: schemas, UUIDv7, refusal helper, state-machine reference + trigger, test helpers.

create schema if not exists app;
create schema if not exists ref;
create schema if not exists audit;
create schema if not exists api;
create schema if not exists tests;

-- Only `api` is ever exposed to PostgREST; later tasks grant on api only.
revoke all on schema app, ref, audit, tests from public, anon, authenticated;
alter default privileges in schema app, ref, audit, tests revoke all on tables from public, anon, authenticated;
alter default privileges in schema app, ref, audit, tests revoke all on sequences from public, anon, authenticated;
alter default privileges in schema app, ref, audit, tests revoke all on functions from public, anon, authenticated;

-- ---------------------------------------------------------------- uuid v7
-- Random v4 uuid with the first 48 bits replaced by epoch milliseconds; version nibble set to 7.
create function app.uuid_v7() returns uuid
language sql volatile
set search_path = ''
as $$
  select encode(set_byte(s.b, 6, (get_byte(s.b, 6) & 15) | 112), 'hex')::uuid
  from (
    select overlay(
      uuid_send(gen_random_uuid())
      placing substring(int8send((floor(extract(epoch from clock_timestamp()) * 1000))::bigint) from 3)
      from 1 for 6) as b
  ) s
$$;

-- ---------------------------------------------------------------- refusals
-- Raises an exception whose SQLSTATE is the code (MR001..MR005) and whose message is JSON.
create function app.refuse(p_code text, p_rule text, p_object text, p_todo text) returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = p_code,
    message = json_build_object('code', p_code, 'rule', p_rule, 'object', p_object, 'todo', p_todo)::text;
end;
$$;

-- ---------------------------------------------------------------- state machines
create table ref.state_transition (
  entity      text not null,
  from_status text not null,
  to_status   text not null,
  primary key (entity, from_status, to_status)
);
alter table ref.state_transition enable row level security;

create function ref.transition_ok(p_entity text, p_from text, p_to text) returns boolean
language sql stable
set search_path = ''
as $$
  select exists (
    select 1 from ref.state_transition
    where entity = p_entity and from_status = p_from and to_status = p_to
  )
$$;

-- Trigger function: attach as `execute function app.enforce_transition('<entity>')` on a table with a `status` column.
create function app.enforce_transition() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if TG_OP = 'UPDATE' and NEW.status is distinct from OLD.status then
    if not ref.transition_ok(TG_ARGV[0], OLD.status, NEW.status) then
      perform app.refuse('MR001', 'illegal_transition', TG_ARGV[0],
        format('%s cannot move from %s to %s', TG_ARGV[0], OLD.status, NEW.status));
    end if;
  end if;
  return NEW;
end;
$$;

insert into ref.state_transition (entity, from_status, to_status) values
  -- claim
  ('claim', 'draft', 'ready'),
  ('claim', 'ready', 'submitted'),
  ('claim', 'submitted', 'accepted'),
  ('claim', 'submitted', 'rejected'),
  ('claim', 'accepted', 'paid'),
  ('claim', 'accepted', 'partially_paid'),
  ('claim', 'accepted', 'denied'),
  -- denial
  ('denial', 'new', 'triaged'),
  ('denial', 'triaged', 'in_correction'),
  ('denial', 'triaged', 'in_evidence'),
  ('denial', 'triaged', 'in_appeal'),
  ('denial', 'triaged', 'in_coverage_update'),
  ('denial', 'in_correction', 'recovered'),
  ('denial', 'in_evidence', 'recovered'),
  ('denial', 'in_appeal', 'recovered'),
  ('denial', 'in_coverage_update', 'recovered'),
  ('denial', 'new', 'written_off'),
  ('denial', 'triaged', 'written_off'),
  ('denial', 'in_correction', 'written_off'),
  ('denial', 'in_evidence', 'written_off'),
  ('denial', 'in_appeal', 'written_off'),
  ('denial', 'in_coverage_update', 'written_off'),
  ('denial', 'recovered', 'written_off'),
  -- appeal
  ('appeal', 'drafting', 'pending_approval'),
  ('appeal', 'pending_approval', 'approved'),
  ('appeal', 'approved', 'filed'),
  ('appeal', 'filed', 'decided'),
  -- case
  ('case', 'open', 'closed'),
  ('case', 'closed', 'open');

-- ---------------------------------------------------------------- test helpers (not exposed)
create table tests.result (
  id     bigint generated always as identity primary key,
  msg    text not null,
  passed boolean not null
);

create function tests.begin() returns void
language sql
set search_path = ''
as $$ truncate tests.result restart identity $$;

create function tests.assert(p_cond boolean, p_msg text) returns void
language sql
set search_path = ''
as $$ insert into tests.result (msg, passed) values (p_msg, coalesce(p_cond, false)) $$;

create function tests.report() returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_failed text;
  v_pass integer;
begin
  select string_agg(msg, '; ' order by id) into v_failed from tests.result where not passed;
  if v_failed is not null then
    raise exception 'TESTS FAILED: %', v_failed;
  end if;
  select count(*) into v_pass from tests.result where passed;
  return v_pass;
end;
$$;

-- ---------------------------------------------------------------- grants: nothing for client roles
revoke all on all tables in schema app, ref, audit, tests from public, anon, authenticated;
revoke all on all functions in schema app, ref, audit, tests from public, anon, authenticated;
