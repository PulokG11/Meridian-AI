-- Task 10: api.case_stage(case_id) returns int (0-8), matching the prototype's STAGES array:
-- 0 Denied, 1 Triaged, 2 Action drafted, 3 Approved, 4 Sent, 5 Payer responded, 6 Remit posted,
-- 7 Deposit allocated, 8 Reconciled. Derived entirely from rows (never stored).
--
-- Ruling: the prototype has four recovery paths (appeal, corrected, evidence, cob) but release 1
-- only built commands for appeal, corrected and evidence (Tasks 6-8). A 'cob' case (coverage-order
-- correction) is modeled the same way as 'corrected' (a replacement claim to the right payer),
-- since mechanically that is what fixing a COB claim means in this schema and no distinct command
-- exists for it.
create or replace function api.case_stage(p_case_id uuid) returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_case app."case";
  v_claim_id uuid;
  v_orig_id uuid;
  v_claim app.claim;
  v_denial app.denial;
  v_repl app.claim;
  v_appeal app.appeal;
  v_rr app.records_request;
  v_rem_posted boolean;
  v_rem_received boolean;
  v_dep_allocated boolean;
begin
  -- Note: composite row variables are checked via a definitely-not-null key column, never a bare
  -- "IS NOT NULL" on the whole row — Postgres treats "row IS NOT NULL" as true only when EVERY
  -- field is non-null, and these rows all have legitimately-nullable columns (filed_at, etc.).
  select * into v_case from app."case" where case_id = p_case_id;
  if v_case.case_id is null then
    return null;
  end if;
  if v_case.status = 'closed' then
    return 8;
  end if;

  select claim_id into v_claim_id from app.case_claim where case_id = p_case_id order by claim_id limit 1;
  if v_claim_id is null then
    return 0;
  end if;
  select * into v_claim from app.claim where claim_id = v_claim_id;
  -- case_claim may point at either the original claim or (once replaced) the replacement claim;
  -- the denial always belongs to the original, so resolve that id first.
  v_orig_id := coalesce(v_claim.original_claim_id, v_claim_id);
  select * into v_denial from app.denial where claim_id = v_orig_id order by received_at desc limit 1;

  if v_denial.denial_id is null then
    return 0;
  end if;
  if v_denial.status = 'new' then
    return 0;
  end if;

  -- Three mutually exclusive recovery paths can each carry a denial out of "just triaged" (stage 1):
  -- an appeal row, a records_request/evidence_item, or a replacement claim. Only one of these
  -- will exist for any given denial; check all three before falling back to the generic stage-1.
  select * into v_appeal from app.appeal where denial_id = v_denial.denial_id and parent_appeal_id is null;
  select * into v_rr from app.records_request where denial_id = v_denial.denial_id order by created_at desc limit 1;
  if v_appeal.appeal_id is null and v_rr.records_request_id is null and not exists (select 1 from app.evidence_item where denial_id = v_denial.denial_id) then
    -- corrected / cob path: a replacement claim carries the rest of the journey. v_claim may already
    -- *be* the replacement (if case_claim points at it); otherwise look one up from the original.
    if v_claim.original_claim_id is not null then
      v_repl := v_claim;
    else
      select * into v_repl from app.claim where original_claim_id = v_orig_id order by created_at desc limit 1;
    end if;
    if v_repl.claim_id is not null then
      v_claim_id := v_repl.claim_id;  -- remittance/posting/deposit checks below look at the replacement claim
    end if;
  end if;

  if v_appeal.appeal_id is null and v_rr.records_request_id is null and v_repl.claim_id is null
     and not exists (select 1 from app.evidence_item where denial_id = v_denial.denial_id) then
    return 1;  -- triaged, no recovery action drafted yet under any path
  end if;

  -- shared tail: payer responded (remittance received) -> remit posted -> deposit allocated -> (closed handled above).
  -- These checks come first since they outrank any claim/appeal status word once money has moved.
  select exists (select 1 from app.remittance_line rl where rl.claim_id = v_claim_id) into v_rem_received;
  select exists (select 1 from app.payment_posting p join app.claim_service_line l on l.claim_service_line_id = p.line_id
                  where l.claim_id = v_claim_id) into v_rem_posted;
  select exists (select 1 from app.deposit_allocation da join app.claim_service_line l on l.claim_service_line_id = da.line_id
                  where l.claim_id = v_claim_id) into v_dep_allocated;

  if v_dep_allocated then return 7; end if;
  if v_rem_posted then return 6; end if;
  if v_rem_received then return 5; end if;

  -- a decided/accepted outcome with nothing posted yet still counts as "payer responded"
  if (v_appeal.appeal_id is not null and v_appeal.status = 'decided') or (v_rr.records_request_id is not null and v_rr.status in ('accepted','rejected')) then
    return 5;
  end if;

  if v_appeal.appeal_id is not null then
    if v_appeal.status in ('drafting', 'pending_approval') then return 2; end if;
    if v_appeal.status = 'approved' then return 3; end if;
    if v_appeal.status = 'filed' then return 4; end if;
  end if;
  if v_rr.records_request_id is not null then
    if v_rr.status = 'open' then return 2; end if;
    if v_rr.status = 'responded' then return 4; end if;
  elsif exists (select 1 from app.evidence_item where denial_id = v_denial.denial_id) then
    return 2;  -- evidence assembled, no formal records_request row yet
  end if;
  if v_repl.claim_id is not null then
    if v_repl.status = 'draft' then return 2; end if;
    if v_repl.status = 'ready' then return 3; end if;
    if v_repl.status = 'submitted' then return 4; end if;
  end if;

  return 1;
end;
$$;

revoke all on function api.case_stage(uuid) from public;
grant execute on function api.case_stage(uuid) to authenticated;
