-- 008_cmd_cash_case: Commands part 3 (cash, patient billing, write-off, case closure). All data synthetic.
-- Reuses the Task 6/7 pipeline and helpers: ctx -> require_portal -> authorize -> validate -> begin_cmd (authorize
-- before begin_cmd) -> scoped loads (MR004) -> guards -> mutate -> finish_cmd. Lock order: service lines before
-- claims/deposits (never deposit then line). Identity always from app.ctx(). Amount shape via app.valid_money /
-- app.valid_amount (MR005); business "exceeds the available amount" checks are a separate MR002 after locking,
-- named like Task 6's IV01_line_overposted for consistency.
--
-- Commands: cmd_posting_apply_payment, cmd_posting_reverse, cmd_deposit_allocate, cmd_patient_payment_apply,
--   cmd_patient_dispute_open, cmd_patient_dispute_resolve, cmd_writeoff_request, cmd_writeoff_post (IV32),
--   cmd_case_close (IV07/IV08), cmd_case_reopen (IV09).
--
-- Change to an earlier object (004/005a stay as applied; done here):
--   app.payment_posting.approval_request_id uuid references app.approval_request -- links a write-off posting to
--   its approval; a partial unique index makes a request postable at most once (mirrors payment_posting_reverses_uq).

alter table app.payment_posting add column approval_request_id uuid references app.approval_request (approval_request_id);
create unique index payment_posting_approval_uq on app.payment_posting (approval_request_id) where approval_request_id is not null;

-- ================================================================ api.cmd_posting_apply_payment
create function api.cmd_posting_apply_payment(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd      constant text := 'posting.apply_payment';
  v_ctx      app.ctx_t;
  v_cached   jsonb;
  v_line_id  uuid;
  v_kind     text;
  v_amt_raw  numeric;
  v_rl_id    uuid;
  v_reason   text;
  v_line     app.claim_service_line;
  v_claim    app.claim;
  v_lb       api.line_balance;
  v_max      numeric;
  v_amt      numeric;
  v_pp       uuid;
  v_case     uuid;
  v_re       uuid;
  v_reopen_ids jsonb := '[]'::jsonb;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('posting.apply_payment');

  v_line_id := app.arg_uuid(p_args, 'line_id');
  v_kind    := app.arg_enum(p_args, 'kind', array['payment','adjustment','patient_share','recoupment']);
  v_amt_raw := app.valid_money(app.arg_numeric(p_args, 'amount'), 'amount');
  v_rl_id   := app.arg_uuid(p_args, 'remittance_line_id', false);
  v_reason  := app.arg_text(p_args, 'reason', false, 500);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_line := jsonb_populate_record(null::app.claim_service_line, app.scoped_row('claim_service_line', v_line_id, true));
  v_claim := jsonb_populate_record(null::app.claim, app.scoped_row('claim', v_line.claim_id));
  if v_claim.status not in ('submitted','accepted','paid','partially_paid','denied') then
    perform app.refuse('MR002', 'claim_not_adjudicable', 'claim',
      format('Claim %s has not been sent to the payer yet (%s); postings only apply after submission', v_claim.claim_number, v_claim.status));
  end if;
  if v_rl_id is not null then
    perform app.scoped_row('remittance_line', v_rl_id);
    if not exists (select 1 from app.remittance_line rl where rl.remittance_line_id = v_rl_id and rl.line_id = v_line.claim_service_line_id) then
      perform app.refuse('MR005', 'remittance_line_mismatch', 'remittance_line', 'The remittance line must belong to this service line');
    end if;
  end if;

  select * into v_lb from api.line_balance lb where lb.line_id = v_line.claim_service_line_id;
  v_max := case v_kind when 'recoupment' then v_lb.paid else v_lb.open_amount end;
  if v_kind = 'recoupment' and coalesce(v_lb.paid, 0) <= 0 then
    perform app.refuse('MR002', 'nothing_to_recoup', 'claim_service_line', 'This line has no payment to recoup');
  end if;
  if v_amt_raw > coalesce(v_max, 0) then
    perform app.refuse('MR002', 'IV01_line_overposted', 'claim_service_line',
      format('%s of %s would exceed the %s available (%s); reverse an earlier posting first',
             v_kind, v_amt_raw, case when v_kind = 'recoupment' then 'amount paid' else 'open amount' end, coalesce(v_max, 0)));
  end if;
  v_amt := v_amt_raw;

  insert into app.payment_posting (tenant_id, line_id, remittance_line_id, kind, amount, reason)
  values (v_ctx.tenant_id, v_line.claim_service_line_id, v_rl_id, v_kind, v_amt, v_reason)
  returning payment_posting_id into v_pp;

  -- IV01: re-mark the line balanced if it now fully balances (the trigger only ever CLEARS the flag on a posting)
  update app.claim_service_line sl set balanced = true
    from api.line_balance lb
   where lb.line_id = sl.claim_service_line_id and sl.claim_service_line_id = v_line.claim_service_line_id
     and not sl.balanced and lb.open_amount = 0;

  -- IV09: a recoupment on a line of a closed case is a reopen trigger (an unconsumed reopen_event; cmd_case_reopen consumes it)
  if v_kind = 'recoupment' then
    for v_case in select c.case_id from app."case" c
                   join app.case_claim cc on cc.case_id = c.case_id
                  where cc.claim_id = v_line.claim_id and c.status = 'closed'
                  order by c.case_id
    loop
      insert into app.reopen_event (tenant_id, case_id, trigger, source_type, source_id, reason)
      values (v_ctx.tenant_id, v_case, 'recoupment', 'payment_posting', v_pp,
              format('Recoupment of %s posted on line %s of claim %s (posting %s)', v_amt, v_line.line_number, v_claim.claim_number, v_pp))
      returning reopen_event_id into v_re;
      v_reopen_ids := v_reopen_ids || to_jsonb(v_re);
    end loop;
  end if;

  -- best-effort: let the handover engine re-check closure readiness for any open case of this claim
  for v_case in select c.case_id from app."case" c
                 join app.case_claim cc on cc.case_id = c.case_id
                where cc.claim_id = v_line.claim_id and c.status = 'open'
  loop
    perform app.emit_event('case.closure_evaluated', v_case, jsonb_build_object('case_id', v_case), c_cmd, p_idem);
  end loop;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('payment_posting_id', v_pp, 'line_id', v_line.claim_service_line_id, 'claim_id', v_claim.claim_id,
                       'kind', v_kind, 'amount', v_amt, 'reopen_event_ids', v_reopen_ids),
    'payment.posted', v_claim.claim_id);
end;
$$;

comment on function api.cmd_posting_apply_payment(text, jsonb) is
$c$posting.apply_payment (portal: provider; permission 'posting.apply_payment'). Posts cash to a line outside a
remittance (manual payment, adjustment, patient share or recoupment).
args: { line_id uuid, kind payment|adjustment|patient_share|recoupment, amount number (2 dp, > 0),
  remittance_line_id uuid (optional; must belong to the line), reason text (optional, <= 500) }
Guards: line and claim in the caller's tenant (MR004, line locked); claim submitted or later (MR002
  claim_not_adjudicable); a recoupment needs something paid to take back (MR002 nothing_to_recoup); the amount does
  not exceed the open amount (payment/adjustment/patient_share) or the amount paid (recoupment), IV01 (MR002
  IV01_line_overposted).
Writes: payment_posting; a recoupment on a line of a closed case also writes an unconsumed reopen_event (IV09; see
  cmd_case_reopen). The posting trigger clears the line's balanced flag if it no longer balances.
result: { payment_posting_id, line_id, claim_id, kind, amount, reopen_event_ids[] }
event: payment.posted (aggregate claim_id; handover H19). Also case.closure_evaluated per open case of the claim.$c$;

-- ================================================================ api.cmd_posting_reverse
create function api.cmd_posting_reverse(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd     constant text := 'posting.reverse';
  v_ctx     app.ctx_t;
  v_cached  jsonb;
  v_orig_id uuid;
  v_reason  text;
  v_orig    app.payment_posting;
  v_claim_id uuid;
  v_rev     uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('posting.reverse');

  v_orig_id := app.arg_uuid(p_args, 'payment_posting_id');
  v_reason  := app.arg_text(p_args, 'reason', false, 500);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_orig := jsonb_populate_record(null::app.payment_posting, app.scoped_row('payment_posting', v_orig_id));
  if v_orig.kind = 'reversal' then
    perform app.refuse('MR005', 'reversal_of_reversal', 'payment_posting', 'A reversal cannot itself be reversed; post a new row instead');
  end if;
  -- lock order: the line before the (append-only) posting; posting_validate re-checks already_reversed under the lock
  perform app.scoped_row('claim_service_line', v_orig.line_id, true);
  select sl.claim_id into v_claim_id from app.claim_service_line sl where sl.claim_service_line_id = v_orig.line_id;

  insert into app.payment_posting (tenant_id, line_id, remittance_line_id, kind, amount, reverses_posting_id, reason)
  values (v_ctx.tenant_id, v_orig.line_id, v_orig.remittance_line_id, 'reversal', v_orig.amount, v_orig.payment_posting_id, v_reason)
  returning payment_posting_id into v_rev;

  -- IV01: a reversal can also bring a line back into balance (for example reversing an offsetting duplicate)
  update app.claim_service_line sl set balanced = true
    from api.line_balance lb
   where lb.line_id = sl.claim_service_line_id and sl.claim_service_line_id = v_orig.line_id
     and not sl.balanced and lb.open_amount = 0;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('payment_posting_id', v_rev, 'reverses_posting_id', v_orig.payment_posting_id,
                       'line_id', v_orig.line_id, 'claim_id', v_claim_id, 'amount', v_orig.amount),
    'payment.reversed', v_claim_id);
end;
$$;

comment on function api.cmd_posting_reverse(text, jsonb) is
$c$posting.reverse (portal: provider; permission 'posting.reverse'). Reverses an earlier posting (IV04 correction).
args: { payment_posting_id uuid, reason text (optional, <= 500) }
Guards: posting in the caller's tenant (MR004); not itself a reversal (MR005); the line is locked first, so
  posting_validate's same-tenant / same-line / same-amount / not-already-reversed checks run under the lock.
Writes: a payment_posting row (kind reversal, same amount, reverses_posting_id); the trigger clears the line's
  balanced flag if it no longer balances.
result: { payment_posting_id, reverses_posting_id, line_id, claim_id, amount }
event: payment.reversed (aggregate claim_id).$c$;

-- ================================================================ api.cmd_deposit_allocate
create function api.cmd_deposit_allocate(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'deposit.allocate';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_dep_id uuid;
  v_rem_id uuid;
  v_rl_id  uuid;
  v_line_id uuid;
  v_amt_raw numeric;
  v_dep    app.deposit;
  v_da     uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('deposit.allocate');

  v_dep_id  := app.arg_uuid(p_args, 'deposit_id');
  v_rem_id  := app.arg_uuid(p_args, 'remittance_id', false);
  v_rl_id   := app.arg_uuid(p_args, 'remittance_line_id', false);
  v_line_id := app.arg_uuid(p_args, 'line_id', false);
  v_amt_raw := app.valid_money(app.arg_numeric(p_args, 'amount'), 'amount');
  if v_rem_id is null and v_rl_id is null and v_line_id is null then
    perform app.refuse('MR005', 'allocation_target_required', 'deposit_allocation',
      'Name a remittance, remittance line or service line to allocate against');
  end if;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  -- lock order: the service line (if any), then the deposit; never deposit then line
  if v_line_id is not null then
    perform app.scoped_row('claim_service_line', v_line_id, true);
  end if;
  v_dep := jsonb_populate_record(null::app.deposit, app.scoped_row('deposit', v_dep_id, true));
  if v_rem_id is not null then
    perform app.scoped_row('remittance', v_rem_id);
  end if;
  if v_rl_id is not null then
    perform app.scoped_row('remittance_line', v_rl_id);
  end if;

  insert into app.deposit_allocation (tenant_id, deposit_id, remittance_id, remittance_line_id, line_id, amount)
  values (v_ctx.tenant_id, v_dep.deposit_id, v_rem_id, v_rl_id, v_line_id, v_amt_raw)
  returning deposit_allocation_id into v_da;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('deposit_allocation_id', v_da, 'deposit_id', v_dep.deposit_id, 'remittance_id', v_rem_id,
                       'remittance_line_id', v_rl_id, 'line_id', v_line_id, 'amount', v_amt_raw),
    'deposit.allocated', v_dep.deposit_id);
end;
$$;

comment on function api.cmd_deposit_allocate(text, jsonb) is
$c$deposit.allocate (portal: provider; permission 'deposit.allocate'). Allocates part of a bank deposit to a
remittance, remittance line or service line.
args: { deposit_id uuid, remittance_id uuid (optional), remittance_line_id uuid (optional), line_id uuid (optional;
  at least one of the three required), amount number (2 dp, > 0) }
Guards: deposit and any named target in the caller's tenant (MR004); the line (if named) is locked before the
  deposit. The deposit_allocation_within_deposit constraint trigger refuses a total over the deposit, IV06 (MR002
  IV06_allocation_exceeds_deposit).
Writes: deposit_allocation.
result: { deposit_allocation_id, deposit_id, remittance_id, remittance_line_id, line_id, amount }
event: deposit.allocated (aggregate deposit_id; handover H20).$c$;

-- ================================================================ api.cmd_patient_payment_apply
create function api.cmd_patient_payment_apply(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'patient_payment.apply';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_resp_id uuid;
  v_amt_raw numeric;
  v_method text;
  v_ref    text;
  v_stmt_id uuid;
  v_resp   app.patient_responsibility;
  v_paid   numeric;
  v_remaining numeric;
  v_amt    numeric;
  v_pp     uuid;
  v_case   uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('patient', 'provider');
  perform app.authorize('patient_payment.apply');

  v_resp_id := app.arg_uuid(p_args, 'patient_responsibility_id');
  v_amt_raw := app.valid_money(app.arg_numeric(p_args, 'amount'), 'amount');
  v_method  := app.arg_enum(p_args, 'method', array['card','cash','check','ach','portal','other']);
  v_ref     := app.arg_text(p_args, 'reference', false, 80);
  v_stmt_id := app.arg_uuid(p_args, 'patient_statement_id', false);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_resp := jsonb_populate_record(null::app.patient_responsibility, app.scoped_row('patient_responsibility', v_resp_id, true));
  if v_ctx.portal = 'patient' and not app.in_scope(v_ctx.tenant_id, null, null, v_resp.patient_id) then
    perform app.not_found('patient_responsibility');
  end if;
  if v_stmt_id is not null then
    perform app.scoped_row('patient_statement', v_stmt_id);
    if not exists (select 1 from app.patient_statement s where s.patient_statement_id = v_stmt_id and s.patient_id = v_resp.patient_id) then
      perform app.refuse('MR005', 'statement_patient_mismatch', 'patient_statement', 'The statement must belong to this patient');
    end if;
  end if;

  select coalesce(sum(pp.amount), 0) into v_paid from app.patient_payment pp where pp.patient_responsibility_id = v_resp.patient_responsibility_id;
  v_remaining := v_resp.amount - v_paid;
  if v_remaining <= 0 then
    perform app.refuse('MR002', 'responsibility_already_settled', 'patient_responsibility', 'This balance is already paid or written off');
  end if;
  if v_amt_raw > v_remaining then
    perform app.refuse('MR002', 'payment_exceeds_remaining', 'patient_payment',
      format('Payment of %s exceeds the %s remaining on this balance', v_amt_raw, v_remaining));
  end if;
  v_amt := v_amt_raw;

  insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, patient_statement_id, amount, method, reference, kind)
  values (v_ctx.tenant_id, v_resp.patient_id, v_resp.patient_responsibility_id, v_stmt_id, v_amt, v_method, v_ref, 'payment')
  returning patient_payment_id into v_pp;

  for v_case in select c.case_id from app."case" c
                 join app.case_claim cc on cc.case_id = c.case_id
                where cc.claim_id = v_resp.claim_id and c.status = 'open'
  loop
    perform app.emit_event('case.closure_evaluated', v_case, jsonb_build_object('case_id', v_case), c_cmd, p_idem);
  end loop;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('patient_payment_id', v_pp, 'patient_responsibility_id', v_resp.patient_responsibility_id,
                       'patient_id', v_resp.patient_id, 'claim_id', v_resp.claim_id, 'amount', v_amt, 'remaining', v_remaining - v_amt),
    'patient_payment.applied', v_resp.claim_id);
end;
$$;

comment on function api.cmd_patient_payment_apply(text, jsonb) is
$c$patient_payment.apply (portals: patient, provider; permission 'patient_payment.apply'). Applies a patient payment
to a responsibility.
args: { patient_responsibility_id uuid, amount number (2 dp, > 0), method card|cash|check|ach|portal|other,
  reference text (optional, <= 80), patient_statement_id uuid (optional) }
Guards: responsibility in the caller's tenant (MR004, locked); a patient caller may only pay their own (or an active
  proxy's) responsibility, same MR004 as a nonexistent id; the amount does not exceed what remains after earlier
  payments and write-offs (MR002 responsibility_already_settled / payment_exceeds_remaining).
Writes: patient_payment (kind payment).
result: { patient_payment_id, patient_responsibility_id, patient_id, claim_id, amount, remaining }
event: patient_payment.applied (aggregate claim_id). Also case.closure_evaluated per open case of the claim.$c$;

-- ================================================================ api.cmd_patient_dispute_open
create function api.cmd_patient_dispute_open(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd      constant text := 'patient_dispute.open';
  v_ctx      app.ctx_t;
  v_cached   jsonb;
  v_patient_id uuid;
  v_reason   text;
  v_claim_id uuid;
  v_resp_id  uuid;
  v_case_id  uuid;
  v_resp     app.patient_responsibility;
  v_pd       uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('patient', 'provider');
  perform app.authorize('patient_dispute.open');

  v_patient_id := app.arg_uuid(p_args, 'patient_id');
  v_reason     := app.arg_text(p_args, 'reason', true, 2000);
  v_claim_id   := app.arg_uuid(p_args, 'claim_id', false);
  v_resp_id    := app.arg_uuid(p_args, 'patient_responsibility_id', false);
  v_case_id    := app.arg_uuid(p_args, 'case_id', false);
  if v_claim_id is null and v_resp_id is null and v_case_id is null then
    perform app.refuse('MR005', 'dispute_target_required', 'patient_dispute', 'Name a claim, responsibility or case the dispute is about');
  end if;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  if v_ctx.portal = 'patient' and not app.in_scope(v_ctx.tenant_id, null, null, v_patient_id) then
    perform app.not_found('patient');
  end if;
  perform app.scoped_row('patient', v_patient_id);
  if v_claim_id is not null then
    perform app.scoped_row('claim', v_claim_id);
  end if;
  if v_resp_id is not null then
    v_resp := jsonb_populate_record(null::app.patient_responsibility, app.scoped_row('patient_responsibility', v_resp_id));
    if v_resp.patient_id <> v_patient_id then
      perform app.refuse('MR005', 'responsibility_patient_mismatch', 'patient_responsibility', 'The responsibility must belong to this patient');
    end if;
  end if;
  if v_case_id is not null then
    perform app.scoped_row('case', v_case_id);
  end if;

  insert into app.patient_dispute (tenant_id, patient_id, case_id, claim_id, patient_responsibility_id, status, reason)
  values (v_ctx.tenant_id, v_patient_id, v_case_id, v_claim_id, v_resp_id, 'open', v_reason)
  returning patient_dispute_id into v_pd;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('patient_dispute_id', v_pd, 'patient_id', v_patient_id, 'claim_id', v_claim_id,
                       'patient_responsibility_id', v_resp_id, 'case_id', v_case_id, 'status', 'open'),
    'patient_dispute.opened', v_pd);
end;
$$;

comment on function api.cmd_patient_dispute_open(text, jsonb) is
$c$patient_dispute.open (portals: patient, provider; permission 'patient_dispute.open'). Opens a patient dispute
(case_blockers 'Open patient dispute' until resolved).
args: { patient_id uuid, reason text (required, <= 2000), claim_id uuid (optional), patient_responsibility_id uuid
  (optional; must belong to patient_id), case_id uuid (optional); at least one of the three required }
Guards: patient (and a patient caller's own, or an active proxy's), claim, responsibility, case in the caller's
  tenant (MR004); a named responsibility belongs to the named patient (MR005).
Writes: patient_dispute (status open).
result: { patient_dispute_id, patient_id, claim_id, patient_responsibility_id, case_id, status }
event: patient_dispute.opened (aggregate patient_dispute_id).$c$;

-- ================================================================ api.cmd_patient_dispute_resolve
create function api.cmd_patient_dispute_resolve(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd      constant text := 'patient_dispute.resolve';
  v_ctx      app.ctx_t;
  v_cached   jsonb;
  v_pd_id    uuid;
  v_resolution text;
  v_pd       app.patient_dispute;
  v_claim_id uuid;
  v_case     uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('patient_dispute.resolve');

  v_pd_id      := app.arg_uuid(p_args, 'patient_dispute_id');
  v_resolution := app.arg_text(p_args, 'resolution', true, 2000);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_pd := jsonb_populate_record(null::app.patient_dispute, app.scoped_row('patient_dispute', v_pd_id, true));
  if v_pd.status <> 'open' then
    perform app.refuse('MR001', 'illegal_transition', 'patient_dispute', format('patient_dispute cannot move from %s to resolved', v_pd.status));
  end if;

  update app.patient_dispute set status = 'resolved', resolution = v_resolution, resolved_at = now() where patient_dispute_id = v_pd.patient_dispute_id;

  v_claim_id := coalesce(v_pd.claim_id, (select r.claim_id from app.patient_responsibility r where r.patient_responsibility_id = v_pd.patient_responsibility_id));
  for v_case in select c.case_id from app."case" c
                where c.status = 'open'
                  and (c.case_id = v_pd.case_id
                       or exists (select 1 from app.case_claim cc where cc.case_id = c.case_id and cc.claim_id = v_claim_id))
  loop
    perform app.emit_event('case.closure_evaluated', v_case, jsonb_build_object('case_id', v_case), c_cmd, p_idem);
  end loop;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('patient_dispute_id', v_pd.patient_dispute_id, 'status', 'resolved', 'resolution', v_resolution),
    'patient_dispute.resolved', v_pd.patient_dispute_id);
end;
$$;

comment on function api.cmd_patient_dispute_resolve(text, jsonb) is
$c$patient_dispute.resolve (portal: provider; permission 'patient_dispute.resolve'). open -> resolved.
args: { patient_dispute_id uuid, resolution text (required, <= 2000) }
Guards: dispute in the caller's tenant (MR004, locked); status open (MR001).
Writes: patient_dispute resolved, resolution, resolved_at.
result: { patient_dispute_id, status, resolution }
event: patient_dispute.resolved (aggregate patient_dispute_id). Also case.closure_evaluated per open case linked
  to the dispute's case / claim / responsibility's claim.$c$;

-- ================================================================ api.cmd_writeoff_request
create function api.cmd_writeoff_request(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'writeoff.request';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_target text;
  v_line_id uuid;
  v_resp_id uuid;
  v_amt_raw numeric;
  v_reason text;
  v_subject_type text;
  v_subject_id   uuid;
  v_max    numeric;
  v_amt    numeric;
  v_ar     uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('writeoff.request');

  v_target  := app.arg_enum(p_args, 'target', array['payer_balance','patient_balance']);
  v_line_id := app.arg_uuid(p_args, 'line_id', false);
  v_resp_id := app.arg_uuid(p_args, 'patient_responsibility_id', false);
  v_amt_raw := app.valid_money(app.arg_numeric(p_args, 'amount'), 'amount');
  v_reason  := app.arg_text(p_args, 'reason', true, 2000);
  if v_target = 'payer_balance' and v_line_id is null then
    perform app.refuse('MR005', 'line_id_required', 'line_id', 'Name the service line whose payer balance is written off');
  end if;
  if v_target = 'patient_balance' and v_resp_id is null then
    perform app.refuse('MR005', 'patient_responsibility_id_required', 'patient_responsibility_id', 'Name the responsibility whose patient balance is written off');
  end if;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  if v_target = 'payer_balance' then
    perform app.scoped_row('claim_service_line', v_line_id);
    select lb.open_amount into v_max from api.line_balance lb where lb.line_id = v_line_id;
    v_subject_type := 'claim_service_line';
    v_subject_id   := v_line_id;
  else
    perform app.scoped_row('patient_responsibility', v_resp_id);
    select r.amount - coalesce((select sum(pp.amount) from app.patient_payment pp where pp.patient_responsibility_id = r.patient_responsibility_id), 0)
      into v_max from app.patient_responsibility r where r.patient_responsibility_id = v_resp_id;
    v_subject_type := 'patient_responsibility';
    v_subject_id   := v_resp_id;
  end if;
  if coalesce(v_max, 0) <= 0 then
    perform app.refuse('MR002', 'nothing_to_write_off', v_subject_type, 'There is nothing open to write off here');
  end if;
  if v_amt_raw > v_max then
    perform app.refuse('MR002', 'writeoff_exceeds_available', 'approval_request',
      format('A write-off of %s exceeds the %s open', v_amt_raw, v_max));
  end if;
  v_amt := v_amt_raw;

  insert into app.approval_request (tenant_id, kind, amount, requester_id, subject_type, subject_id, reason)
  values (v_ctx.tenant_id, 'write_off', v_amt, v_ctx.user_id, v_subject_type, v_subject_id, v_reason)
  returning approval_request_id into v_ar;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('approval_request_id', v_ar, 'target', v_target, 'subject_type', v_subject_type,
                       'subject_id', v_subject_id, 'amount', v_amt, 'status', 'pending'),
    'approval.requested', v_ar);
end;
$$;

comment on function api.cmd_writeoff_request(text, jsonb) is
$c$writeoff.request (portal: provider; permission 'writeoff.request'). Requests approval to write off an open
balance (IV32: posting needs an approved request). Decide it with api.cmd_approval_decide (kind write_off; the
requester cannot decide their own request, IV13).
args: { target payer_balance|patient_balance, line_id uuid (required for payer_balance), patient_responsibility_id
  uuid (required for patient_balance), amount number (2 dp, > 0, <= the open amount), reason text (required, <= 2000) }
Guards: line / responsibility in the caller's tenant (MR004); something open to write off (MR002
  nothing_to_write_off); amount does not exceed what is open (MR002 writeoff_exceeds_available).
Writes: approval_request (kind write_off, pending, requester = caller from ctx).
result: { approval_request_id, target, subject_type, subject_id, amount, status }
event: approval.requested (aggregate approval_request_id).$c$;

-- ================================================================ api.cmd_writeoff_post
create function api.cmd_writeoff_post(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'writeoff.post';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_ar_id  uuid;
  v_ar     app.approval_request;
  v_line   app.claim_service_line;
  v_resp   app.patient_responsibility;
  v_blocked text;
  v_open   numeric;
  v_amt    numeric;
  v_post_id uuid;
  v_claim_id uuid;
  v_case   uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('writeoff.post');

  v_ar_id := app.arg_uuid(p_args, 'approval_request_id');

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_ar := jsonb_populate_record(null::app.approval_request, app.scoped_row('approval_request', v_ar_id, true));
  if v_ar.kind <> 'write_off' then
    perform app.refuse('MR002', 'not_a_writeoff_request', 'approval_request', 'This request is not a write-off request');
  end if;
  if v_ar.status <> 'approved' then
    perform app.refuse('MR002', 'IV32_approval_required', 'approval_request',
      format('The write-off is %s, not approved; it cannot be posted yet', v_ar.status));
  end if;
  if exists (select 1 from app.payment_posting p where p.approval_request_id = v_ar.approval_request_id)
     or exists (select 1 from app.patient_payment pp where pp.approval_request_id = v_ar.approval_request_id) then
    perform app.refuse('MR002', 'already_posted', 'approval_request', 'This write-off was already posted');
  end if;

  if v_ar.subject_type = 'claim_service_line' then
    v_line := jsonb_populate_record(null::app.claim_service_line, app.scoped_row('claim_service_line', v_ar.subject_id, true));
    -- IV32 open-rights check: an open denial on this line whose deadline has not yet passed still has time to act;
    -- a denial with no deadline row yet (not triaged / path-confirmed) counts as still open.
    select string_agg(format('denial %s (%s)', d.denial_id, d.status), ', ') into v_blocked
      from app.denial d
      left join lateral (
        select dl.due_at from app.deadline dl
         where dl.subject_type = 'denial' and dl.subject_id = d.denial_id and dl.met_at is null
         order by dl.due_at desc limit 1
      ) dl on true
     where d.line_id = v_line.claim_service_line_id and d.status not in ('recovered', 'written_off')
       and (dl.due_at is null or dl.due_at > now());
    if v_blocked is not null then
      perform app.refuse('MR002', 'IV32_rights_not_exhausted', 'denial',
        format('This line still has time to act on an open denial (%s); write off only once the filing rights have expired', v_blocked));
    end if;
    select lb.open_amount into v_open from api.line_balance lb where lb.line_id = v_line.claim_service_line_id;
    if v_ar.amount > coalesce(v_open, 0) then
      perform app.refuse('MR002', 'writeoff_exceeds_available', 'claim_service_line',
        format('The approved write-off of %s exceeds the %s now open', v_ar.amount, coalesce(v_open, 0)));
    end if;
    v_amt := v_ar.amount;
    insert into app.payment_posting (tenant_id, line_id, kind, amount, reason, approval_request_id)
    values (v_ctx.tenant_id, v_line.claim_service_line_id, 'adjustment', v_amt,
            format('Write-off approved (request %s): %s', v_ar.approval_request_id, v_ar.reason), v_ar.approval_request_id)
    returning payment_posting_id into v_post_id;
    update app.claim_service_line sl set balanced = true
      from api.line_balance lb
     where lb.line_id = sl.claim_service_line_id and sl.claim_service_line_id = v_line.claim_service_line_id
       and not sl.balanced and lb.open_amount = 0;
    v_claim_id := v_line.claim_id;
  else
    v_resp := jsonb_populate_record(null::app.patient_responsibility, app.scoped_row('patient_responsibility', v_ar.subject_id, true));
    if exists (select 1 from app.patient_dispute d where d.patient_responsibility_id = v_resp.patient_responsibility_id and d.status = 'open') then
      perform app.refuse('MR002', 'IV32_rights_not_exhausted', 'patient_dispute',
        'This balance has an open dispute; resolve it before writing the balance off');
    end if;
    select v_resp.amount - coalesce(sum(pp.amount), 0) into v_open from app.patient_payment pp where pp.patient_responsibility_id = v_resp.patient_responsibility_id;
    if v_ar.amount > coalesce(v_open, v_resp.amount) then
      perform app.refuse('MR002', 'writeoff_exceeds_available', 'patient_responsibility',
        format('The approved write-off of %s exceeds the %s now remaining', v_ar.amount, coalesce(v_open, v_resp.amount)));
    end if;
    v_amt := v_ar.amount;
    insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method, kind, approval_request_id)
    values (v_ctx.tenant_id, v_resp.patient_id, v_resp.patient_responsibility_id, v_amt, 'other', 'writeoff', v_ar.approval_request_id)
    returning patient_payment_id into v_post_id;
    v_claim_id := v_resp.claim_id;
  end if;

  for v_case in select c.case_id from app."case" c
                 join app.case_claim cc on cc.case_id = c.case_id
                where cc.claim_id = v_claim_id and c.status = 'open'
  loop
    perform app.emit_event('case.closure_evaluated', v_case, jsonb_build_object('case_id', v_case), c_cmd, p_idem);
  end loop;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('approval_request_id', v_ar.approval_request_id, 'posting_id', v_post_id,
                       'subject_type', v_ar.subject_type, 'subject_id', v_ar.subject_id, 'claim_id', v_claim_id, 'amount', v_amt),
    'writeoff.posted', v_ar.approval_request_id);
end;
$$;

comment on function api.cmd_writeoff_post(text, jsonb) is
$c$writeoff.post (portal: provider; permission 'writeoff.post'). Posts an approved write-off (IV32).
args: { approval_request_id uuid }
Guards: request in the caller's tenant (MR004, locked); kind write_off (MR002 not_a_writeoff_request); status
  approved (MR002 IV32_approval_required); not already posted (MR002 already_posted, via the partial unique index
  on payment_posting.approval_request_id / patient_payment.approval_request_id); open-rights check (MR002
  IV32_rights_not_exhausted): a payer-balance write-off is refused while the line has an open denial whose filing
  deadline has not yet passed (or has no deadline recorded yet); a patient-balance write-off is refused while an
  open patient_dispute names the responsibility. The approved amount is re-checked against what is open now (MR002
  writeoff_exceeds_available), since it may have changed since the request.
Writes: payer balance -> payment_posting (kind adjustment, approval_request_id set); patient balance ->
  patient_payment (kind writeoff, approval_request_id set).
result: { approval_request_id, posting_id, subject_type, subject_id, claim_id, amount }
event: writeoff.posted (aggregate approval_request_id). Also case.closure_evaluated per open case of the claim.$c$;

-- ================================================================ api.cmd_case_close
create function api.cmd_case_close(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd     constant text := 'case.close';
  v_ctx     app.ctx_t;
  v_cached  jsonb;
  v_case_id uuid;
  v_reason  text;
  v_case    app."case";
  v_blockers text[];
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('case.close');

  v_case_id := app.arg_uuid(p_args, 'case_id');
  v_reason  := app.arg_text(p_args, 'reason', true, 2000);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_case := jsonb_populate_record(null::app."case", app.scoped_row('case', v_case_id, true));
  if v_case.status <> 'open' then
    perform app.refuse('MR001', 'illegal_transition', 'case', format('case cannot move from %s to closed', v_case.status));
  end if;
  select array_agg(b.blocker order by b.blocker) into v_blockers from api.case_blockers b where b.case_id = v_case.case_id;
  if v_blockers is not null and array_length(v_blockers, 1) > 0 then
    perform app.refuse('MR002', 'IV07_case_not_ready', 'case_blockers',
      format('Case %s cannot close yet: %s', v_case.case_number, array_to_string(v_blockers, '; ')));
  end if;

  perform set_config('app.status_reason', v_reason, true);   -- IV08: case_history_write stores the closure reason
  update app."case" set status = 'closed', closed_at = now() where case_id = v_case.case_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('case_id', v_case.case_id, 'status', 'closed', 'reason', v_reason),
    'case.closed', v_case.case_id);
end;
$$;

comment on function api.cmd_case_close(text, jsonb) is
$c$case.close (portal: provider; permission 'case.close'). open -> closed (D6, IV07/IV08).
args: { case_id uuid, reason text (required, <= 2000; the closure reason, IV08) }
Guards: case in the caller's tenant (MR004, locked); status open (MR001); api.case_blockers for the case is empty
  (MR002 IV07_case_not_ready, listing every unmet condition).
Writes: case open -> closed, closed_at; case_status_history row carries the reason (app.status_reason GUC).
result: { case_id, status, reason }
event: case.closed (aggregate case_id).$c$;

-- ================================================================ api.cmd_case_reopen
create function api.cmd_case_reopen(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd      constant text := 'case.reopen';
  v_ctx      app.ctx_t;
  v_cached   jsonb;
  v_case_id  uuid;
  v_trigger_filter text;
  v_reason_arg text;
  v_case     app."case";
  v_re       app.reopen_event;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('case.reopen');

  v_case_id        := app.arg_uuid(p_args, 'case_id');
  v_trigger_filter := app.arg_enum(p_args, 'trigger', array['recoupment','late_payment','payer_correction','appeal_decision','patient_dispute','other'], false);
  v_reason_arg      := app.arg_text(p_args, 'reason', false, 2000);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_case := jsonb_populate_record(null::app."case", app.scoped_row('case', v_case_id, true));
  if v_case.status <> 'closed' then
    perform app.refuse('MR001', 'illegal_transition', 'case', format('case cannot move from %s to open (reopen)', v_case.status));
  end if;

  select * into v_re from app.reopen_event r
   where r.case_id = v_case.case_id and r.consumed_at is null
     and (v_trigger_filter is null or r.trigger = v_trigger_filter)
   order by r.occurred_at, r.reopen_event_id
   limit 1
     for update;
  if not found then
    perform app.refuse('MR002', 'IV09_no_reopen_trigger', 'reopen_event',
      'No recorded trigger (a recoupment, late payment, payer correction, appeal decision or patient dispute) justifies reopening this case');
  end if;

  update app.reopen_event set consumed_at = now() where reopen_event_id = v_re.reopen_event_id;
  perform set_config('app.status_reason', coalesce(v_reason_arg, v_re.reason), true);   -- IV09: the trigger's reason is recorded
  update app."case" set status = 'open', closed_at = null where case_id = v_case.case_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('case_id', v_case.case_id, 'status', 'open', 'reopen_event_id', v_re.reopen_event_id,
                       'trigger', v_re.trigger, 'reason', coalesce(v_reason_arg, v_re.reason)),
    'case.reopened', v_case.case_id);
end;
$$;

comment on function api.cmd_case_reopen(text, jsonb) is
$c$case.reopen (portal: provider; permission 'case.reopen'). closed -> open (IV09).
args: { case_id uuid, trigger recoupment|late_payment|payer_correction|appeal_decision|patient_dispute|other
  (optional filter), reason text (optional, <= 2000; overrides the trigger's own reason) }
Guards: case in the caller's tenant (MR004, locked); status closed (MR001); an unconsumed app.reopen_event exists
  for the case (optionally of the named trigger), IV09 (MR002 IV09_no_reopen_trigger). A recoupment posted by
  cmd_posting_apply_payment on a closed case's line writes such an event automatically.
Writes: the oldest matching reopen_event consumed_at = now(); case closed -> open, closed_at null; case_status_history
  carries the reason.
result: { case_id, status, reopen_event_id, trigger, reason }
event: case.reopened (aggregate case_id).$c$;

-- ================================================================ grants
revoke all on function api.cmd_posting_apply_payment(text, jsonb) from public, anon;
revoke all on function api.cmd_posting_reverse(text, jsonb) from public, anon;
revoke all on function api.cmd_deposit_allocate(text, jsonb) from public, anon;
revoke all on function api.cmd_patient_payment_apply(text, jsonb) from public, anon;
revoke all on function api.cmd_patient_dispute_open(text, jsonb) from public, anon;
revoke all on function api.cmd_patient_dispute_resolve(text, jsonb) from public, anon;
revoke all on function api.cmd_writeoff_request(text, jsonb) from public, anon;
revoke all on function api.cmd_writeoff_post(text, jsonb) from public, anon;
revoke all on function api.cmd_case_close(text, jsonb) from public, anon;
revoke all on function api.cmd_case_reopen(text, jsonb) from public, anon;
grant execute on function api.cmd_posting_apply_payment(text, jsonb) to authenticated;
grant execute on function api.cmd_posting_reverse(text, jsonb) to authenticated;
grant execute on function api.cmd_deposit_allocate(text, jsonb) to authenticated;
grant execute on function api.cmd_patient_payment_apply(text, jsonb) to authenticated;
grant execute on function api.cmd_patient_dispute_open(text, jsonb) to authenticated;
grant execute on function api.cmd_patient_dispute_resolve(text, jsonb) to authenticated;
grant execute on function api.cmd_writeoff_request(text, jsonb) to authenticated;
grant execute on function api.cmd_writeoff_post(text, jsonb) to authenticated;
grant execute on function api.cmd_case_close(text, jsonb) to authenticated;
grant execute on function api.cmd_case_reopen(text, jsonb) to authenticated;

-- new column is covered by the existing table-level SELECT grant; restated for clarity
revoke all on all tables in schema app from public, anon, authenticated;
grant select on all tables in schema app to authenticated;
