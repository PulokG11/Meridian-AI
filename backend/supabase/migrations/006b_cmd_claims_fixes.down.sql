-- Undo 006b_cmd_claims_fixes: restore the 006 definitions of cmd_remittance_receive, cmd_remittance_post and
-- cmd_claim_submit, the 006 trace uniqueness (tenant_id, payer_id, trace_number), and remove the three claim transitions.
-- (Restoring the narrower constraint fails if an inbound and an outbound interchange now share a trace; resolve first.)

delete from ref.state_transition
 where entity = 'claim' and (from_status, to_status) in (('partially_paid','paid'), ('denied','paid'), ('denied','partially_paid'));

alter table app.edi_interchange drop constraint edi_interchange_trace_unique;
alter table app.edi_interchange add constraint edi_interchange_trace_unique unique (tenant_id, payer_id, trace_number);

-- ================================================================ api.cmd_remittance_receive
create or replace function api.cmd_remittance_receive(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'remittance.receive';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_trace  text;
  v_payer  uuid;
  v_ch     uuid;
  v_total  numeric(12,2);
  v_method text;
  v_paid_date date;
  v_lines  jsonb;
  v_norm   jsonb := '[]'::jsonb;
  v_seen   uuid[] := '{}';
  l        jsonb;
  v_line   app.claim_service_line;
  v_claim  app.claim;
  v_sum    numeric;
  v_ix     uuid;
  v_rem    uuid;
  v_rl     uuid;
  v_rl_ids jsonb := '[]'::jsonb;
  v_line_id uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('clearinghouse', 'provider');
  perform app.authorize('remittance.receive');

  v_trace     := app.arg_text(p_args, 'interchange_trace', true, 80);
  v_payer     := app.arg_uuid(p_args, 'payer_id');
  v_ch        := app.arg_uuid(p_args, 'clearinghouse_id', false);
  v_total     := app.valid_money(app.arg_numeric(p_args, 'control_total'), 'control_total', true);
  v_method    := coalesce(app.arg_enum(p_args, 'payment_method', array['eft','check','virtual_card','non_payment'], false), 'eft');
  v_paid_date := app.arg_date(p_args, 'paid_date', false);
  v_lines     := p_args -> 'lines';
  if jsonb_typeof(v_lines) is distinct from 'array' or jsonb_array_length(v_lines) = 0 then
    perform app.refuse('MR005', 'lines_required', 'lines', 'Send at least one remittance line');
  end if;
  if jsonb_array_length(v_lines) > 999 then
    perform app.refuse('MR005', 'too_many_lines', 'lines', 'A remittance may carry at most 999 lines');
  end if;
  for l in select x.value from jsonb_array_elements(v_lines) x loop
    if jsonb_typeof(l) is distinct from 'object' then
      perform app.refuse('MR005', 'invalid_line', 'lines', 'Each remittance line is an object');
    end if;
    v_line_id := app.arg_uuid(l, 'line_id');
    if v_line_id = any (v_seen) then
      perform app.refuse('MR005', 'duplicate_line', 'lines', 'A service line may appear only once per remittance');
    end if;
    v_seen := v_seen || v_line_id;
    l := jsonb_build_object(
      'claim_id',      app.arg_uuid(l, 'claim_id'),
      'line_id',       v_line_id,
      'paid',          app.valid_money(coalesce(app.arg_numeric(l, 'paid', false), 0), 'paid', true),
      'adjustment',    app.valid_money(coalesce(app.arg_numeric(l, 'adjustment', false), 0), 'adjustment', true),
      'patient_share', app.valid_money(coalesce(app.arg_numeric(l, 'patient_share', false), 0), 'patient_share', true),
      'denied',        app.valid_money(coalesce(app.arg_numeric(l, 'denied', false), 0), 'denied', true),
      'group_code',    app.arg_enum(l, 'group_code', array['CO','PR','OA','PI','CR'], false),
      'carc',          app.arg_text(l, 'carc', false, 10),
      'rarc',          app.arg_text(l, 'rarc', false, 10));
    if (l->>'paid')::numeric + (l->>'adjustment')::numeric + (l->>'patient_share')::numeric + (l->>'denied')::numeric = 0 then
      perform app.refuse('MR005', 'line_amount_zero', 'lines', 'A remittance line must pay, adjust, assign or deny an amount');
    end if;
    v_norm := v_norm || jsonb_build_array(l);
  end loop;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  perform app.scoped_row('payer', v_payer);
  if v_ctx.portal = 'clearinghouse' then
    if v_ch is null then
      v_ch := v_ctx.party_id;
    elsif v_ch is distinct from v_ctx.party_id then
      perform app.not_found('clearinghouse');
    end if;
  end if;
  if v_ch is not null then
    perform app.scoped_row('clearinghouse', v_ch);
  end if;

  for l in select x.value from jsonb_array_elements(v_norm) x loop
    v_claim := jsonb_populate_record(null::app.claim, app.scoped_row('claim', (l->>'claim_id')::uuid));
    select * into v_line from app.claim_service_line sl
     where sl.claim_service_line_id = (l->>'line_id')::uuid and sl.claim_id = v_claim.claim_id and sl.tenant_id = v_ctx.tenant_id;
    if not found then
      perform app.not_found('claim_service_line');
    end if;
    if v_claim.payer_id <> v_payer then
      perform app.refuse('MR005', 'claim_payer_mismatch', 'claim',
        format('Claim %s is billed to another payer than this remittance', v_claim.claim_number));
    end if;
    v_sum := (l->>'paid')::numeric + (l->>'adjustment')::numeric + (l->>'patient_share')::numeric + (l->>'denied')::numeric;
    if v_sum > v_line.billed then
      perform app.refuse('MR005', 'amount_exceeds_billed', 'remittance_line',
        format('Line %s of claim %s: paid, adjusted, patient share and denied total %s but the line billed %s',
               v_line.line_number, v_claim.claim_number, v_sum, v_line.billed));
    end if;
  end loop;

  if exists (select 1 from app.edi_interchange x
              where x.tenant_id = v_ctx.tenant_id and x.payer_id = v_payer and x.trace_number = v_trace)
     or exists (select 1 from app.remittance m
              where m.tenant_id = v_ctx.tenant_id and m.payer_id = v_payer and m.trace_number = v_trace) then
    perform app.refuse('MR002', 'duplicate_interchange', 'edi_interchange',
      format('Interchange %s from this payer was already received (IV37); it is not processed twice', v_trace));
  end if;

  begin
    insert into app.edi_interchange (tenant_id, clearinghouse_id, payer_id, direction, transaction_set, trace_number, status)
    values (v_ctx.tenant_id, v_ch, v_payer, 'inbound', '835', v_trace, 'received')
    returning edi_interchange_id into v_ix;
  exception when unique_violation then
    perform app.refuse('MR002', 'duplicate_interchange', 'edi_interchange',
      format('Interchange %s from this payer was already received (IV37); it is not processed twice', v_trace));
  end;

  insert into app.remittance (tenant_id, payer_id, edi_interchange_id, trace_number, payment_method, payment_amount, paid_date, status)
  values (v_ctx.tenant_id, v_payer, v_ix, v_trace, v_method, v_total, v_paid_date, 'received')
  returning remittance_id into v_rem;

  for l in select x.value from jsonb_array_elements(v_norm) x loop
    insert into app.remittance_line (tenant_id, remittance_id, claim_id, line_id, billed, paid, adjusted, patient_share,
                                     denied_amount, group_code, carc, rarc)
    select v_ctx.tenant_id, v_rem, sl.claim_id, sl.claim_service_line_id, sl.billed,
           (l->>'paid')::numeric, (l->>'adjustment')::numeric, (l->>'patient_share')::numeric, (l->>'denied')::numeric,
           l->>'group_code', l->>'carc', l->>'rarc'
      from app.claim_service_line sl
     where sl.claim_service_line_id = (l->>'line_id')::uuid
    returning remittance_line_id into v_rl;
    v_rl_ids := v_rl_ids || to_jsonb(v_rl);
  end loop;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('remittance_id', v_rem, 'edi_interchange_id', v_ix, 'remittance_line_ids', v_rl_ids,
                       'line_count', jsonb_array_length(v_rl_ids), 'control_total', v_total, 'status', 'received'),
    'remittance.received', v_rem);
end;
$$;

comment on function api.cmd_remittance_receive(text, jsonb) is
$c$remittance.receive (portals: clearinghouse, provider; permission 'remittance.receive'). Stores an inbound 835.
args: { interchange_trace text (required, <= 80), payer_id uuid (required), clearinghouse_id uuid (optional; a
  clearinghouse caller defaults to and may only name its own), control_total number >= 0 (2 dp), payment_method
  eft|check|virtual_card|non_payment (default eft), paid_date YYYY-MM-DD (optional),
  lines [ { claim_id uuid, line_id uuid, paid, adjustment, patient_share, denied (numbers >= 0, 2 dp, default 0,
  not all zero, total <= the line's billed), group_code CO|PR|OA|PI|CR, carc, rarc } ] (1..999, each line once) }
Guards: payer, clearinghouse, claims and lines in the caller's tenant (MR004); claim billed to this payer (MR005);
  the (payer, trace) not seen before, IV37 (MR002 duplicate_interchange). The control total is stored as sent; it is
  checked when posting (IV01) and by handover H15.
Writes: edi_interchange (inbound 835, received), remittance (received), remittance_line per line (billed copied).
result: { remittance_id, edi_interchange_id, remittance_line_ids[], line_count, control_total, status }
event: remittance.received (aggregate remittance_id).$c$;

-- ================================================================ api.cmd_remittance_post
create or replace function api.cmd_remittance_post(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd      constant text := 'remittance.post';
  v_ctx      app.ctx_t;
  v_cached   jsonb;
  v_rem_id   uuid;
  v_rem      app.remittance;
  v_n        integer;
  v_sum      numeric;
  rl         record;
  v_id       uuid;
  v_pp_ids   jsonb := '[]'::jsonb;
  v_den_ids  jsonb := '[]'::jsonb;
  v_claim_ids jsonb := '[]'::jsonb;
  v_claims   jsonb := '[]'::jsonb;
  v_c        uuid;
  v_status   text;
  v_new      text;
  v_paid     numeric;
  v_open     boolean;
  v_denied   boolean;
  v_claim_pp jsonb;
  v_bad      text;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('remittance.post');

  v_rem_id := app.arg_uuid(p_args, 'remittance_id');

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_rem := jsonb_populate_record(null::app.remittance, app.scoped_row('remittance', v_rem_id, true));
  if v_rem.status <> 'received' then
    perform app.refuse('MR001', 'illegal_transition', 'remittance',
      format('remittance cannot move from %s to posted', v_rem.status));
  end if;

  select count(*), coalesce(sum(l.paid), 0) into v_n, v_sum
    from app.remittance_line l where l.remittance_id = v_rem.remittance_id;
  if v_n = 0 then
    perform app.refuse('MR002', 'remittance_has_no_lines', 'remittance', 'This remittance has no lines to post');
  end if;
  if v_sum <> v_rem.payment_amount then
    perform app.refuse('MR002', 'IV01_control_total_mismatch', 'remittance',
      format('The lines pay %s but the control total is %s; correct the remittance before posting', v_sum, v_rem.payment_amount));
  end if;
  if exists (select 1 from app.remittance_line l where l.remittance_id = v_rem.remittance_id and l.line_id is null) then
    perform app.refuse('MR002', 'remittance_line_unmatched', 'remittance', 'Every line must be matched to a service line first');
  end if;

  -- locks: service lines in ascending id, then claims in ascending id
  perform 1 from app.claim_service_line sl
   where sl.claim_service_line_id in (select l.line_id from app.remittance_line l where l.remittance_id = v_rem.remittance_id)
   order by sl.claim_service_line_id
     for update of sl;
  perform 1 from app.claim c
   where c.claim_id in (select l.claim_id from app.remittance_line l where l.remittance_id = v_rem.remittance_id)
   order by c.claim_id
     for update of c;

  select string_agg(c.claim_number || ' (' || c.status || ')', ', ' order by c.claim_number) into v_bad
    from app.claim c
   where c.claim_id in (select l.claim_id from app.remittance_line l where l.remittance_id = v_rem.remittance_id)
     and c.status not in ('submitted', 'accepted', 'paid', 'partially_paid', 'denied');
  if v_bad is not null then
    perform app.refuse('MR002', 'claim_not_adjudicable', 'claim',
      format('A remittance can only post to submitted claims; not: %s', v_bad));
  end if;

  select string_agg(format('line %s of claim %s (open %s, posting %s)', sl.line_number, c.claim_number, lb.open_amount,
                           l.paid + l.adjusted + l.patient_share), ', ') into v_bad
    from app.remittance_line l
    join app.claim_service_line sl on sl.claim_service_line_id = l.line_id
    join app.claim c on c.claim_id = sl.claim_id
    join api.line_balance lb on lb.line_id = l.line_id
   where l.remittance_id = v_rem.remittance_id
     and l.paid + l.adjusted + l.patient_share > lb.open_amount;
  if v_bad is not null then
    perform app.refuse('MR002', 'IV01_line_overposted', 'claim_service_line',
      format('Posting would exceed the billed amount: %s; reverse the earlier postings first', v_bad));
  end if;

  -- postings and denials, line by line
  for rl in select l.* from app.remittance_line l where l.remittance_id = v_rem.remittance_id
             order by l.line_id, l.remittance_line_id loop
    if rl.paid > 0 then
      insert into app.payment_posting (tenant_id, line_id, remittance_line_id, kind, amount, reason)
      values (v_ctx.tenant_id, rl.line_id, rl.remittance_line_id, 'payment', rl.paid, null)
      returning payment_posting_id into v_id;
      v_pp_ids := v_pp_ids || to_jsonb(v_id);
    end if;
    if rl.adjusted > 0 then
      insert into app.payment_posting (tenant_id, line_id, remittance_line_id, kind, amount, reason)
      values (v_ctx.tenant_id, rl.line_id, rl.remittance_line_id, 'adjustment', rl.adjusted,
              nullif(concat_ws('-', rl.group_code, rl.carc), ''))
      returning payment_posting_id into v_id;
      v_pp_ids := v_pp_ids || to_jsonb(v_id);
    end if;
    if rl.patient_share > 0 then
      insert into app.payment_posting (tenant_id, line_id, remittance_line_id, kind, amount, reason)
      values (v_ctx.tenant_id, rl.line_id, rl.remittance_line_id, 'patient_share', rl.patient_share, null)
      returning payment_posting_id into v_id;
      v_pp_ids := v_pp_ids || to_jsonb(v_id);
    end if;
    if rl.denied_amount > 0 then
      insert into app.denial (tenant_id, claim_id, line_id, remittance_line_id, status, group_code, carc, rarc, denied_amount)
      values (v_ctx.tenant_id, rl.claim_id, rl.line_id, rl.remittance_line_id, 'new', rl.group_code, rl.carc, rl.rarc, rl.denied_amount)
      returning denial_id into v_id;
      v_den_ids := v_den_ids || to_jsonb(v_id);
    end if;
  end loop;

  -- IV01: lines that now balance are (re-)marked balanced (a posting clears the flag when it breaks the balance)
  update app.claim_service_line sl
     set balanced = true
    from api.line_balance lb
   where lb.line_id = sl.claim_service_line_id
     and sl.claim_service_line_id in (select l.line_id from app.remittance_line l where l.remittance_id = v_rem.remittance_id)
     and not sl.balanced
     and lb.open_amount = 0;

  -- claim status per claim: submitted -> accepted (an 835 is the payer's adjudication), then accepted -> paid (nothing
  -- open, no denial), partially_paid (something paid) or denied (nothing paid). A claim already paid / partially_paid /
  -- denied keeps its status (the state machine has no move between them); its postings still apply.
  for v_c in select distinct l.claim_id from app.remittance_line l where l.remittance_id = v_rem.remittance_id order by l.claim_id loop
    select c.status into v_status from app.claim c where c.claim_id = v_c;
    select coalesce(sum(lb.paid), 0), coalesce(bool_or(lb.open_amount <> 0), false) into v_paid, v_open
      from api.line_balance lb where lb.claim_id = v_c;
    v_denied := exists (select 1 from app.denial d join app.remittance_line l on l.remittance_line_id = d.remittance_line_id
                         where l.remittance_id = v_rem.remittance_id and d.claim_id = v_c);
    v_new := case when not v_open and not v_denied then 'paid' when v_paid > 0 then 'partially_paid' else 'denied' end;
    if v_status = 'submitted' then
      update app.claim set status = 'accepted' where claim_id = v_c;
      v_status := 'accepted';
    end if;
    if v_status = 'accepted' then
      update app.claim set status = v_new where claim_id = v_c;
      v_status := v_new;
    end if;
    v_claim_ids := v_claim_ids || to_jsonb(v_c);
    v_claims := v_claims || jsonb_build_array(jsonb_build_object('claim_id', v_c, 'status', v_status));

    select coalesce(jsonb_agg(p.payment_posting_id order by p.payment_posting_id), '[]'::jsonb) into v_claim_pp
      from app.payment_posting p join app.remittance_line l on l.remittance_line_id = p.remittance_line_id
     where l.remittance_id = v_rem.remittance_id and l.claim_id = v_c;
    perform app.emit_event('payment.posted', v_c,
      jsonb_build_object('subject_id', v_c, 'claim_id', v_c, 'remittance_id', v_rem.remittance_id,
                         'payment_posting_ids', v_claim_pp), c_cmd, p_idem);
  end loop;

  for v_id in select d.denial_id from app.denial d join app.remittance_line l on l.remittance_line_id = d.remittance_line_id
               where l.remittance_id = v_rem.remittance_id order by d.denial_id loop
    perform app.emit_event('denial.created', v_id,
      (select jsonb_build_object('denial_id', d.denial_id, 'claim_id', d.claim_id, 'line_id', d.line_id,
                                 'remittance_id', v_rem.remittance_id)
         from app.denial d where d.denial_id = v_id), c_cmd, p_idem);
  end loop;

  update app.remittance set status = 'posted' where remittance_id = v_rem.remittance_id;
  update app.edi_interchange set status = 'processed' where edi_interchange_id = v_rem.edi_interchange_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('remittance_id', v_rem.remittance_id, 'status', 'posted', 'claim_ids', v_claim_ids,
                       'claims', v_claims, 'payment_posting_ids', v_pp_ids, 'denial_ids', v_den_ids,
                       'posted_paid', v_sum),
    'remittance.posted', v_rem.remittance_id);
end;
$$;

comment on function api.cmd_remittance_post(text, jsonb) is
$c$remittance.post (portal: provider; permission 'remittance.post'). Posts a received remittance.
args: { remittance_id uuid }
Guards: remittance in the caller's tenant (MR004) and received (MR001); has lines (MR002); sum(line.paid) = control
  total, IV01 (MR002 IV01_control_total_mismatch); every claim submitted or later (MR002 claim_not_adjudicable);
  no line would be posted beyond its billed amount (MR002 IV01_line_overposted, so a balanced line stays balanced).
Locks: the remittance, its service lines (ascending id), its claims (ascending id).
Writes (one transaction): payment_posting per line and kind (payment / adjustment / patient_share, amounts > 0);
  lines whose open amount is now 0 marked balanced; a denial (status new) per line with denied_amount > 0; claims
  submitted -> accepted -> paid | partially_paid | denied; remittance posted; its interchange processed.
result: { remittance_id, status, claim_ids[], claims[{claim_id,status}], payment_posting_ids[], denial_ids[], posted_paid }
events: payment.posted once per claim (aggregate claim_id, payload subject_id = claim_id, remittance_id,
  payment_posting_ids), denial.created once per denial (aggregate denial_id), remittance.posted (aggregate remittance_id).$c$;

-- ================================================================ api.cmd_claim_submit
create or replace function api.cmd_claim_submit(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'claim.submit';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_claim_id uuid;
  v_claim  app.claim;
  v_conn   app.clearinghouse_connection;
  v_trace  text;
  v_ix     uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('claim.submit');

  v_claim_id := app.arg_uuid(p_args, 'claim_id');

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_claim := jsonb_populate_record(null::app.claim, app.scoped_row('claim', v_claim_id, true));
  if v_claim.status <> 'ready' then
    perform app.refuse('MR001', 'illegal_transition', 'claim', format('claim cannot move from %s to submitted', v_claim.status));
  end if;
  if v_claim.hold then
    perform app.refuse('MR002', 'IV12_bill_hold_active', 'claim',
      format('Claim %s is on bill hold (%s); clear the hold first', v_claim.claim_number, v_claim.hold_reason));
  end if;
  if app.claim_has_failed_hard_edit(v_claim.claim_id) then
    perform app.refuse('MR002', 'IV11_hard_edit_failed', 'claim',
      format('Claim %s has a failed hard edit; it cannot be submitted', v_claim.claim_number));
  end if;

  select cc.* into v_conn
    from app.clearinghouse_connection cc
    join app.clearinghouse ch on ch.clearinghouse_id = cc.clearinghouse_id
   where cc.tenant_id = v_ctx.tenant_id
     and (cc.payer_id = v_claim.payer_id or cc.payer_id is null)
     and cc.status = 'active' and ch.status = 'active'
   order by (cc.payer_id is null), cc.clearinghouse_connection_id
   limit 1;
  if not found then
    perform app.refuse('MR002', 'clearinghouse_unreachable', 'clearinghouse_connection',
      'No active clearinghouse connection serves this payer; restore the connection and submit again');
  end if;

  -- deterministic interchange key: one outbound 837 per claim, so a retried submission reuses it
  v_trace := '837-' || replace(v_claim.claim_id::text, '-', '');
  insert into app.edi_interchange (tenant_id, clearinghouse_id, payer_id, direction, transaction_set, trace_number,
                                   control_number, status)
  values (v_ctx.tenant_id, v_conn.clearinghouse_id, v_claim.payer_id, 'outbound', '837', v_trace,
          lpad((abs(hashtext(v_claim.claim_id::text)) % 1000000000)::text, 9, '0'), 'queued')
  on conflict on constraint edi_interchange_trace_unique do nothing
  returning edi_interchange_id into v_ix;
  if v_ix is null then
    select x.edi_interchange_id into v_ix from app.edi_interchange x
     where x.tenant_id = v_ctx.tenant_id and x.payer_id = v_claim.payer_id and x.trace_number = v_trace;
  end if;

  update app.claim set status = 'submitted', submitted_at = now() where claim_id = v_claim.claim_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('claim_id', v_claim.claim_id, 'status', 'submitted', 'edi_interchange_id', v_ix,
                       'clearinghouse_id', v_conn.clearinghouse_id,
                       'clearinghouse_connection_id', v_conn.clearinghouse_connection_id, 'trace_number', v_trace),
    'claim.submitted', v_claim.claim_id);
end;
$$;

comment on function api.cmd_claim_submit(text, jsonb) is
$c$claim.submit (portal: provider; permission 'claim.submit'). ready -> submitted.
args: { claim_id uuid }
Guards: claim in the caller's tenant (MR004, locked); status ready (MR001); still no bill hold / failed hard edit
  (MR002, IV12 / IV11); an active clearinghouse connection for the payer (or for all payers) on an active
  clearinghouse (MR002 clearinghouse_unreachable).
Writes: outbound 837 edi_interchange (queued) with the deterministic trace '837-<claim id hex>' (reused if present);
  claim submitted, submitted_at.
result: { claim_id, status, edi_interchange_id, clearinghouse_id, clearinghouse_connection_id, trace_number }
event: claim.submitted (aggregate claim_id; handover H14).$c$;


revoke all on function api.cmd_remittance_receive(text, jsonb) from public, anon;
revoke all on function api.cmd_remittance_post(text, jsonb) from public, anon;
revoke all on function api.cmd_claim_submit(text, jsonb) from public, anon;
grant execute on function api.cmd_remittance_receive(text, jsonb) to authenticated;
grant execute on function api.cmd_remittance_post(text, jsonb) to authenticated;
grant execute on function api.cmd_claim_submit(text, jsonb) to authenticated;
