-- Task 10 case seed: replays the 15 synthetic cases from the prototype (backend/seed/cases.json)
-- through the real Tasks 6-8 commands, driven by the Task 9 seeded users (plus three payer-scoped
-- reps created below, since Task 9's payer-portal test users are not scoped to one payer).
--
-- Each denial is inserted directly as a starting fixture (the historical adjudication that produced
-- it already happened before this release existed); everything from triage onward replays through
-- api.cmd_* so the case's derived stage (api.case_stage) is reproducible from rows, not stored.
-- Ruling: a 'cob' case (coverage-order correction) is modeled with cmd_claim_create_replacement,
-- the same as 'corrected' (see 009_case_stage.sql's header for why).
-- Not idempotent by design (one-time case load); re-running starts from whatever already exists and
-- will raise on duplicate claim_number/case_number — drop and re-run backend/supabase against a fresh
-- project to redo it.
create or replace function pg_temp._run(u uuid, fn text, k text, a jsonb) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  execute format('select api.%I($1, $2)', fn) into v using k, a;
  reset role;
  return v;
end $$;

do $$
declare
  v_tenant uuid;
  v_prov uuid := app.uuid_v7();
  u_denials uuid; u_appeals uuid; u_billing uuid; u_sup uuid; u_mgr uuid; u_cash uuid; u_ar uuid; u_fin uuid;
  u_pay_a uuid := gen_random_uuid(); u_pay_b uuid := gen_random_uuid(); u_pay_c uuid := gen_random_uuid();
  pay_a uuid; pay_b uuid; pay_c uuid;
  n int := 0;
  j jsonb;

  -- per-case working variables, reused across the loop body below
  v_pat uuid; v_cov uuid; v_claim uuid; v_den uuid; v_case uuid; v_repl uuid; v_appeal uuid; v_ar uuid; v_rr uuid; v_dep uuid; v_rem uuid;
  v_line1 uuid; v_line2 uuid; v_line3 uuid;
begin
  select tenant_id into v_tenant from app.tenant where name = 'Meridian Demo Health';
  select user_id into u_denials from app.app_user where tenant_id = v_tenant and role_key = 'denials';
  select user_id into u_appeals from app.app_user where tenant_id = v_tenant and role_key = 'appeals';
  select user_id into u_billing from app.app_user where tenant_id = v_tenant and role_key = 'billing';
  select user_id into u_sup     from app.app_user where tenant_id = v_tenant and role_key = 'sup';
  select user_id into u_mgr     from app.app_user where tenant_id = v_tenant and role_key = 'mgr';
  select user_id into u_cash    from app.app_user where tenant_id = v_tenant and role_key = 'cash';
  select user_id into u_ar      from app.app_user where tenant_id = v_tenant and role_key = 'ar';
  select user_id into u_fin     from app.app_user where tenant_id = v_tenant and role_key = 'fin';
  select payer_id into pay_a from app.payer where tenant_id = v_tenant and payer_code = 'COM-A';
  select payer_id into pay_b from app.payer where tenant_id = v_tenant and payer_code = 'COM-B';
  select payer_id into pay_c from app.payer where tenant_id = v_tenant and payer_code = 'COM-C';

  insert into app.provider (provider_id, tenant_id, npi, name) values (v_prov, v_tenant, '1000099001', 'Seeded Provider Group');
  insert into app.root_cause (tenant_id, code, label, category)
    select v_tenant, 'GENERAL', 'General recovery cause', 'other'
    where not exists (select 1 from app.root_cause where tenant_id = v_tenant and code = 'GENERAL');

  -- payer-scoped reps (Task 9's py4/py5/py1 test users carry no party_id; the payer-decision and
  -- records-request-decide commands need a caller scoped to one specific payer)
  insert into auth.users (id, aud, role, email) values
    (u_pay_a, 'authenticated', 'authenticated', 'payer-a-rep@meridian.test'),
    (u_pay_b, 'authenticated', 'authenticated', 'payer-b-rep@meridian.test'),
    (u_pay_c, 'authenticated', 'authenticated', 'payer-c-rep@meridian.test');
  insert into app.app_user (user_id, tenant_id, portal, role_key, party_id, display_name) values
    (u_pay_a, v_tenant, 'payer', 'py4', pay_a, 'Payer A rep (seed)'),
    (u_pay_b, v_tenant, 'payer', 'py4', pay_b, 'Payer B rep (seed)'),
    (u_pay_c, v_tenant, 'payer', 'py4', pay_c, 'Payer C rep (seed)');

  -- ================================================================ CLM-24017: appeal, stage 2 (Action drafted)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24017', 'Patient', 'A', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_a, 'A-4471-90', date '2025-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24017', v_pat, v_prov, pay_a, v_cov, 'accepted', date '2026-04-09', date '2026-04-09');
  v_line1 := app.uuid_v7(); v_line2 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
    (v_line1, v_tenant, v_claim, 1, '72148', 2410.00), (v_line2, v_tenant, v_claim, 2, '72158', 2410.00);
  insert into app.claim_diagnosis (tenant_id, claim_id, sequence, icd10_code) values (v_tenant, v_claim, 1, 'M54.16'), (v_tenant, v_claim, 2, 'R20.2');
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '50', 'N115', 4820.00, now() - interval '30 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24017', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c17-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'appeal', 'confidence', 0.86));
  perform pg_temp._run(u_denials, 'cmd_denial_confirm_path', 'c17-cp', jsonb_build_object('denial_id', v_den, 'path', 'appeal'));
  j := pg_temp._run(u_appeals, 'cmd_appeal_draft', 'c17-dr', jsonb_build_object('denial_id', v_den, 'statements', jsonb_build_array(
    jsonb_build_object('text', 'Chart documents a neurological deficit meeting the policy exception for imaging before 6 weeks of therapy.', 'source_ref', 'claim:' || v_claim),
    jsonb_build_object('text', 'Every field on the claim is complete.'))));
  n := n + 1; raise notice 'seeded %: CLM-24017 (stage 2, appeal drafting)', n;

  -- ================================================================ CLM-24033: corrected, stage 1 (Triaged)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24033', 'Patient', 'B', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_b, 'B-2280-15', date '2025-03-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24033', v_pat, v_prov, pay_b, v_cov, 'accepted', date '2026-04-21', date '2026-04-21');
  v_line1 := app.uuid_v7(); v_line2 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
    (v_line1, v_tenant, v_claim, 1, '99214', 210.00), (v_line2, v_tenant, v_claim, 2, '94010', 1050.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '16', 'N290', 1260.00, now() - interval '30 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24033', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c33-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'correction', 'confidence', 0.93));
  n := n + 1; raise notice 'seeded %: CLM-24033 (stage 1, triaged)', n;

  -- ================================================================ CLM-24051: evidence, stage 1 (Triaged)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24051', 'Patient', 'C', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_a, 'A-5120-33', date '2025-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24051', v_pat, v_prov, pay_a, v_cov, 'accepted', date '2026-04-28', date '2026-04-28');
  v_line1 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values (v_line1, v_tenant, v_claim, 1, '73721', 2340.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '252', 'M127', 2340.00, now() - interval '30 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24051', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c51-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'evidence', 'confidence', 0.88));
  perform pg_temp._run(u_denials, 'cmd_denial_confirm_path', 'c51-cp', jsonb_build_object('denial_id', v_den, 'path', 'evidence'));
  n := n + 1; raise notice 'seeded %: CLM-24051 (stage 1, in_evidence)', n;

  -- ================================================================ CLM-24068: cob (as corrected), stage 1 (Triaged)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24068', 'Patient', 'D', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_c, 'C-9910-04', date '2025-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24068', v_pat, v_prov, pay_c, v_cov, 'accepted', date '2026-05-06', date '2026-05-06');
  v_line1 := app.uuid_v7(); v_line2 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
    (v_line1, v_tenant, v_claim, 1, '99213', 140.00), (v_line2, v_tenant, v_claim, 2, '81001', 840.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '22', 980.00, now() - interval '30 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24068', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c68-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'correction', 'confidence', 0.81));
  n := n + 1; raise notice 'seeded %: CLM-24068 (stage 1, triaged, COB)', n;

  -- ================================================================ CLM-23988: appeal, stage 8 (closed, reconciled)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-23988', 'Patient', 'E', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_a, 'A-3308-12', date '2025-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-23988', v_pat, v_prov, pay_a, v_cov, 'accepted', date '2026-03-18', date '2026-03-18');
  v_line1 := app.uuid_v7(); v_line2 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
    (v_line1, v_tenant, v_claim, 1, '72148', 3050.00), (v_line2, v_tenant, v_claim, 2, '72158', 3050.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '50', 'N115', 6100.00, now() - interval '200 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-23988', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c88-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'appeal', 'confidence', 0.90));
  perform pg_temp._run(u_denials, 'cmd_denial_confirm_path', 'c88-cp', jsonb_build_object('denial_id', v_den, 'path', 'appeal'));
  j := pg_temp._run(u_appeals, 'cmd_appeal_draft', 'c88-dr', jsonb_build_object('denial_id', v_den, 'statements', jsonb_build_array(
    jsonb_build_object('text', 'The patient had a documented neurological deficit on Mar 18.', 'source_ref', 'claim:' || v_claim),
    jsonb_build_object('text', 'The imaging order cites spinal stenosis with deficit.', 'source_ref', 'claim:' || v_claim))));
  v_appeal := (j->>'appeal_id')::uuid;
  j := pg_temp._run(u_appeals, 'cmd_appeal_request_approval', 'c88-rq', jsonb_build_object('appeal_id', v_appeal));
  v_ar := (j->>'approval_request_id')::uuid;
  perform pg_temp._run(u_mgr, 'cmd_approval_decide', 'c88-ad', jsonb_build_object('approval_request_id', v_ar, 'decision', 'approved'));
  perform pg_temp._run(u_appeals, 'cmd_appeal_file', 'c88-fl', jsonb_build_object('appeal_id', v_appeal, 'submission_ref', 'APL-4102'));
  perform pg_temp._run(u_pay_a, 'cmd_appeal_record_decision', 'c88-pd', jsonb_build_object('appeal_id', v_appeal, 'decision', 'overturned_in_part', 'amount', 5490.00));
  j := pg_temp._run(u_cash, 'cmd_remittance_receive', 'c88-rcv', jsonb_build_object('interchange_trace', 'TRN-C88', 'payer_id', pay_a, 'control_total', 5490.00, 'lines', jsonb_build_array(
    jsonb_build_object('claim_id', v_claim, 'line_id', v_line1, 'paid', 2745.00, 'adjustment', 305.00, 'group_code', 'CO', 'carc', '45'),
    jsonb_build_object('claim_id', v_claim, 'line_id', v_line2, 'paid', 2745.00, 'adjustment', 305.00, 'group_code', 'CO', 'carc', '45'))));
  v_rem := (j->>'remittance_id')::uuid;
  perform pg_temp._run(u_cash, 'cmd_remittance_post', 'c88-post', jsonb_build_object('remittance_id', v_rem));
  v_dep := app.uuid_v7();
  insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values (v_dep, v_tenant, pay_a, 'DEP-88213', 5490.00);
  perform pg_temp._run(u_cash, 'cmd_deposit_allocate', 'c88-alloc1', jsonb_build_object('deposit_id', v_dep, 'remittance_id', v_rem, 'line_id', v_line1, 'amount', 2745.00));
  perform pg_temp._run(u_cash, 'cmd_deposit_allocate', 'c88-alloc2', jsonb_build_object('deposit_id', v_dep, 'remittance_id', v_rem, 'line_id', v_line2, 'amount', 2745.00));
  perform pg_temp._run(u_fin, 'cmd_case_close', 'c88-close', jsonb_build_object('case_id', v_case, 'reason', 'Reconciled; appeal overturned in part and payment posted'));
  n := n + 1; raise notice 'seeded %: CLM-23988 (stage 8, closed)', n;

  -- ================================================================ CLM-24201: corrected, stage 1 (Triaged)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24201', 'Alex', 'Morgan', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_b, 'B-2280-15', date '2025-03-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24201', v_pat, v_prov, pay_b, v_cov, 'accepted', date '2026-10-03', date '2026-10-03');
  v_line1 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values (v_line1, v_tenant, v_claim, 1, '99214', 210.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '16', 'MA130', 210.00, now() - interval '26 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24201', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c201-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'correction', 'confidence', 0.92));
  n := n + 1; raise notice 'seeded %: CLM-24201 (stage 1, triaged)', n;

  -- ================================================================ CLM-24202: evidence, stage 7 (deposit allocated)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24202', 'Alex', 'Morgan', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_b, 'B-2280-15', date '2025-03-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24202', v_pat, v_prov, pay_b, v_cov, 'accepted', date '2026-10-12', date '2026-10-12');
  v_line1 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values (v_line1, v_tenant, v_claim, 1, '73721', 2340.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '252', 'M127', 2340.00, now() - interval '21 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24202', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c202-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'evidence', 'confidence', 0.90));
  perform pg_temp._run(u_denials, 'cmd_denial_confirm_path', 'c202-cp', jsonb_build_object('denial_id', v_den, 'path', 'evidence'));
  j := pg_temp._run(u_denials, 'cmd_evidence_assemble', 'c202-ev', jsonb_build_object('denial_id', v_den,
    'items', jsonb_build_array(jsonb_build_object('kind', 'authorization', 'title', 'Authorization AUTH-81234', 'source_ref', 'auth:81234'))));
  v_rr := app.uuid_v7();
  insert into app.records_request (records_request_id, tenant_id, claim_id, denial_id, requested_items, due_at) values
    (v_rr, v_tenant, v_claim, v_den, 'Prior authorization number', now() + interval '30 days');
  perform pg_temp._run(u_denials, 'cmd_records_request_respond', 'c202-rr', jsonb_build_object('records_request_id', v_rr, 'evidence_item_ids', j->'created_ids', 'note', 'Authorization number attached'));
  perform pg_temp._run(u_pay_b, 'cmd_records_request_decide', 'c202-rd', jsonb_build_object('records_request_id', v_rr, 'decision', 'accepted', 'reason', 'Complete'));
  j := pg_temp._run(u_cash, 'cmd_remittance_receive', 'c202-rcv', jsonb_build_object('interchange_trace', 'TRN-C202', 'payer_id', pay_b, 'control_total', 380.00, 'lines', jsonb_build_array(
    jsonb_build_object('claim_id', v_claim, 'line_id', v_line1, 'paid', 380.00, 'adjustment', 1160.00, 'patient_share', 800.00, 'group_code', 'CO', 'carc', '45'))));
  v_rem := (j->>'remittance_id')::uuid;
  perform pg_temp._run(u_cash, 'cmd_remittance_post', 'c202-post', jsonb_build_object('remittance_id', v_rem));
  v_dep := app.uuid_v7();
  insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values (v_dep, v_tenant, pay_b, 'DEP-88402', 380.00);
  perform pg_temp._run(u_cash, 'cmd_deposit_allocate', 'c202-alloc', jsonb_build_object('deposit_id', v_dep, 'remittance_id', v_rem, 'line_id', v_line1, 'amount', 380.00));
  n := n + 1; raise notice 'seeded %: CLM-24202 (stage 7, deposit allocated)', n;

  -- ================================================================ CLM-24203: cob (as corrected), stage 5 (payer responded)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24203', 'Riley', 'Morgan', date '2015-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_a, 'A-7781-02', date '2026-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24203', v_pat, v_prov, pay_a, v_cov, 'accepted', date '2026-10-18', date '2026-10-18');
  v_line1 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values (v_line1, v_tenant, v_claim, 1, '99213', 180.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '22', 180.00, now() - interval '6 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24203', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c203-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'correction', 'confidence', 0.84));
  j := pg_temp._run(u_billing, 'cmd_claim_create_replacement', 'c203-rep', jsonb_build_object('original_claim_id', v_claim));
  v_repl := (j->>'claim_id')::uuid;
  perform pg_temp._run(u_billing, 'cmd_claim_release', 'c203-rel', jsonb_build_object('claim_id', v_repl));
  perform pg_temp._run(u_billing, 'cmd_claim_submit', 'c203-sub', jsonb_build_object('claim_id', v_repl));
  perform pg_temp._run(u_cash, 'cmd_remittance_receive', 'c203-rcv', jsonb_build_object('interchange_trace', 'TRN-C203', 'payer_id', pay_a, 'control_total', 90.00, 'lines', jsonb_build_array(
    jsonb_build_object('claim_id', v_repl, 'line_id', (select claim_service_line_id from app.claim_service_line where claim_id = v_repl), 'paid', 90.00, 'adjustment', 60.00, 'patient_share', 30.00, 'group_code', 'CO', 'carc', '45'))));
  n := n + 1; raise notice 'seeded %: CLM-24203 (stage 5, payer responded, COB)', n;

  -- ================================================================ CLM-24204: cob (as corrected), stage 5, self-pay
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24204', 'Sam', 'Okoye', date '1990-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_c, 'C-9910-77', date '2025-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24204', v_pat, v_prov, pay_c, v_cov, 'accepted', date '2026-10-20', date '2026-10-20');
  v_line1 := app.uuid_v7(); v_line2 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
    (v_line1, v_tenant, v_claim, 1, '94010', 840.00), (v_line2, v_tenant, v_claim, 2, '99213', 485.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '27', 1325.00, now() - interval '13 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24204', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c204-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'correction', 'confidence', 0.88));
  j := pg_temp._run(u_billing, 'cmd_claim_create_replacement', 'c204-rep', jsonb_build_object('original_claim_id', v_claim));
  v_repl := (j->>'claim_id')::uuid;
  perform pg_temp._run(u_billing, 'cmd_claim_release', 'c204-rel', jsonb_build_object('claim_id', v_repl));
  perform pg_temp._run(u_billing, 'cmd_claim_submit', 'c204-sub', jsonb_build_object('claim_id', v_repl));
  perform pg_temp._run(u_cash, 'cmd_remittance_receive', 'c204-rcv', jsonb_build_object('interchange_trace', 'TRN-C204', 'payer_id', pay_c, 'control_total', 0, 'lines', jsonb_build_array(
    jsonb_build_object('claim_id', v_repl, 'line_id', (select claim_service_line_id from app.claim_service_line where claim_id = v_repl and line_number = 1), 'paid', 0, 'patient_share', 840.00, 'group_code', 'CO', 'carc', '27'),
    jsonb_build_object('claim_id', v_repl, 'line_id', (select claim_service_line_id from app.claim_service_line where claim_id = v_repl and line_number = 2), 'paid', 0, 'patient_share', 485.00, 'group_code', 'CO', 'carc', '27'))));
  n := n + 1; raise notice 'seeded %: CLM-24204 (stage 5, payer responded, self-pay)', n;

  -- ================================================================ CLM-24205: appeal, stage 2 (Action drafted)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24205', 'Patient', 'L', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_a, 'A-6612-48', date '2025-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24205', v_pat, v_prov, pay_a, v_cov, 'accepted', date '2026-09-16', date '2026-09-16');
  v_line1 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values (v_line1, v_tenant, v_claim, 1, '29881', 7800.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '50', 'N115', 7800.00, now() - interval '19 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24205', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c205-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'appeal', 'confidence', 0.79));
  perform pg_temp._run(u_denials, 'cmd_denial_confirm_path', 'c205-cp', jsonb_build_object('denial_id', v_den, 'path', 'appeal'));
  perform pg_temp._run(u_appeals, 'cmd_appeal_draft', 'c205-dr', jsonb_build_object('denial_id', v_den, 'statements', jsonb_build_array(
    jsonb_build_object('text', 'The patient had mechanical knee symptoms with locking documented on Sep 9.', 'source_ref', 'claim:' || v_claim),
    jsonb_build_object('text', 'MRI on Aug 28 shows a displaced tear of the medial meniscus.', 'source_ref', 'claim:' || v_claim),
    jsonb_build_object('text', 'The patient failed 8 weeks of conservative therapy.'))));
  n := n + 1; raise notice 'seeded %: CLM-24205 (stage 2, one unsourced statement)', n;

  -- ================================================================ CLM-24206: evidence, stage 1 (Triaged, auth missing)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24206', 'Patient', 'M', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_a, 'A-3340-91', date '2025-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24206', v_pat, v_prov, pay_a, v_cov, 'accepted', date '2026-10-05', date '2026-10-05');
  v_line1 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values (v_line1, v_tenant, v_claim, 1, '70551', 2980.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '197', 'N54', 2980.00, now() - interval '11 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24206', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c206-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'evidence', 'confidence', 0.85));
  perform pg_temp._run(u_denials, 'cmd_denial_confirm_path', 'c206-cp', jsonb_build_object('denial_id', v_den, 'path', 'evidence'));
  n := n + 1; raise notice 'seeded %: CLM-24206 (stage 1, no authorization number)', n;

  -- ================================================================ CLM-24207: corrected, closed then reopened by a $420 recoupment
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24207', 'Patient', 'N', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_b, 'B-5541-02', date '2025-03-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24207', v_pat, v_prov, pay_b, v_cov, 'accepted', date '2026-07-08', date '2026-07-08');
  v_line1 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values (v_line1, v_tenant, v_claim, 1, '43239', 1740.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '16', 'N290', 1740.00, now() - interval '90 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24207', v_pat);
  -- deliberately not linked to v_claim: the replacement claim (linked below) is the one that gets
  -- all the cash activity, and a case_claim link to a claim with no postings would permanently
  -- trip the cash-not-reconciled blocker on close
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c207-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'correction', 'confidence', 0.91));
  j := pg_temp._run(u_billing, 'cmd_claim_create_replacement', 'c207-rep', jsonb_build_object('original_claim_id', v_claim));
  v_repl := (j->>'claim_id')::uuid;
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_repl);
  perform pg_temp._run(u_billing, 'cmd_claim_release', 'c207-rel', jsonb_build_object('claim_id', v_repl));
  perform pg_temp._run(u_billing, 'cmd_claim_submit', 'c207-sub', jsonb_build_object('claim_id', v_repl));
  select claim_service_line_id into v_line1 from app.claim_service_line where claim_id = v_repl;
  j := pg_temp._run(u_cash, 'cmd_remittance_receive', 'c207-rcv', jsonb_build_object('interchange_trace', 'TRN-C207', 'payer_id', pay_b, 'control_total', 1320.00, 'lines', jsonb_build_array(
    jsonb_build_object('claim_id', v_repl, 'line_id', v_line1, 'paid', 1320.00, 'adjustment', 420.00, 'group_code', 'CO', 'carc', '45'))));
  v_rem := (j->>'remittance_id')::uuid;
  perform pg_temp._run(u_cash, 'cmd_remittance_post', 'c207-post', jsonb_build_object('remittance_id', v_rem));
  v_dep := app.uuid_v7();
  insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount) values (v_dep, v_tenant, pay_b, 'DEP-88407', 1320.00);
  perform pg_temp._run(u_cash, 'cmd_deposit_allocate', 'c207-alloc', jsonb_build_object('deposit_id', v_dep, 'remittance_id', v_rem, 'line_id', v_line1, 'amount', 1320.00));
  perform pg_temp._run(u_fin, 'cmd_case_close', 'c207-close', jsonb_build_object('case_id', v_case, 'reason', 'Reconciled; corrected claim paid in full'));
  -- the payer's post-payment audit recoups $420, which reopens the closed case (IV09)
  perform pg_temp._run(u_cash, 'cmd_posting_apply_payment', 'c207-recoup', jsonb_build_object('line_id', v_line1, 'kind', 'recoupment', 'amount', 420.00));
  perform pg_temp._run(u_mgr, 'cmd_case_reopen', 'c207-reopen', jsonb_build_object('case_id', v_case, 'trigger', 'recoupment', 'reason', 'Payer post-payment audit recouped $420'));
  n := n + 1; raise notice 'seeded %: CLM-24207 (reopened by a $420 recoupment)', n;

  -- ================================================================ CLM-24208: appeal, stage 4 (Sent)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24208', 'Patient', 'O', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_a, 'A-8802-17', date '2025-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24208', v_pat, v_prov, pay_a, v_cov, 'accepted', date '2026-09-02', date '2026-09-02');
  v_line1 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values (v_line1, v_tenant, v_claim, 1, '95810', 3400.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '50', 'N115', 3400.00, now() - interval '32 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24208', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c208-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'appeal', 'confidence', 0.88));
  perform pg_temp._run(u_denials, 'cmd_denial_confirm_path', 'c208-cp', jsonb_build_object('denial_id', v_den, 'path', 'appeal'));
  j := pg_temp._run(u_appeals, 'cmd_appeal_draft', 'c208-dr', jsonb_build_object('denial_id', v_den, 'statements', jsonb_build_array(
    jsonb_build_object('text', 'The patient reported excessive daytime sleepiness on Aug 20.', 'source_ref', 'claim:' || v_claim),
    jsonb_build_object('text', 'The Epworth score was 14, above the screening threshold.', 'source_ref', 'claim:' || v_claim))));
  v_appeal := (j->>'appeal_id')::uuid;
  j := pg_temp._run(u_appeals, 'cmd_appeal_request_approval', 'c208-rq', jsonb_build_object('appeal_id', v_appeal));
  v_ar := (j->>'approval_request_id')::uuid;
  perform pg_temp._run(u_mgr, 'cmd_approval_decide', 'c208-ad', jsonb_build_object('approval_request_id', v_ar, 'decision', 'approved'));
  perform pg_temp._run(u_appeals, 'cmd_appeal_file', 'c208-fl', jsonb_build_object('appeal_id', v_appeal, 'submission_ref', 'APL-5208'));
  n := n + 1; raise notice 'seeded %: CLM-24208 (stage 4, filed, waiting on payer)', n;

  -- ================================================================ CLM-24209: evidence, stage 4 (Sent)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24209', 'Patient', 'P', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_b, 'B-1190-63', date '2025-03-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24209', v_pat, v_prov, pay_b, v_cov, 'accepted', date '2026-09-24', date '2026-09-24');
  v_line1 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values (v_line1, v_tenant, v_claim, 1, '72148', 1880.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '252', 'M127', 1880.00, now() - interval '17 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24209', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c209-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'evidence', 'confidence', 0.90));
  perform pg_temp._run(u_denials, 'cmd_denial_confirm_path', 'c209-cp', jsonb_build_object('denial_id', v_den, 'path', 'evidence'));
  j := pg_temp._run(u_denials, 'cmd_evidence_assemble', 'c209-ev', jsonb_build_object('denial_id', v_den,
    'items', jsonb_build_array(jsonb_build_object('kind', 'authorization', 'title', 'Authorization AUTH-81877', 'source_ref', 'auth:81877'))));
  v_rr := app.uuid_v7();
  insert into app.records_request (records_request_id, tenant_id, claim_id, denial_id, requested_items, due_at) values
    (v_rr, v_tenant, v_claim, v_den, 'Prior authorization number', now() + interval '30 days');
  perform pg_temp._run(u_denials, 'cmd_records_request_respond', 'c209-rr', jsonb_build_object('records_request_id', v_rr, 'evidence_item_ids', j->'created_ids', 'note', 'Authorization number attached'));
  n := n + 1; raise notice 'seeded %: CLM-24209 (stage 4, packet sent)', n;

  -- ================================================================ CLM-24210: corrected, stage 4 (Sent)
  v_pat := app.uuid_v7();
  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob) values (v_pat, v_tenant, 'MRN-24210', 'Patient', 'Q', date '1975-01-01');
  v_cov := app.uuid_v7();
  insert into app.coverage (coverage_id, tenant_id, patient_id, payer_id, member_id, effective_from, source) values (v_cov, v_tenant, v_pat, pay_c, 'C-2207-58', date '2025-01-01', 'eligibility');
  v_claim := app.uuid_v7();
  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id, coverage_id, status, service_from, service_to) values
    (v_claim, v_tenant, 'CLM-24210', v_pat, v_prov, pay_c, v_cov, 'accepted', date '2026-10-06', date '2026-10-06');
  v_line1 := app.uuid_v7(); v_line2 := app.uuid_v7(); v_line3 := app.uuid_v7();
  insert into app.claim_service_line (claim_service_line_id, tenant_id, claim_id, line_number, procedure_code, billed) values
    (v_line1, v_tenant, v_claim, 1, '99214', 210.00), (v_line2, v_tenant, v_claim, 2, '83036', 30.00), (v_line3, v_tenant, v_claim, 3, '92250', 720.00);
  v_den := app.uuid_v7();
  insert into app.denial (denial_id, tenant_id, claim_id, status, group_code, carc, rarc, denied_amount, received_at) values
    (v_den, v_tenant, v_claim, 'new', 'CO', '16', 'N290', 960.00, now() - interval '9 days');
  v_case := app.uuid_v7();
  insert into app."case" (case_id, tenant_id, case_number, patient_id) values (v_case, v_tenant, 'CLM-24210', v_pat);
  insert into app.case_claim (tenant_id, case_id, claim_id) values (v_tenant, v_case, v_claim);
  perform pg_temp._run(u_denials, 'cmd_denial_triage', 'c210-tri', jsonb_build_object('denial_id', v_den, 'root_cause', 'GENERAL', 'recommended_path', 'correction', 'confidence', 0.93));
  j := pg_temp._run(u_billing, 'cmd_claim_create_replacement', 'c210-rep', jsonb_build_object('original_claim_id', v_claim));
  v_repl := (j->>'claim_id')::uuid;
  perform pg_temp._run(u_billing, 'cmd_claim_release', 'c210-rel', jsonb_build_object('claim_id', v_repl));
  perform pg_temp._run(u_billing, 'cmd_claim_submit', 'c210-sub', jsonb_build_object('claim_id', v_repl));
  n := n + 1; raise notice 'seeded %: CLM-24210 (stage 4, resubmitted)', n;

  raise notice '--- % of 15 cases seeded ---', n;
end $$;

drop function pg_temp._run(uuid, text, text, jsonb);
