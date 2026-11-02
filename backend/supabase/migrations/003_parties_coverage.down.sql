-- 003_parties_coverage.down: undo, reverse dependency order.
drop table if exists app.eligibility_response;
drop table if exists app.eligibility_request;
drop table if exists app.coverage;
drop table if exists app.clearinghouse_connection;
drop table if exists app.clearinghouse;
drop table if exists app.payer_config;
drop table if exists app.payer_plan;
drop table if exists app.payer;
drop table if exists app.proxy_access;
drop table if exists app.patient_relationship;
drop table if exists app.provider;
drop table if exists app.patient;
drop function if exists app.in_scope(uuid, uuid, uuid, uuid);
