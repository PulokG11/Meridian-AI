-- Undo 005c_handover_fixes: restore the 005b definitions of app.approval_request_guard and app.process_outbox.

drop function if exists ref.subject_tenant(text, uuid);

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
    return new;
  end if;

  if old.status <> 'pending' then
    if new.status is not distinct from old.status
       and row(new.tenant_id, new.kind, new.amount, new.requester_id, new.approver_id, new.subject_type, new.subject_id)
           is distinct from row(old.tenant_id, old.kind, old.amount, old.requester_id, old.approver_id, old.subject_type, old.subject_id)
    then
      perform app.refuse('MR002', 'approval_request_final', 'approval_request', 'A decided request cannot be changed; raise a new request');
    end if;
    return new;
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
          begin
            execute format('select ref.%I($1)', 'check_' || lower(h.handover_id)) into v_ok using v_subject;
            v_status := case when coalesce(v_ok, false) then 'passed' else 'held' end;
          exception when others then
            v_status := 'failed_check';
            v_detail := left(sqlerrm, 500);
          end;

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
    end loop;

    v_total := v_total + v_n;
    exit when v_n = 0;
  end loop;
  return v_total;
end;
$$;
revoke all on function app.process_outbox() from public, anon, authenticated;

alter table audit.outbox_event drop column if exists process_error;
