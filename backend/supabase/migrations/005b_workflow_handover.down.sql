-- Undo 005b_workflow_handover, in reverse dependency order.
-- NOTE: drops the pg_cron extension only because 005b created it; remove that line if another job needs it.

select cron.unschedule('process_outbox_every_minute')
 where exists (select 1 from cron.job where jobname = 'process_outbox_every_minute');
drop extension if exists pg_cron;

drop function if exists app.process_outbox();
drop function if exists ref.check_h24(uuid);
drop function if exists ref.check_h23(uuid);
drop function if exists ref.check_h22(uuid);
drop function if exists ref.check_h21(uuid);
drop function if exists ref.check_h20(uuid);
drop function if exists ref.check_h19(uuid);
drop function if exists ref.check_h18(uuid);
drop function if exists ref.check_h17(uuid);
drop function if exists ref.check_h16(uuid);
drop function if exists ref.check_h15(uuid);
drop function if exists ref.check_h14(uuid);
drop function if exists ref.check_h13(uuid);
drop function if exists app.claim_has_failed_hard_edit(uuid);

alter table app.patient_payment drop constraint if exists patient_payment_approval_request_fk;

drop table if exists app.ai_review;
drop table if exists app.ai_interaction;
drop table if exists app.ai_model_version;
drop table if exists app.rule;
drop table if exists app.rule_pack;
drop table if exists app.task;
drop table if exists app.handover_event;
drop table if exists app.approval_request;          -- drops its triggers
drop function if exists app.approval_request_guard();
drop function if exists app.approver_limit(uuid, uuid, text);
drop table if exists app.work_queue;
delete from ref.state_transition where entity = 'approval_request';
drop table if exists ref.handover_def;

drop index if exists audit.outbox_event_pending_agg_idx;
drop index if exists audit.outbox_event_pending_seq_idx;
alter table audit.outbox_event drop column if exists seq;
