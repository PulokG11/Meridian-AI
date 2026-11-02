-- 007b_cmd_appeals_fixes: Task 7 review fix round 1 (007_cmd_appeals stays as applied). Synthetic data.
--  1. IV13: who wrote an appeal is recorded in an append-only table app.appeal_contributor (author, editor,
--     requester). app.appeal_contributors() reads it, so the self-approval check in cmd_approval_decide refuses
--     everyone who ever created, edited (even re-sending unchanged text) or requested approval of the appeal.
--     Rows are written by cmd_appeal_draft (author on create / next level, editor on every amend), by a trigger on
--     app.appeal (the author of every new appeal row and of every author change, which also covers the next-level
--     appeal opened by the payer decision) and by a trigger on app.approval_request (the requester of an appeal).
--  2. IV16: cmd_ai_review refuses a reviewer who recorded the AI interaction or wrote an appeal linked to it (MR003
--     IV16_reviewer_not_independent). appeal.ai_interaction_id, once set, never changes (cmd_appeal_draft MR002
--     IV16_ai_link_immutable; trigger appeal_ai_link_guard as backstop). Linking needs an interaction with task
--     'appeal.draft' whose subject_id is the appeal or its denial (MR005). cmd_appeal_file needs the latest review to
--     be 'approved' and an approval by an independent reviewer (not the recorder, not a contributor) that is later
--     than every rejection.
--  3. IV15: source_ref is a typed reference '<type>:<uuid>' (type evidence_item, claim, claim_service_line,
--     remittance_line, coverage). A ref that does not parse, or does not resolve to a row of the caller's tenant tied
--     to the appeal's claim, is refused MR005 IV15_source_unresolved naming the statement (one message whether the
--     row is missing, in another tenant or on another claim). A statement without source_ref stays allowed and
--     flagged unsupported (IV14 blocks request_approval).
-- Command names, argument fields, result shapes, permission keys and event names are unchanged.

-- ================================================================ 1. app.appeal_contributor
create table app.appeal_contributor (
  appeal_contributor_id uuid primary key default app.uuid_v7(),
  tenant_id  uuid not null references app.tenant (tenant_id),
  appeal_id  uuid not null references app.appeal (appeal_id),
  user_id    uuid not null references app.app_user (user_id),
  role       text not null check (role in ('author', 'editor', 'requester')),
  first_at   timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint appeal_contributor_once unique (appeal_id, user_id, role)
);
create index appeal_contributor_tenant_idx on app.appeal_contributor (tenant_id);
create index appeal_contributor_user_idx   on app.appeal_contributor (user_id);
-- appeal_id is the leading column of appeal_contributor_once.

create trigger appeal_contributor_touch before insert or update on app.appeal_contributor
  for each row execute function app.touch();
create trigger appeal_contributor_no_modify before update or delete on app.appeal_contributor
  for each row execute function app.append_only();
create trigger appeal_contributor_no_truncate before truncate on app.appeal_contributor
  for each statement execute function app.append_only();

alter table app.appeal_contributor enable row level security;
create policy tenant_staff_select on app.appeal_contributor for select to authenticated using (app.in_scope(tenant_id));

-- Backfill (no appeals exist yet; kept for completeness): authors, creators and requesters of existing appeals.
insert into app.appeal_contributor (tenant_id, appeal_id, user_id, role)
select a.tenant_id, a.appeal_id, a.author_id, 'author' from app.appeal a
union
select a.tenant_id, a.appeal_id, a.created_by, 'author' from app.appeal a
 where a.created_by is not null and exists (select 1 from app.app_user u where u.user_id = a.created_by)
union
select q.tenant_id, q.subject_id, q.requester_id, 'requester' from app.approval_request q
 where q.subject_type = 'appeal' and exists (select 1 from app.appeal a where a.appeal_id = q.subject_id)
on conflict on constraint appeal_contributor_once do nothing;

-- The author of every new appeal row (including the next level opened by the payer decision) and every new author.
create function app.appeal_contributor_author() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into app.appeal_contributor (tenant_id, appeal_id, user_id, role)
  values (new.tenant_id, new.appeal_id, new.author_id, 'author')
  on conflict on constraint appeal_contributor_once do nothing;
  return null;
end;
$$;
create trigger appeal_contributor_author after insert or update of author_id on app.appeal
  for each row execute function app.appeal_contributor_author();

-- The requester of an approval for an appeal (cmd_appeal_request_approval creates it with requester = the caller).
create function app.appeal_contributor_requester() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.subject_type = 'appeal' then
    insert into app.appeal_contributor (tenant_id, appeal_id, user_id, role)
    select new.tenant_id, a.appeal_id, new.requester_id, 'requester'
      from app.appeal a where a.appeal_id = new.subject_id and a.tenant_id = new.tenant_id
    on conflict on constraint appeal_contributor_once do nothing;
  end if;
  return null;
end;
$$;
create trigger approval_request_contributor after insert on app.approval_request
  for each row execute function app.appeal_contributor_requester();

-- Everyone who ever wrote the appeal or asked for its approval (signature unchanged from 007).
create or replace function app.appeal_contributors(p_appeal uuid) returns uuid[]
language sql stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct x.u), '{}')
    from (select c.user_id as u from app.appeal_contributor c where c.appeal_id = p_appeal
          union all
          select a.author_id from app.appeal a where a.appeal_id = p_appeal) x
$$;

-- ================================================================ 2. IV16 link guard (backstop for the command check)
create function app.appeal_ai_link_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.ai_interaction_id is not null and new.ai_interaction_id is distinct from old.ai_interaction_id then
    perform app.refuse('MR002', 'IV16_ai_link_immutable', 'appeal',
      'The AI interaction an appeal was drafted from cannot be changed or removed');
  end if;
  return new;
end;
$$;
create trigger appeal_ai_link_guard before update of ai_interaction_id on app.appeal
  for each row execute function app.appeal_ai_link_guard();

-- ================================================================ 3. IV15 typed source references
-- arg_statements (validation stage): a non-null source_ref must parse as '<type>:<uuid>'; it is normalised to lower case.
create or replace function app.arg_statements(p_args jsonb) returns jsonb
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
    if v_src is not null then
      if v_src !~* '^(evidence_item|claim|claim_service_line|remittance_line|coverage):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        perform app.refuse('MR005', 'IV15_source_unresolved', 'appeal_statement',
          format('Statement %s: source_ref must be <type>:<uuid> with type evidence_item, claim, claim_service_line, remittance_line or coverage', i));
      end if;
      v_src := lower(v_src);
    end if;
    out := out || jsonb_build_array(jsonb_build_object(
      'seq', i, 'text', app.arg_text(s, 'text', true, 4000), 'source_ref', v_src,
      'unsupported', coalesce(v_uns, false) or v_src is null));
  end loop;
  return out;
end;
$$;

-- True when a parsed '<type>:<uuid>' names a row of the caller's tenant tied to the appeal's claim:
--   evidence_item      its denial is the appeal's denial, or its claim is the appeal's claim
--   claim              the appeal's claim
--   claim_service_line / remittance_line   a line of the appeal's claim
--   coverage           the claim's coverage, or a coverage of the claim's patient
create function app.source_ref_resolves(p_ref text, p_appeal app.appeal) returns boolean
language plpgsql stable
set search_path = ''
as $$
declare
  v_tenant uuid := (app.ctx()).tenant_id;
  v_type   text := split_part(p_ref, ':', 1);
  v_id     uuid := split_part(p_ref, ':', 2)::uuid;
begin
  return case v_type
    when 'evidence_item' then exists (
      select 1 from app.evidence_item e
       where e.evidence_item_id = v_id and e.tenant_id = v_tenant
         and (e.denial_id = p_appeal.denial_id or e.claim_id = p_appeal.claim_id))
    when 'claim' then v_id = p_appeal.claim_id and exists (
      select 1 from app.claim c where c.claim_id = v_id and c.tenant_id = v_tenant)
    when 'claim_service_line' then exists (
      select 1 from app.claim_service_line l
       where l.claim_service_line_id = v_id and l.tenant_id = v_tenant and l.claim_id = p_appeal.claim_id)
    when 'remittance_line' then exists (
      select 1 from app.remittance_line rl
       where rl.remittance_line_id = v_id and rl.tenant_id = v_tenant and rl.claim_id = p_appeal.claim_id)
    when 'coverage' then exists (
      select 1 from app.coverage cv join app.claim c on c.claim_id = p_appeal.claim_id and c.tenant_id = v_tenant
       where cv.coverage_id = v_id and cv.tenant_id = v_tenant
         and (cv.coverage_id = c.coverage_id or cv.patient_id = c.patient_id))
    else false end;
end;
$$;

-- ================================================================ api.cmd_appeal_draft (fixes 1, 2b, 3)
create or replace function api.cmd_appeal_draft(p_idem text, p_args jsonb) returns jsonb
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
    -- IV16: an AI link, once set, never changes (it may be set once while empty)
    if v_ai_id is not null and v_ap.ai_interaction_id is not null and v_ai_id <> v_ap.ai_interaction_id then
      perform app.refuse('MR002', 'IV16_ai_link_immutable', 'appeal',
        'This appeal was drafted from another AI interaction; that link cannot be replaced');
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

  -- IV16: the AI output linked to an appeal is an appeal draft about this appeal or its denial
  if v_ai_id is not null then
    if v_ai.subject_id is null or v_ai.subject_id not in (v_ap.appeal_id, v_ap.denial_id) then
      perform app.refuse('MR005', 'ai_interaction_subject_mismatch', 'ai_interaction',
        'The AI interaction must name this appeal or its denial as its subject');
    end if;
    if v_ai.task is distinct from 'appeal.draft' then
      perform app.refuse('MR005', 'ai_interaction_wrong_task', 'ai_interaction',
        format('The AI interaction is a %s task, not an appeal draft', v_ai.task));
    end if;
  end if;

  -- IV15: every source resolves to a record of this appeal's claim (one message for missing, foreign or unrelated)
  for s in select e.value from jsonb_array_elements(v_stmts) e loop
    if s->>'source_ref' is not null and not app.source_ref_resolves(s->>'source_ref', v_ap) then
      perform app.refuse('MR005', 'IV15_source_unresolved', 'appeal_statement',
        format('Statement %s: the %s named in source_ref is not a record of this appeal''s claim; reference an existing evidence item, claim, service line, remittance line or coverage of the claim',
               s->>'seq', split_part(s->>'source_ref', ':', 1)));
    end if;
  end loop;

  for s in select e.value from jsonb_array_elements(v_stmts) e loop
    insert into app.appeal_statement (tenant_id, appeal_id, seq, text, source_ref, unsupported)
    values (v_ctx.tenant_id, v_ap.appeal_id, (s->>'seq')::integer, s->>'text', s->>'source_ref', (s->>'unsupported')::boolean)
    on conflict (appeal_id, seq) do update
      set text = excluded.text, source_ref = excluded.source_ref, unsupported = excluded.unsupported, removed_at = null;
  end loop;
  update app.appeal_statement set removed_at = now()
   where appeal_id = v_ap.appeal_id and seq > jsonb_array_length(v_stmts) and removed_at is null;

  -- IV13: the caller wrote this appeal (author on create / next level, editor on every amend, even if nothing changed)
  insert into app.appeal_contributor (tenant_id, appeal_id, user_id, role)
  values (v_ctx.tenant_id, v_ap.appeal_id, v_ctx.user_id, case when v_mode = 'amended' then 'editor' else 'author' end)
  on conflict on constraint appeal_contributor_once do nothing;

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
  (amend a drafting appeal) }, statements [ { text (<= 4000), source_ref '<type>:<uuid>' with type evidence_item |
  claim | claim_service_line | remittance_line | coverage (optional), unsupported bool } ] (1..50; a statement without
  source_ref is flagged unsupported; unsupported=false without a source is MR005), amount (optional, > 0, 2 dp, <= the
  denied amount), ai_interaction_id (optional; may be set once, never replaced).
Guards: ids in the caller's tenant (MR004; the target row locked). New: denial in_appeal (MR002 denial_not_in_appeal), no
  level-1 appeal yet (MR002 appeal_exists). Next level: parent decided upheld (MR002 parent_not_upheld), none open yet
  (MR002 next_level_exists), payer_config in effect (MR002 payer_rules_missing) with level < appeal_levels (MR002
  appeal_levels_exhausted), window open (MR002 next_level_deadline_passed). Amend: status drafting (MR001); a set AI link
  cannot change (MR002 IV16_ai_link_immutable). AI interaction: task 'appeal.draft' (MR005 ai_interaction_wrong_task)
  about this appeal or its denial (MR005 ai_interaction_subject_mismatch). IV15: a source_ref that does not parse or
  does not resolve to a record of the appeal's claim in the caller's tenant is MR005 IV15_source_unresolved (names the
  statement; the same message for a missing, foreign or unrelated row).
Writes: appeal (drafting, author = caller; on amend the amender becomes the author), appeal_statement rows upserted by
  seq, statements beyond the new list get removed_at; next level: also a deadline; app.appeal_contributor (author on
  create / next level, editor on amend).
result: { appeal_id, denial_id, claim_id, parent_appeal_id, level, status, amount, author_id, ai_interaction_id,
  deadline_id, mode created|amended|next_level, statement_ids[], unsupported_statement_ids[], unsupported_count }
event: appeal.drafted (aggregate appeal_id).$c$;

-- ================================================================ api.cmd_appeal_file (fix 2: independent approval)
create or replace function api.cmd_appeal_file(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd     constant text := 'appeal.file';
  v_ctx     app.ctx_t;
  v_cached  jsonb;
  v_ap_id   uuid;
  v_ref     text;
  v_ap      app.appeal;
  v_rev     text;
  v_rec     uuid;
  v_contrib uuid[];
  v_ok_at   timestamptz;
  v_dl      app.deadline;
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
  -- IV16: an AI-drafted appeal leaves the building only when the latest review approves the AI output and an
  -- independent reviewer (not who recorded the output, not anyone who wrote the appeal) approved it after any rejection
  if v_ap.ai_interaction_id is not null then
    select ai.created_by into v_rec from app.ai_interaction ai where ai.ai_interaction_id = v_ap.ai_interaction_id;
    v_contrib := app.appeal_contributors(v_ap.appeal_id);
    select r.decision into v_rev from app.ai_review r
     where r.ai_interaction_id = v_ap.ai_interaction_id and r.tenant_id = v_ctx.tenant_id
     order by r.reviewed_at desc, r.created_at desc, r.ai_review_id desc
     limit 1;
    select max(r.reviewed_at) into v_ok_at from app.ai_review r
     where r.ai_interaction_id = v_ap.ai_interaction_id and r.tenant_id = v_ctx.tenant_id and r.decision = 'approved'
       and r.reviewer_id is distinct from v_rec and not (r.reviewer_id = any (v_contrib));
    if v_rev is distinct from 'approved' or v_ok_at is null
       or exists (select 1 from app.ai_review r
                   where r.ai_interaction_id = v_ap.ai_interaction_id and r.tenant_id = v_ctx.tenant_id
                     and r.decision = 'rejected' and r.reviewed_at > v_ok_at) then
      perform app.refuse('MR002', 'IV16_ai_review_required', 'ai_interaction',
        format('This appeal was drafted with AI (interaction %s); an independent reviewer must approve the AI output (ai.review), after any rejection, before filing',
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
  ai_review to be 'approved' AND an 'approved' review by an independent reviewer (not the interaction's recorder, not a
  contributor of the appeal) later than every 'rejected' review (MR002 IV16_ai_review_required); an open appeal_filing
  deadline (the appeal's own, else for level 1 the denial's) exists (MR002 appeal_deadline_missing) and has not passed
  (MR002 appeal_deadline_passed).
Writes: appeal filed, filed_at, submission_ref; the deadline met_at.
result: { appeal_id, status, filed_at, deadline_id, submission_ref, level }   event: appeal.filed (aggregate appeal_id).$c$;

-- ================================================================ api.cmd_ai_review (fix 2: reviewer independence)
create or replace function api.cmd_ai_review(p_idem text, p_args jsonb) returns jsonb
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
  -- IV16: the reviewer is independent: not who recorded the AI output, not anyone who wrote an appeal drafted from it
  if v_ctx.user_id = v_ai.created_by
     or exists (select 1 from app.appeal a
                 where a.ai_interaction_id = v_ai.ai_interaction_id and a.tenant_id = v_ctx.tenant_id
                   and v_ctx.user_id = any (app.appeal_contributors(a.appeal_id))) then
    perform app.refuse('MR003', 'IV16_reviewer_not_independent', 'ai_interaction',
      'You produced this AI output or wrote the appeal drafted from it, so someone else must review it');
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
Guards: interaction in the caller's tenant (MR004, locked); not expired (MR001); the reviewer is independent: not the
  user who recorded the interaction and not a contributor of an appeal linked to it (MR003 IV16_reviewer_not_independent).
  Several reviews may exist; appeal.file needs the latest to approve and an independent approval after any rejection.
Writes: ai_review (reviewer = caller, reviewed_at = clock time); ai_interaction status accepted | rejected.
result: { ai_review_id, ai_interaction_id, decision, status, reviewer_id }   event: ai.reviewed (aggregate ai_interaction_id).$c$;

-- ================================================================ grants
revoke all on function app.appeal_contributor_author() from public, anon, authenticated;
revoke all on function app.appeal_contributor_requester() from public, anon, authenticated;
revoke all on function app.appeal_contributors(uuid) from public, anon, authenticated;
revoke all on function app.appeal_ai_link_guard() from public, anon, authenticated;
revoke all on function app.arg_statements(jsonb) from public, anon, authenticated;
revoke all on function app.source_ref_resolves(text, app.appeal) from public, anon, authenticated;
revoke all on function api.cmd_appeal_draft(text, jsonb) from public, anon;
revoke all on function api.cmd_appeal_file(text, jsonb) from public, anon;
revoke all on function api.cmd_ai_review(text, jsonb) from public, anon;
grant execute on function api.cmd_appeal_draft(text, jsonb) to authenticated;
grant execute on function api.cmd_appeal_file(text, jsonb) to authenticated;
grant execute on function api.cmd_ai_review(text, jsonb) to authenticated;

revoke all on all tables in schema app from public, anon, authenticated;
grant select on all tables in schema app to authenticated;
