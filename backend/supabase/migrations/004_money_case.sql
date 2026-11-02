-- 004_money_case: claims, payments & recovery, patient billing and case tables (27 tables), money invariants
-- (IV01 line balance, IV04 append-only, IV06 allocation <= deposit, IV10 replacement <> original),
-- state-machine triggers, case status history, views api.line_balance and api.case_blockers, party-scoped RLS.
-- All data synthetic. Client roles get SELECT only; every write goes through SECURITY DEFINER api.cmd_* (Tasks 6-8).

-- ---------------------------------------------------------------- Task 1 helper: run state checks as owner
-- enforce_transition reads ref.state_transition (not visible to client roles) and calls app.refuse; as a definer
-- function it behaves the same whether the UPDATE comes from a definer command, the owner, or any other role.
alter function app.enforce_transition() security definer;

-- ================================================================ claims
create table app.claim (
  claim_id          uuid primary key default app.uuid_v7(),
  tenant_id         uuid not null references app.tenant (tenant_id),
  claim_number      text not null,
  patient_id        uuid not null references app.patient (patient_id),
  provider_id       uuid references app.provider (provider_id),
  payer_id          uuid not null references app.payer (payer_id),
  coverage_id       uuid references app.coverage (coverage_id),
  original_claim_id uuid references app.claim (claim_id),
  frequency_code    text not null default '1' check (frequency_code in ('1','7','8')),  -- original, replacement, void
  status            text not null default 'draft'
                    check (status in ('draft','ready','submitted','accepted','rejected','paid','partially_paid','denied')),
  hold              boolean not null default false,   -- bill hold (IV11: no release while held)
  hold_reason       text,
  service_from      date,
  service_to        date,
  submitted_at      timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  unique (tenant_id, claim_number),
  constraint claim_not_own_replacement check (original_claim_id is null or original_claim_id <> claim_id),   -- IV10
  constraint claim_replacement_has_original check (frequency_code = '1' or original_claim_id is not null),
  constraint claim_hold_has_reason check (not hold or hold_reason is not null),
  check (service_to is null or service_from is null or service_to >= service_from)
);

create table app.claim_service_line (
  claim_service_line_id uuid primary key default app.uuid_v7(),
  tenant_id      uuid not null references app.tenant (tenant_id),
  claim_id       uuid not null references app.claim (claim_id),
  line_number    integer not null check (line_number between 1 and 999),
  procedure_code text not null,
  modifiers      text[] not null default '{}',
  units          numeric(8,2) not null default 1 check (units > 0),
  billed         numeric(12,2) not null check (billed >= 0),
  service_date   date,
  balanced       boolean not null default false,     -- IV01: true only when billed = paid + adjusted + patient_share
  balanced_at    timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  unique (claim_id, line_number),
  unique (claim_service_line_id, claim_id)            -- target of (line_id, claim_id) FKs: a line must belong to the row's claim
);

create table app.claim_diagnosis (
  claim_diagnosis_id uuid primary key default app.uuid_v7(),
  tenant_id  uuid not null references app.tenant (tenant_id),
  claim_id   uuid not null references app.claim (claim_id),
  sequence   integer not null check (sequence between 1 and 12),
  icd10_code text not null,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (claim_id, sequence)
);

create table app.claim_edit_result (
  claim_edit_result_id uuid primary key default app.uuid_v7(),
  tenant_id  uuid not null references app.tenant (tenant_id),
  claim_id   uuid not null references app.claim (claim_id),
  line_id    uuid,
  rule_code  text not null,
  severity   text not null check (severity in ('hard','soft')),   -- IV12: no release with a failed hard edit
  passed     boolean not null,
  message    text,
  checked_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  foreign key (line_id, claim_id) references app.claim_service_line (claim_service_line_id, claim_id)
);

create table app.edi_interchange (
  edi_interchange_id uuid primary key default app.uuid_v7(),
  tenant_id        uuid not null references app.tenant (tenant_id),
  clearinghouse_id uuid references app.clearinghouse (clearinghouse_id),
  payer_id         uuid not null references app.payer (payer_id),
  direction        text not null check (direction in ('inbound','outbound')),
  transaction_set  text not null check (transaction_set in ('837','835','999','277CA')),
  trace_number     text not null,
  control_number   text,
  status           text not null default 'received' check (status in ('queued','sent','received','accepted','rejected','processed')),
  exchanged_at     timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint edi_interchange_trace_unique unique (tenant_id, payer_id, trace_number)   -- duplicate 835 detection (IV37)
);

create table app.claim_ack (
  claim_ack_id       uuid primary key default app.uuid_v7(),
  tenant_id          uuid not null references app.tenant (tenant_id),
  edi_interchange_id uuid not null references app.edi_interchange (edi_interchange_id),
  claim_id           uuid not null references app.claim (claim_id),
  ack_type           text not null check (ack_type in ('999','277CA')),
  status             text not null check (status in ('accepted','accepted_with_errors','rejected')),
  message            text,
  received_at        timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid
);

-- ================================================================ payments & recovery
create table app.remittance (
  remittance_id      uuid primary key default app.uuid_v7(),
  tenant_id          uuid not null references app.tenant (tenant_id),
  payer_id           uuid not null references app.payer (payer_id),
  edi_interchange_id uuid references app.edi_interchange (edi_interchange_id),
  trace_number       text not null,
  payment_method     text not null default 'eft' check (payment_method in ('eft','check','virtual_card','non_payment')),
  payment_amount     numeric(12,2) not null check (payment_amount >= 0),   -- control total
  paid_date          date,
  status             text not null default 'received' check (status in ('received','posted','rejected')),
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  unique (tenant_id, payer_id, trace_number)
);

create table app.remittance_line (
  remittance_line_id uuid primary key default app.uuid_v7(),
  tenant_id     uuid not null references app.tenant (tenant_id),
  remittance_id uuid not null references app.remittance (remittance_id),
  claim_id      uuid references app.claim (claim_id),
  line_id       uuid,
  billed        numeric(12,2) check (billed >= 0),
  paid          numeric(12,2) not null default 0,          -- as reported on the 835 (may be negative on a payer reversal)
  adjusted      numeric(12,2) not null default 0,
  patient_share numeric(12,2) not null default 0 check (patient_share >= 0),
  group_code    text check (group_code in ('CO','PR','OA','PI','CR')),
  carc          text,
  rarc          text,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  check (line_id is null or claim_id is not null),
  foreign key (line_id, claim_id) references app.claim_service_line (claim_service_line_id, claim_id)
);

-- Append-only (IV04). kind / amount sign convention (see api.line_balance):
--   amount is always > 0; recoupment is a payment taken back; a reversal repeats the reversed row's amount,
--   carries reverses_posting_id, and nets the original out of its bucket.
create table app.payment_posting (
  payment_posting_id  uuid primary key default app.uuid_v7(),
  tenant_id           uuid not null references app.tenant (tenant_id),
  line_id             uuid not null references app.claim_service_line (claim_service_line_id),
  remittance_line_id  uuid references app.remittance_line (remittance_line_id),
  kind                text not null check (kind in ('payment','adjustment','patient_share','recoupment','reversal')),
  amount              numeric(12,2) not null check (amount > 0),
  reverses_posting_id uuid references app.payment_posting (payment_posting_id),
  reason              text,
  posted_at           timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint payment_posting_reversal_link check ((kind = 'reversal') = (reverses_posting_id is not null))
);

create table app.deposit (
  deposit_id     uuid primary key default app.uuid_v7(),
  tenant_id      uuid not null references app.tenant (tenant_id),
  payer_id       uuid references app.payer (payer_id),
  bank_reference text not null,
  amount         numeric(12,2) not null check (amount > 0),
  deposit_date   date not null default current_date,
  status         text not null default 'open' check (status in ('open','reconciled')),
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  unique (tenant_id, bank_reference)
);

-- Append-only (IV04); total per deposit <= deposit.amount (IV06). A correction is a negative row that
-- reverses one earlier allocation (reverses_allocation_id) for exactly its amount.
create table app.deposit_allocation (
  deposit_allocation_id  uuid primary key default app.uuid_v7(),
  tenant_id              uuid not null references app.tenant (tenant_id),
  deposit_id             uuid not null references app.deposit (deposit_id),
  remittance_id          uuid references app.remittance (remittance_id),
  remittance_line_id     uuid references app.remittance_line (remittance_line_id),
  line_id                uuid references app.claim_service_line (claim_service_line_id),
  amount                 numeric(12,2) not null,
  reverses_allocation_id uuid references app.deposit_allocation (deposit_allocation_id),
  allocated_at           timestamptz not null default now(),
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  updated_by             uuid,
  constraint deposit_allocation_sign check ((reverses_allocation_id is null and amount > 0)
                                         or (reverses_allocation_id is not null and amount < 0)),
  constraint deposit_allocation_target check (remittance_id is not null or remittance_line_id is not null or line_id is not null)
);

create table app.root_cause (
  root_cause_id uuid primary key default app.uuid_v7(),
  tenant_id  uuid not null references app.tenant (tenant_id),
  code       text not null,
  label      text not null,
  category   text not null check (category in ('front_end','coding','clinical','payer','billing','other')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (tenant_id, code)
);

create table app.denial (
  denial_id          uuid primary key default app.uuid_v7(),
  tenant_id          uuid not null references app.tenant (tenant_id),
  claim_id           uuid not null references app.claim (claim_id),
  line_id            uuid,                                       -- null = claim-level denial
  remittance_line_id uuid references app.remittance_line (remittance_line_id),
  status             text not null default 'new'
                     check (status in ('new','triaged','in_correction','in_evidence','in_appeal','in_coverage_update','recovered','written_off')),
  group_code         text check (group_code in ('CO','PR','OA','PI','CR')),
  carc               text,
  rarc               text,
  denied_amount      numeric(12,2) not null default 0 check (denied_amount >= 0),
  root_cause         text,                                       -- root_cause.code of the same tenant
  received_at        timestamptz not null default now(),
  resolved_at        timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  foreign key (line_id, claim_id) references app.claim_service_line (claim_service_line_id, claim_id),
  foreign key (tenant_id, root_cause) references app.root_cause (tenant_id, code)
);

create table app.denial_triage (
  denial_triage_id uuid primary key default app.uuid_v7(),
  tenant_id        uuid not null references app.tenant (tenant_id),
  denial_id        uuid not null references app.denial (denial_id),
  root_cause       text,
  recommended_path text not null check (recommended_path in ('correction','evidence','appeal','coverage_update','write_off')),
  confidence       numeric(4,3) check (confidence between 0 and 1),
  rationale        text,
  ai_generated     boolean not null default false,
  confirmed_path   text check (confirmed_path in ('correction','evidence','appeal','coverage_update','write_off')),
  override_reason  text,
  confirmed_by     uuid references app.app_user (user_id),
  confirmed_at     timestamptz,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint denial_triage_override_reason check (confirmed_path is null or confirmed_path = recommended_path
                                                  or nullif(btrim(override_reason), '') is not null),
  foreign key (tenant_id, root_cause) references app.root_cause (tenant_id, code)
);

create table app.records_request (
  records_request_id uuid primary key default app.uuid_v7(),
  tenant_id       uuid not null references app.tenant (tenant_id),
  claim_id        uuid not null references app.claim (claim_id),
  denial_id       uuid references app.denial (denial_id),
  requested_items text not null,
  status          text not null default 'open' check (status in ('open','responded','closed','expired')),
  requested_at    timestamptz not null default now(),
  due_at          timestamptz,
  responded_at    timestamptz,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid
);

create table app.appeal (
  appeal_id        uuid primary key default app.uuid_v7(),
  tenant_id        uuid not null references app.tenant (tenant_id),
  claim_id         uuid not null references app.claim (claim_id),
  denial_id        uuid not null references app.denial (denial_id),
  parent_appeal_id uuid references app.appeal (appeal_id),     -- previous level
  level            integer not null default 1 check (level between 1 and 5),
  status           text not null default 'drafting' check (status in ('drafting','pending_approval','approved','filed','decided')),
  author_id        uuid not null references app.app_user (user_id),
  approver_id      uuid references app.app_user (user_id),
  amount           numeric(12,2) not null default 0 check (amount >= 0),   -- amount in dispute (approval limit)
  filed_at         timestamptz,
  decided_at       timestamptz,
  decision         text check (decision in ('overturned','upheld','partial')),
  decision_amount  numeric(12,2) check (decision_amount >= 0),
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  check (parent_appeal_id is null or parent_appeal_id <> appeal_id),
  constraint appeal_approver_not_author check (approver_id is null or approver_id <> author_id)   -- IV13
);

create table app.appeal_statement (
  appeal_statement_id uuid primary key default app.uuid_v7(),
  tenant_id   uuid not null references app.tenant (tenant_id),
  appeal_id   uuid not null references app.appeal (appeal_id),
  seq         integer not null check (seq > 0),
  text        text not null,
  source_ref  text,
  unsupported boolean not null default false,                -- IV14: no approval while any statement is unsupported
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  unique (appeal_id, seq),
  constraint appeal_statement_sourced check (source_ref is not null or unsupported)
);

create table app.evidence_item (
  evidence_item_id   uuid primary key default app.uuid_v7(),
  tenant_id          uuid not null references app.tenant (tenant_id),
  claim_id           uuid not null references app.claim (claim_id),
  denial_id          uuid references app.denial (denial_id),
  appeal_id          uuid references app.appeal (appeal_id),
  records_request_id uuid references app.records_request (records_request_id),
  kind               text not null check (kind in ('medical_record','authorization','invoice','correspondence','policy','other')),
  title              text not null,
  storage_ref        text,
  source_ref         text,
  ai_generated       boolean not null default false,
  collected_at       timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid
);

create table app.deadline (
  deadline_id  uuid primary key default app.uuid_v7(),
  tenant_id    uuid not null references app.tenant (tenant_id),
  subject_type text not null check (subject_type in ('claim','denial','appeal','records_request','case','patient_dispute','patient_statement')),
  subject_id   uuid not null,
  kind         text not null check (kind in ('timely_filing','appeal_filing','records_response','payer_decision','dispute_response','statement_due','other')),
  due_at       timestamptz not null,
  met_at       timestamptz,
  note         text,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid
);

-- ================================================================ case
create table app."case" (
  case_id     uuid primary key default app.uuid_v7(),
  tenant_id   uuid not null references app.tenant (tenant_id),
  case_number text not null,
  patient_id  uuid not null references app.patient (patient_id),
  title       text,
  status      text not null default 'open' check (status in ('open','closed')),
  opened_at   timestamptz not null default now(),
  closed_at   timestamptz,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  unique (tenant_id, case_number)
);

create table app.case_claim (
  case_claim_id uuid primary key default app.uuid_v7(),
  tenant_id  uuid not null references app.tenant (tenant_id),
  case_id    uuid not null references app."case" (case_id),
  claim_id   uuid not null references app.claim (claim_id),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (case_id, claim_id)
);

-- Written only by the trigger on app."case" (append-only).
create table app.case_status_history (
  case_status_history_id uuid primary key default app.uuid_v7(),
  tenant_id   uuid not null references app.tenant (tenant_id),
  case_id     uuid not null references app."case" (case_id),
  from_status text,
  to_status   text not null,
  reason      text,
  changed_at  timestamptz not null default clock_timestamp(),
  changed_by  uuid,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

-- What justifies reopening a closed case (IV09); produced by Task 8 commands.
create table app.reopen_event (
  reopen_event_id uuid primary key default app.uuid_v7(),
  tenant_id   uuid not null references app.tenant (tenant_id),
  case_id     uuid not null references app."case" (case_id),
  trigger     text not null check (trigger in ('recoupment','late_payment','payer_correction','appeal_decision','patient_dispute','other')),
  source_type text,
  source_id   uuid,
  reason      text not null,
  occurred_at timestamptz not null default now(),
  consumed_at timestamptz,               -- set when a reopen used this event
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

-- ================================================================ patient billing
create table app.patient_responsibility (
  patient_responsibility_id uuid primary key default app.uuid_v7(),
  tenant_id  uuid not null references app.tenant (tenant_id),
  patient_id uuid not null references app.patient (patient_id),
  claim_id   uuid not null references app.claim (claim_id),
  line_id    uuid not null,
  amount     numeric(12,2) not null check (amount > 0),
  reason     text not null check (reason in ('deductible','coinsurance','copay','non_covered','other')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  foreign key (line_id, claim_id) references app.claim_service_line (claim_service_line_id, claim_id)
);

create table app.patient_statement (
  patient_statement_id uuid primary key default app.uuid_v7(),
  tenant_id      uuid not null references app.tenant (tenant_id),
  patient_id     uuid not null references app.patient (patient_id),
  statement_date date not null default current_date,
  amount_due     numeric(12,2) not null check (amount_due >= 0),
  due_date       date,
  status         text not null default 'draft' check (status in ('draft','sent','paid','void')),
  sent_at        timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);

create table app.patient_payment (
  patient_payment_id        uuid primary key default app.uuid_v7(),
  tenant_id                 uuid not null references app.tenant (tenant_id),
  patient_id                uuid not null references app.patient (patient_id),
  patient_responsibility_id uuid not null references app.patient_responsibility (patient_responsibility_id),
  patient_statement_id      uuid references app.patient_statement (patient_statement_id),
  amount                    numeric(12,2) not null check (amount > 0),
  method                    text not null check (method in ('card','cash','check','ach','portal','other')),
  reference                 text,
  received_at               timestamptz not null default now(),
  created_at                timestamptz not null default now(),
  created_by                uuid,
  updated_at                timestamptz not null default now(),
  updated_by                uuid
);

create table app.patient_dispute (
  patient_dispute_id        uuid primary key default app.uuid_v7(),
  tenant_id                 uuid not null references app.tenant (tenant_id),
  patient_id                uuid not null references app.patient (patient_id),
  case_id                   uuid references app."case" (case_id),
  claim_id                  uuid references app.claim (claim_id),
  patient_responsibility_id uuid references app.patient_responsibility (patient_responsibility_id),
  status                    text not null default 'open' check (status in ('open','resolved')),
  reason                    text not null,
  resolution                text,
  opened_at                 timestamptz not null default now(),
  resolved_at               timestamptz,
  created_at                timestamptz not null default now(),
  created_by                uuid,
  updated_at                timestamptz not null default now(),
  updated_by                uuid,
  check (case_id is not null or claim_id is not null or patient_responsibility_id is not null)
);

-- ================================================================ indexes (tenant, every FK, lookups)
create index claim_patient_idx               on app.claim (patient_id);
create index claim_provider_idx               on app.claim (provider_id);
create index claim_payer_idx                  on app.claim (payer_id);
create index claim_coverage_idx               on app.claim (coverage_id);
create index claim_original_idx               on app.claim (original_claim_id);
create index claim_service_line_tenant_idx    on app.claim_service_line (tenant_id);
create index claim_diagnosis_tenant_idx       on app.claim_diagnosis (tenant_id);
create index claim_edit_result_tenant_idx     on app.claim_edit_result (tenant_id);
create index claim_edit_result_claim_idx      on app.claim_edit_result (claim_id);
create index claim_edit_result_line_idx       on app.claim_edit_result (line_id, claim_id);
create index edi_interchange_ch_idx           on app.edi_interchange (clearinghouse_id);
create index edi_interchange_payer_idx        on app.edi_interchange (payer_id);
create index claim_ack_tenant_idx             on app.claim_ack (tenant_id);
create index claim_ack_interchange_idx        on app.claim_ack (edi_interchange_id);
create index claim_ack_claim_idx              on app.claim_ack (claim_id);
create index remittance_payer_idx             on app.remittance (payer_id);
create index remittance_interchange_idx       on app.remittance (edi_interchange_id);
create index remittance_line_tenant_idx       on app.remittance_line (tenant_id);
create index remittance_line_remittance_idx   on app.remittance_line (remittance_id);
create index remittance_line_claim_idx        on app.remittance_line (claim_id);
create index remittance_line_line_idx         on app.remittance_line (line_id, claim_id);
create index payment_posting_tenant_idx       on app.payment_posting (tenant_id);
create index payment_posting_line_idx         on app.payment_posting (line_id);
create index payment_posting_rl_idx           on app.payment_posting (remittance_line_id);
create unique index payment_posting_reverses_uq on app.payment_posting (reverses_posting_id);   -- one reversal per posting
create index deposit_payer_idx                on app.deposit (payer_id);
create index deposit_allocation_tenant_idx    on app.deposit_allocation (tenant_id);
create index deposit_allocation_deposit_idx   on app.deposit_allocation (deposit_id);
create index deposit_allocation_rem_idx       on app.deposit_allocation (remittance_id);
create index deposit_allocation_rl_idx        on app.deposit_allocation (remittance_line_id);
create index deposit_allocation_line_idx      on app.deposit_allocation (line_id);
create unique index deposit_allocation_reverses_uq on app.deposit_allocation (reverses_allocation_id);
create index denial_tenant_idx                on app.denial (tenant_id);
create index denial_claim_idx                 on app.denial (claim_id);
create index denial_line_idx                  on app.denial (line_id, claim_id);
create index denial_rl_idx                    on app.denial (remittance_line_id);
create index denial_root_cause_idx            on app.denial (tenant_id, root_cause);
create index denial_triage_tenant_idx         on app.denial_triage (tenant_id, root_cause);
create index denial_triage_denial_idx         on app.denial_triage (denial_id);
create index denial_triage_confirmed_by_idx   on app.denial_triage (confirmed_by);
create index records_request_tenant_idx       on app.records_request (tenant_id);
create index records_request_claim_idx        on app.records_request (claim_id);
create index records_request_denial_idx       on app.records_request (denial_id);
create index appeal_tenant_idx                on app.appeal (tenant_id);
create index appeal_claim_idx                 on app.appeal (claim_id);
create index appeal_denial_idx                on app.appeal (denial_id);
create index appeal_parent_idx                on app.appeal (parent_appeal_id);
create index appeal_author_idx                on app.appeal (author_id);
create index appeal_approver_idx              on app.appeal (approver_id);
create index appeal_statement_tenant_idx      on app.appeal_statement (tenant_id);
create index evidence_item_tenant_idx         on app.evidence_item (tenant_id);
create index evidence_item_claim_idx          on app.evidence_item (claim_id);
create index evidence_item_denial_idx         on app.evidence_item (denial_id);
create index evidence_item_appeal_idx         on app.evidence_item (appeal_id);
create index evidence_item_rr_idx             on app.evidence_item (records_request_id);
create index deadline_tenant_idx              on app.deadline (tenant_id, due_at) where met_at is null;
create index deadline_tenant_all_idx          on app.deadline (tenant_id);
create index deadline_subject_idx             on app.deadline (subject_type, subject_id);
create index case_patient_idx                 on app."case" (patient_id);
create index case_claim_tenant_idx            on app.case_claim (tenant_id);
create index case_claim_claim_idx             on app.case_claim (claim_id);
create index case_status_history_tenant_idx   on app.case_status_history (tenant_id);
create index case_status_history_case_idx     on app.case_status_history (case_id, changed_at);
create index reopen_event_tenant_idx          on app.reopen_event (tenant_id);
create index reopen_event_case_idx            on app.reopen_event (case_id);
create index patient_responsibility_tenant_idx  on app.patient_responsibility (tenant_id);
create index patient_responsibility_patient_idx on app.patient_responsibility (patient_id);
create index patient_responsibility_claim_idx   on app.patient_responsibility (claim_id);
create index patient_responsibility_line_idx    on app.patient_responsibility (line_id, claim_id);
create index patient_statement_tenant_idx     on app.patient_statement (tenant_id);
create index patient_statement_patient_idx    on app.patient_statement (patient_id);
create index patient_payment_tenant_idx       on app.patient_payment (tenant_id);
create index patient_payment_patient_idx      on app.patient_payment (patient_id);
create index patient_payment_resp_idx         on app.patient_payment (patient_responsibility_id);
create index patient_payment_statement_idx    on app.patient_payment (patient_statement_id);
create index patient_dispute_tenant_idx       on app.patient_dispute (tenant_id);
create index patient_dispute_patient_idx      on app.patient_dispute (patient_id);
create index patient_dispute_case_idx         on app.patient_dispute (case_id);
create index patient_dispute_claim_idx        on app.patient_dispute (claim_id);
create index patient_dispute_resp_idx         on app.patient_dispute (patient_responsibility_id);
-- Covered by a unique constraint leading with the FK column: claim_service_line(claim_id), claim_diagnosis(claim_id),
-- appeal_statement(appeal_id), case_claim(case_id); tenant_id leads the unique keys of claim, edi_interchange,
-- remittance, deposit, root_cause, "case".

-- ================================================================ audit-column trigger
do $$
declare t text;
begin
  foreach t in array array['claim','claim_service_line','claim_diagnosis','claim_edit_result','edi_interchange','claim_ack',
                           'remittance','remittance_line','payment_posting','deposit','deposit_allocation','root_cause','denial',
                           'denial_triage','records_request','appeal','appeal_statement','evidence_item','deadline',
                           'case','case_claim','case_status_history','reopen_event',
                           'patient_responsibility','patient_statement','patient_payment','patient_dispute']
  loop
    execute format('create trigger %I before insert or update on app.%I for each row execute function app.touch()', t || '_touch', t);
  end loop;
end $$;

-- ================================================================ state machines (ref.state_transition, IV39)
create trigger claim_transition  before update on app.claim  for each row execute function app.enforce_transition('claim');
create trigger denial_transition before update on app.denial for each row execute function app.enforce_transition('denial');
create trigger appeal_transition before update on app.appeal for each row execute function app.enforce_transition('appeal');
create trigger case_transition   before update on app."case" for each row execute function app.enforce_transition('case');

-- ================================================================ append-only (IV04)
-- Mirrors audit.no_modify for any table: UPDATE / DELETE / TRUNCATE refused with MR002 append_only.
create function app.append_only() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform app.refuse('MR002', 'append_only', TG_TABLE_NAME,
    format('%s is append-only; record a correction as a new reversing row', TG_TABLE_NAME));
  return null;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['payment_posting','deposit_allocation','case_status_history']
  loop
    execute format('create trigger %I before update or delete on app.%I for each row execute function app.append_only()', t || '_no_modify', t);
    execute format('create trigger %I before truncate on app.%I for each statement execute function app.append_only()', t || '_no_truncate', t);
  end loop;
end $$;

-- ================================================================ posting rules
-- A reversal must point at a non-reversal posting on the same line, of the same tenant and amount, not yet reversed.
create function app.posting_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_line_tenant uuid;
  o app.payment_posting;
begin
  select l.tenant_id into v_line_tenant from app.claim_service_line l where l.claim_service_line_id = new.line_id;
  if v_line_tenant is distinct from new.tenant_id then
    perform app.refuse('MR005', 'tenant_mismatch', 'payment_posting', 'The posting and its service line must belong to the same tenant');
  end if;
  if new.kind = 'reversal' and new.reverses_posting_id is not null then
    select * into o from app.payment_posting p where p.payment_posting_id = new.reverses_posting_id;
    if not found then
      perform app.refuse('MR005', 'reversal_target_missing', 'payment_posting', 'Reverse an existing posting');
    end if;
    if o.kind = 'reversal' then
      perform app.refuse('MR005', 'reversal_of_reversal', 'payment_posting', 'A reversal cannot itself be reversed; post a new row instead');
    end if;
    if o.line_id <> new.line_id or o.tenant_id <> new.tenant_id then
      perform app.refuse('MR005', 'reversal_line_mismatch', 'payment_posting', 'A reversal must be posted to the same line as the posting it reverses');
    end if;
    if o.amount <> new.amount then
      perform app.refuse('MR005', 'reversal_amount_mismatch', 'payment_posting',
        format('A reversal must repeat the reversed amount (%s)', o.amount));
    end if;
    if exists (select 1 from app.payment_posting p where p.reverses_posting_id = o.payment_posting_id) then
      perform app.refuse('MR002', 'already_reversed', 'payment_posting', 'This posting has already been reversed');
    end if;
  end if;
  return new;
end;
$$;

create trigger payment_posting_validate before insert on app.payment_posting
  for each row execute function app.posting_validate();

-- IV01 stays true: a new posting that breaks the balance of a line flagged balanced clears the flag.
create function app.posting_unbalance() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update app.claim_service_line l
     set balanced = false
   where l.claim_service_line_id = new.line_id
     and l.balanced
     and l.billed <> (select lb.paid + lb.adjusted + lb.patient_share from api.line_balance lb where lb.line_id = new.line_id);
  return null;
end;
$$;

create trigger payment_posting_unbalance after insert on app.payment_posting
  for each row execute function app.posting_unbalance();

-- IV01: a line can be (or stay) balanced only while billed = paid + adjusted + patient_share (from api.line_balance).
create function app.line_balance_check() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_paid numeric(12,2);
  v_adj  numeric(12,2);
  v_ps   numeric(12,2);
begin
  if new.balanced and (TG_OP = 'INSERT' or not old.balanced or new.billed is distinct from old.billed) then
    select lb.paid, lb.adjusted, lb.patient_share into v_paid, v_adj, v_ps
      from api.line_balance lb where lb.line_id = new.claim_service_line_id;
    v_paid := coalesce(v_paid, 0); v_adj := coalesce(v_adj, 0); v_ps := coalesce(v_ps, 0);
    if new.billed <> v_paid + v_adj + v_ps then
      perform app.refuse('MR002', 'IV01_line_not_balanced', 'claim_service_line',
        format('Billed %s must equal paid %s + adjusted %s + patient share %s before the line is marked balanced',
               new.billed, v_paid, v_adj, v_ps));
    end if;
  end if;
  if new.balanced then
    if TG_OP = 'INSERT' or not old.balanced then
      new.balanced_at := now();
    end if;
  else
    new.balanced_at := null;
  end if;
  return new;
end;
$$;

create trigger claim_service_line_balance before insert or update on app.claim_service_line
  for each row execute function app.line_balance_check();

-- ================================================================ deposit allocation rules
create function app.allocation_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_dep_tenant uuid;
  o app.deposit_allocation;
begin
  select d.tenant_id into v_dep_tenant from app.deposit d where d.deposit_id = new.deposit_id;
  if v_dep_tenant is distinct from new.tenant_id then
    perform app.refuse('MR005', 'tenant_mismatch', 'deposit_allocation', 'The allocation and its deposit must belong to the same tenant');
  end if;
  if new.reverses_allocation_id is not null then
    select * into o from app.deposit_allocation a where a.deposit_allocation_id = new.reverses_allocation_id;
    if not found or o.reverses_allocation_id is not null or o.deposit_id <> new.deposit_id then
      perform app.refuse('MR005', 'allocation_reversal_target', 'deposit_allocation',
        'Reverse an existing, non-reversal allocation of the same deposit');
    end if;
    if new.amount <> -o.amount then
      perform app.refuse('MR005', 'allocation_reversal_amount', 'deposit_allocation',
        format('A reversal must be exactly -%s', o.amount));
    end if;
    if exists (select 1 from app.deposit_allocation a where a.reverses_allocation_id = o.deposit_allocation_id) then
      perform app.refuse('MR002', 'already_reversed', 'deposit_allocation', 'This allocation has already been reversed');
    end if;
  end if;
  return new;
end;
$$;

create trigger deposit_allocation_validate before insert on app.deposit_allocation
  for each row execute function app.allocation_validate();

-- IV06: after each allocation the deposit's total allocated must not exceed its amount. The deposit row is locked
-- first so concurrent allocations to one deposit are checked one after another.
create function app.allocation_within_deposit() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_amount numeric(12,2);
  v_total  numeric(12,2);
begin
  select d.amount into v_amount from app.deposit d where d.deposit_id = new.deposit_id for update;
  select coalesce(sum(a.amount), 0) into v_total from app.deposit_allocation a where a.deposit_id = new.deposit_id;
  if v_total > v_amount then
    perform app.refuse('MR002', 'IV06_allocation_exceeds_deposit', 'deposit_allocation',
      format('Allocations would total %s but the deposit is %s', v_total, v_amount));
  end if;
  return null;
end;
$$;

create constraint trigger deposit_allocation_within_deposit after insert on app.deposit_allocation
  deferrable initially immediate
  for each row execute function app.allocation_within_deposit();

-- IV06 from the other side: a deposit amount cannot drop below what is already allocated.
create function app.deposit_amount_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_total numeric(12,2);
begin
  if new.amount < old.amount then
    select coalesce(sum(a.amount), 0) into v_total from app.deposit_allocation a where a.deposit_id = new.deposit_id;
    if v_total > new.amount then
      perform app.refuse('MR002', 'IV06_allocation_exceeds_deposit', 'deposit',
        format('The deposit already has %s allocated', v_total));
    end if;
  end if;
  return new;
end;
$$;

create trigger deposit_amount_guard before update of amount on app.deposit
  for each row execute function app.deposit_amount_guard();

-- ================================================================ case status history (cannot be skipped)
-- Every insert and every status change of app."case" writes a row. A command may pass a reason with
-- set_config('app.status_reason', '<text>', true) before the update.
create function app.case_history_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if TG_OP = 'INSERT' or new.status is distinct from old.status then
    insert into app.case_status_history (tenant_id, case_id, from_status, to_status, reason, changed_at, changed_by)
    values (new.tenant_id, new.case_id,
            case when TG_OP = 'UPDATE' then old.status end, new.status,
            nullif(current_setting('app.status_reason', true), ''), clock_timestamp(), auth.uid());
  end if;
  return null;
end;
$$;

create trigger case_status_history_write after insert or update of status on app."case"
  for each row execute function app.case_history_write();

-- ================================================================ views
create view api.line_balance with (security_invoker = true) as
select l.claim_service_line_id                                                           as line_id,
       l.billed,
       coalesce(po.paid, 0)::numeric(12,2)                                               as paid,
       coalesce(po.adjusted, 0)::numeric(12,2)                                           as adjusted,
       coalesce(po.patient_share, 0)::numeric(12,2)                                      as patient_share,
       coalesce(pt.patient_paid, 0)::numeric(12,2)                                       as patient_paid,
       (l.billed - coalesce(po.paid, 0) - coalesce(po.adjusted, 0) - coalesce(po.patient_share, 0))::numeric(12,2)
                                                                                         as open_amount,
       l.claim_id,
       l.tenant_id,
       l.balanced
  from app.claim_service_line l
  left join lateral (
    select sum(e.signed) filter (where e.base_kind in ('payment', 'recoupment')) as paid,
           sum(e.signed) filter (where e.base_kind = 'adjustment')               as adjusted,
           sum(e.signed) filter (where e.base_kind = 'patient_share')            as patient_share
      from (select coalesce(o.kind, p.kind) as base_kind,
                   (case when p.kind = 'reversal' then -1 else 1 end)
                 * (case when coalesce(o.kind, p.kind) = 'recoupment' then -1 else 1 end)
                 * p.amount as signed
              from app.payment_posting p
              left join app.payment_posting o on o.payment_posting_id = p.reverses_posting_id
             where p.line_id = l.claim_service_line_id) e
  ) po on true
  left join lateral (
    select sum(pp.amount) as patient_paid
      from app.patient_responsibility r
      join app.patient_payment pp on pp.patient_responsibility_id = r.patient_responsibility_id
     where r.line_id = l.claim_service_line_id
  ) pt on true;

comment on view api.line_balance is
$c$Per service line money position (one row per app.claim_service_line). Task 8 depends on this definition.
All app.payment_posting.amount values are > 0; the sign comes from kind:
  paid          = sum(payment) - sum(recoupment) - sum(reversal of a payment) + sum(reversal of a recoupment)
                  (a recoupment is a negative payment)
  adjusted      = sum(adjustment) - sum(reversal of an adjustment)
                  (contractual/other adjustments reduce the open amount)
  patient_share = sum(patient_share) - sum(reversal of a patient_share)
  A reversal row (kind = 'reversal') carries reverses_posting_id, repeats the reversed row's amount, and is counted
  with the opposite sign in the reversed row's bucket, so the pair nets to zero.
  patient_paid  = sum(app.patient_payment.amount) over the app.patient_responsibility rows of this line
                  (does not change open_amount; patient collection is tracked against patient_share / responsibility)
  open_amount   = billed - paid - adjusted - patient_share (0 means the line balances, IV01)
Extra columns: claim_id, tenant_id, balanced (the IV01 flag on the line). security_invoker: RLS of the caller applies.$c$;

-- One row per unmet closure condition of a case (D6, IV07/IV08). Empty = the case may close.
create view api.case_blockers with (security_invoker = true) as
with case_deposit as (
  select cc.case_id, a.deposit_id
    from app.deposit_allocation a
    join app.claim_service_line l on l.claim_service_line_id = a.line_id
    join app.case_claim cc on cc.claim_id = l.claim_id
  union
  select cc.case_id, a.deposit_id
    from app.deposit_allocation a
    join app.remittance_line rl on rl.remittance_line_id = a.remittance_line_id
    join app.case_claim cc on cc.claim_id = rl.claim_id
  union
  select cc.case_id, a.deposit_id
    from app.deposit_allocation a
    join app.remittance_line rl on rl.remittance_id = a.remittance_id
    join app.case_claim cc on cc.claim_id = rl.claim_id
)
select c.case_id, 'Cash is not reconciled yet'::text as blocker
  from app."case" c
 where exists (select 1 from app.case_claim cc
                 join api.line_balance lb on lb.claim_id = cc.claim_id
                where cc.case_id = c.case_id and (lb.open_amount <> 0 or not lb.balanced))
union all
select c.case_id, 'Patient balance is open'::text
  from app."case" c
 where exists (select 1 from app.case_claim cc
                 join app.patient_responsibility r on r.claim_id = cc.claim_id
                where cc.case_id = c.case_id
                  and r.amount > coalesce((select sum(pp.amount) from app.patient_payment pp
                                            where pp.patient_responsibility_id = r.patient_responsibility_id), 0))
union all
select c.case_id, 'Open patient dispute'::text
  from app."case" c
 where exists (select 1 from app.patient_dispute d
                where d.status = 'open'
                  and (d.case_id = c.case_id
                       or exists (select 1 from app.case_claim cc where cc.case_id = c.case_id and cc.claim_id = d.claim_id)
                       or exists (select 1 from app.case_claim cc
                                    join app.patient_responsibility r on r.claim_id = cc.claim_id
                                   where cc.case_id = c.case_id and r.patient_responsibility_id = d.patient_responsibility_id)))
union all
select c.case_id, 'Deposit allocation difference'::text
  from app."case" c
 where exists (select 1 from case_deposit cd
                 join app.deposit d on d.deposit_id = cd.deposit_id
                where cd.case_id = c.case_id
                  and d.amount <> (select coalesce(sum(a.amount), 0) from app.deposit_allocation a where a.deposit_id = d.deposit_id));

comment on view api.case_blockers is
$c$One row per unmet closure condition (cmd_case_close refuses unless empty):
  'Cash is not reconciled yet'    any line of the case's claims with api.line_balance.open_amount <> 0 or balanced = false
  'Patient balance is open'       any patient_responsibility on the case's claims whose amount exceeds its patient payments
  'Open patient dispute'          a patient_dispute with status 'open' linked to the case, one of its claims, or their responsibilities
  'Deposit allocation difference' a deposit with an allocation to the case (line, remittance line or remittance of its claims)
                                  whose allocations do not add up to the deposit amount
security_invoker: RLS of the caller applies.$c$;

-- ================================================================ RLS (SELECT only; no write policies)
do $$
declare t text;
begin
  foreach t in array array['claim','claim_service_line','claim_diagnosis','claim_edit_result','edi_interchange','claim_ack',
                           'remittance','remittance_line','payment_posting','deposit','deposit_allocation','root_cause','denial',
                           'denial_triage','records_request','appeal','appeal_statement','evidence_item','deadline',
                           'case','case_claim','case_status_history','reopen_event',
                           'patient_responsibility','patient_statement','patient_payment','patient_dispute']
  loop
    execute format('alter table app.%I enable row level security', t);
  end loop;
  -- tenant staff (provider / platform) only
  foreach t in array array['claim_edit_result','payment_posting','deposit','deposit_allocation','root_cause','denial_triage',
                           'appeal_statement','evidence_item','deadline','case','case_claim','case_status_history','reopen_event']
  loop
    execute format('create policy tenant_staff_select on app.%I for select to authenticated using (app.in_scope(tenant_id))', t);
  end loop;
  -- patient billing: the patient (or an active proxy) and tenant staff
  foreach t in array array['patient_responsibility','patient_statement','patient_payment','patient_dispute']
  loop
    execute format('create policy scope_select on app.%I for select to authenticated using (app.in_scope(tenant_id, null, null, patient_id))', t);
  end loop;
end $$;

-- A payer sees claims addressed to its payer_id once they have left the provider (not draft / ready).
create policy scope_select on app.claim for select to authenticated
  using (app.in_scope(tenant_id, payer_id) and (status not in ('draft', 'ready') or app.in_scope(tenant_id)));
-- Children of a claim are visible exactly when the claim is (the subselect is itself filtered by the claim policy).
create policy scope_select on app.claim_service_line for select to authenticated
  using (exists (select 1 from app.claim c where c.claim_id = claim_service_line.claim_id and c.tenant_id = claim_service_line.tenant_id));
create policy scope_select on app.claim_diagnosis for select to authenticated
  using (exists (select 1 from app.claim c where c.claim_id = claim_diagnosis.claim_id and c.tenant_id = claim_diagnosis.tenant_id));
create policy scope_select on app.denial for select to authenticated
  using (exists (select 1 from app.claim c where c.claim_id = denial.claim_id and c.tenant_id = denial.tenant_id));
create policy scope_select on app.records_request for select to authenticated
  using (exists (select 1 from app.claim c where c.claim_id = records_request.claim_id and c.tenant_id = records_request.tenant_id));
-- A payer sees an appeal of its claim once it is filed (drafts and approvals stay internal).
create policy scope_select on app.appeal for select to authenticated
  using (exists (select 1 from app.claim c where c.claim_id = appeal.claim_id and c.tenant_id = appeal.tenant_id)
         and (status in ('filed', 'decided') or app.in_scope(tenant_id)));
create policy scope_select on app.remittance for select to authenticated
  using (app.in_scope(tenant_id, payer_id));
create policy scope_select on app.remittance_line for select to authenticated
  using (exists (select 1 from app.remittance m where m.remittance_id = remittance_line.remittance_id and m.tenant_id = remittance_line.tenant_id));
-- A clearinghouse sees only interchanges routed through it, and the acks on them.
create policy scope_select on app.edi_interchange for select to authenticated
  using (app.in_scope(tenant_id, null, clearinghouse_id));
create policy scope_select on app.claim_ack for select to authenticated
  using (exists (select 1 from app.edi_interchange x where x.edi_interchange_id = claim_ack.edi_interchange_id and x.tenant_id = claim_ack.tenant_id));

-- ================================================================ grants
revoke all on all tables in schema app from public, anon, authenticated;
grant select on all tables in schema app to authenticated;
revoke all on api.line_balance, api.case_blockers from public, anon, authenticated;
grant select on api.line_balance, api.case_blockers to authenticated;

revoke all on function app.append_only() from public, anon, authenticated;
revoke all on function app.posting_validate() from public, anon, authenticated;
revoke all on function app.posting_unbalance() from public, anon, authenticated;
revoke all on function app.line_balance_check() from public, anon, authenticated;
revoke all on function app.allocation_validate() from public, anon, authenticated;
revoke all on function app.allocation_within_deposit() from public, anon, authenticated;
revoke all on function app.deposit_amount_guard() from public, anon, authenticated;
revoke all on function app.case_history_write() from public, anon, authenticated;
revoke all on function app.enforce_transition() from public, anon, authenticated;
