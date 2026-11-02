-- 005a_money_fixes down: restore the 004_money_case definitions of the two views, posting_validate and
-- allocation_validate, and remove patient_payment.kind / approval_request_id.
-- The views are dropped and recreated (CREATE OR REPLACE cannot remove the appended columns).

drop view if exists api.case_blockers;
drop view if exists api.line_balance;

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

revoke all on api.line_balance, api.case_blockers from public, anon, authenticated;
grant select on api.line_balance, api.case_blockers to authenticated;

drop index if exists app.patient_payment_approval_idx;
alter table app.patient_payment
  drop constraint if exists patient_payment_writeoff_approved,
  drop column if exists approval_request_id,
  drop column if exists kind;

create or replace function app.posting_validate() returns trigger
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
revoke all on function app.posting_validate() from public, anon, authenticated;

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
