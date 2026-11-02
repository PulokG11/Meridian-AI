-- Task 1 tests: UUIDv7, state machines, refuse(), test helpers.
-- Run with execute_sql (whole file in one call). Starts by clearing tests.result.
select tests.begin();

-- uuid_v7 ordering: two calls 1+ ms apart compare ascending
do $$
declare a uuid; b uuid;
begin
  a := app.uuid_v7();
  perform pg_sleep(0.002);
  b := app.uuid_v7();
  perform tests.assert(a < b, 'uuid_v7 values sort by creation');
  perform tests.assert(substr(a::text, 15, 1) = '7', 'uuid_v7 has version nibble 7');
  perform tests.assert(substr(a::text, 20, 1) in ('8','9','a','b'), 'uuid_v7 has RFC variant');
  perform tests.assert(
    abs(extract(epoch from clock_timestamp()) * 1000
        - ('x' || substr(replace(a::text, '-', ''), 1, 12))::bit(48)::bigint) < 5000,
    'uuid_v7 first 48 bits are epoch milliseconds');
end $$;

-- ref.transition_ok
select tests.assert(ref.transition_ok('denial', 'new', 'triaged'), 'legal denial transition accepted');
select tests.assert(not ref.transition_ok('denial', 'new', 'recovered'), 'illegal denial transition refused');
select tests.assert(ref.transition_ok('denial', 'new', 'written_off'), 'denial new -> written_off allowed');
select tests.assert(ref.transition_ok('denial', 'in_appeal', 'written_off'), 'denial in_appeal -> written_off allowed');
select tests.assert(ref.transition_ok('claim', 'accepted', 'partially_paid'), 'claim accepted -> partially_paid allowed');
select tests.assert(not ref.transition_ok('claim', 'draft', 'submitted'), 'claim draft -> submitted refused');
select tests.assert(ref.transition_ok('case', 'closed', 'open'), 'case closed -> open allowed');
select tests.assert(not ref.transition_ok('case', 'open', 'open'), 'case open -> open refused');
select tests.assert(ref.transition_ok('appeal', 'filed', 'decided'), 'appeal filed -> decided allowed');
select tests.assert(not ref.transition_ok('appeal', 'drafting', 'filed'), 'appeal drafting -> filed refused');
select tests.assert(ref.transition_ok('nope', 'a', 'b') is false, 'unknown entity is false, not null');
select tests.assert((select count(*) from ref.state_transition where entity = 'denial' and to_status = 'written_off') = 7,
  'written_off reachable from all 7 denial statuses');

-- app.refuse raises the SQLSTATE with JSON message
do $$
declare s text; m text; j jsonb;
begin
  begin
    perform app.refuse('MR005', 'amount_positive', 'payment', 'Enter an amount above zero');
  exception when others then
    get stacked diagnostics s = returned_sqlstate, m = message_text;
  end;
  perform tests.assert(s = 'MR005', 'refuse sets SQLSTATE to the code');
  j := m::jsonb;
  perform tests.assert(j->>'code' = 'MR005' and j->>'rule' = 'amount_positive'
    and j->>'object' = 'payment' and j->>'todo' = 'Enter an amount above zero',
    'refuse message is JSON with code, rule, object, todo');
end $$;

-- trigger raises MR001 on an illegal status change
create temp table _t_den (id int primary key, status text not null);
create trigger _t_den_enforce before update on _t_den
  for each row execute function app.enforce_transition('denial');
insert into _t_den values (1, 'new');

do $$
begin
  update _t_den set status = 'triaged' where id = 1;
  perform tests.assert(true, 'trigger allows legal transition');
  begin
    update _t_den set status = 'recovered' where id = 1;
    perform tests.assert(false, 'trigger raises MR001');
  exception when sqlstate 'MR001' then
    perform tests.assert(true, 'trigger raises MR001');
  end;
  perform tests.assert((select status from _t_den where id = 1) = 'triaged', 'status unchanged after refused transition');
  update _t_den set id = 1 where id = 1;
  perform tests.assert(true, 'trigger ignores updates that do not change status');
end $$;

drop table _t_den;

-- helpers behave: a failing assertion makes report() raise
do $$
declare raised boolean := false;
begin
  perform tests.assert(false, 'deliberate failure');
  begin
    perform tests.report();
  exception when others then raised := true;
  end;
  delete from tests.result where msg = 'deliberate failure';
  perform tests.assert(raised, 'report raises when an assertion failed');
end $$;

select tests.report();
