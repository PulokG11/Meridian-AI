-- down for 008_cmd_cash_case
drop function if exists api.cmd_case_reopen(text, jsonb);
drop function if exists api.cmd_case_close(text, jsonb);
drop function if exists api.cmd_writeoff_post(text, jsonb);
drop function if exists api.cmd_writeoff_request(text, jsonb);
drop function if exists api.cmd_patient_dispute_resolve(text, jsonb);
drop function if exists api.cmd_patient_dispute_open(text, jsonb);
drop function if exists api.cmd_patient_payment_apply(text, jsonb);
drop function if exists api.cmd_deposit_allocate(text, jsonb);
drop function if exists api.cmd_posting_reverse(text, jsonb);
drop function if exists api.cmd_posting_apply_payment(text, jsonb);

drop index if exists payment_posting_approval_uq;
alter table app.payment_posting drop column if exists approval_request_id;
