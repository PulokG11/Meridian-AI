-- Undo 006_cmd_claims: drop the seven commands and the helpers, the remittance state machine and its trigger,
-- and the two columns added to earlier tables (reverse dependency order).

drop function if exists api.cmd_claim_submit(text, jsonb);
drop function if exists api.cmd_claim_release(text, jsonb);
drop function if exists api.cmd_claim_create_replacement(text, jsonb);
drop function if exists api.cmd_denial_confirm_path(text, jsonb);
drop function if exists api.cmd_denial_triage(text, jsonb);
drop function if exists api.cmd_remittance_post(text, jsonb);
drop function if exists api.cmd_remittance_receive(text, jsonb);

drop function if exists app.emit_event(text, uuid, jsonb, text, text);
drop function if exists app.arg_date(jsonb, text, boolean);
drop function if exists app.arg_enum(jsonb, text, text[], boolean);
drop function if exists app.arg_numeric(jsonb, text, boolean);
drop function if exists app.arg_uuid(jsonb, text, boolean);
drop function if exists app.arg_text(jsonb, text, boolean, integer);
drop function if exists app.valid_amount(numeric, numeric);
drop function if exists app.valid_money(numeric, text, boolean, numeric);
drop function if exists app.scoped_row(text, uuid, boolean);
drop function if exists app.require_portal(text[]);
drop function if exists app.not_found(text);

drop trigger if exists remittance_transition on app.remittance;
delete from ref.state_transition where entity = 'remittance';

alter table app.denial_triage drop column if exists reasons;
alter table app.remittance_line drop column if exists denied_amount;
