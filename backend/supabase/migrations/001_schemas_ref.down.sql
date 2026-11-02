-- Undo 001_schemas_ref (reverse dependency order).
drop function if exists tests.report();
drop function if exists tests.assert(boolean, text);
drop function if exists tests.begin();
drop table if exists tests.result;
drop function if exists app.enforce_transition();
drop function if exists ref.transition_ok(text, text, text);
drop table if exists ref.state_transition;
drop function if exists app.refuse(text, text, text, text);
drop function if exists app.uuid_v7();
drop schema if exists tests;
drop schema if exists api;
drop schema if exists audit;
drop schema if exists ref;
drop schema if exists app;
