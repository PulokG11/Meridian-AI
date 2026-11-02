-- 006_cmd_claims: the first api.cmd_* command functions (remittance, denial, claim) and the shared command helpers
-- that Tasks 7 and 8 reuse. All data synthetic.
--
-- Command convention (every api.cmd_*, in this order; the spec 5.1 pipeline):
--   1 authenticate   v_ctx := app.ctx()                      MR003 no session / no app_user
--   2 authorize      app.require_portal(...)                 MR003 wrong_portal
--                    app.authorize('<command name>')         MR003 permission_required (permission key = command name)
--   3 validate       app.arg_* / app.valid_money / valid_amount: argument shape, MR005, before any write
--   5 idempotency    app.begin_cmd(<command name>, key, args): a finished key with the same args returns its first
--                    result (the command returns it at once); same key + other args, blank key, in-flight key: MR005.
--                    Keys are per tenant + command, so authorize MUST run before begin_cmd.
--   3b scope         app.scoped_row(<table>, id, lock): the row of the caller's tenant or MR004 not_found, with the
--                    same message whether the id does not exist or belongs to another tenant
--   4 guard          state machine (MR001) and business gates (MR002)
--   6 mutate
--   7+8 audit/emit   app.finish_cmd(<command name>, key, args, result, '<event>', aggregate): stores the result for
--                    replays, writes the outbox event (ids only) and the audit row. Extra events: app.emit_event.
-- Identity (author, confirmer, poster) always comes from app.ctx(), never from args.
-- Lock order for money commands: remittance row, then service lines in ascending id, then claims in ascending id.
--
-- Changes to earlier objects (004 stays as applied; done here):
--   app.remittance_line.denied_amount  numeric(12,2) >= 0  -- the 835 denied amount, carried from receive to post
--   app.denial_triage.reasons          jsonb array          -- the triage reasons (spec 4.3 "reasons stored")
--   ref.state_transition remittance received -> posted | rejected, and trigger remittance_transition (IV39)

-- ================================================================ earlier objects
alter table app.remittance_line
  add column denied_amount numeric(12,2) not null default 0 check (denied_amount >= 0);
alter table app.denial_triage
  add column reasons jsonb not null default '[]'::jsonb check (jsonb_typeof(reasons) = 'array');

insert into ref.state_transition (entity, from_status, to_status) values
  ('remittance', 'received', 'posted'),
  ('remittance', 'received', 'rejected');
create trigger remittance_transition before update on app.remittance
  for each row execute function app.enforce_transition('remittance');

-- ================================================================ helpers (owner-only; called from definer commands)
-- MR004 for a row that is missing or outside the caller's tenant. One message for both: never leak existence.
create function app.not_found(p_object text) returns void
language plpgsql
set search_path = ''
as $$
begin
  perform app.refuse('MR004', 'not_found', p_object,
    format('No %s with this id is available to you; check the id', p_object));
end;
$$;

-- MR003 unless the caller's portal (from app.ctx()) is one of p_portals.
create function app.require_portal(variadic p_portals text[]) returns void
language plpgsql stable
set search_path = ''
as $$
declare
  v_portal text := (app.ctx()).portal;
begin
  if v_portal is null or not (v_portal = any (p_portals)) then
    perform app.refuse('MR003', 'wrong_portal', coalesce(v_portal, ''),
      format('This action is not available in the %s portal', coalesce(v_portal, 'current')));
  end if;
end;
$$;

-- The row of app.<p_table> whose <p_table>_id = p_id in the caller's tenant, as jsonb (optionally locked FOR UPDATE);
-- MR004 via app.not_found otherwise. Use: v := jsonb_populate_record(null::app.claim, app.scoped_row('claim', id, true)).
create function app.scoped_row(p_table text, p_id uuid, p_lock boolean default false) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := (app.ctx()).tenant_id;
  v_row    jsonb;
begin
  if p_id is not null then
    execute format('select to_jsonb(t) from app.%I t where t.%I = $1 and t.tenant_id = $2%s',
                   p_table, p_table || '_id', case when p_lock then ' for update' else '' end)
       into v_row using p_id, v_tenant;
  end if;
  if v_row is null then
    perform app.not_found(p_table);
  end if;
  return v_row;
end;
$$;

-- Money check (MR005): not null, at most 2 decimals, not negative, not zero unless p_allow_zero, fits numeric(12,2),
-- not above p_max. Returns the amount as numeric(12,2). p_field names the argument in the refusal.
create function app.valid_money(p_amount numeric, p_field text, p_allow_zero boolean default false, p_max numeric default null)
returns numeric
language plpgsql
set search_path = ''
as $$
begin
  if p_amount is null then
    perform app.refuse('MR005', 'amount_required', p_field, format('%s is required', p_field));
  end if;
  if p_amount <> round(p_amount, 2) then
    perform app.refuse('MR005', 'amount_precision', p_field, format('%s must have at most 2 decimal places', p_field));
  end if;
  if p_amount < 0 or (p_amount = 0 and not p_allow_zero) then
    perform app.refuse('MR005', 'amount_not_positive', p_field,
      format('%s must be %s', p_field, case when p_allow_zero then 'zero or more' else 'more than zero' end));
  end if;
  if p_amount > 9999999999.99 then
    perform app.refuse('MR005', 'amount_too_large', p_field, format('%s is too large', p_field));
  end if;
  if p_max is not null and p_amount > p_max then
    perform app.refuse('MR005', 'amount_exceeds_max', p_field, format('%s must not exceed %s', p_field, p_max));
  end if;
  return p_amount::numeric(12,2);
end;
$$;

-- Strictly positive amount (MR005 on null, <= 0, more than 2 decimals, or > p_max). Task 8 reuses this.
create function app.valid_amount(p_amount numeric, p_max numeric default null) returns numeric
language sql
set search_path = ''
as $$ select app.valid_money(p_amount, 'amount', false, p_max) $$;

-- Argument readers (MR005 on a missing required value or a wrong type). Blank strings count as missing.
create function app.arg_text(p_args jsonb, p_key text, p_required boolean default true, p_max_len integer default 200)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_type text := jsonb_typeof(p_args -> p_key);
  v      text;
begin
  if v_type in ('object', 'array') then
    perform app.refuse('MR005', 'invalid_text', p_key, format('%s must be text', p_key));
  end if;
  v := nullif(btrim(p_args ->> p_key), '');
  if v is null and p_required then
    perform app.refuse('MR005', 'required', p_key, format('%s is required', p_key));
  end if;
  if length(v) > p_max_len then
    perform app.refuse('MR005', 'text_too_long', p_key, format('%s must be at most %s characters', p_key, p_max_len));
  end if;
  return v;
end;
$$;

create function app.arg_uuid(p_args jsonb, p_key text, p_required boolean default true) returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v text := app.arg_text(p_args, p_key, p_required, 36);
begin
  if v is null then
    return null;
  end if;
  if v !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    perform app.refuse('MR005', 'invalid_uuid', p_key, format('%s must be a uuid', p_key));
  end if;
  return v::uuid;
end;
$$;

create function app.arg_numeric(p_args jsonb, p_key text, p_required boolean default true) returns numeric
language plpgsql
set search_path = ''
as $$
declare
  v jsonb := p_args -> p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_required then
      perform app.refuse('MR005', 'required', p_key, format('%s is required', p_key));
    end if;
    return null;
  end if;
  if jsonb_typeof(v) = 'number' then
    return (v #>> '{}')::numeric;
  end if;
  if jsonb_typeof(v) = 'string' and btrim(v #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then
    return btrim(v #>> '{}')::numeric;
  end if;
  perform app.refuse('MR005', 'invalid_number', p_key, format('%s must be a number', p_key));
  return null;
end;
$$;

create function app.arg_enum(p_args jsonb, p_key text, p_allowed text[], p_required boolean default true) returns text
language plpgsql
set search_path = ''
as $$
declare
  v text := app.arg_text(p_args, p_key, p_required, 40);
begin
  if v is not null and not (v = any (p_allowed)) then
    perform app.refuse('MR005', 'invalid_value', p_key, format('%s must be one of %s', p_key, array_to_string(p_allowed, ', ')));
  end if;
  return v;
end;
$$;

create function app.arg_date(p_args jsonb, p_key text, p_required boolean default true) returns date
language plpgsql
set search_path = ''
as $$
declare
  v text := app.arg_text(p_args, p_key, p_required, 10);
begin
  if v is null then
    return null;
  end if;
  if v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    perform app.refuse('MR005', 'invalid_date', p_key, format('%s must be a date (YYYY-MM-DD)', p_key));
  end if;
  begin
    return v::date;
  exception when others then
    perform app.refuse('MR005', 'invalid_date', p_key, format('%s must be a date (YYYY-MM-DD)', p_key));
  end;
  return null;
end;
$$;

-- An extra outbox event inside a command (finish_cmd writes the command's main event). The payload keeps ids only
-- (id, *_id strings, *_ids arrays) like finish_cmd; the correlation id equals finish_cmd's when p_cmd / p_idem are
-- given, so all events of one command share it. Returns the event id.
create function app.emit_event(p_type text, p_aggregate uuid, p_payload jsonb, p_cmd text default null, p_idem text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_ctx     app.ctx_t := app.ctx();
  v_payload jsonb := '{}'::jsonb;
  v_id      uuid;
begin
  if p_type is null or p_type !~ '^[a-z][a-z_]*\.[a-z][a-z_]*$' then
    perform app.refuse('MR005', 'event_type', coalesce(p_type, ''), 'An event type is <entity>.<verb>, lower case');
  end if;
  if jsonb_typeof(p_payload) = 'object' then
    select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) into v_payload
      from jsonb_each(p_payload) e
     where (e.key = 'id' or e.key like '%\_id' escape '\') and jsonb_typeof(e.value) = 'string'
        or (e.key like '%\_ids' escape '\') and jsonb_typeof(e.value) = 'array';
  end if;
  insert into audit.outbox_event (tenant_id, type, aggregate_id, payload, correlation_id)
  values (v_ctx.tenant_id, p_type, p_aggregate, v_payload,
          case when p_cmd is not null and p_idem is not null
               then md5(v_ctx.tenant_id::text || '|' || p_cmd || '|' || p_idem)::uuid end)
  returning event_id into v_id;
  return v_id;
end;
$$;

-- ================================================================ api.cmd_remittance_receive
create function api.cmd_remittance_receive(p_idem text, p_args jsonb) returns jsonb
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
create function api.cmd_remittance_post(p_idem text, p_args jsonb) returns jsonb
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

-- ================================================================ api.cmd_denial_triage
create function api.cmd_denial_triage(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd     constant text := 'denial.triage';
  v_ctx     app.ctx_t;
  v_cached  jsonb;
  v_den_id  uuid;
  v_path    text;
  v_rc      text;
  v_conf    numeric;
  v_reasons jsonb;
  v_rat     text;
  v_ai      boolean;
  v_den     app.denial;
  v_tri     uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('denial.triage');

  v_den_id := app.arg_uuid(p_args, 'denial_id');
  v_rc     := app.arg_text(p_args, 'root_cause', true, 40);
  v_path   := app.arg_enum(p_args, 'recommended_path', array['correction','evidence','appeal','coverage_update','write_off']);
  v_conf   := app.arg_numeric(p_args, 'confidence', false);
  if v_conf is not null and (v_conf < 0 or v_conf > 1 or v_conf <> round(v_conf, 3)) then
    perform app.refuse('MR005', 'invalid_confidence', 'confidence', 'confidence is a number from 0 to 1 with at most 3 decimals');
  end if;
  v_reasons := coalesce(p_args -> 'reasons', '[]'::jsonb);
  if jsonb_typeof(v_reasons) <> 'array' or jsonb_array_length(v_reasons) > 20
     or exists (select 1 from jsonb_array_elements(v_reasons) x
                 where jsonb_typeof(x.value) <> 'string' or length(x.value #>> '{}') > 500) then
    perform app.refuse('MR005', 'invalid_reasons', 'reasons', 'reasons is a list of up to 20 texts of at most 500 characters');
  end if;
  v_rat := app.arg_text(p_args, 'rationale', false, 2000);
  if jsonb_typeof(p_args -> 'ai_generated') not in ('boolean', 'null') then
    perform app.refuse('MR005', 'invalid_boolean', 'ai_generated', 'ai_generated is true or false');
  end if;
  v_ai := coalesce((p_args ->> 'ai_generated')::boolean, false);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_den := jsonb_populate_record(null::app.denial, app.scoped_row('denial', v_den_id, true));
  if v_den.status <> 'new' then
    perform app.refuse('MR001', 'illegal_transition', 'denial', format('denial cannot move from %s to triaged', v_den.status));
  end if;
  if nullif(btrim(v_den.carc), '') is null then
    perform app.refuse('MR002', 'codes_not_parsed', 'denial',
      'The denial has no CARC yet; code the denial (manual coding queue) before triage');
  end if;
  if not exists (select 1 from app.root_cause rc where rc.tenant_id = v_ctx.tenant_id and rc.code = v_rc) then
    perform app.refuse('MR005', 'unknown_root_cause', 'root_cause', format('Root cause %s is not defined', v_rc));
  end if;

  insert into app.denial_triage (tenant_id, denial_id, root_cause, recommended_path, confidence, rationale, reasons, ai_generated)
  values (v_ctx.tenant_id, v_den.denial_id, v_rc, v_path, v_conf, v_rat, v_reasons, v_ai)
  returning denial_triage_id into v_tri;
  update app.denial set status = 'triaged', root_cause = v_rc where denial_id = v_den.denial_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('denial_id', v_den.denial_id, 'denial_triage_id', v_tri, 'status', 'triaged',
                       'recommended_path', v_path, 'root_cause', v_rc),
    'denial.triaged', v_den.denial_id);
end;
$$;

comment on function api.cmd_denial_triage(text, jsonb) is
$c$denial.triage (portal: provider; permission 'denial.triage'). Records the triage of a new denial.
args: { denial_id uuid, root_cause text (an app.root_cause code of the tenant), recommended_path
  correction|evidence|appeal|coverage_update|write_off, confidence number 0..1 (<= 3 dp, optional), reasons [text]
  (<= 20, each <= 500, optional), rationale text (optional), ai_generated boolean (default false) }
Guards: denial in the caller's tenant (MR004); status new (MR001); CARC parsed (MR002 codes_not_parsed; RARC is
  optional, as in handover H16); root cause defined (MR005).
Writes: denial_triage row; denial new -> triaged with root_cause (IV38).
result: { denial_id, denial_triage_id, status, recommended_path, root_cause }   event: denial.triaged (aggregate denial_id).$c$;

-- ================================================================ api.cmd_denial_confirm_path
create function api.cmd_denial_confirm_path(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd     constant text := 'denial.confirm_path';
  v_ctx     app.ctx_t;
  v_cached  jsonb;
  v_den_id  uuid;
  v_path    text;
  v_reason  text;
  v_den     app.denial;
  v_tri     app.denial_triage;
  v_cfg     app.payer_config;
  v_over    boolean;
  v_status  text;
  v_kind    text;
  v_days    integer;
  v_due     timestamptz;
  v_dl      uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('denial.confirm_path');

  v_den_id := app.arg_uuid(p_args, 'denial_id');
  v_path   := app.arg_enum(p_args, 'path', array['correction','evidence','appeal','coverage_update','write_off']);
  if v_path = 'write_off' then
    perform app.refuse('MR005', 'write_off_needs_approval', 'path',
      'A write-off is requested and approved through the write-off commands, not confirmed here');
  end if;
  v_reason := app.arg_text(p_args, 'reason', false, 2000);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_den := jsonb_populate_record(null::app.denial, app.scoped_row('denial', v_den_id, true));
  v_status := 'in_' || v_path;
  if v_den.status <> 'triaged' then
    perform app.refuse('MR001', 'illegal_transition', 'denial', format('denial cannot move from %s to %s', v_den.status, v_status));
  end if;
  select * into v_tri from app.denial_triage t
   where t.denial_id = v_den.denial_id
   order by t.created_at desc, t.denial_triage_id desc
   limit 1
     for update;
  if not found then
    perform app.refuse('MR002', 'triage_missing', 'denial_triage', 'Triage the denial before confirming a path');
  end if;
  v_over := v_path <> v_tri.recommended_path;
  if v_over and v_reason is null then
    perform app.refuse('MR005', 'override_reason_required', 'reason',
      format('The recommendation was %s; give a reason for choosing %s', v_tri.recommended_path, v_path));
  end if;

  select pc.* into v_cfg
    from app.payer_config pc join app.claim c on c.payer_id = pc.payer_id
   where c.claim_id = v_den.claim_id and pc.tenant_id = v_ctx.tenant_id and pc.effective_from <= current_date
   order by pc.effective_from desc
   limit 1;
  if not found then
    perform app.refuse('MR002', 'payer_rules_missing', 'payer_config',
      'The payer has no rules pack in effect, so the deadline cannot be set; add the payer configuration');
  end if;
  -- deadline rules (from the denial's received_at): evidence = records_request_days (records_response);
  -- appeal = timely_filing_days (appeal_filing; payer_config has no separate appeal window);
  -- correction / coverage_update = timely_filing_days (timely_filing, the corrected claim must be refiled).
  v_kind := case v_path when 'evidence' then 'records_response' when 'appeal' then 'appeal_filing' else 'timely_filing' end;
  v_days := case v_path when 'evidence' then v_cfg.records_request_days else v_cfg.timely_filing_days end;
  v_due  := v_den.received_at + make_interval(days => v_days);

  update app.denial_triage
     set confirmed_path = v_path, override_reason = v_reason, confirmed_by = v_ctx.user_id, confirmed_at = now()
   where denial_triage_id = v_tri.denial_triage_id;
  update app.denial set status = v_status where denial_id = v_den.denial_id;
  insert into app.deadline (tenant_id, subject_type, subject_id, kind, due_at, note)
  values (v_ctx.tenant_id, 'denial', v_den.denial_id, v_kind, v_due,
          format('%s days from the denial (payer_config effective %s)', v_days, v_cfg.effective_from))
  returning deadline_id into v_dl;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('denial_id', v_den.denial_id, 'denial_triage_id', v_tri.denial_triage_id, 'deadline_id', v_dl,
                       'status', v_status, 'path', v_path, 'recommended_path', v_tri.recommended_path,
                       'overridden', v_over, 'due_at', v_due),
    'denial.path_confirmed', v_den.denial_id);
end;
$$;

comment on function api.cmd_denial_confirm_path(text, jsonb) is
$c$denial.confirm_path (portal: provider; permission 'denial.confirm_path'). The analyst confirms or overrides the
triage recommendation (handover H17).
args: { denial_id uuid, path correction|evidence|appeal|coverage_update (write_off: MR005, use the write-off
  commands), reason text (required, non-blank, when path differs from the recommended path) }
Guards: denial in the caller's tenant (MR004); status triaged (MR001); a triage row exists (MR002); override needs a
  reason (MR005 override_reason_required); the payer has a payer_config in effect (MR002 payer_rules_missing).
Writes: latest denial_triage confirmed (confirmed_path, override_reason, confirmed_by = caller from ctx, confirmed_at);
  denial triaged -> in_<path>; deadline (subject denial) from denial.received_at: evidence + records_request_days
  (records_response), appeal + timely_filing_days (appeal_filing), correction / coverage_update + timely_filing_days
  (timely_filing).
result: { denial_id, denial_triage_id, deadline_id, status, path, recommended_path, overridden, due_at }
event: denial.path_confirmed (aggregate denial_id).$c$;

-- ================================================================ api.cmd_claim_create_replacement
create function api.cmd_claim_create_replacement(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'claim.create_replacement';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_orig_id uuid;
  v_freq   text;
  v_orig   app.claim;
  v_new    uuid := app.uuid_v7();
  v_number text;
  v_k      integer;
  v_lines  integer;
  v_dx     integer;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('claim.create_replacement');

  v_orig_id := app.arg_uuid(p_args, 'original_claim_id');
  v_freq    := coalesce(app.arg_enum(p_args, 'frequency_code', array['7','8'], false), '7');

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_orig := jsonb_populate_record(null::app.claim, app.scoped_row('claim', v_orig_id, true));
  if v_new = v_orig.claim_id then
    perform app.refuse('MR005', 'IV10_not_own_replacement', 'claim', 'A claim cannot be its own replacement');
  end if;
  if v_orig.status in ('draft', 'ready') then
    perform app.refuse('MR002', 'original_not_submitted', 'claim',
      format('Claim %s has not been sent to the payer (%s); edit it instead of replacing it', v_orig.claim_number, v_orig.status));
  end if;
  if exists (select 1 from app.claim c where c.original_claim_id = v_orig.claim_id and c.status in ('draft', 'ready')) then
    perform app.refuse('MR002', 'replacement_in_progress', 'claim',
      format('Claim %s already has a replacement in progress; finish or submit that one', v_orig.claim_number));
  end if;

  select count(*) + 1 into v_k from app.claim c where c.original_claim_id = v_orig.claim_id;
  loop
    v_number := v_orig.claim_number || '-R' || v_k;
    exit when not exists (select 1 from app.claim c where c.tenant_id = v_ctx.tenant_id and c.claim_number = v_number);
    v_k := v_k + 1;
  end loop;

  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id,
                         original_claim_id, frequency_code, status, hold, service_from, service_to)
  values (v_new, v_ctx.tenant_id, v_number, v_orig.patient_id, v_orig.provider_id, v_orig.payer_id, v_orig.coverage_id,
          v_orig.claim_id, v_freq, 'draft', false, v_orig.service_from, v_orig.service_to);
  insert into app.claim_service_line (tenant_id, claim_id, line_number, procedure_code, modifiers, units, billed, service_date)
  select v_ctx.tenant_id, v_new, l.line_number, l.procedure_code, l.modifiers, l.units, l.billed, l.service_date
    from app.claim_service_line l where l.claim_id = v_orig.claim_id order by l.line_number;
  get diagnostics v_lines = row_count;
  insert into app.claim_diagnosis (tenant_id, claim_id, sequence, icd10_code)
  select v_ctx.tenant_id, v_new, d.sequence, d.icd10_code
    from app.claim_diagnosis d where d.claim_id = v_orig.claim_id order by d.sequence;
  get diagnostics v_dx = row_count;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('claim_id', v_new, 'original_claim_id', v_orig.claim_id, 'claim_number', v_number,
                       'frequency_code', v_freq, 'status', 'draft', 'line_count', v_lines, 'diagnosis_count', v_dx),
    'claim.replacement_drafted', v_new);
end;
$$;

comment on function api.cmd_claim_create_replacement(text, jsonb) is
$c$claim.create_replacement (portal: provider; permission 'claim.create_replacement'). Drafts a corrected claim as a NEW row.
args: { original_claim_id uuid, frequency_code '7' replacement (default) | '8' void }
Guards: original in the caller's tenant (MR004, locked); the new id differs from the original, IV10 (MR005; also the
  table CHECK); original already sent to the payer, not draft / ready (MR002 original_not_submitted); no other
  replacement of it in draft / ready (MR002 replacement_in_progress).
Writes: claim (draft, original_claim_id, frequency_code, claim_number '<original>-R<n>'), copies of the service lines
  (unbalanced, no postings) and diagnoses.
result: { claim_id, original_claim_id, claim_number, frequency_code, status, line_count, diagnosis_count }
event: claim.replacement_drafted (aggregate = the new claim_id).$c$;

-- ================================================================ api.cmd_claim_release
create function api.cmd_claim_release(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'claim.release';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_claim_id uuid;
  v_claim  app.claim;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('claim.release');

  v_claim_id := app.arg_uuid(p_args, 'claim_id');

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_claim := jsonb_populate_record(null::app.claim, app.scoped_row('claim', v_claim_id, true));
  if v_claim.status <> 'draft' then
    perform app.refuse('MR001', 'illegal_transition', 'claim', format('claim cannot move from %s to ready', v_claim.status));
  end if;
  if v_claim.hold then
    perform app.refuse('MR002', 'IV12_bill_hold_active', 'claim',
      format('Claim %s is on bill hold (%s); clear the hold first', v_claim.claim_number, v_claim.hold_reason));
  end if;
  if app.claim_has_failed_hard_edit(v_claim.claim_id) then
    perform app.refuse('MR002', 'IV11_hard_edit_failed', 'claim',
      format('Claim %s has a failed hard edit; fix it and re-run the edits', v_claim.claim_number));
  end if;
  if not exists (select 1 from app.claim_service_line l where l.claim_id = v_claim.claim_id) then
    perform app.refuse('MR002', 'claim_has_no_lines', 'claim', 'Add at least one service line before release');
  end if;

  update app.claim set status = 'ready' where claim_id = v_claim.claim_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('claim_id', v_claim.claim_id, 'status', 'ready'),
    'claim.ready', v_claim.claim_id);
end;
$$;

comment on function api.cmd_claim_release(text, jsonb) is
$c$claim.release (portal: provider; permission 'claim.release'). draft -> ready.
args: { claim_id uuid }
Guards: claim in the caller's tenant (MR004, locked); status draft (MR001); no active bill hold, IV12 (MR002
  IV12_bill_hold_active); no failed hard edit (latest result per rule and line), IV11 (MR002 IV11_hard_edit_failed;
  soft failures do not block); at least one service line (MR002 claim_has_no_lines).
result: { claim_id, status }   event: claim.ready (aggregate claim_id; handover H13).$c$;

-- ================================================================ api.cmd_claim_submit
create function api.cmd_claim_submit(p_idem text, p_args jsonb) returns jsonb
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

-- ================================================================ grants
revoke all on function app.not_found(text) from public, anon, authenticated;
revoke all on function app.require_portal(text[]) from public, anon, authenticated;
revoke all on function app.scoped_row(text, uuid, boolean) from public, anon, authenticated;
revoke all on function app.valid_money(numeric, text, boolean, numeric) from public, anon, authenticated;
revoke all on function app.valid_amount(numeric, numeric) from public, anon, authenticated;
revoke all on function app.arg_text(jsonb, text, boolean, integer) from public, anon, authenticated;
revoke all on function app.arg_uuid(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function app.arg_numeric(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function app.arg_enum(jsonb, text, text[], boolean) from public, anon, authenticated;
revoke all on function app.arg_date(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function app.emit_event(text, uuid, jsonb, text, text) from public, anon, authenticated;

revoke all on function api.cmd_remittance_receive(text, jsonb) from public, anon;
revoke all on function api.cmd_remittance_post(text, jsonb) from public, anon;
revoke all on function api.cmd_denial_triage(text, jsonb) from public, anon;
revoke all on function api.cmd_denial_confirm_path(text, jsonb) from public, anon;
revoke all on function api.cmd_claim_create_replacement(text, jsonb) from public, anon;
revoke all on function api.cmd_claim_release(text, jsonb) from public, anon;
revoke all on function api.cmd_claim_submit(text, jsonb) from public, anon;
grant execute on function api.cmd_remittance_receive(text, jsonb) to authenticated;
grant execute on function api.cmd_remittance_post(text, jsonb) to authenticated;
grant execute on function api.cmd_denial_triage(text, jsonb) to authenticated;
grant execute on function api.cmd_denial_confirm_path(text, jsonb) to authenticated;
grant execute on function api.cmd_claim_create_replacement(text, jsonb) to authenticated;
grant execute on function api.cmd_claim_release(text, jsonb) to authenticated;
grant execute on function api.cmd_claim_submit(text, jsonb) to authenticated;

-- new columns are covered by the existing table-level SELECT grants; restated for clarity
revoke all on all tables in schema app from public, anon, authenticated;
grant select on all tables in schema app to authenticated;
