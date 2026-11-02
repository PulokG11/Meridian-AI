-- 005a_money_fixes: Task 4 review fix round 1 (004_money_case stays as applied).
--  1. IV01 under concurrency: posting_validate locks the parent service line FOR UPDATE, so postings and
--     balance-marking on one line serialise. The balance check (BEFORE INSERT/UPDATE on claim_service_line)
--     already runs under the UPDATE's row lock; in READ COMMITTED each statement inside the plpgsql trigger takes
--     a fresh snapshot, so after waiting for the lock its read of api.line_balance sees the committed postings.
--  2. Patient side: patient_payment gets kind ('payment' | 'writeoff') and approval_request_id (required for a
--     write-off; FK added by Task 5 when app.approval_request exists). api.line_balance gains patient_writeoff,
--     patient_open (= patient_share - patient_paid - patient_writeoff) and deposit_allocated; patient_paid now
--     counts kind = 'payment' only. 'Patient balance is open' fires on patient_open > 0 for any case line
--     (or, as before, on a responsibility row not covered by payments + write-offs).
--  3. D6 cash: 'Cash is not reconciled yet' also fires when a case line's net payer cash (line_balance.paid)
--     differs from the net deposit allocation on that line. For that netting to hold, an allocation reversal
--     must carry exactly the reversed row's targets (remittance_id, remittance_line_id, line_id).

-- ================================================================ 1. lock the line before a posting
create or replace function app.posting_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_line_tenant uuid;
  o app.payment_posting;
begin
  -- Lock the parent line first: postings and balance-marking on the same line run one after another (IV01).
  select l.tenant_id into v_line_tenant from app.claim_service_line l where l.claim_service_line_id = new.line_id for update;
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
revoke all on function app.posting_validate() from public, anon, authenticated;

-- ================================================================ 3. allocation reversal keeps its targets
create or replace function app.allocation_validate() returns trigger
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
    if new.remittance_id is distinct from o.remittance_id
       or new.remittance_line_id is distinct from o.remittance_line_id
       or new.line_id is distinct from o.line_id then
      perform app.refuse('MR005', 'allocation_reversal_target', 'deposit_allocation',
        'A reversal must name the same remittance, remittance line and service line as the allocation it reverses');
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
revoke all on function app.allocation_validate() from public, anon, authenticated;

-- ================================================================ 2. patient payment kinds
alter table app.patient_payment
  add column kind text not null default 'payment' check (kind in ('payment','writeoff')),
  add column approval_request_id uuid,   -- FK to app.approval_request added in Task 5
  add constraint patient_payment_writeoff_approved check (kind <> 'writeoff' or approval_request_id is not null);
create index patient_payment_approval_idx on app.patient_payment (approval_request_id);

-- ================================================================ views (columns appended; security_invoker kept)
create or replace view api.line_balance with (security_invoker = true) as
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
       l.balanced,
       coalesce(pt.patient_writeoff, 0)::numeric(12,2)                                   as patient_writeoff,
       (coalesce(po.patient_share, 0) - coalesce(pt.patient_paid, 0) - coalesce(pt.patient_writeoff, 0))::numeric(12,2)
                                                                                         as patient_open,
       coalesce(al.deposit_allocated, 0)::numeric(12,2)                                  as deposit_allocated
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
    select sum(pp.amount) filter (where pp.kind = 'payment')  as patient_paid,
           sum(pp.amount) filter (where pp.kind = 'writeoff') as patient_writeoff
      from app.patient_responsibility r
      join app.patient_payment pp on pp.patient_responsibility_id = r.patient_responsibility_id
     where r.line_id = l.claim_service_line_id
  ) pt on true
  left join lateral (
    select sum(x.amount) as deposit_allocated
      from (select a.amount
              from app.deposit_allocation a
             where a.line_id = l.claim_service_line_id
            union all
            select a.amount
              from app.remittance_line rl
              join app.deposit_allocation a on a.remittance_line_id = rl.remittance_line_id
             where rl.line_id = l.claim_service_line_id and a.line_id is null) x
  ) al on true;

comment on view api.line_balance is
$c$Per service line money position (one row per app.claim_service_line). Task 8 depends on this definition.
Payer side. All app.payment_posting.amount values are > 0; the sign comes from kind:
  paid          = sum(payment) - sum(recoupment) - sum(reversal of a payment) + sum(reversal of a recoupment)
                  (a recoupment is a negative payment; this is the line's net payer cash)
  adjusted      = sum(adjustment) - sum(reversal of an adjustment)
                  (contractual/other adjustments reduce the open amount)
  patient_share = sum(patient_share) - sum(reversal of a patient_share)
  A reversal row (kind = 'reversal') carries reverses_posting_id, repeats the reversed row's amount, and is counted
  with the opposite sign in the reversed row's bucket, so the pair nets to zero.
  open_amount   = billed - paid - adjusted - patient_share (payer-side open amount; 0 means the line balances, IV01)
Patient side (app.patient_payment rows reach the line through app.patient_responsibility.line_id):
  patient_paid     = sum(patient_payment.amount) where kind = 'payment'
  patient_writeoff = sum(patient_payment.amount) where kind = 'writeoff' (each write-off row needs an approval_request_id)
  patient_open     = patient_share - patient_paid - patient_writeoff (> 0 means the patient still owes on this line)
Cash side:
  deposit_allocated = sum(app.deposit_allocation.amount) allocated to this line, either directly (line_id) or through
                      a remittance line of this line (remittance_line_id, when line_id is null); reversal rows are
                      negative and carry the reversed row's targets, so they net out. Remittance-level allocations
                      (remittance_id only) are not attributed to a line.
Columns 1-7 are the Task 4 interface; claim_id, tenant_id, balanced, patient_writeoff, patient_open,
deposit_allocated follow. security_invoker: RLS of the caller applies.$c$;

create or replace view api.case_blockers with (security_invoker = true) as
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
                where cc.case_id = c.case_id
                  and (lb.open_amount <> 0 or not lb.balanced or lb.paid <> lb.deposit_allocated))
union all
select c.case_id, 'Patient balance is open'::text
  from app."case" c
 where exists (select 1 from app.case_claim cc
                 join api.line_balance lb on lb.claim_id = cc.claim_id
                where cc.case_id = c.case_id and lb.patient_open > 0)
    or exists (select 1 from app.case_claim cc
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
  'Cash is not reconciled yet'    any line of the case's claims with api.line_balance.open_amount <> 0, balanced = false,
                                  or net payer cash (paid) <> net deposit allocation on the line (deposit_allocated), D6
  'Patient balance is open'       any line of the case's claims with patient_open > 0 (patient_share - patient_paid -
                                  patient_writeoff), or any patient_responsibility on its claims whose amount exceeds its
                                  patient payments plus write-offs
  'Open patient dispute'          a patient_dispute with status 'open' linked to the case, one of its claims, or their responsibilities
  'Deposit allocation difference' a deposit with an allocation to the case (line, remittance line or remittance of its claims)
                                  whose allocations do not add up to the deposit amount
security_invoker: RLS of the caller applies.$c$;

-- grants are kept by CREATE OR REPLACE VIEW; restated for clarity
revoke all on api.line_balance, api.case_blockers from public, anon, authenticated;
grant select on api.line_balance, api.case_blockers to authenticated;
