-- 007_cmd_appeals: command functions part 2 (evidence, appeals, approvals, AI review, records requests). Synthetic data.
-- Same pipeline as 006 (see its header): ctx -> require_portal -> authorize -> validate args (MR005) -> begin_cmd
-- (idempotency) -> tenant-scoped loads (MR004) -> guards (MR001 / MR002 / MR003) -> mutate -> finish_cmd (+ emit_event).
-- Identity (author, requester, approver, reviewer, responder, payer decider) always comes from app.ctx().
-- Lock order: appeal row before its approval_request; denial before its evidence items; records_request before its
-- evidence items; evidence items in ascending id.
--
-- Provider portal: cmd_evidence_assemble, cmd_appeal_draft, cmd_appeal_request_approval, cmd_approval_decide,
--   cmd_appeal_file, cmd_records_request_respond, cmd_ai_review, cmd_ai_interaction_record.
-- Payer portal (scope: claim.payer_id = ctx.party_id; anything else is the same MR004 as a nonexistent id):
--   cmd_appeal_record_decision, cmd_records_request_decide.
--
-- Changes to earlier objects (earlier migrations stay as applied):
--   app.appeal            + ai_interaction_id (FK app.ai_interaction, IV16), submission_ref (filing receipt),
--                           expected_payment (cash expected after an overturn; cash itself comes only from remittances),
--                           decision_reason, decided_by (FK app_user); decision values now overturned |
--                           overturned_in_part | upheld (was overturned | upheld | partial; no rows used 'partial')
--   app.appeal_statement  + removed_at (a statement removed by an amending draft; ignored by IV14)
--   app.records_request   + response_note, responded_by, decision_reason, decided_at, decided_by;
--                           status adds accepted | rejected; state machine + trigger records_request_transition
--   app.ai_review         decision adds 'approved' (the ai.review command writes approved | rejected)
--   app.ai_interaction    + model_version (the stand-in's model label, e.g. 'appeal-draft-sim-0.1')
--   ref.state_transition  appeal pending_approval -> drafting (rejected approval);
--                         records_request open -> responded, responded -> accepted | rejected

-- ================================================================ earlier objects
alter table app.appeal
  add column ai_interaction_id uuid references app.ai_interaction (ai_interaction_id),
  add column submission_ref    text,
  add column expected_payment  numeric(12,2) check (expected_payment >= 0),
  add column decision_reason   text,
  add column decided_by        uuid references app.app_user (user_id);
create index appeal_ai_interaction_idx on app.appeal (ai_interaction_id);
create index appeal_decided_by_idx     on app.appeal (decided_by);
alter table app.appeal drop constraint appeal_decision_check;
alter table app.appeal add constraint appeal_decision_check
  check (decision in ('overturned', 'overturned_in_part', 'upheld'));

alter table app.appeal_statement add column removed_at timestamptz;

alter table app.records_request
  add column response_note   text,
  add column responded_by    uuid references app.app_user (user_id),
  add column decision_reason text,
  add column decided_at      timestamptz,
  add column decided_by      uuid references app.app_user (user_id);
create index records_request_responded_by_idx on app.records_request (responded_by);
create index records_request_decided_by_idx   on app.records_request (decided_by);
alter table app.records_request drop constraint records_request_status_check;
alter table app.records_request add constraint records_request_status_check
  check (status in ('open', 'responded', 'accepted', 'rejected', 'closed', 'expired'));

alter table app.ai_review drop constraint ai_review_decision_check;
alter table app.ai_review add constraint ai_review_decision_check
  check (decision in ('approved', 'accepted', 'edited', 'rejected'));

alter table app.ai_interaction add column model_version text;

insert into ref.state_transition (entity, from_status, to_status) values
  ('appeal', 'pending_approval', 'drafting'),
  ('records_request', 'open', 'responded'),
  ('records_request', 'responded', 'accepted'),
  ('records_request', 'responded', 'rejected');
create trigger records_request_transition before update on app.records_request
  for each row execute function app.enforce_transition('records_request');

-- ================================================================ helpers (owner-only)
-- Optional boolean argument (MR005 when present and not a JSON boolean).
create function app.arg_bool(p_args jsonb, p_key text) returns boolean
language plpgsql
set search_path = ''
as $$
begin
  if p_args -> p_key is null or jsonb_typeof(p_args -> p_key) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_args -> p_key) <> 'boolean' then
    perform app.refuse('MR005', 'invalid_boolean', p_key, format('%s is true or false', p_key));
  end if;
  return (p_args ->> p_key)::boolean;
end;
$$;

-- Optional array of uuids (MR005 on a wrong shape, a repeated id or more than p_max entries); '{}' when absent.
create function app.arg_uuid_list(p_args jsonb, p_key text, p_max integer default 50) returns uuid[]
language plpgsql
set search_path = ''
as $$
declare
  v   jsonb := p_args -> p_key;
  x   jsonb;
  ids uuid[] := '{}';
  id  uuid;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    return ids;
  end if;
  if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) > p_max then
    perform app.refuse('MR005', 'invalid_id_list', p_key, format('%s is a list of at most %s ids', p_key, p_max));
  end if;
  for x in select e.value from jsonb_array_elements(v) e loop
    id := app.arg_uuid(jsonb_build_object(p_key, x), p_key);
    if id = any (ids) then
      perform app.refuse('MR005', 'duplicate_id', p_key, format('%s lists the same id twice', p_key));
    end if;
    ids := ids || id;
  end loop;
  return ids;
end;
$$;

-- The statements of an appeal draft, normalised to [{seq, text, source_ref, unsupported}] (seq = position, 1-based).
-- A statement without source_ref is flagged unsupported (IV14/IV15); explicitly unsupported=false without a source is
-- MR005 statement_source_required. 1..50 statements, text <= 4000, source_ref <= 500.
create function app.arg_statements(p_args jsonb) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v     jsonb := p_args -> 'statements';
  s     jsonb;
  i     integer := 0;
  v_src text;
  v_uns boolean;
  out   jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(v) is distinct from 'array' or jsonb_array_length(v) = 0 or jsonb_array_length(v) > 50 then
    perform app.refuse('MR005', 'statements_required', 'statements', 'Send 1 to 50 statements, each with text and a source_ref');
  end if;
  for s in select e.value from jsonb_array_elements(v) e loop
    i := i + 1;
    if jsonb_typeof(s) is distinct from 'object' then
      perform app.refuse('MR005', 'invalid_statement', 'statements', 'Each statement is an object {text, source_ref}');
    end if;
    v_src := app.arg_text(s, 'source_ref', false, 500);
    v_uns := app.arg_bool(s, 'unsupported');
    if v_src is null and v_uns is false then
      perform app.refuse('MR005', 'statement_source_required', 'statements',
        format('Statement %s has no source_ref; add one or flag it unsupported', i));
    end if;
    out := out || jsonb_build_array(jsonb_build_object(
      'seq', i, 'text', app.arg_text(s, 'text', true, 4000), 'source_ref', v_src,
      'unsupported', coalesce(v_uns, false) or v_src is null));
  end loop;
  return out;
end;
$$;

-- Everyone who wrote the appeal: its author, its creator, and whoever created or edited one of its statements.
-- Segregation of duties (IV13): none of them may approve it.
create function app.appeal_contributors(p_appeal uuid) returns uuid[]
language sql stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct u) filter (where u is not null), '{}')
    from (select a.author_id as u from app.appeal a where a.appeal_id = p_appeal
          union all select a.created_by from app.appeal a where a.appeal_id = p_appeal
          union all select s.created_by from app.appeal_statement s where s.appeal_id = p_appeal
          union all select s.updated_by from app.appeal_statement s where s.appeal_id = p_appeal) x
$$;

-- The payer rules pack in effect for a claim's payer (null row when there is none).
create function app.claim_payer_config(p_claim uuid) returns app.payer_config
language sql stable
set search_path = ''
as $$
  select pc.*
    from app.payer_config pc join app.claim c on c.payer_id = pc.payer_id and c.tenant_id = pc.tenant_id
   where c.claim_id = p_claim and pc.effective_from <= current_date
   order by pc.effective_from desc
   limit 1
$$;

-- Payer-portal scope for an appeal: the caller's tenant, a claim billed to the caller's payer (ctx.party_id) and an
-- appeal the payer can see (filed or decided). Anything else is MR004 not_found('appeal'), the same as a missing id.
create function app.payer_appeal(p_appeal uuid, p_lock boolean default false) returns app.appeal
language plpgsql
set search_path = ''
as $$
declare
  v_ctx app.ctx_t := app.ctx();
  v     app.appeal;
begin
  if p_lock then
    select a.* into v from app.appeal a join app.claim c on c.claim_id = a.claim_id and c.tenant_id = a.tenant_id
     where a.appeal_id = p_appeal and a.tenant_id = v_ctx.tenant_id and c.payer_id = v_ctx.party_id
       and a.status in ('filed', 'decided')
       for update of a;
  else
    select a.* into v from app.appeal a join app.claim c on c.claim_id = a.claim_id and c.tenant_id = a.tenant_id
     where a.appeal_id = p_appeal and a.tenant_id = v_ctx.tenant_id and c.payer_id = v_ctx.party_id
       and a.status in ('filed', 'decided');
  end if;
  if v.appeal_id is null then
    perform app.not_found('appeal');
  end if;
  return v;
end;
$$;

-- Payer-portal scope for a records request: the caller's tenant and a claim billed to the caller's payer; otherwise
-- MR004 not_found('records_request').
create function app.payer_records_request(p_rr uuid, p_lock boolean default false) returns app.records_request
language plpgsql
set search_path = ''
as $$
declare
  v_ctx app.ctx_t := app.ctx();
  v     app.records_request;
begin
  if p_lock then
    select q.* into v from app.records_request q join app.claim c on c.claim_id = q.claim_id and c.tenant_id = q.tenant_id
     where q.records_request_id = p_rr and q.tenant_id = v_ctx.tenant_id and c.payer_id = v_ctx.party_id
       for update of q;
  else
    select q.* into v from app.records_request q join app.claim c on c.claim_id = q.claim_id and c.tenant_id = q.tenant_id
     where q.records_request_id = p_rr and q.tenant_id = v_ctx.tenant_id and c.payer_id = v_ctx.party_id;
  end if;
  if v.records_request_id is null then
    perform app.not_found('records_request');
  end if;
  return v;
end;
$$;

-- ================================================================ api.cmd_evidence_assemble
create function api.cmd_evidence_assemble(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd      constant text := 'evidence.assemble';
  c_kinds    constant text[] := array['medical_record','authorization','invoice','correspondence','policy','other'];
  v_ctx      app.ctx_t;
  v_cached   jsonb;
  v_den_id   uuid;
  v_ap_id    uuid;
  v_link     uuid[];
  v_items    jsonb;
  v_norm     jsonb := '[]'::jsonb;
  v_req      text[];
  it         jsonb;
  v_den      app.denial;
  v_ap       app.appeal;
  v_ev       app.evidence_item;
  v_id       uuid;
  v_created  jsonb := '[]'::jsonb;
  v_linked   jsonb := '[]'::jsonb;
  v_present  text[];
  v_missing  text[];
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('evidence.assemble');

  v_den_id := app.arg_uuid(p_args, 'denial_id');
  v_ap_id  := app.arg_uuid(p_args, 'appeal_id', false);
  v_link   := app.arg_uuid_list(p_args, 'evidence_item_ids');
  v_items  := coalesce(p_args -> 'items', '[]'::jsonb);
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) > 50 then
    perform app.refuse('MR005', 'invalid_items', 'items', 'items is a list of at most 50 evidence items');
  end if;
  for it in select e.value from jsonb_array_elements(v_items) e loop
    if jsonb_typeof(it) is distinct from 'object' then
      perform app.refuse('MR005', 'invalid_item', 'items', 'Each evidence item is an object {kind, title, storage_ref, source_ref}');
    end if;
    v_norm := v_norm || jsonb_build_array(jsonb_build_object(
      'kind', app.arg_enum(it, 'kind', c_kinds),
      'title', app.arg_text(it, 'title', true, 200),
      'storage_ref', app.arg_text(it, 'storage_ref', false, 500),
      'source_ref', app.arg_text(it, 'source_ref', false, 500),
      'ai_generated', coalesce(app.arg_bool(it, 'ai_generated'), false)));
  end loop;
  if jsonb_array_length(v_norm) = 0 and cardinality(v_link) = 0 then
    perform app.refuse('MR005', 'evidence_required', 'items', 'Send new items, evidence_item_ids to link, or both');
  end if;
  if p_args -> 'required_kinds' is null or jsonb_typeof(p_args -> 'required_kinds') = 'null' then
    v_req := array['medical_record'];
  elsif jsonb_typeof(p_args -> 'required_kinds') <> 'array'
     or exists (select 1 from jsonb_array_elements(p_args -> 'required_kinds') x
                 where jsonb_typeof(x.value) <> 'string' or not ((x.value #>> '{}') = any (c_kinds))) then
    perform app.refuse('MR005', 'invalid_required_kinds', 'required_kinds',
      format('required_kinds is a list of: %s', array_to_string(c_kinds, ', ')));
  else
    select coalesce(array_agg(distinct x.value #>> '{}'), '{}') into v_req from jsonb_array_elements(p_args -> 'required_kinds') x;
  end if;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_den := jsonb_populate_record(null::app.denial, app.scoped_row('denial', v_den_id, true));
  if v_den.status not in ('in_evidence', 'in_appeal') then
    perform app.refuse('MR002', 'denial_not_in_evidence_path', 'denial',
      format('The denial is %s; confirm the evidence or appeal path before assembling evidence', v_den.status));
  end if;
  if v_ap_id is not null then
    v_ap := jsonb_populate_record(null::app.appeal, app.scoped_row('appeal', v_ap_id));
    if v_ap.denial_id <> v_den.denial_id then
      perform app.refuse('MR005', 'appeal_denial_mismatch', 'appeal', 'The appeal belongs to another denial');
    end if;
  end if;

  -- existing items to link: tenant-checked and locked in ascending id
  for v_id in select x from unnest(v_link) x order by x loop
    v_ev := jsonb_populate_record(null::app.evidence_item, app.scoped_row('evidence_item', v_id, true));
    if v_ev.claim_id <> v_den.claim_id or (v_ev.denial_id is not null and v_ev.denial_id <> v_den.denial_id) then
      perform app.refuse('MR005', 'evidence_claim_mismatch', 'evidence_item',
        format('Evidence item %s belongs to another claim or denial', v_ev.title));
    end if;
    update app.evidence_item set denial_id = v_den.denial_id, appeal_id = coalesce(v_ap_id, appeal_id)
     where evidence_item_id = v_ev.evidence_item_id;
    v_linked := v_linked || to_jsonb(v_ev.evidence_item_id);
  end loop;

  for it in select e.value from jsonb_array_elements(v_norm) e loop
    insert into app.evidence_item (tenant_id, claim_id, denial_id, appeal_id, kind, title, storage_ref, source_ref, ai_generated)
    values (v_ctx.tenant_id, v_den.claim_id, v_den.denial_id, v_ap_id, it->>'kind', it->>'title', it->>'storage_ref',
            it->>'source_ref', (it->>'ai_generated')::boolean)
    returning evidence_item_id into v_id;
    v_created := v_created || to_jsonb(v_id);
  end loop;

  select coalesce(array_agg(distinct e.kind order by e.kind), '{}') into v_present
    from app.evidence_item e where e.denial_id = v_den.denial_id and e.tenant_id = v_ctx.tenant_id;
  select coalesce(array_agg(k order by k), '{}') into v_missing from unnest(v_req) k where not (k = any (v_present));

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('denial_id', v_den.denial_id, 'claim_id', v_den.claim_id, 'appeal_id', v_ap_id,
                       'evidence_item_ids', v_created || v_linked, 'created_ids', v_created, 'linked_ids', v_linked,
                       'completeness', jsonb_build_object('required', to_jsonb(v_req), 'present', to_jsonb(v_present),
                                                          'missing', to_jsonb(v_missing), 'complete', cardinality(v_missing) = 0)),
    'evidence.assembled', v_den.denial_id);
end;
$$;

comment on function api.cmd_evidence_assemble(text, jsonb) is
$c$evidence.assemble (portal: provider; permission 'evidence.assemble'). Collects evidence for a denial and reports completeness.
args: { denial_id uuid, appeal_id uuid (optional, an appeal of this denial), items [ { kind medical_record|authorization|
  invoice|correspondence|policy|other, title (<= 200), storage_ref, source_ref (<= 500, optional), ai_generated bool } ]
  (<= 50), evidence_item_ids [uuid] (<= 50, existing items of the same claim to link), required_kinds [kind] (default
  ['medical_record']) } -- at least one item or id.
Guards: denial in the caller's tenant (MR004, locked) and in_evidence or in_appeal (MR002 denial_not_in_evidence_path);
  appeal of the same denial (MR005); every linked item in the tenant (MR004, locked in id order) and of the same claim /
  denial (MR005 evidence_claim_mismatch).
Writes: new evidence_item rows (claim, denial, appeal); linked items get denial_id (and appeal_id when given).
result: { denial_id, claim_id, appeal_id, evidence_item_ids[], created_ids[], linked_ids[],
  completeness { required[], present[] (kinds on the denial), missing[], complete } }
event: evidence.assembled (aggregate denial_id).$c$;

-- ================================================================ api.cmd_appeal_draft
create function api.cmd_appeal_draft(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd     constant text := 'appeal.draft';
  v_ctx     app.ctx_t;
  v_cached  jsonb;
  v_ap_id   uuid;
  v_den_id  uuid;
  v_par_id  uuid;
  v_ai_id   uuid;
  v_amount  numeric;
  v_stmts   jsonb;
  v_mode    text;
  v_den     app.denial;
  v_ap      app.appeal;
  v_par     app.appeal;
  v_ai      app.ai_interaction;
  v_cfg     app.payer_config;
  v_due     timestamptz;
  v_dl      uuid;
  s         jsonb;
  v_ids     jsonb;
  v_uns     jsonb;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('appeal.draft');

  v_ap_id  := app.arg_uuid(p_args, 'appeal_id', false);
  v_den_id := app.arg_uuid(p_args, 'denial_id', false);
  v_par_id := app.arg_uuid(p_args, 'parent_appeal_id', false);
  v_ai_id  := app.arg_uuid(p_args, 'ai_interaction_id', false);
  if num_nonnulls(v_ap_id, v_den_id, v_par_id) <> 1 then
    perform app.refuse('MR005', 'one_target_required', 'appeal',
      'Send exactly one of denial_id (new appeal), parent_appeal_id (next level) or appeal_id (amend a draft)');
  end if;
  v_amount := app.arg_numeric(p_args, 'amount', false);
  if v_amount is not null then
    v_amount := app.valid_money(v_amount, 'amount');
  end if;
  v_stmts := app.arg_statements(p_args);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  if v_ai_id is not null then
    v_ai := jsonb_populate_record(null::app.ai_interaction, app.scoped_row('ai_interaction', v_ai_id));
  end if;

  if v_ap_id is not null then
    -- amend a draft: the statement list replaces the current one; the amender becomes the author of record
    v_mode := 'amended';
    v_ap := jsonb_populate_record(null::app.appeal, app.scoped_row('appeal', v_ap_id, true));
    if v_ap.status <> 'drafting' then
      perform app.refuse('MR001', 'illegal_transition', 'appeal',
        format('appeal is %s; only a drafting appeal can be amended', v_ap.status));
    end if;
    select d.* into v_den from app.denial d where d.denial_id = v_ap.denial_id;
    if v_amount is not null then
      perform app.valid_money(v_amount, 'amount', false, v_den.denied_amount);
    end if;
    update app.appeal
       set author_id = v_ctx.user_id, amount = coalesce(v_amount, amount),
           ai_interaction_id = coalesce(v_ai_id, ai_interaction_id)
     where appeal_id = v_ap.appeal_id;
  elsif v_par_id is not null then
    -- next level of an upheld appeal (only when payer_config allows it and its deadline is open)
    v_mode := 'next_level';
    v_par := jsonb_populate_record(null::app.appeal, app.scoped_row('appeal', v_par_id, true));
    if v_par.status <> 'decided' or v_par.decision is distinct from 'upheld' then
      perform app.refuse('MR002', 'parent_not_upheld', 'appeal', 'A next-level appeal follows an upheld decision only');
    end if;
    select a.appeal_id into v_ap_id from app.appeal a where a.parent_appeal_id = v_par.appeal_id limit 1;
    if v_ap_id is not null then
      perform app.refuse('MR002', 'next_level_exists', 'appeal',
        format('The next level is already open as appeal %s; amend that draft (appeal_id)', v_ap_id));
    end if;
    v_cfg := app.claim_payer_config(v_par.claim_id);
    if v_cfg.payer_config_id is null then
      perform app.refuse('MR002', 'payer_rules_missing', 'payer_config', 'The payer has no rules pack in effect');
    end if;
    if v_par.level >= least(v_cfg.appeal_levels, 5) then
      perform app.refuse('MR002', 'appeal_levels_exhausted', 'appeal',
        format('The payer allows %s appeal level(s); no further level is available', v_cfg.appeal_levels));
    end if;
    v_due := coalesce(v_par.decided_at, now()) + make_interval(days => v_cfg.timely_filing_days);
    if v_due < now() then
      perform app.refuse('MR002', 'next_level_deadline_passed', 'deadline', 'The window for the next appeal level has closed');
    end if;
    select d.* into v_den from app.denial d where d.denial_id = v_par.denial_id;
    if v_amount is not null then
      perform app.valid_money(v_amount, 'amount', false, v_den.denied_amount);
    end if;
    insert into app.appeal (tenant_id, claim_id, denial_id, parent_appeal_id, level, status, author_id, amount, ai_interaction_id)
    values (v_ctx.tenant_id, v_par.claim_id, v_par.denial_id, v_par.appeal_id, v_par.level + 1, 'drafting', v_ctx.user_id,
            coalesce(v_amount, v_par.amount), v_ai_id)
    returning * into v_ap;
    insert into app.deadline (tenant_id, subject_type, subject_id, kind, due_at, note)
    values (v_ctx.tenant_id, 'appeal', v_ap.appeal_id, 'appeal_filing', v_due,
            format('Level %s: %s days from the level %s decision (payer_config effective %s)',
                   v_ap.level, v_cfg.timely_filing_days, v_par.level, v_cfg.effective_from))
    returning deadline_id into v_dl;
  else
    -- first-level appeal of a denial on the appeal path
    v_mode := 'created';
    v_den := jsonb_populate_record(null::app.denial, app.scoped_row('denial', v_den_id, true));
    if v_den.status <> 'in_appeal' then
      perform app.refuse('MR002', 'denial_not_in_appeal', 'denial',
        format('The denial is %s; confirm the appeal path before drafting an appeal', v_den.status));
    end if;
    select a.appeal_id into v_ap_id from app.appeal a where a.denial_id = v_den.denial_id and a.level = 1 limit 1;
    if v_ap_id is not null then
      perform app.refuse('MR002', 'appeal_exists', 'appeal',
        format('This denial already has appeal %s; amend it (appeal_id) or draft the next level (parent_appeal_id)', v_ap_id));
    end if;
    v_amount := app.valid_money(coalesce(v_amount, v_den.denied_amount), 'amount', false, v_den.denied_amount);
    insert into app.appeal (tenant_id, claim_id, denial_id, level, status, author_id, amount, ai_interaction_id)
    values (v_ctx.tenant_id, v_den.claim_id, v_den.denial_id, 1, 'drafting', v_ctx.user_id, v_amount, v_ai_id)
    returning * into v_ap;
  end if;

  -- the AI output must be about this appeal, its denial or its claim
  if v_ai_id is not null and v_ai.subject_id is not null
     and v_ai.subject_id not in (v_ap.appeal_id, v_ap.denial_id, v_ap.claim_id) then
    perform app.refuse('MR005', 'ai_interaction_subject_mismatch', 'ai_interaction',
      'The AI interaction is about another subject than this appeal, its denial or its claim');
  end if;

  for s in select e.value from jsonb_array_elements(v_stmts) e loop
    insert into app.appeal_statement (tenant_id, appeal_id, seq, text, source_ref, unsupported)
    values (v_ctx.tenant_id, v_ap.appeal_id, (s->>'seq')::integer, s->>'text', s->>'source_ref', (s->>'unsupported')::boolean)
    on conflict (appeal_id, seq) do update
      set text = excluded.text, source_ref = excluded.source_ref, unsupported = excluded.unsupported, removed_at = null;
  end loop;
  update app.appeal_statement set removed_at = now()
   where appeal_id = v_ap.appeal_id and seq > jsonb_array_length(v_stmts) and removed_at is null;

  select coalesce(jsonb_agg(st.appeal_statement_id order by st.seq), '[]'::jsonb),
         coalesce(jsonb_agg(st.appeal_statement_id order by st.seq) filter (where st.unsupported), '[]'::jsonb)
    into v_ids, v_uns
    from app.appeal_statement st where st.appeal_id = v_ap.appeal_id and st.removed_at is null;
  select a.* into v_ap from app.appeal a where a.appeal_id = v_ap.appeal_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('appeal_id', v_ap.appeal_id, 'denial_id', v_ap.denial_id, 'claim_id', v_ap.claim_id,
                       'parent_appeal_id', v_ap.parent_appeal_id, 'level', v_ap.level, 'status', v_ap.status,
                       'amount', v_ap.amount, 'author_id', v_ap.author_id, 'ai_interaction_id', v_ap.ai_interaction_id,
                       'deadline_id', v_dl, 'mode', v_mode, 'statement_ids', v_ids,
                       'unsupported_statement_ids', v_uns, 'unsupported_count', jsonb_array_length(v_uns)),
    'appeal.drafted', v_ap.appeal_id);
end;
$$;

comment on function api.cmd_appeal_draft(text, jsonb) is
$c$appeal.draft (portal: provider; permission 'appeal.draft'). Creates or amends an appeal in drafting with its statements.
args: exactly one of { denial_id (new level-1 appeal) | parent_appeal_id (next level of an upheld appeal) | appeal_id
  (amend a drafting appeal) }, statements [ { text (<= 4000), source_ref (<= 500), unsupported bool } ] (1..50; a
  statement without source_ref is flagged unsupported; unsupported=false without a source is MR005), amount (optional,
  > 0, 2 dp, <= the denied amount; default the denied amount / the parent's amount), ai_interaction_id (optional; kept
  on amend when not sent, so an AI draft stays an AI draft).
Guards: ids in the caller's tenant (MR004; the target row locked). New: denial in_appeal (MR002 denial_not_in_appeal), no
  level-1 appeal yet (MR002 appeal_exists). Next level: parent decided upheld (MR002 parent_not_upheld), none open yet
  (MR002 next_level_exists), payer_config in effect (MR002 payer_rules_missing) with level < appeal_levels (MR002
  appeal_levels_exhausted), window open (MR002 next_level_deadline_passed). Amend: status drafting (MR001). The AI
  interaction is about the appeal, its denial or its claim (MR005).
Writes: appeal (drafting, author = caller; on amend the amender becomes the author), appeal_statement rows upserted by
  seq, statements beyond the new list get removed_at; next level: also a deadline (subject appeal, appeal_filing,
  decision + timely_filing_days).
result: { appeal_id, denial_id, claim_id, parent_appeal_id, level, status, amount, author_id, ai_interaction_id,
  deadline_id, mode created|amended|next_level, statement_ids[], unsupported_statement_ids[], unsupported_count }
event: appeal.drafted (aggregate appeal_id).$c$;

-- ================================================================ api.cmd_appeal_request_approval
create function api.cmd_appeal_request_approval(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'appeal.request_approval';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_ap_id  uuid;
  v_ap     app.appeal;
  v_n      integer;
  v_bad    text;
  v_ar     uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('appeal.request_approval');

  v_ap_id := app.arg_uuid(p_args, 'appeal_id');

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_ap := jsonb_populate_record(null::app.appeal, app.scoped_row('appeal', v_ap_id, true));
  if v_ap.status <> 'drafting' then
    perform app.refuse('MR001', 'illegal_transition', 'appeal',
      format('appeal cannot move from %s to pending_approval', v_ap.status));
  end if;
  if not exists (select 1 from app.appeal_statement s where s.appeal_id = v_ap.appeal_id and s.removed_at is null) then
    perform app.refuse('MR002', 'appeal_has_no_statements', 'appeal', 'Draft at least one statement before requesting approval');
  end if;
  -- IV14 / IV15: every statement has a source; name each blocking statement
  select count(*), string_agg(format('statement %s (%s): "%s"', s.seq, s.appeal_statement_id, left(s.text, 80)), '; ' order by s.seq)
    into v_n, v_bad
    from app.appeal_statement s
   where s.appeal_id = v_ap.appeal_id and s.removed_at is null and (s.unsupported or s.source_ref is null);
  if v_n > 0 then
    perform app.refuse('MR002', 'IV14_unsupported_statement', 'appeal_statement',
      format('%s unsupported statement(s) block approval: %s. Add a source or remove the statement, then request approval again',
             v_n, v_bad));
  end if;
  if v_ap.amount <= 0 then
    perform app.refuse('MR002', 'appeal_amount_missing', 'appeal', 'Set the disputed amount before requesting approval');
  end if;
  if exists (select 1 from app.approval_request q
              where q.tenant_id = v_ctx.tenant_id and q.subject_type = 'appeal' and q.subject_id = v_ap.appeal_id
                and q.status = 'pending') then
    perform app.refuse('MR002', 'approval_pending', 'approval_request', 'An approval request for this appeal is already pending');
  end if;

  insert into app.approval_request (tenant_id, kind, amount, requester_id, status, subject_type, subject_id)
  values (v_ctx.tenant_id, 'appeal', v_ap.amount, v_ctx.user_id, 'pending', 'appeal', v_ap.appeal_id)
  returning approval_request_id into v_ar;
  update app.appeal set status = 'pending_approval' where appeal_id = v_ap.appeal_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('appeal_id', v_ap.appeal_id, 'approval_request_id', v_ar, 'subject_id', v_ar,
                       'status', 'pending_approval', 'amount', v_ap.amount, 'requester_id', v_ctx.user_id),
    'approval.requested', v_ar);
end;
$$;

comment on function api.cmd_appeal_request_approval(text, jsonb) is
$c$appeal.request_approval (portal: provider; permission 'appeal.request_approval'). drafting -> pending_approval.
args: { appeal_id uuid }
Guards: appeal in the caller's tenant (MR004, locked); status drafting (MR001); at least one statement (MR002); no
  unsupported or unsourced statement, IV14 / IV15 (MR002 IV14_unsupported_statement, the message names every blocking
  statement by number and id); amount > 0 (MR002); no other pending request (MR002 approval_pending).
Writes: approval_request (kind 'appeal', amount = the disputed amount, requester = caller, subject appeal, pending);
  appeal pending_approval.
result: { appeal_id, approval_request_id, subject_id (= approval_request_id), status, amount, requester_id }
event: approval.requested (aggregate approval_request_id).$c$;

-- ================================================================ api.cmd_approval_decide
create function api.cmd_approval_decide(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd     constant text := 'approval.decide';
  v_ctx     app.ctx_t;
  v_cached  jsonb;
  v_ar_id   uuid;
  v_dec     text;
  v_reason  text;
  v_ar      app.approval_request;
  v_ap      app.appeal;
  v_limit   numeric;
  v_next    jsonb;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('approval.decide');

  v_ar_id  := app.arg_uuid(p_args, 'approval_request_id');
  v_dec    := app.arg_enum(p_args, 'decision', array['approved','rejected']);
  v_reason := app.arg_text(p_args, 'reason', false, 2000);
  if v_dec = 'rejected' and v_reason is null then
    perform app.refuse('MR005', 'reason_required', 'reason', 'Say why the request is rejected so the author can fix it');
  end if;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  -- lock order: the subject appeal first, then the request
  v_ar := jsonb_populate_record(null::app.approval_request, app.scoped_row('approval_request', v_ar_id));
  if v_ar.subject_type = 'appeal' then
    v_ap := jsonb_populate_record(null::app.appeal, app.scoped_row('appeal', v_ar.subject_id, true));
  end if;
  select q.* into v_ar from app.approval_request q where q.approval_request_id = v_ar.approval_request_id for update;
  if v_ar.status <> 'pending' then
    perform app.refuse('MR001', 'illegal_transition', 'approval_request',
      format('approval_request cannot move from %s to %s', v_ar.status, v_dec));
  end if;

  -- IV13 segregation of duties: the requester and anyone who wrote the appeal cannot decide it
  if v_ctx.user_id = v_ar.requester_id
     or (v_ap.appeal_id is not null and v_ctx.user_id = any (app.appeal_contributors(v_ap.appeal_id))) then
    perform app.refuse('MR003', 'IV13_self_approval', 'approval_request',
      'You drafted or requested this work, so someone else must decide it');
  end if;
  if v_dec = 'approved' then
    v_limit := app.approver_limit(v_ctx.tenant_id, v_ctx.user_id, v_ar.kind);
    if v_limit is null then
      perform app.refuse('MR003', 'IV13_no_approval_authority', 'approval_request',
        format('Your role has no approval limit for %s requests', v_ar.kind));
    end if;
    if v_ar.amount > v_limit then
      perform app.refuse('MR003', 'IV13_approval_limit_exceeded', 'approval_request',
        format('%s exceeds your %s approval limit of %s; ask someone with a higher limit', v_ar.amount, v_ar.kind, v_limit));
    end if;
  end if;
  if v_ap.appeal_id is not null and v_ap.status <> 'pending_approval' then
    perform app.refuse('MR001', 'illegal_transition', 'appeal',
      format('appeal is %s, not pending_approval', v_ap.status));
  end if;

  update app.approval_request
     set status = v_dec, approver_id = v_ctx.user_id, reason = coalesce(v_reason, reason)
   where approval_request_id = v_ar.approval_request_id;
  if v_ap.appeal_id is not null then
    if v_dec = 'approved' then
      update app.appeal set status = 'approved', approver_id = v_ctx.user_id where appeal_id = v_ap.appeal_id;
    else
      update app.appeal set status = 'drafting' where appeal_id = v_ap.appeal_id;
    end if;
    v_next := jsonb_build_object('appeal_id', v_ap.appeal_id,
                                 'status', case when v_dec = 'approved' then 'approved' else 'drafting' end);
  end if;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('approval_request_id', v_ar.approval_request_id, 'subject_id', v_ar.approval_request_id,
                       'appeal_id', v_ap.appeal_id, 'decision', v_dec, 'status', v_dec, 'kind', v_ar.kind,
                       'amount', v_ar.amount, 'decided_by', v_ctx.user_id,
                       'within_limit', case when v_dec = 'approved' then true end, 'next', v_next),
    'approval.decided', v_ar.approval_request_id);
end;
$$;

comment on function api.cmd_approval_decide(text, jsonb) is
$c$approval.decide (portal: provider; permission 'approval.decide'). Decides a pending approval_request (any kind; an
appeal subject also moves). The approver is always the caller (app.ctx()), never an argument.
args: { approval_request_id uuid, decision approved|rejected, reason (required when rejected, <= 2000) }
Guards: request in the caller's tenant (MR004); the subject appeal locked before the request; status pending (MR001);
  IV13 checked here, before the table trigger, with clean refusals: the caller is not the requester, the appeal's author,
  its creator or a writer of one of its statements (MR003 IV13_self_approval); approving needs a limit for the kind
  (MR003 IV13_no_approval_authority) that covers the amount (MR003 IV13_approval_limit_exceeded); an appeal subject is
  pending_approval (MR001).
Writes: approval_request approved | rejected with approver = caller (decided_at by the trigger, which re-checks IV13);
  appeal: approved -> approved (approver_id = caller); rejected -> back to drafting.
result: { approval_request_id, subject_id (= approval_request_id), appeal_id, decision, status, kind, amount,
  decided_by, within_limit, next { appeal_id, status } }
event: approval.decided (aggregate approval_request_id; handover H18).$c$;

-- ================================================================ api.cmd_appeal_file
create function api.cmd_appeal_file(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'appeal.file';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_ap_id  uuid;
  v_ref    text;
  v_ap     app.appeal;
  v_rev    text;
  v_dl     app.deadline;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('appeal.file');

  v_ap_id := app.arg_uuid(p_args, 'appeal_id');
  v_ref   := app.arg_text(p_args, 'submission_ref', false, 200);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_ap := jsonb_populate_record(null::app.appeal, app.scoped_row('appeal', v_ap_id, true));
  if v_ap.status <> 'approved' then
    perform app.refuse('MR001', 'illegal_transition', 'appeal', format('appeal cannot move from %s to filed', v_ap.status));
  end if;
  if not exists (select 1 from app.approval_request q
                  where q.tenant_id = v_ctx.tenant_id and q.subject_type = 'appeal' and q.subject_id = v_ap.appeal_id
                    and q.status = 'approved') then
    perform app.refuse('MR002', 'approval_missing', 'approval_request', 'The appeal has no approved approval request');
  end if;
  -- IV16: an AI-drafted appeal leaves the building only after a person approved the AI output (latest review wins)
  if v_ap.ai_interaction_id is not null then
    select r.decision into v_rev from app.ai_review r
     where r.ai_interaction_id = v_ap.ai_interaction_id and r.tenant_id = v_ctx.tenant_id
     order by r.reviewed_at desc, r.created_at desc, r.ai_review_id desc
     limit 1;
    if v_rev is distinct from 'approved' then
      perform app.refuse('MR002', 'IV16_ai_review_required', 'ai_interaction',
        format('This appeal was drafted with AI (interaction %s); a reviewer must approve the AI output (ai.review) before filing',
               v_ap.ai_interaction_id));
    end if;
  end if;
  -- the filing deadline: the appeal's own (next levels), else the denial's appeal_filing deadline (level 1)
  select d.* into v_dl from app.deadline d
   where d.tenant_id = v_ctx.tenant_id and d.kind = 'appeal_filing' and d.met_at is null
     and ((d.subject_type = 'appeal' and d.subject_id = v_ap.appeal_id)
          or (v_ap.level = 1 and d.subject_type = 'denial' and d.subject_id = v_ap.denial_id))
   order by (d.subject_type = 'appeal') desc, d.due_at
   limit 1
     for update;
  if v_dl.deadline_id is null then
    perform app.refuse('MR002', 'appeal_deadline_missing', 'deadline', 'No open appeal filing deadline exists for this appeal');
  end if;
  if v_dl.due_at < now() then
    perform app.refuse('MR002', 'appeal_deadline_passed', 'deadline',
      format('The appeal filing deadline passed on %s; the appeal cannot be filed', to_char(v_dl.due_at, 'YYYY-MM-DD')));
  end if;

  update app.appeal
     set status = 'filed', filed_at = now(),
         submission_ref = coalesce(v_ref, 'FILED-' || upper(left(replace(v_ap.appeal_id::text, '-', ''), 12)))
   where appeal_id = v_ap.appeal_id
  returning * into v_ap;
  update app.deadline set met_at = now() where deadline_id = v_dl.deadline_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('appeal_id', v_ap.appeal_id, 'status', 'filed', 'filed_at', v_ap.filed_at,
                       'deadline_id', v_dl.deadline_id, 'submission_ref', v_ap.submission_ref, 'level', v_ap.level),
    'appeal.filed', v_ap.appeal_id);
end;
$$;

comment on function api.cmd_appeal_file(text, jsonb) is
$c$appeal.file (portal: provider; permission 'appeal.file'). approved -> filed.
args: { appeal_id uuid, submission_ref text (the payer's receipt, optional, <= 200; a synthetic one is generated) }
Guards: appeal in the caller's tenant (MR004, locked); status approved (MR001; filing before approval is refused); an
  approved approval_request exists (MR002 approval_missing); IV16: an appeal with ai_interaction_id needs its latest
  ai_review to be 'approved' (MR002 IV16_ai_review_required); an open appeal_filing deadline (the appeal's own, else for
  level 1 the denial's) exists (MR002 appeal_deadline_missing) and has not passed (MR002 appeal_deadline_passed).
Writes: appeal filed, filed_at, submission_ref; the deadline met_at.
result: { appeal_id, status, filed_at, deadline_id, submission_ref, level }   event: appeal.filed (aggregate appeal_id).$c$;

-- ================================================================ api.cmd_appeal_record_decision (payer portal)
create function api.cmd_appeal_record_decision(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'appeal.record_decision';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_ap_id  uuid;
  v_dec    text;
  v_amount numeric;
  v_reason text;
  v_ap     app.appeal;
  v_cfg    app.payer_config;
  v_child  app.appeal;
  v_dl     uuid;
  v_due    timestamptz;
  v_why    text;
begin
  v_ctx := app.ctx();
  perform app.require_portal('payer');
  perform app.authorize('appeal.record_decision');

  v_ap_id  := app.arg_uuid(p_args, 'appeal_id');
  v_dec    := app.arg_enum(p_args, 'decision', array['overturned','overturned_in_part','upheld']);
  v_amount := app.arg_numeric(p_args, 'amount', false);
  v_reason := app.arg_text(p_args, 'reason', false, 2000);
  if v_dec = 'upheld' and v_amount is not null and v_amount <> 0 then
    perform app.refuse('MR005', 'upheld_has_no_amount', 'amount', 'An upheld decision pays nothing; leave the amount out');
  end if;
  if v_dec = 'overturned_in_part' and v_amount is null then
    perform app.refuse('MR005', 'required', 'amount', 'amount is required for a partial overturn');
  end if;
  if v_dec <> 'upheld' and v_amount is not null then
    v_amount := app.valid_money(v_amount, 'amount');
  end if;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_ap := app.payer_appeal(v_ap_id, true);
  if v_ap.status <> 'filed' then
    perform app.refuse('MR001', 'illegal_transition', 'appeal', format('appeal cannot move from %s to decided', v_ap.status));
  end if;
  if v_dec = 'overturned' then
    v_amount := app.valid_money(coalesce(v_amount, v_ap.amount), 'amount', false, v_ap.amount);
  elsif v_dec = 'overturned_in_part' then
    v_amount := app.valid_money(v_amount, 'amount', false, v_ap.amount);
    if v_amount >= v_ap.amount then
      perform app.refuse('MR005', 'partial_amount_not_less', 'amount',
        format('A partial overturn pays less than the disputed %s; use overturned for the full amount', v_ap.amount));
    end if;
  else
    v_amount := 0;
  end if;

  update app.appeal
     set status = 'decided', decided_at = now(), decision = v_dec, decision_amount = v_amount,
         expected_payment = case when v_dec = 'upheld' then null else v_amount end,
         decision_reason = v_reason, decided_by = v_ctx.user_id
   where appeal_id = v_ap.appeal_id
  returning * into v_ap;

  -- upheld: open the next level when payer_config allows another level and its window is open
  if v_dec = 'upheld' then
    v_cfg := app.claim_payer_config(v_ap.claim_id);
    if v_cfg.payer_config_id is null then
      v_why := 'payer_rules_missing';
    elsif v_ap.level >= least(v_cfg.appeal_levels, 5) then
      v_why := 'appeal_levels_exhausted';
    else
      v_due := v_ap.decided_at + make_interval(days => v_cfg.timely_filing_days);
      if v_due < now() then
        v_why := 'next_level_deadline_passed';
      else
        insert into app.appeal (tenant_id, claim_id, denial_id, parent_appeal_id, level, status, author_id, amount)
        values (v_ap.tenant_id, v_ap.claim_id, v_ap.denial_id, v_ap.appeal_id, v_ap.level + 1, 'drafting', v_ap.author_id, v_ap.amount)
        returning * into v_child;
        insert into app.deadline (tenant_id, subject_type, subject_id, kind, due_at, note)
        values (v_ap.tenant_id, 'appeal', v_child.appeal_id, 'appeal_filing', v_due,
                format('Level %s: %s days from the level %s decision (payer_config effective %s)',
                       v_child.level, v_cfg.timely_filing_days, v_ap.level, v_cfg.effective_from))
        returning deadline_id into v_dl;
        perform app.emit_event('appeal.drafted', v_child.appeal_id,
          jsonb_build_object('appeal_id', v_child.appeal_id, 'parent_appeal_id', v_ap.appeal_id,
                             'denial_id', v_ap.denial_id, 'deadline_id', v_dl), c_cmd, p_idem);
      end if;
    end if;
  else
    v_why := 'not_upheld';
  end if;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('appeal_id', v_ap.appeal_id, 'claim_id', v_ap.claim_id, 'denial_id', v_ap.denial_id,
                       'status', 'decided', 'decision', v_dec, 'decision_amount', v_amount,
                       'expected_payment', v_ap.expected_payment, 'next_appeal_id', v_child.appeal_id,
                       'next_level', jsonb_build_object('opened', v_child.appeal_id is not null, 'appeal_id', v_child.appeal_id,
                                                        'level', v_child.level, 'deadline_id', v_dl, 'due_at', v_due,
                                                        'reason', v_why)),
    'appeal.decided', v_ap.appeal_id);
end;
$$;

comment on function api.cmd_appeal_record_decision(text, jsonb) is
$c$appeal.record_decision (portal: payer; permission 'appeal.record_decision'). filed -> decided. Scope: the appeal's
claim is billed to the caller's payer (ctx.party_id); another payer's appeal, an unfiled one or a missing id is the same
MR004 not_found('appeal').
args: { appeal_id uuid, decision overturned|overturned_in_part|upheld, amount (overturned: optional, default and max the
  disputed amount; overturned_in_part: required, > 0 and < the disputed amount; upheld: none), reason (optional) }
Guards: scope (MR004, locked); status filed (MR001); amounts (MR005).
Writes: appeal decided, decided_at, decision, decision_amount, expected_payment (overturns only; NO cash is posted here,
  cash arrives only through the remittance commands), decision_reason, decided_by = caller. Upheld and payer_config
  appeal_levels > level and the next window (decision + timely_filing_days) open: a next-level appeal (drafting,
  parent_appeal_id, same author and amount) and its appeal_filing deadline.
result: { appeal_id, claim_id, denial_id, status, decision, decision_amount, expected_payment, next_appeal_id,
  next_level { opened, appeal_id, level, deadline_id, due_at, reason } }
events: appeal.decided (aggregate appeal_id); appeal.drafted for an opened next level (aggregate the new appeal_id).$c$;

-- ================================================================ api.cmd_records_request_respond
create function api.cmd_records_request_respond(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'records_request.respond';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_rr_id  uuid;
  v_ids    uuid[];
  v_note   text;
  v_rr     app.records_request;
  v_ev     app.evidence_item;
  v_id     uuid;
  v_linked jsonb := '[]'::jsonb;
  v_met    jsonb;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('records_request.respond');

  v_rr_id := app.arg_uuid(p_args, 'records_request_id');
  v_ids   := app.arg_uuid_list(p_args, 'evidence_item_ids');
  v_note  := app.arg_text(p_args, 'note', false, 2000);
  if cardinality(v_ids) = 0 then
    perform app.refuse('MR005', 'evidence_required', 'evidence_item_ids', 'Answer the request with at least one evidence item');
  end if;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_rr := jsonb_populate_record(null::app.records_request, app.scoped_row('records_request', v_rr_id, true));
  if v_rr.status <> 'open' then
    perform app.refuse('MR001', 'illegal_transition', 'records_request',
      format('records_request cannot move from %s to responded', v_rr.status));
  end if;
  for v_id in select x from unnest(v_ids) x order by x loop
    v_ev := jsonb_populate_record(null::app.evidence_item, app.scoped_row('evidence_item', v_id, true));
    if v_ev.claim_id <> v_rr.claim_id then
      perform app.refuse('MR005', 'evidence_claim_mismatch', 'evidence_item',
        format('Evidence item %s belongs to another claim', v_ev.title));
    end if;
    if v_ev.records_request_id is not null and v_ev.records_request_id <> v_rr.records_request_id then
      perform app.refuse('MR002', 'evidence_linked_elsewhere', 'evidence_item',
        format('Evidence item %s already answers another records request', v_ev.title));
    end if;
    update app.evidence_item set records_request_id = v_rr.records_request_id where evidence_item_id = v_ev.evidence_item_id;
    v_linked := v_linked || to_jsonb(v_ev.evidence_item_id);
  end loop;

  update app.records_request
     set status = 'responded', responded_at = now(), responded_by = v_ctx.user_id, response_note = v_note
   where records_request_id = v_rr.records_request_id;
  with met as (
    update app.deadline d set met_at = now()
     where d.tenant_id = v_ctx.tenant_id and d.kind = 'records_response' and d.met_at is null
       and ((d.subject_type = 'records_request' and d.subject_id = v_rr.records_request_id)
            or (v_rr.denial_id is not null and d.subject_type = 'denial' and d.subject_id = v_rr.denial_id))
    returning d.deadline_id)
  select coalesce(jsonb_agg(met.deadline_id order by met.deadline_id), '[]'::jsonb) into v_met from met;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('records_request_id', v_rr.records_request_id, 'claim_id', v_rr.claim_id, 'denial_id', v_rr.denial_id,
                       'status', 'responded', 'evidence_item_ids', v_linked, 'met_deadline_ids', v_met,
                       'late', v_rr.due_at is not null and v_rr.due_at < now()),
    'records_request.responded', v_rr.records_request_id);
end;
$$;

comment on function api.cmd_records_request_respond(text, jsonb) is
$c$records_request.respond (portal: provider; permission 'records_request.respond'). open -> responded.
args: { records_request_id uuid, evidence_item_ids [uuid] (1..50), note text (optional) }
Guards: request in the caller's tenant (MR004, locked); status open (MR001); every item in the tenant (MR004, locked in
  id order), of the request's claim (MR005 evidence_claim_mismatch) and not answering another request (MR002
  evidence_linked_elsewhere). A late answer is allowed and reported (late = true).
Writes: evidence items linked (records_request_id); request responded, responded_at, responded_by = caller,
  response_note; open records_response deadlines of the request (or its denial) met.
result: { records_request_id, claim_id, denial_id, status, evidence_item_ids[], met_deadline_ids[], late }
event: records_request.responded (aggregate records_request_id).$c$;

-- ================================================================ api.cmd_records_request_decide (payer portal)
create function api.cmd_records_request_decide(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'records_request.decide';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_rr_id  uuid;
  v_dec    text;
  v_reason text;
  v_rr     app.records_request;
begin
  v_ctx := app.ctx();
  perform app.require_portal('payer');
  perform app.authorize('records_request.decide');

  v_rr_id  := app.arg_uuid(p_args, 'records_request_id');
  v_dec    := app.arg_enum(p_args, 'decision', array['accepted','rejected']);
  v_reason := app.arg_text(p_args, 'reason', false, 2000);
  if v_dec = 'rejected' and v_reason is null then
    perform app.refuse('MR005', 'reason_required', 'reason', 'Say what is missing so the provider can answer again');
  end if;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_rr := app.payer_records_request(v_rr_id, true);
  if v_rr.status <> 'responded' then
    perform app.refuse('MR001', 'illegal_transition', 'records_request',
      format('records_request cannot move from %s to %s', v_rr.status, v_dec));
  end if;
  update app.records_request
     set status = v_dec, decided_at = now(), decided_by = v_ctx.user_id, decision_reason = v_reason
   where records_request_id = v_rr.records_request_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('records_request_id', v_rr.records_request_id, 'claim_id', v_rr.claim_id, 'denial_id', v_rr.denial_id,
                       'status', v_dec, 'decision', v_dec),
    'records_request.decided', v_rr.records_request_id);
end;
$$;

comment on function api.cmd_records_request_decide(text, jsonb) is
$c$records_request.decide (portal: payer; permission 'records_request.decide'). responded -> accepted | rejected.
Scope: the request's claim is billed to the caller's payer; anything else is MR004 not_found('records_request').
args: { records_request_id uuid, decision accepted|rejected, reason (required when rejected) }
Guards: scope (MR004, locked); status responded (MR001).
Writes: request accepted | rejected, decided_at, decided_by = caller, decision_reason.
result: { records_request_id, claim_id, denial_id, status, decision }   event: records_request.decided (aggregate records_request_id).$c$;

-- ================================================================ api.cmd_ai_review
create function api.cmd_ai_review(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'ai.review';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_ai_id  uuid;
  v_dec    text;
  v_reason text;
  v_ai     app.ai_interaction;
  v_rev    uuid;
  v_status text;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('ai.review');

  v_ai_id  := app.arg_uuid(p_args, 'ai_interaction_id');
  v_dec    := app.arg_enum(p_args, 'decision', array['approved','rejected']);
  v_reason := app.arg_text(p_args, 'reason', true, 2000);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  v_ai := jsonb_populate_record(null::app.ai_interaction, app.scoped_row('ai_interaction', v_ai_id, true));
  if v_ai.status = 'expired' then
    perform app.refuse('MR001', 'illegal_transition', 'ai_interaction', 'The AI output has expired; run the task again');
  end if;
  v_status := case when v_dec = 'approved' then 'accepted' else 'rejected' end;
  insert into app.ai_review (tenant_id, ai_interaction_id, reviewer_id, decision, reason, reviewed_at)
  values (v_ctx.tenant_id, v_ai.ai_interaction_id, v_ctx.user_id, v_dec, v_reason, clock_timestamp())
  returning ai_review_id into v_rev;
  update app.ai_interaction set status = v_status where ai_interaction_id = v_ai.ai_interaction_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('ai_review_id', v_rev, 'ai_interaction_id', v_ai.ai_interaction_id, 'decision', v_dec,
                       'status', v_status, 'reviewer_id', v_ctx.user_id),
    'ai.reviewed', v_ai.ai_interaction_id);
end;
$$;

comment on function api.cmd_ai_review(text, jsonb) is
$c$ai.review (portal: provider; permission 'ai.review'). A person's decision on an AI output (IV16).
args: { ai_interaction_id uuid, decision approved|rejected, reason text (required, <= 2000) }
Guards: interaction in the caller's tenant (MR004, locked); not expired (MR001). Several reviews may exist; the latest
  one counts (appeal.file reads it).
Writes: ai_review (reviewer = caller, reviewed_at = clock time); ai_interaction status accepted | rejected.
result: { ai_review_id, ai_interaction_id, decision, status, reviewer_id }   event: ai.reviewed (aggregate ai_interaction_id).$c$;

-- ================================================================ api.cmd_ai_interaction_record
create function api.cmd_ai_interaction_record(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd    constant text := 'ai.interaction_record';
  v_ctx    app.ctx_t;
  v_cached jsonb;
  v_task   text;
  v_stype  text;
  v_sid    uuid;
  v_mv     text;
  v_mv_id  uuid;
  v_input  text;
  v_out    jsonb;
  v_label  text;
  v_id     uuid;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('ai.interaction_record');

  v_task  := app.arg_text(p_args, 'task', true, 80);
  v_stype := app.arg_enum(p_args, 'subject_type', array['claim','denial','appeal','records_request','evidence_item'], false);
  v_sid   := app.arg_uuid(p_args, 'subject_id', false);
  if (v_stype is null) <> (v_sid is null) then
    perform app.refuse('MR005', 'subject_pair', 'subject_id', 'Send subject_type and subject_id together');
  end if;
  v_mv    := app.arg_text(p_args, 'model_version', true, 120);
  v_mv_id := app.arg_uuid(p_args, 'model_version_id', false);
  v_input := app.arg_text(p_args, 'input_ref', false, 500);
  v_out   := p_args -> 'output';
  if jsonb_typeof(v_out) is distinct from 'object' or length(v_out::text) > 65536 then
    perform app.refuse('MR005', 'invalid_output', 'output', 'output is a JSON object of at most 64 KB');
  end if;
  v_label := coalesce(app.arg_text(p_args, 'label', false, 40), 'Simulated');
  if v_label <> 'Simulated' then
    perform app.refuse('MR005', 'label_must_be_simulated', 'label', 'All AI output in this prototype is labelled Simulated');
  end if;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  if v_sid is not null then
    perform app.scoped_row(v_stype, v_sid);       -- table name from the fixed list above
  end if;
  if v_mv_id is not null then
    perform app.scoped_row('ai_model_version', v_mv_id);
  end if;

  insert into app.ai_interaction (tenant_id, task, subject_type, subject_id, model_version_id, model_version, input_ref,
                                  output, label, status)
  values (v_ctx.tenant_id, v_task, v_stype, v_sid, v_mv_id, v_mv, v_input, v_out, 'Simulated', 'suggested')
  returning ai_interaction_id into v_id;

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('ai_interaction_id', v_id, 'task', v_task, 'subject_type', v_stype, 'subject_id', v_sid,
                       'model_version', v_mv, 'model_version_id', v_mv_id, 'label', 'Simulated', 'status', 'suggested'),
    'ai.interaction_recorded', v_id);
end;
$$;

comment on function api.cmd_ai_interaction_record(text, jsonb) is
$c$ai.interaction_record (portal: provider; permission 'ai.interaction_record'). Stores one AI task output (spec 7.3);
called by the ai-standin Edge Function with the signed-in user's token.
args: { task text (<= 80, e.g. 'appeal.draft'), subject_type claim|denial|appeal|records_request|evidence_item and
  subject_id uuid (optional, together), model_version text (required, <= 120), model_version_id uuid (optional),
  input_ref text (a reference, never raw text; optional), output jsonb object (<= 64 KB), label (optional, must be
  'Simulated') }
Guards: subject and model version in the caller's tenant (MR004).
Writes: ai_interaction (label 'Simulated', status suggested).
result: { ai_interaction_id, task, subject_type, subject_id, model_version, model_version_id, label, status }
event: ai.interaction_recorded (aggregate ai_interaction_id).$c$;

-- ================================================================ grants
revoke all on function app.arg_bool(jsonb, text) from public, anon, authenticated;
revoke all on function app.arg_uuid_list(jsonb, text, integer) from public, anon, authenticated;
revoke all on function app.arg_statements(jsonb) from public, anon, authenticated;
revoke all on function app.appeal_contributors(uuid) from public, anon, authenticated;
revoke all on function app.claim_payer_config(uuid) from public, anon, authenticated;
revoke all on function app.payer_appeal(uuid, boolean) from public, anon, authenticated;
revoke all on function app.payer_records_request(uuid, boolean) from public, anon, authenticated;

revoke all on function api.cmd_evidence_assemble(text, jsonb) from public, anon;
revoke all on function api.cmd_appeal_draft(text, jsonb) from public, anon;
revoke all on function api.cmd_appeal_request_approval(text, jsonb) from public, anon;
revoke all on function api.cmd_approval_decide(text, jsonb) from public, anon;
revoke all on function api.cmd_appeal_file(text, jsonb) from public, anon;
revoke all on function api.cmd_appeal_record_decision(text, jsonb) from public, anon;
revoke all on function api.cmd_records_request_respond(text, jsonb) from public, anon;
revoke all on function api.cmd_records_request_decide(text, jsonb) from public, anon;
revoke all on function api.cmd_ai_review(text, jsonb) from public, anon;
revoke all on function api.cmd_ai_interaction_record(text, jsonb) from public, anon;
grant execute on function api.cmd_evidence_assemble(text, jsonb) to authenticated;
grant execute on function api.cmd_appeal_draft(text, jsonb) to authenticated;
grant execute on function api.cmd_appeal_request_approval(text, jsonb) to authenticated;
grant execute on function api.cmd_approval_decide(text, jsonb) to authenticated;
grant execute on function api.cmd_appeal_file(text, jsonb) to authenticated;
grant execute on function api.cmd_appeal_record_decision(text, jsonb) to authenticated;
grant execute on function api.cmd_records_request_respond(text, jsonb) to authenticated;
grant execute on function api.cmd_records_request_decide(text, jsonb) to authenticated;
grant execute on function api.cmd_ai_review(text, jsonb) to authenticated;
grant execute on function api.cmd_ai_interaction_record(text, jsonb) to authenticated;

-- new columns are covered by the existing table-level SELECT grants; restated for clarity
revoke all on all tables in schema app from public, anon, authenticated;
grant select on all tables in schema app to authenticated;
