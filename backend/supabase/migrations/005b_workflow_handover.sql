-- 005b_workflow_handover: workflow tables (work_queue, task, approval_request, handover_event), Rules & AI tables
-- (rule_pack, rule, ai_model_version, ai_interaction, ai_review), ref.handover_def seeded H13..H24 (spec 5.4),
-- the approval trigger (IV13), ready checks ref.check_h13 .. ref.check_h24, the handover engine app.process_outbox()
-- (IV26 hold = exactly one task, IV27 replay = nothing new) and its pg_cron job. All data synthetic.
-- Client roles get SELECT only; the engine and the checks are owner-only (cron / definer code).

-- ================================================================ outbox ordering
-- event_id is a uuid v7 with millisecond resolution and a random tail, so it cannot order two events written in the
-- same millisecond. seq (insertion order) is the per-aggregate processing order.
alter table audit.outbox_event add column seq bigint generated always as identity;
create index outbox_event_pending_seq_idx on audit.outbox_event (seq) where processed_at is null;
create index outbox_event_pending_agg_idx on audit.outbox_event (aggregate_id, seq) where processed_at is null;

-- ================================================================ handover definitions
create table ref.handover_def (
  handover_id   text primary key check (handover_id ~ '^H[0-9]{2}$'),
  route         text not null,            -- spec 5.4 "From to"
  trigger_event text not null,            -- outbox event type (spec 5.2 "Emits")
  ready_check   text not null,            -- spec 5.4 "Ready check" (description); implemented by ref.check_<lower(handover_id)>(uuid)
  hold_queue    text not null,            -- spec 5.4 "If the check fails": the work queue the task goes to
  active        boolean not null default true
);
create index handover_def_trigger_idx on ref.handover_def (trigger_event) where active;
alter table ref.handover_def enable row level security;

insert into ref.handover_def (handover_id, route, trigger_event, ready_check, hold_queue, active) values
  ('H13', 'M11 to B01 Claim build',                              'claim.ready',                     'No holds, authorization linked, coverage order set',    'Back to the holding queue',      true),
  ('H14', 'B02 Claim to C02 to Y03 Payer',                       'claim.submitted',                 'Claim passes edits',                                    'Rejection queue',                true),
  ('H15', 'Y06 Payer to C04 to B04 Posting',                     'remittance.received',             'File complete and matched to claims',                   'Unmatched remit queue',          true),
  ('H16', 'B04 Posting to B05 Triage',                           'denial.created',                  'Denial codes parsed per line',                          'Manual coding of denial',        true),
  ('H17', 'B05 to B06, B07, B08, B09',                           'denial.path_confirmed',           'Analyst confirmed or overrode the recommendation',      'Supervisor review',              true),
  ('H18', 'B06, B07, B08 to Y03, Y04, Y05',                      'approval.decided',                'Approved by a reviewer within limit',                   'Returned to author',             true),
  ('H19', 'B04 to B13 Patient billing',                          'payment.posted',                  'Primary and secondary payers finished',                 'Wait for secondary or return to B09', true),
  ('H20', 'B04 to B17 Reconciliation',                           'deposit.allocated',               'A deposit exists for the trace',                        'Break log',                      true),
  ('H21', 'B04, B13, B16, B17 to B20 Closure',                   'case.closure_evaluated',          'Closure rule satisfied for every line',                 'Stays open with the blocking reason', true),
  ('H22', 'B05 and B20 to B21 to A06, A07, A08, M09, M11',       'rule.published',                  'Rule owner approves the change',                        'Stays a recommendation',         true),
  ('H23', 'A08 Provider and Y02 Payer',                          'authorization.requested',         'Request has required clinical data',                    'Pended for more information',    false),
  ('H24', 'A06 Provider and Y01 Payer (through C03)',            'eligibility.response_received',   'Eligibility response parsed to benefits',               'Retry, then manual portal check', true);

-- ================================================================ workflow tables
create table app.work_queue (
  work_queue_id uuid primary key default app.uuid_v7(),
  tenant_id     uuid not null references app.tenant (tenant_id),
  name          text not null,
  description   text,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  unique (tenant_id, name)
);

create table app.approval_request (
  approval_request_id uuid primary key default app.uuid_v7(),
  tenant_id    uuid not null references app.tenant (tenant_id),
  kind         text not null,                       -- matches app.approval_limit.kind (for example 'appeal', 'write_off')
  amount       numeric(12,2) not null default 0 check (amount >= 0),
  requester_id uuid not null references app.app_user (user_id),
  approver_id  uuid references app.app_user (user_id),
  status       text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  subject_type text,
  subject_id   uuid,
  reason       text,
  requested_at timestamptz not null default now(),
  decided_at   timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint approval_request_approver_not_requester check (approver_id is null or approver_id <> requester_id)   -- IV13
);

-- handover_event is declared before task so task can point at it.
create table app.handover_event (
  handover_event_id uuid primary key default app.uuid_v7(),
  tenant_id       uuid not null references app.tenant (tenant_id),
  handover_id     text not null references ref.handover_def (handover_id),
  subject_id      uuid not null,
  source_event_id uuid not null references audit.outbox_event (event_id),
  status          text not null check (status in ('passed','held','failed_check')),
  detail          text,
  checked_at      timestamptz not null default clock_timestamp(),
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  constraint handover_event_once unique (handover_id, subject_id, source_event_id)   -- IV27: a replay creates nothing
);

create table app.task (
  task_id       uuid primary key default app.uuid_v7(),
  tenant_id     uuid not null references app.tenant (tenant_id),
  queue_id      uuid not null references app.work_queue (work_queue_id),
  subject_type  text not null,
  subject_id    uuid not null,
  status        text not null default 'open' check (status in ('open','in_progress','done','cancelled')),
  title         text,
  due_at        timestamptz,
  assignee_id   uuid references app.app_user (user_id),
  source_handover_event_id uuid references app.handover_event (handover_event_id),
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);

-- ================================================================ rules and AI tables
create table app.rule_pack (
  rule_pack_id   uuid primary key default app.uuid_v7(),
  tenant_id      uuid not null references app.tenant (tenant_id),
  name           text not null,
  version        integer not null check (version > 0),
  effective_from date not null,
  status         text not null default 'draft' check (status in ('draft','active','retired')),
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  unique (tenant_id, name, version)
);

create table app.rule (
  rule_id        uuid primary key default app.uuid_v7(),
  tenant_id      uuid not null references app.tenant (tenant_id),
  rule_pack_id   uuid not null references app.rule_pack (rule_pack_id),
  rule_key       text not null,
  payload        jsonb not null default '{}'::jsonb,
  effective_from date not null,
  effective_to   date,
  owner          uuid not null references app.app_user (user_id),
  approved_by    uuid references app.app_user (user_id),
  approved_at    timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  unique (rule_pack_id, rule_key, effective_from),
  check (effective_to is null or effective_to >= effective_from),
  constraint rule_approval_pair check ((approved_by is null) = (approved_at is null))
);

create table app.ai_model_version (
  ai_model_version_id uuid primary key default app.uuid_v7(),
  tenant_id  uuid not null references app.tenant (tenant_id),
  name       text not null,
  version    text not null,
  purpose    text not null,
  owner      uuid references app.app_user (user_id),
  limits     text,
  status     text not null default 'candidate' check (status in ('candidate','approved','retired')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (tenant_id, name, version)
);

create table app.ai_interaction (
  ai_interaction_id uuid primary key default app.uuid_v7(),
  tenant_id        uuid not null references app.tenant (tenant_id),
  task             text not null,
  subject_type     text,
  subject_id       uuid,
  model_version_id uuid references app.ai_model_version (ai_model_version_id),
  input_ref        text,                                  -- reference to the input, never the raw text
  output           jsonb not null default '{}'::jsonb,
  label            text not null default 'Simulated',     -- all AI output is labelled Simulated in this prototype
  status           text not null default 'suggested' check (status in ('suggested','accepted','edited','rejected','expired')),
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid
);

create table app.ai_review (
  ai_review_id      uuid primary key default app.uuid_v7(),
  tenant_id         uuid not null references app.tenant (tenant_id),
  ai_interaction_id uuid not null references app.ai_interaction (ai_interaction_id),
  reviewer_id       uuid not null references app.app_user (user_id),
  decision          text not null check (decision in ('accepted','edited','rejected')),
  reason            text,
  reviewed_at       timestamptz not null default now(),
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid
);

-- ================================================================ indexes (tenant, every FK, lookups)
create index approval_request_tenant_idx    on app.approval_request (tenant_id);
create index approval_request_requester_idx on app.approval_request (requester_id);
create index approval_request_approver_idx  on app.approval_request (approver_id);
create index approval_request_subject_idx   on app.approval_request (subject_type, subject_id);
create index handover_event_tenant_idx      on app.handover_event (tenant_id);
create index handover_event_source_idx      on app.handover_event (source_event_id);
create index handover_event_subject_idx     on app.handover_event (subject_id);
create index task_tenant_idx                on app.task (tenant_id);
create index task_queue_idx                 on app.task (queue_id, status);
create index task_subject_idx               on app.task (subject_type, subject_id);
create index task_assignee_idx              on app.task (assignee_id);
create unique index task_source_handover_uq on app.task (source_handover_event_id) where source_handover_event_id is not null;   -- one task per held handover
create index rule_tenant_idx                on app.rule (tenant_id);
create index rule_owner_idx                 on app.rule (owner);
create index rule_approved_by_idx           on app.rule (approved_by);
create index ai_model_version_owner_idx     on app.ai_model_version (owner);
create index ai_interaction_tenant_idx      on app.ai_interaction (tenant_id);
create index ai_interaction_model_idx       on app.ai_interaction (model_version_id);
create index ai_interaction_subject_idx     on app.ai_interaction (subject_type, subject_id);
create index ai_review_tenant_idx           on app.ai_review (tenant_id);
create index ai_review_interaction_idx      on app.ai_review (ai_interaction_id);
create index ai_review_reviewer_idx         on app.ai_review (reviewer_id);
-- Covered by a unique constraint leading with the FK column: work_queue(tenant_id), rule_pack(tenant_id),
-- ai_model_version(tenant_id), rule(rule_pack_id), handover_event(handover_id).

-- ================================================================ audit-column trigger
do $$
declare t text;
begin
  foreach t in array array['work_queue','task','approval_request','handover_event','rule_pack','rule',
                           'ai_model_version','ai_interaction','ai_review']
  loop
    execute format('create trigger %I before insert or update on app.%I for each row execute function app.touch()', t || '_touch', t);
  end loop;
end $$;

-- ================================================================ approval request: state machine and IV13
insert into ref.state_transition (entity, from_status, to_status) values
  ('approval_request', 'pending', 'approved'),
  ('approval_request', 'pending', 'rejected'),
  ('approval_request', 'pending', 'cancelled');

create trigger approval_request_transition before update on app.approval_request
  for each row execute function app.enforce_transition('approval_request');

-- The highest limit for a kind among the roles of a user (the app_user role and any user_role grants) in a tenant;
-- null when none of the user's roles has a limit for the kind.
create function app.approver_limit(p_tenant uuid, p_user uuid, p_kind text) returns numeric
language sql stable security definer
set search_path = ''
as $$
  select max(l.max_amount)
    from app.approval_limit l
   where l.tenant_id = p_tenant
     and l.kind = p_kind
     and l.role_key in (select u.role_key from app.app_user u where u.user_id = p_user and u.tenant_id = p_tenant
                        union
                        select ur.role_key from app.user_role ur where ur.user_id = p_user and ur.tenant_id = p_tenant)
$$;

-- IV13 gate. Insert: only 'pending'. Update: a decided request is final (illegal moves are MR001 from
-- enforce_transition); a decision (approved / rejected) needs an approver who is not the requester, in the same
-- tenant; approving also needs a limit for the kind that covers the amount.
create function app.approval_request_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_limit  numeric;
begin
  if TG_OP = 'INSERT' then
    if new.status <> 'pending' then
      perform app.refuse('MR002', 'approval_starts_pending', 'approval_request', 'A request is created pending and decided afterwards');
    end if;
    return new;
  end if;

  if old.status <> 'pending' then
    if new.status is not distinct from old.status
       and row(new.tenant_id, new.kind, new.amount, new.requester_id, new.approver_id, new.subject_type, new.subject_id)
           is distinct from row(old.tenant_id, old.kind, old.amount, old.requester_id, old.approver_id, old.subject_type, old.subject_id)
    then
      perform app.refuse('MR002', 'approval_request_final', 'approval_request', 'A decided request cannot be changed; raise a new request');
    end if;
    return new;
  end if;

  if new.status in ('approved', 'rejected') then
    if new.approver_id is null then
      perform app.refuse('MR002', 'approver_required', 'approval_request', 'Name the approver who decides this request');
    end if;
    if new.approver_id = new.requester_id then
      perform app.refuse('MR003', 'IV13_approver_not_requester', 'approval_request', 'Someone other than the requester must decide this request');
    end if;
    select u.tenant_id into v_tenant from app.app_user u where u.user_id = new.approver_id;
    if v_tenant is distinct from new.tenant_id then
      perform app.refuse('MR003', 'approver_not_in_tenant', 'approval_request', 'The approver must belong to the same organisation');
    end if;
    if new.status = 'approved' then
      v_limit := app.approver_limit(new.tenant_id, new.approver_id, new.kind);
      if v_limit is null then
        perform app.refuse('MR003', 'no_approval_authority', 'approval_request',
          format('Your role has no approval limit for %s requests', new.kind));
      end if;
      if new.amount > v_limit then
        perform app.refuse('MR003', 'IV13_over_approval_limit', 'approval_request',
          format('%s exceeds your %s approval limit of %s; ask someone with a higher limit', new.amount, new.kind, v_limit));
      end if;
    end if;
    new.decided_at := coalesce(new.decided_at, now());
  end if;
  return new;
end;
$$;

create trigger approval_request_guard before insert or update on app.approval_request
  for each row execute function app.approval_request_guard();

-- patient_payment write-offs point at the approval (column added in 005a).
alter table app.patient_payment
  add constraint patient_payment_approval_request_fk
  foreign key (approval_request_id) references app.approval_request (approval_request_id);

-- ================================================================ ready checks ref.check_hNN(subject) -> boolean
-- One per handover; SECURITY DEFINER (they read tables the callers cannot), stable, never exposed to clients.
-- A missing subject always returns false (held), never an error.

-- True when the latest result of any hard edit (per rule and line) on the claim is a failure.
create function app.claim_has_failed_hard_edit(p_claim uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
      from (select distinct on (e.rule_code, e.line_id) e.passed
              from app.claim_edit_result e
             where e.claim_id = p_claim and e.severity = 'hard'
             order by e.rule_code, e.line_id, e.checked_at desc, e.claim_edit_result_id desc) x
     where not x.passed)
$$;

-- H13 claim.ready (subject = claim_id). Tests: the claim exists, has a coverage that is active, is not on bill hold,
-- and has no failed hard edit (latest result per rule and line). Approximation: "authorization linked" is not tested
-- (no authorization_request table in release 1; see H23); "coverage order set" is read as "coverage chosen and active".
create function ref.check_h13(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
      from app.claim c
      join app.coverage cv on cv.coverage_id = c.coverage_id and cv.status = 'active'
     where c.claim_id = p_subject
       and not c.hold)
     and not app.claim_has_failed_hard_edit(p_subject)
$$;

-- H14 claim.submitted (subject = claim_id). Tests: the claim exists and has no failed hard edit (latest result per
-- rule and line); soft edit failures do not hold the claim.
create function ref.check_h14(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from app.claim c where c.claim_id = p_subject)
     and not app.claim_has_failed_hard_edit(p_subject)
$$;

-- H15 remittance.received (subject = remittance_id). Tests: the remittance has at least one line, every line is
-- matched to a claim, and the lines' paid amounts add up to the control total (payment_amount).
-- Approximation: provider-level adjustments (PLB) are not modelled, so control total = sum of line payments.
create function ref.check_h15(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from app.remittance_line l where l.remittance_id = p_subject)
     and not exists (select 1 from app.remittance_line l where l.remittance_id = p_subject and l.claim_id is null)
     and (select coalesce(sum(l.paid), 0) from app.remittance_line l where l.remittance_id = p_subject)
         = (select r.payment_amount from app.remittance r where r.remittance_id = p_subject)
$$;

-- H16 denial.created (subject = denial_id). Tests: the denial exists and has a non-blank CARC. The RARC is optional
-- (many denials carry none), so a missing RARC does not hold the denial.
create function ref.check_h16(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from app.denial d where d.denial_id = p_subject and nullif(btrim(d.carc), '') is not null)
$$;

-- H17 denial.path_confirmed (subject = denial_id). Tests: the latest triage row of the denial has a confirmed path,
-- a confirmer and a confirmation time, and either confirms the recommendation or carries an override reason.
create function ref.check_h17(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((
    select t.confirmed_path is not null and t.confirmed_by is not null and t.confirmed_at is not null
           and (t.confirmed_path = t.recommended_path or nullif(btrim(t.override_reason), '') is not null)
      from app.denial_triage t
     where t.denial_id = p_subject
     order by t.created_at desc, t.denial_triage_id desc
     limit 1), false)
$$;

-- H18 approval.decided (subject = approval_request_id). Tests: status approved, an approver who is not the requester,
-- and the approver's highest limit for the kind covers the amount (re-checked here, independent of the trigger).
create function ref.check_h18(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((
    select a.status = 'approved'
           and a.approver_id is not null and a.approver_id <> a.requester_id
           and a.amount <= coalesce(app.approver_limit(a.tenant_id, a.approver_id, a.kind), -1)
      from app.approval_request a
     where a.approval_request_id = p_subject), false)
$$;

-- H19 payment.posted (subject = claim_id). Tests: the claim has service lines and every line has a zero payer-side
-- open amount in api.line_balance (billed = paid + adjusted + patient_share), i.e. what the primary and secondary
-- payers will not pay is already adjusted or moved to the patient. Approximation: payer sequencing is not modelled
-- beyond the line balances, so "secondary finished" is inferred from the lines having nothing left open.
create function ref.check_h19(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from app.claim_service_line l where l.claim_id = p_subject)
     and not exists (select 1 from api.line_balance lb where lb.claim_id = p_subject and lb.open_amount <> 0)
$$;

-- H20 deposit.allocated (subject = deposit_id, remittance_id or edi_interchange_id). Tests:
--   deposit      : the deposit exists and its net allocation (reversals netted) is positive;
--   remittance / interchange : its (payer, trace number) has a deposit, found either by bank_reference = trace number
--                  or by a deposit with a net-positive allocation to a remittance (or one of its lines) of that trace.
create function ref.check_h20(p_subject uuid) returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if exists (select 1 from app.deposit d where d.deposit_id = p_subject) then
    return coalesce((select sum(a.amount) from app.deposit_allocation a where a.deposit_id = p_subject), 0) > 0;
  end if;
  return exists (
    select 1
      from (select r.tenant_id, r.payer_id, r.trace_number from app.remittance r where r.remittance_id = p_subject
            union all
            select x.tenant_id, x.payer_id, x.trace_number from app.edi_interchange x where x.edi_interchange_id = p_subject) s
      join app.deposit d on d.tenant_id = s.tenant_id and (d.payer_id is null or d.payer_id = s.payer_id)
     where d.bank_reference = s.trace_number
        or (select coalesce(sum(a.amount), 0)
              from app.deposit_allocation a
              left join app.remittance_line rl on rl.remittance_line_id = a.remittance_line_id
              join app.remittance r2 on r2.remittance_id = coalesce(a.remittance_id, rl.remittance_id)
             where a.deposit_id = d.deposit_id
               and r2.tenant_id = s.tenant_id and r2.payer_id = s.payer_id and r2.trace_number = s.trace_number) > 0);
end;
$$;

-- H21 case.closure_evaluated (subject = case_id). Tests: the case exists and api.case_blockers returns no row for it.
create function ref.check_h21(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from app."case" c where c.case_id = p_subject)
     and not exists (select 1 from api.case_blockers b where b.case_id = p_subject)
$$;

-- H22 rule.published (subject = rule_id or rule_pack_id). Tests: a rule has approved_by and approved_at; a pack has at
-- least one rule and all of its rules are approved. (The approval itself is the owner's decision; who may approve is
-- enforced by the publishing command, Task 7.)
create function ref.check_h22(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from app.rule r where r.rule_id = p_subject) then
      exists (select 1 from app.rule r where r.rule_id = p_subject and r.approved_by is not null and r.approved_at is not null)
    when exists (select 1 from app.rule_pack p where p.rule_pack_id = p_subject) then
      exists (select 1 from app.rule r where r.rule_pack_id = p_subject)
      and not exists (select 1 from app.rule r where r.rule_pack_id = p_subject and r.approved_by is null)
    else false end
$$;

-- H23 authorization.requested. The handover is inactive in release 1: there is no authorization_request table, so
-- there is no clinical data to test. The check always returns false; it is never called while the handover is inactive.
create function ref.check_h23(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select false
$$;

-- H24 eligibility.response_received (subject = eligibility_response_id or eligibility_request_id). Tests: a response
-- exists (for the request) whose coverage_status was parsed (active or inactive, not unknown).
create function ref.check_h24(p_subject uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from app.eligibility_response r
     where (r.eligibility_response_id = p_subject or r.eligibility_request_id = p_subject)
       and r.coverage_status <> 'unknown')
$$;

-- ================================================================ the handover engine
-- Processes unprocessed outbox events. For each event, for each ACTIVE handover_def whose trigger_event matches:
-- run ref.check_<id>(subject); write one handover_event (passed | held | failed_check); on held / failed_check also
-- write exactly one task in the named queue (queue created on first use per tenant).
-- Subject = payload.subject_id when it names one, else the event's aggregate_id.
-- Idempotent (IV27): unique(handover_id, subject_id, source_event_id) + ON CONFLICT DO NOTHING; the task is only
-- inserted when the handover_event row was.
-- Concurrency: rows are taken FOR UPDATE SKIP LOCKED in batches, so two runs never process the same event; an event
-- is only taken when no earlier unprocessed event of the same aggregate exists, so per-aggregate order holds across
-- runs and later events of an aggregate wait for the next batch.
create function app.process_outbox() returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  c_batch   constant integer := 100;
  c_batches constant integer := 50;
  v_total   integer := 0;
  v_n       integer;
  v_pass    integer;
  e         record;
  h         record;
  v_subject uuid;
  v_ok      boolean;
  v_status  text;
  v_detail  text;
  v_he      uuid;
  v_queue   uuid;
begin
  for v_pass in 1 .. c_batches loop
    v_n := 0;
    for e in
      select o.event_id, o.tenant_id, o.type, o.aggregate_id, o.payload
        from audit.outbox_event o
       where o.processed_at is null
         and not exists (select 1 from audit.outbox_event p
                          where p.aggregate_id = o.aggregate_id and p.processed_at is null and p.seq < o.seq)
       order by o.seq
       limit c_batch
         for update of o skip locked
    loop
      v_n := v_n + 1;
      v_subject := coalesce(
        case when e.payload ->> 'subject_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             then (e.payload ->> 'subject_id')::uuid end,
        e.aggregate_id);

      if v_subject is not null then
        for h in select d.handover_id, d.hold_queue, d.ready_check
                   from ref.handover_def d
                  where d.active and d.trigger_event = e.type
                  order by d.handover_id
        loop
          v_detail := null;
          begin
            execute format('select ref.%I($1)', 'check_' || lower(h.handover_id)) into v_ok using v_subject;
            v_status := case when coalesce(v_ok, false) then 'passed' else 'held' end;
          exception when others then
            v_status := 'failed_check';
            v_detail := left(sqlerrm, 500);
          end;

          v_he := null;
          insert into app.handover_event (tenant_id, handover_id, subject_id, source_event_id, status, detail, checked_at)
          values (e.tenant_id, h.handover_id, v_subject, e.event_id, v_status, v_detail, clock_timestamp())
          on conflict (handover_id, subject_id, source_event_id) do nothing
          returning handover_event_id into v_he;

          if v_he is not null and v_status <> 'passed' then
            insert into app.work_queue (tenant_id, name) values (e.tenant_id, h.hold_queue)
            on conflict (tenant_id, name) do nothing;
            select q.work_queue_id into v_queue
              from app.work_queue q where q.tenant_id = e.tenant_id and q.name = h.hold_queue;
            insert into app.task (tenant_id, queue_id, subject_type, subject_id, status, title, source_handover_event_id)
            values (e.tenant_id, v_queue, split_part(e.type, '.', 1), v_subject, 'open',
                    format('%s %s: %s', h.handover_id,
                           case when v_status = 'held' then 'held' else 'check could not run' end, h.ready_check),
                    v_he);
          end if;
        end loop;
      end if;

      update audit.outbox_event o set processed_at = clock_timestamp() where o.event_id = e.event_id;
    end loop;

    v_total := v_total + v_n;
    exit when v_n = 0;
  end loop;
  return v_total;
end;
$$;

-- ================================================================ RLS (SELECT only; tenant staff)
alter table app.work_queue       enable row level security;
alter table app.task             enable row level security;
alter table app.approval_request enable row level security;
alter table app.handover_event   enable row level security;
alter table app.rule_pack        enable row level security;
alter table app.rule             enable row level security;
alter table app.ai_model_version enable row level security;
alter table app.ai_interaction   enable row level security;
alter table app.ai_review        enable row level security;

do $$
declare t text;
begin
  foreach t in array array['work_queue','task','approval_request','handover_event','rule_pack','rule',
                           'ai_model_version','ai_interaction','ai_review']
  loop
    execute format('create policy tenant_staff_select on app.%I for select to authenticated using (app.in_scope(tenant_id))', t);
  end loop;
end $$;

-- ================================================================ grants
revoke all on all tables in schema app, audit from public, anon, authenticated;
grant select on all tables in schema app, audit to authenticated;

revoke all on function app.approver_limit(uuid, uuid, text) from public, anon, authenticated;
revoke all on function app.approval_request_guard() from public, anon, authenticated;
revoke all on function app.claim_has_failed_hard_edit(uuid) from public, anon, authenticated;
revoke all on function app.process_outbox() from public, anon, authenticated;
revoke all on function ref.check_h13(uuid) from public, anon, authenticated;
revoke all on function ref.check_h14(uuid) from public, anon, authenticated;
revoke all on function ref.check_h15(uuid) from public, anon, authenticated;
revoke all on function ref.check_h16(uuid) from public, anon, authenticated;
revoke all on function ref.check_h17(uuid) from public, anon, authenticated;
revoke all on function ref.check_h18(uuid) from public, anon, authenticated;
revoke all on function ref.check_h19(uuid) from public, anon, authenticated;
revoke all on function ref.check_h20(uuid) from public, anon, authenticated;
revoke all on function ref.check_h21(uuid) from public, anon, authenticated;
revoke all on function ref.check_h22(uuid) from public, anon, authenticated;
revoke all on function ref.check_h23(uuid) from public, anon, authenticated;
revoke all on function ref.check_h24(uuid) from public, anon, authenticated;

-- ================================================================ schedule
create extension if not exists pg_cron;
select cron.schedule('process_outbox_every_minute', '* * * * *', 'select app.process_outbox()');
