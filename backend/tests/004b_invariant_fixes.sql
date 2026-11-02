-- Task 4 review fix round 1 tests (migration 005a_money_fixes):
--  (a) patient balance per line = patient_share - patient_paid - patient_writeoff; write-offs need an approval id
--  (b) cash reconciled = per-line net payer cash equals net deposit allocation on the line (D6)
--  (c) IV01 line lock: posting_validate locks the parent line FOR UPDATE; balance flag behaviour
-- Run with execute_sql (whole file in one call). Fixtures live in a rolled-back sub-transaction (no residue).
select tests.begin();

create or replace function pg_temp._add(r jsonb, m text, p boolean) returns jsonb
language sql as $$ select r || jsonb_build_array(jsonb_build_object('m', m, 'p', coalesce(p, false))) $$;

-- Runs one statement and returns 'ok' or the SQLSTATE it raised.
create or replace function pg_temp._try(q text) returns text
language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- true when the case currently shows the given blocker
create or replace function pg_temp._blk(c uuid, b text) returns boolean
language sql as $$ select exists (select 1 from api.case_blockers where case_id = c and blocker = b) $$;

do $$
declare
  r jsonb := '[]'::jsonb;
  m text;
  res text;
  t1 uuid := app.uuid_v7();
  u_prov uuid := gen_random_uuid();
  pat_a uuid := app.uuid_v7(); pay_a uuid := app.uuid_v7();
  c1 uuid := app.uuid_v7(); c2 uuid := app.uuid_v7(); c3 uuid := app.uuid_v7();
  l1 uuid := app.uuid_v7(); l2 uuid := app.uuid_v7(); l3 uuid := app.uuid_v7();
  k1 uuid := app.uuid_v7(); k2 uuid := app.uuid_v7(); k3 uuid := app.uuid_v7();
  r1 uuid := app.uuid_v7(); r1b uuid := app.uuid_v7(); r2 uuid := app.uuid_v7();
  d1 uuid := app.uuid_v7();
  rem3 uuid := app.uuid_v7(); rl3 uuid := app.uuid_v7();
  a60 uuid := app.uuid_v7();
  rc uuid := app.uuid_v7();
  def text;
  ar1 uuid := app.uuid_v7(); ar2 uuid := app.uuid_v7();
begin
  begin  -- sub-transaction, always rolled back
    -- ---------------------------------------------------------------- fixtures (as owner)
    insert into app.tenant (tenant_id, name) values (t1, 'Tenant One');
    insert into app.role (role_key, label, portal) values ('t_prov', 'Provider', 'provider');
    insert into auth.users (id, aud, role, email) values (u_prov, 'authenticated', 'authenticated', 'p1@meridian.test');
    insert into app.app_user (user_id, tenant_id, portal, role_key, display_name) values (u_prov, t1, 'provider', 't_prov', 'Prov One');
    insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (pat_a, t1, 'MRN-A', 'Ada', 'Alpha', date '1980-01-01');
    -- Task 5 added the FK patient_payment.approval_request_id -> approval_request, so write-offs need real requests
    insert into app.approval_request (approval_request_id, tenant_id, kind, amount, requester_id) values
      (ar1, t1, 'write_off', 20.00, u_prov), (ar2, t1, 'write_off', 10.00, u_prov);
    insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type) values (pay_a, t1, 'Payer A', 'PA01', 'commercial');
    insert into app.claim (claim_id, tenant_id, claim_number, patient_id, payer_id, status) values
      (c1, t1, 'CLM-1', pat_a, pay_a, 'accepted'), (c2, t1, 'CLM-2', pat_a, pay_a, 'accepted'), (c3, t1, 'CLM-3', pat_a, pay_a, 'accepted');
    insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
      (l1, t1, c1, 1, '99213', 100.00), (l2, t1, c2, 1, '99213', 100.00), (l3, t1, c3, 1, '99213', 100.00);
    insert into app."case" (case_id, tenant_id, case_number, patient_id) values
      (k1, t1, 'CASE-1', pat_a), (k2, t1, 'CASE-2', pat_a), (k3, t1, 'CASE-3', pat_a);
    insert into app.case_claim (tenant_id, case_id, claim_id) values (t1, k1, c1), (t1, k2, c2), (t1, k3, c3);
    insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values (d1, t1, pay_a, 'BANK-3', 100.00);
    insert into app.remittance (remittance_id, tenant_id, payer_id, trace_number, payment_amount) values (rem3, t1, pay_a, 'TRN-3', 100.00);
    insert into app.remittance_line (remittance_line_id, tenant_id, remittance_id, claim_id, line_id, billed, paid) values
      (rl3, t1, rem3, c3, l3, 100.00, 100.00);

    -- ---------------------------------------------------------------- (a) patient balance per line
    insert into app.payment_posting (tenant_id, line_id, kind, amount) values
      (t1, l1, 'payment', 80.00), (t1, l1, 'patient_share', 20.00),
      (t1, l2, 'payment', 80.00), (t1, l2, 'patient_share', 20.00);
    update app.claim_service_line set balanced = true where claim_service_line_id in (l1, l2);
    r := pg_temp._add(r, 'line_balance exposes patient_open = patient_share - patient_paid - patient_writeoff (20 open)',
      (select patient_share = 20.00 and patient_paid = 0 and patient_writeoff = 0 and patient_open = 20.00
         from api.line_balance where line_id = l1));
    r := pg_temp._add(r, 'uncollected patient share with no responsibility row blocks the case (Patient balance is open)',
      pg_temp._blk(k1, 'Patient balance is open')
      and not exists (select 1 from app.patient_responsibility where line_id = l1));

    insert into app.patient_responsibility (patient_responsibility_id, tenant_id, patient_id, claim_id, line_id, amount, reason)
      values (r1, t1, pat_a, c1, l1, 20.00, 'coinsurance');
    insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method)
      values (t1, pat_a, r1, 5.00, 'card');
    r := pg_temp._add(r, 'a partial patient payment (5 of 20) leaves the patient balance blocker',
      pg_temp._blk(k1, 'Patient balance is open')
      and (select patient_paid = 5.00 and patient_open = 15.00 from api.line_balance where line_id = l1));
    insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method, kind)
      values (t1, pat_a, r1, 15.00, 'portal', 'payment');
    r := pg_temp._add(r, 'patient payments of the full share (kind = payment) clear the blocker',
      not pg_temp._blk(k1, 'Patient balance is open')
      and (select patient_paid = 20.00 and patient_open = 0 from api.line_balance where line_id = l1));

    insert into app.patient_responsibility (patient_responsibility_id, tenant_id, patient_id, claim_id, line_id, amount, reason)
      values (r2, t1, pat_a, c2, l2, 20.00, 'deductible');
    r := pg_temp._add(r, 'patient write-off without an approval_request_id refused (23514)',
      pg_temp._try(format($q$insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method, kind)
        values (%L, %L, %L, 20.00, 'other', 'writeoff')$q$, t1, pat_a, r2)) = '23514');
    r := pg_temp._add(r, 'unknown patient payment kind refused (23514)',
      pg_temp._try(format($q$insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method, kind)
        values (%L, %L, %L, 1.00, 'card', 'refund')$q$, t1, pat_a, r2)) = '23514');
    r := pg_temp._add(r, 'refused write-off left the patient balance blocker in place',
      pg_temp._blk(k2, 'Patient balance is open'));
    insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method, kind, approval_request_id)
      values (t1, pat_a, r2, 20.00, 'other', 'writeoff', ar1);
    r := pg_temp._add(r, 'an approved patient write-off of the full share clears the blocker',
      not pg_temp._blk(k2, 'Patient balance is open')
      and (select patient_paid = 0 and patient_writeoff = 20.00 and patient_open = 0 from api.line_balance where line_id = l2));

    r := pg_temp._add(r, 'a write-off naming a non-existent approval request is refused by the Task 5 FK (23503)',
      pg_temp._try(format($q$insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method, kind, approval_request_id)
        values (%L, %L, %L, 1.00, 'other', 'writeoff', %L)$q$, t1, pat_a, r2, gen_random_uuid())) = '23503');

    -- the responsibility-based condition is kept: a responsibility above the posted share still blocks
    insert into app.patient_responsibility (patient_responsibility_id, tenant_id, patient_id, claim_id, line_id, amount, reason)
      values (r1b, t1, pat_a, c1, l1, 10.00, 'non_covered');
    r := pg_temp._add(r, 'an unpaid responsibility row still blocks even when patient_open is 0',
      pg_temp._blk(k1, 'Patient balance is open')
      and (select patient_open = 0 from api.line_balance where line_id = l1));
    insert into app.patient_payment (tenant_id, patient_id, patient_responsibility_id, amount, method, kind, approval_request_id)
      values (t1, pat_a, r1b, 10.00, 'other', 'writeoff', ar2);
    r := pg_temp._add(r, 'an approved write-off covers the responsibility row too (blocker gone; patient_open -10 is not a blocker)',
      not pg_temp._blk(k1, 'Patient balance is open')
      and (select patient_open = -10.00 from api.line_balance where line_id = l1));

    -- ---------------------------------------------------------------- (b) payer cash matched to a deposit
    insert into app.payment_posting (tenant_id, line_id, kind, amount) values (t1, l3, 'payment', 100.00);
    update app.claim_service_line set balanced = true where claim_service_line_id = l3;
    r := pg_temp._add(r, 'balanced line with payer cash but no deposit allocation blocks the case (Cash is not reconciled yet)',
      (select open_amount = 0 and balanced and paid = 100.00 and deposit_allocated = 0 from api.line_balance where line_id = l3)
      and pg_temp._blk(k3, 'Cash is not reconciled yet'));
    insert into app.deposit_allocation (deposit_allocation_id, tenant_id, deposit_id, line_id, amount) values (a60, t1, d1, l3, 60.00);
    r := pg_temp._add(r, 'a partial allocation (60 of 100) keeps the cash blocker and shows the deposit difference',
      (select deposit_allocated = 60.00 from api.line_balance where line_id = l3)
      and pg_temp._blk(k3, 'Cash is not reconciled yet') and pg_temp._blk(k3, 'Deposit allocation difference'));
    insert into app.deposit_allocation (tenant_id, deposit_id, remittance_line_id, amount) values (t1, d1, rl3, 40.00);
    r := pg_temp._add(r, 'allocating the rest through the line''s remittance line clears the cash blocker; case has no blockers',
      (select deposit_allocated = 100.00 from api.line_balance where line_id = l3)
      and not pg_temp._blk(k3, 'Cash is not reconciled yet')
      and not exists (select 1 from api.case_blockers where case_id = k3));
    r := pg_temp._add(r, 'an allocation reversal naming a different target than the reversed row is refused (MR005)',
      pg_temp._try(format($q$insert into app.deposit_allocation (tenant_id, deposit_id, remittance_line_id, amount, reverses_allocation_id)
        values (%L, %L, %L, -60.00, %L)$q$, t1, d1, rl3, a60)) = 'MR005');
    insert into app.deposit_allocation (tenant_id, deposit_id, line_id, amount, reverses_allocation_id) values (t1, d1, l3, -60.00, a60);
    r := pg_temp._add(r, 'a correct reversal nets out of deposit_allocated and brings the cash blocker back',
      (select deposit_allocated = 40.00 from api.line_balance where line_id = l3)
      and pg_temp._blk(k3, 'Cash is not reconciled yet'));
    insert into app.deposit_allocation (tenant_id, deposit_id, remittance_id, amount) values (t1, d1, rem3, 60.00);
    r := pg_temp._add(r, 'a remittance-level allocation is not attributed to a line (cash blocker stays, as documented)',
      (select deposit_allocated = 40.00 from api.line_balance where line_id = l3)
      and pg_temp._blk(k3, 'Cash is not reconciled yet'));

    -- ---------------------------------------------------------------- (c) IV01 line lock
    def := pg_get_functiondef('app.posting_validate()'::regprocedure);
    r := pg_temp._add(r, 'posting_validate locks the parent service line FOR UPDATE before anything else',
      def ~ 'from app\.claim_service_line l where l\.claim_service_line_id = new\.line_id for update'
      and position('for update' in def) < position('reversal' in def));
    r := pg_temp._add(r, 'the IV01 check is a BEFORE INSERT/UPDATE row trigger on claim_service_line (runs under the UPDATE row lock)',
      (select (t.tgtype & 23) = 23 from pg_trigger t
        where t.tgrelid = 'app.claim_service_line'::regclass and t.tgname = 'claim_service_line_balance'
          and t.tgfoid = 'app.line_balance_check()'::regprocedure));
    insert into app.payment_posting (payment_posting_id, tenant_id, line_id, kind, amount, reason) values (rc, t1, l3, 'recoupment', 10.00, 'Recoup');
    r := pg_temp._add(r, 'inserting a posting that breaks the balance clears the balanced flag',
      (select not balanced and balanced_at is null from app.claim_service_line where claim_service_line_id = l3));
    r := pg_temp._add(r, 'marking a line balanced while a mismatch is pending is refused (MR002)',
      pg_temp._try(format('update app.claim_service_line set balanced = true where claim_service_line_id = %L', l3)) = 'MR002');
    insert into app.payment_posting (tenant_id, line_id, kind, amount, reverses_posting_id) values (t1, l3, 'reversal', 10.00, rc);
    res := pg_temp._try(format('update app.claim_service_line set balanced = true where claim_service_line_id = %L', l3));
    r := pg_temp._add(r, 'after the mismatch is reversed the line can be marked balanced again',
      res = 'ok' and (select balanced from app.claim_service_line where claim_service_line_id = l3));

    -- ---------------------------------------------------------------- structure
    r := pg_temp._add(r, 'line_balance keeps columns 1-10 and appends patient_writeoff, patient_open, deposit_allocated',
      (select array_agg(a.attname::text order by a.attnum) from pg_attribute a
        where a.attrelid = 'api.line_balance'::regclass and a.attnum > 0 and not a.attisdropped)
      = array['line_id','billed','paid','adjusted','patient_share','patient_paid','open_amount','claim_id','tenant_id','balanced',
              'patient_writeoff','patient_open','deposit_allocated']);
    r := pg_temp._add(r, 'both views are still security_invoker and readable by authenticated only',
      (select bool_and(cl.reloptions @> array['security_invoker=true']) from pg_class cl
        where cl.oid in ('api.line_balance'::regclass, 'api.case_blockers'::regclass))
      and has_table_privilege('authenticated', 'api.line_balance', 'select')
      and has_table_privilege('authenticated', 'api.case_blockers', 'select')
      and not has_table_privilege('anon', 'api.line_balance', 'select')
      and not has_table_privilege('anon', 'api.case_blockers', 'select'));
    r := pg_temp._add(r, 'view comments document the patient side and the cash match',
      (select d ~ 'patient_writeoff' and d ~ 'patient_open' and d ~ 'deposit_allocated' and d ~ 'reversal' and d ~ 'recoupment'
         from obj_description('api.line_balance'::regclass, 'pg_class') d)
      and (select d ~ 'deposit_allocated' and d ~ 'patient_writeoff' from obj_description('api.case_blockers'::regclass, 'pg_class') d));
    r := pg_temp._add(r, 'patient_payment.kind defaults to payment; approval_request_id is indexed for the Task 5 FK',
      (select column_default like '''payment''%' from information_schema.columns
        where table_schema = 'app' and table_name = 'patient_payment' and column_name = 'kind')
      and exists (select 1 from pg_index i where i.indrelid = 'app.patient_payment'::regclass
                    and i.indkey[0] = (select attnum from pg_attribute where attrelid = 'app.patient_payment'::regclass and attname = 'approval_request_id')));

    raise exception using errcode = 'P0001', message = '__rollback__';
  exception when sqlstate 'P0001' then
    get stacked diagnostics m = message_text;
    if m <> '__rollback__' then raise; end if;
  end;

  r := pg_temp._add(r, 'fixtures rolled back (no residue)',
    not exists (select 1 from app.tenant where tenant_id = t1)
    and not exists (select 1 from auth.users where id = u_prov)
    and not exists (select 1 from app.role where role_key like 't\_%' escape '\')
    and not exists (select 1 from app.claim where claim_id in (c1, c2, c3)));

  perform tests.assert((e->>'p')::boolean, e->>'m') from jsonb_array_elements(r) e;
end $$;

drop function pg_temp._add(jsonb, text, boolean);
drop function pg_temp._try(text);
drop function pg_temp._blk(uuid, text);

select tests.report();
