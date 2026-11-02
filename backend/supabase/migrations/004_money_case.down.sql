-- 004_money_case down: remove the views, the 27 tables (reverse dependency order) and the trigger functions;
-- restore app.enforce_transition to SECURITY INVOKER as Task 1 created it.

drop view if exists api.case_blockers;
drop view if exists api.line_balance;

drop table if exists app.patient_dispute;
drop table if exists app.patient_payment;
drop table if exists app.patient_statement;
drop table if exists app.patient_responsibility;
drop table if exists app.reopen_event;
drop table if exists app.case_status_history;
drop table if exists app.case_claim;
drop table if exists app."case";
drop table if exists app.deadline;
drop table if exists app.evidence_item;
drop table if exists app.appeal_statement;
drop table if exists app.appeal;
drop table if exists app.records_request;
drop table if exists app.denial_triage;
drop table if exists app.denial;
drop table if exists app.root_cause;
drop table if exists app.deposit_allocation;
drop table if exists app.deposit;
drop table if exists app.payment_posting;
drop table if exists app.remittance_line;
drop table if exists app.remittance;
drop table if exists app.claim_ack;
drop table if exists app.edi_interchange;
drop table if exists app.claim_edit_result;
drop table if exists app.claim_diagnosis;
drop table if exists app.claim_service_line;
drop table if exists app.claim;

drop function if exists app.case_history_write();
drop function if exists app.deposit_amount_guard();
drop function if exists app.allocation_within_deposit();
drop function if exists app.allocation_validate();
drop function if exists app.line_balance_check();
drop function if exists app.posting_unbalance();
drop function if exists app.posting_validate();
drop function if exists app.append_only();

alter function app.enforce_transition() security invoker;
