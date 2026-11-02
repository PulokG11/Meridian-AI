-- Undo 007b_cmd_appeals_fixes (run before 007_cmd_appeals.down.sql). Restores the 007 bodies of
-- app.arg_statements, app.appeal_contributors, api.cmd_appeal_draft, api.cmd_appeal_file and api.cmd_ai_review
-- (copied verbatim from 007), then drops the contributor table, its triggers and the new helpers.
-- The append-only triggers refuse TRUNCATE/DELETE on app.appeal_contributor, so the table is dropped, not emptied.

drop trigger if exists approval_request_contributor on app.approval_request;
drop trigger if exists appeal_contributor_author on app.appeal;
drop trigger if exists appeal_ai_link_guard on app.appeal;

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
    out := out || jsonb_build_array(jsonb_build_object(
      'seq', i, 'text', app.arg_text(s, 'text', true, 4000), 'source_ref', v_src,
      'unsupported', coalesce(v_uns, false) or v_src is null));
  end loop;
  return out;
end;
$$;

create or replace function app.appeal_contributors(p_appeal uuid) returns uuid[]
language sql stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct u) filter (where u is not null), '{}')
    from (select a.author_id as u from app.appeal a where a.appeal_id = p_appeal
          union all select a.created_by from app.appeal a where a.appeal_id = p_appeal
          union all select s.created_by from app.appeal_statement s where s.appeal_id = p_appeal
          union all select s.updated_by from app.appeal_statement s where s.appeal_id = p_appeal) x
$$;

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

create or replace function api.cmd_appeal_file(p_idem text, p_args jsonb) returns jsonb
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

revoke all on function app.arg_statements(jsonb) from public, anon, authenticated;
revoke all on function app.appeal_contributors(uuid) from public, anon, authenticated;

drop function if exists app.source_ref_resolves(text, app.appeal);
drop function if exists app.appeal_ai_link_guard();
drop function if exists app.appeal_contributor_requester();
drop function if exists app.appeal_contributor_author();
drop table if exists app.appeal_contributor;
