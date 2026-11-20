-- Undo 010_cmd_case_create: drop the two new commands.

drop function if exists api.cmd_deposit_create(text, jsonb);
drop function if exists api.cmd_case_create(text, jsonb);
