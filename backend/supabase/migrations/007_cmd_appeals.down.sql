-- Undo 007_cmd_appeals (reverse dependency order). Restoring the narrower CHECK constraints fails if rows use the
-- values added in 007 (appeal decision overturned_in_part, records_request accepted / rejected, ai_review approved).

drop function if exists api.cmd_ai_interaction_record(text, jsonb);
drop function if exists api.cmd_ai_review(text, jsonb);
drop function if exists api.cmd_records_request_decide(text, jsonb);
drop function if exists api.cmd_records_request_respond(text, jsonb);
drop function if exists api.cmd_appeal_record_decision(text, jsonb);
drop function if exists api.cmd_appeal_file(text, jsonb);
drop function if exists api.cmd_approval_decide(text, jsonb);
drop function if exists api.cmd_appeal_request_approval(text, jsonb);
drop function if exists api.cmd_appeal_draft(text, jsonb);
drop function if exists api.cmd_evidence_assemble(text, jsonb);

drop function if exists app.payer_records_request(uuid, boolean);
drop function if exists app.payer_appeal(uuid, boolean);
drop function if exists app.claim_payer_config(uuid);
drop function if exists app.appeal_contributors(uuid);
drop function if exists app.arg_statements(jsonb);
drop function if exists app.arg_uuid_list(jsonb, text, integer);
drop function if exists app.arg_bool(jsonb, text);

drop trigger if exists records_request_transition on app.records_request;
delete from ref.state_transition
 where (entity, from_status, to_status) in (('appeal', 'pending_approval', 'drafting'),
                                            ('records_request', 'open', 'responded'),
                                            ('records_request', 'responded', 'accepted'),
                                            ('records_request', 'responded', 'rejected'));

alter table app.ai_interaction drop column if exists model_version;

alter table app.ai_review drop constraint ai_review_decision_check;
alter table app.ai_review add constraint ai_review_decision_check check (decision in ('accepted', 'edited', 'rejected'));

alter table app.records_request drop constraint records_request_status_check;
alter table app.records_request add constraint records_request_status_check
  check (status in ('open', 'responded', 'closed', 'expired'));
drop index if exists app.records_request_decided_by_idx;
drop index if exists app.records_request_responded_by_idx;
alter table app.records_request
  drop column if exists decided_by,
  drop column if exists decided_at,
  drop column if exists decision_reason,
  drop column if exists responded_by,
  drop column if exists response_note;

alter table app.appeal_statement drop column if exists removed_at;

alter table app.appeal drop constraint appeal_decision_check;
alter table app.appeal add constraint appeal_decision_check check (decision in ('overturned', 'upheld', 'partial'));
drop index if exists app.appeal_decided_by_idx;
drop index if exists app.appeal_ai_interaction_idx;
alter table app.appeal
  drop column if exists decided_by,
  drop column if exists decision_reason,
  drop column if exists expected_payment,
  drop column if exists submission_ref,
  drop column if exists ai_interaction_id;
