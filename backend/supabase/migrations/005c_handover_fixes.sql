-- 005c_handover_fixes: Task 5 review fix round 1 (005b_workflow_handover stays as applied).
--  1. Approval guard bypass: the deciding UPDATE could change amount / kind / requester_id in the same statement and so
--     defeat the limit and approver <> requester checks. A pending row now keeps tenant, kind, amount, requester,
--     subject_type and subject_id; a decided row is frozen in every column (except updated_at / updated_by); the
--     requester of a new request must belong to the request's tenant.
--  2. Cross-tenant subject oracle: the engine ran tenant-blind checks on payload.subject_id. ref.subject_tenant maps a
--     handover and subject to the subject's tenant; app.process_outbox records failed_check 'subject_tenant_mismatch'
--     (one task, check NOT run) when it is null or differs from the event's tenant. Each event is also processed inside
--     its own exception guard: an unexpected error marks the event processed with audit.outbox_event.process_error set
--     instead of stalling the batch for ever.

-- ================================================================ 1. approval guard
create or replace function app.approval_request_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_limit  numeric;
begin
  if TG_OP = 'INSERT' then
    if new.status <> 'pending' then
      perform app.refuse('MR002', 'approval_starts_pending', 'approval_request', 'A request is created pending and decided afterwards');
    end if;
    select u.tenant_id into v_tenant from app.app_user u where u.user_id = new.requester_id;
    if v_tenant is distinct from new.tenant_id then
      perform app.refuse('MR005', 'requester_not_in_tenant', 'approval_request', 'The requester must belong to the same organisation as the request');
    end if;
    return new;
  end if;

  -- A decided request is final in every column. A status change on a decided row is refused by enforce_transition (MR001).
  if old.status <> 'pending' then
    if new.status is not distinct from old.status
       and (to_jsonb(new) - 'updated_at' - 'updated_by') is distinct from (to_jsonb(old) - 'updated_at' - 'updated_by')
    then
      perform app.refuse('MR002', 'approval_request_final', 'approval_request', 'A decided request cannot be changed; raise a new request');
    end if;
    return new;
  end if;

  -- Pending: what is being approved cannot change in the same statement (or any other) while the request is open.
  if row(new.tenant_id, new.kind, new.amount, new.requester_id, new.subject_type, new.subject_id)
     is distinct from row(old.tenant_id, old.kind, old.amount, old.requester_id, old.subject_type, old.subject_id)
  then
    perform app.refuse('MR002', 'approval_request_immutable_fields', 'approval_request',
      'Tenant, kind, amount, requester and subject cannot change on an open request; cancel it and raise a new one');
  end if;

  if new.status in ('approved', 'rejected') then
    if new.approver_id is null then
      perform app.refuse('MR002', 'approver_required', 'approval_request', 'Name the approver who decides this request');
    end if;
    if new.approver_id = new.requester_id then
      perform app.refuse('MR003', 'IV13_approver_not_requester', 'approval_request', 'Someone other than the requester must decide this request');
    end if;
    select u.tenant_id into v_tenant from app.app_user u where u.user_id = new.approver_id;
    if v_tenant is distinct from new.tenant_id then
      perform app.refuse('MR003', 'approver_not_in_tenant', 'approval_request', 'The approver must belong to the same organisation');
    end if;
    if new.status = 'approved' then
      v_limit := app.approver_limit(new.tenant_id, new.approver_id, new.kind);
      if v_limit is null then
        perform app.refuse('MR003', 'no_approval_authority', 'approval_request',
          format('Your role has no approval limit for %s requests', new.kind));
      end if;
      if new.amount > v_limit then
        perform app.refuse('MR003', 'IV13_over_approval_limit', 'approval_request',
          format('%s exceeds your %s approval limit of %s; ask someone with a higher limit', new.amount, new.kind, v_limit));
      end if;
    end if;
    new.decided_at := coalesce(new.decided_at, now());
  end if;
  return new;
end;
$$;
revoke all on function app.approval_request_guard() from public, anon, authenticated;

-- ================================================================ 2. subject tenant
alter table audit.outbox_event add column process_error text;   -- set when the engine gave up on an event (unexpected error)

-- The tenant that owns the subject a handover check would read, or null when the subject does not exist in the table(s)
-- that handover's check reads (or the handover has no subject table, like the inactive H23).
create function ref.subject_tenant(p_handover_id text, p_subject uuid) returns uuid
language sql stable security definer
set search_path = ''
as $$
  select case p_handover_id
    when 'H13' then (select c.tenant_id from app.claim c where c.claim_id = p_subject)
    when 'H14' then (select c.tenant_id from app.claim c where c.claim_id = p_subject)
    when 'H19' then (select c.tenant_id from app.claim c where c.claim_id = p_subject)
    when 'H15' then (select r.tenant_id from app.remittance r where r.remittance_id = p_subject)
    when 'H16' then (select d.tenant_id from app.denial d where d.denial_id = p_subject)
    when 'H17' then (select d.tenant_id from app.denial d where d.denial_id = p_subject)
    when 'H18' then (select a.tenant_id from app.approval_request a where a.approval_request_id = p_subject)
    when 'H20' then coalesce(
      (select d.tenant_id from app.deposit d where d.deposit_id = p_subject),
      (select r.tenant_id from app.remittance r where r.remittance_id = p_subject),
      (select x.tenant_id from app.edi_interchange x where x.edi_interchange_id = p_subject))
    when 'H21' then (select c.tenant_id from app."case" c where c.case_id = p_subject)
    when 'H22' then coalesce(
      (select r.tenant_id from app.rule r where r.rule_id = p_subject),
      (select p.tenant_id from app.rule_pack p where p.rule_pack_id = p_subject))
    when 'H24' then coalesce(
      (select r.tenant_id from app.eligibility_response r where r.eligibility_response_id = p_subject),
      (select q.tenant_id from app.eligibility_request q where q.eligibility_request_id = p_subject))
    else null end
$$;
revoke all on function ref.subject_tenant(text, uuid) from public, anon, authenticated;

-- ================================================================ 2b. engine
-- Everything from 005b is kept (batches of 100, FOR UPDATE SKIP LOCKED, only the first unprocessed event per
-- aggregate, order by seq, idempotent insert, one task per held / failed handover, sub-transaction around the check).
-- New: the tenant gate before the check, and a per-event exception guard.
create or replace function app.process_outbox() returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  c_batch   constant integer := 100;
  c_batches constant integer := 50;
  v_total   integer := 0;
  v_n       integer;
  v_pass    integer;
  e         record;
  h         record;
  v_subject uuid;
  v_tenant  uuid;
  v_ok      boolean;
  v_status  text;
  v_detail  text;
  v_he      uuid;
  v_queue   uuid;
begin
  for v_pass in 1 .. c_batches loop
    v_n := 0;
    for e in
      select o.event_id, o.tenant_id, o.type, o.aggregate_id, o.payload
        from audit.outbox_event o
       where o.processed_at is null
         and not exists (select 1 from audit.outbox_event p
                          where p.aggregate_id = o.aggregate_id and p.processed_at is null and p.seq < o.seq)
       order by o.seq
       limit c_batch
         for update of o skip locked
    loop
      v_n := v_n + 1;
      begin   -- per-event guard: an unexpected error rolls back this event's work only
        v_subject := coalesce(
          case when e.payload ->> 'subject_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
               then (e.payload ->> 'subject_id')::uuid end,
          e.aggregate_id);

        if v_subject is not null then
          for h in select d.handover_id, d.hold_queue, d.ready_check
                     from ref.handover_def d
                    where d.active and d.trigger_event = e.type
                    order by d.handover_id
          loop
            v_detail := null;
            v_tenant := ref.subject_tenant(h.handover_id, v_subject);
            if v_tenant is distinct from e.tenant_id then
              -- the subject is missing or belongs to another tenant: never run the check on it
              v_status := 'failed_check';
              v_detail := 'subject_tenant_mismatch';
            else
              begin
                execute format('select ref.%I($1)', 'check_' || lower(h.handover_id)) into v_ok using v_subject;
                v_status := case when coalesce(v_ok, false) then 'passed' else 'held' end;
              exception when others then
                v_status := 'failed_check';
                v_detail := left(sqlerrm, 500);
              end;
            end if;

            v_he := null;
            insert into app.handover_event (tenant_id, handover_id, subject_id, source_event_id, status, detail, checked_at)
            values (e.tenant_id, h.handover_id, v_subject, e.event_id, v_status, v_detail, clock_timestamp())
            on conflict (handover_id, subject_id, source_event_id) do nothing
            returning handover_event_id into v_he;

            if v_he is not null and v_status <> 'passed' then
              insert into app.work_queue (tenant_id, name) values (e.tenant_id, h.hold_queue)
              on conflict (tenant_id, name) do nothing;
              select q.work_queue_id into v_queue
                from app.work_queue q where q.tenant_id = e.tenant_id and q.name = h.hold_queue;
              insert into app.task (tenant_id, queue_id, subject_type, subject_id, status, title, source_handover_event_id)
              values (e.tenant_id, v_queue, split_part(e.type, '.', 1), v_subject, 'open',
                      format('%s %s: %s', h.handover_id,
                             case when v_status = 'held' then 'held' else 'check could not run' end, h.ready_check),
                      v_he);
            end if;
          end loop;
        end if;

        update audit.outbox_event o set processed_at = clock_timestamp() where o.event_id = e.event_id;
      exception when others then
        -- give up on this event only: keep the reason on the outbox row and let the batch move on
        update audit.outbox_event o
           set processed_at = clock_timestamp(), process_error = left(sqlstate || ': ' || sqlerrm, 500)
         where o.event_id = e.event_id;
      end;
    end loop;

    v_total := v_total + v_n;
    exit when v_n = 0;
  end loop;
  return v_total;
end;
$$;
revoke all on function app.process_outbox() from public, anon, authenticated;

-- the new column is covered by the existing table-level SELECT grant to authenticated
revoke all on all tables in schema app, audit from public, anon, authenticated;
grant select on all tables in schema app, audit to authenticated;
