-- 002_platform.down: undo, reverse dependency order.
alter table tests.result disable row level security;

drop function if exists app.finish_cmd(text, text, jsonb, jsonb, text, uuid);
drop function if exists app.begin_cmd(text, text, jsonb);
drop trigger if exists audit_log_no_truncate on audit.audit_log;
drop trigger if exists audit_log_no_modify on audit.audit_log;
drop function if exists audit.no_modify();
drop function if exists audit.verify_chain(uuid);
drop function if exists audit.write(text, text, uuid, jsonb);
drop function if exists audit.row_hash(text, bigint, timestamptz, uuid, text, text, uuid, jsonb);
drop function if exists app.authorize(text);
drop function if exists app.ctx();
drop type if exists app.ctx_t;

drop table if exists audit.outbox_event;
drop table if exists audit.audit_log;
drop table if exists app.idempotency_key;
drop table if exists app.approval_limit;
drop table if exists app.user_role;
drop table if exists app.app_user;
drop table if exists app.role_permission;
drop table if exists app.permission;
drop table if exists app.role;
drop table if exists app.org_unit;
drop table if exists app.tenant;
drop function if exists app.touch();

revoke usage on schema app, audit, api from authenticated;
