-- Task 9 reference seed: tenant, org units, 48 roles/permissions, 13 payers + configs,
-- clearinghouses + connections, a rule pack. Idempotent (natural-key WHERE NOT EXISTS guards),
-- data-only (lives in seed/, not migrations/, no down script). Run once via execute_sql.
--
-- Source of the 48 roles: index.html PERS array (persona id/role/portal/approval-limit) + PERM
-- object (prototype capability groups), read at lines ~340-351, ~667-670, ~890, ~1037-1044.
-- Source of the 13 payers: Meridian_Platform_Plan_Part3_TestCases_and_SyntheticData.xlsx,
-- sheet "Payers and orgs" (read via PowerShell zip/XML, no Python on this machine).
--
-- Ruling (recorded in the ledger): only 27 permission keys exist (the commands actually built in
-- Tasks 6-8); the prototype's PERM groups (tri/draft/send/release/post/alloc/recon/close/ar/pat/ovr)
-- are mapped onto them by the controller's judgment below. 'recon' (reconciliation) has no
-- implemented command in release 1 and is intentionally left unmapped.

do $$
declare
  v_tenant uuid;
begin
  -- ---------------------------------------------------------------- tenant + org units
  select tenant_id into v_tenant from app.tenant where name = 'Meridian Demo Health';
  if v_tenant is null then
    v_tenant := app.uuid_v7();
    insert into app.tenant (tenant_id, name) values (v_tenant, 'Meridian Demo Health');
  end if;

  insert into app.org_unit (org_unit_id, tenant_id, parent_id, name)
  select app.uuid_v7(), v_tenant, null, x.name
  from (values ('Meridian Primary Care East'), ('Meridian Primary Care West'), ('North Imaging'),
               ('Meridian Orthopedics'), ('Meridian General Hospital')) as x(name)
  where not exists (select 1 from app.org_unit o where o.tenant_id = v_tenant and o.name = x.name);

  -- ---------------------------------------------------------------- roles (48, excluding the prototype's "tester")
  insert into app.role (role_key, label, portal)
  select x.role_key, x.label, x.portal from (values
    -- provider portal: Cases + Denials loop staff (index.html PERS, no `g`/`pt` field)
    ('denials','Denials analyst','provider'), ('appeals','Appeals specialist','provider'),
    ('billing','Billing specialist','provider'), ('ar','AR specialist','provider'),
    ('cash','Cash poster','provider'), ('fin','Finance analyst','provider'),
    ('sup','Supervisor','provider'), ('mgr','RCM manager','provider'), ('comp','Compliance reviewer','provider'),
    -- provider portal: Access group (g:'Access')
    ('contact','Contact center agent','provider'), ('sched','Scheduler','provider'),
    ('reg','Registrar','provider'), ('ver','Verification specialist','provider'),
    ('auth','Authorization specialist','provider'), ('fc','Financial counselor','provider'),
    ('am','Patient access manager','provider'),
    -- provider portal: Clinical group (g:'Clinical')
    ('md','Physician','provider'), ('ma','Nurse or medical assistant','provider'),
    ('ur','Utilization review nurse','provider'), ('cdi','CDI specialist','provider'),
    ('coder','Coder','provider'), ('him','HIM specialist','provider'),
    ('enr','Enrollment specialist','provider'), ('ri','Revenue integrity analyst','provider'),
    ('tpl','Liability specialist','provider'),
    -- provider portal: Finance group
    ('cua','Contract and underpayment analyst','provider'), ('pfs','Patient financial services rep','provider'),
    ('ref','Refund and credit specialist','provider'),
    -- provider portal: admin (pt:'provider')
    ('cfo','Practice administrator or CFO','provider'), ('priv','Privacy officer','provider'),
    ('adm','Provider system administrator','provider'),
    -- patient portal (pt:'patient')
    ('pat','Patient','patient'), ('gua','Guarantor or proxy','patient'), ('slf','Self-pay patient','patient'),
    -- payer portal (pt:'payer')
    ('py1','Eligibility and enrollment rep','payer'), ('py2','Utilization nurse reviewer','payer'),
    ('py3','Medical director','payer'), ('py4','Claims adjudicator','payer'),
    ('py5','Appeals and grievances analyst','payer'), ('py6','Remittance and payment operations','payer'),
    ('py7','Payment integrity analyst','payer'), ('py8','Network and contracts manager','payer'),
    -- clearinghouse portal (pt:'clearinghouse')
    ('ch1','Clearinghouse operations analyst','clearinghouse'), ('ch2','Connectivity and enrollment engineer','clearinghouse'),
    ('ch3','Client support rep','clearinghouse'),
    -- platform portal (pt:'platform')
    ('pl1','Platform administrator','platform'), ('pl2','AI governance reviewer','platform'),
    ('pl3','Rules and policy pack owner','platform')
  ) as x(role_key, label, portal)
  where not exists (select 1 from app.role r where r.role_key = x.role_key);

  -- ---------------------------------------------------------------- permissions (the 27 commands built in Tasks 6-8)
  insert into app.permission (permission_key, description)
  select x.permission_key, x.description from (values
    ('remittance.receive','Receive an 835 remittance'), ('remittance.post','Post a received remittance'),
    ('denial.triage','Triage a denial'), ('denial.confirm_path','Confirm a denial''s recovery path'),
    ('claim.create_replacement','Draft a replacement claim'), ('claim.release','Release a claim to submission'),
    ('claim.submit','Submit a released claim'),
    ('evidence.assemble','Assemble evidence for a denial'), ('appeal.draft','Draft or amend an appeal'),
    ('appeal.request_approval','Send an appeal for approval'), ('approval.decide','Decide an approval request'),
    ('appeal.file','File an approved appeal'), ('records_request.respond','Respond to a records request'),
    ('ai.review','Review an AI-drafted interaction'), ('ai.interaction_record','Record an AI interaction'),
    ('appeal.record_decision','Record a payer''s appeal decision'), ('records_request.decide','Decide a records response'),
    ('posting.apply_payment','Apply a payment or adjustment to a line'), ('posting.reverse','Reverse a posting'),
    ('deposit.allocate','Allocate a deposit to a remittance or line'),
    ('patient_payment.apply','Apply a patient payment'), ('patient_dispute.open','Open a patient dispute'),
    ('patient_dispute.resolve','Resolve a patient dispute'),
    ('writeoff.request','Request a write-off'), ('writeoff.post','Post an approved write-off'),
    ('case.close','Close a case'), ('case.reopen','Reopen a closed case')
  ) as x(permission_key, description)
  where not exists (select 1 from app.permission p where p.permission_key = x.permission_key);

  -- ---------------------------------------------------------------- role_permission (prototype PERM groups, mapped)
  insert into app.role_permission (role_key, permission_key)
  select g.role_key, g.permission_key from (values
    -- tri: denial triage + path confirmation
    ('denials','denial.triage'),('appeals','denial.triage'),('billing','denial.triage'),('ar','denial.triage'),('sup','denial.triage'),('mgr','denial.triage'),
    ('denials','denial.confirm_path'),('appeals','denial.confirm_path'),('billing','denial.confirm_path'),('ar','denial.confirm_path'),('sup','denial.confirm_path'),('mgr','denial.confirm_path'),
    -- draft: appeal drafting, evidence assembly, recording the AI draft interaction
    ('denials','appeal.draft'),('appeals','appeal.draft'),('billing','appeal.draft'),('sup','appeal.draft'),('mgr','appeal.draft'),
    ('denials','evidence.assemble'),('appeals','evidence.assemble'),('billing','evidence.assemble'),('sup','evidence.assemble'),('mgr','evidence.assemble'),
    ('denials','ai.interaction_record'),('appeals','ai.interaction_record'),('billing','ai.interaction_record'),('sup','ai.interaction_record'),('mgr','ai.interaction_record'),
    -- send: request approval, respond to a records request, file once approved
    ('denials','appeal.request_approval'),('appeals','appeal.request_approval'),('billing','appeal.request_approval'),('sup','appeal.request_approval'),('mgr','appeal.request_approval'),
    ('denials','records_request.respond'),('appeals','records_request.respond'),('billing','records_request.respond'),('sup','records_request.respond'),('mgr','records_request.respond'),
    ('denials','appeal.file'),('appeals','appeal.file'),('billing','appeal.file'),('sup','appeal.file'),('mgr','appeal.file'),
    -- release: release and submit claims, draft a replacement
    ('billing','claim.release'),('sup','claim.release'),('mgr','claim.release'),
    ('billing','claim.submit'),('sup','claim.submit'),('mgr','claim.submit'),
    ('billing','claim.create_replacement'),('sup','claim.create_replacement'),('mgr','claim.create_replacement'),
    -- post: post remittances / postings (cash + fin + sup + mgr); receive also open to the clearinghouse ops role
    ('cash','remittance.post'),('fin','remittance.post'),('sup','remittance.post'),('mgr','remittance.post'),
    ('cash','remittance.receive'),('fin','remittance.receive'),('sup','remittance.receive'),('mgr','remittance.receive'),('ch1','remittance.receive'),('ch2','remittance.receive'),
    ('cash','posting.apply_payment'),('fin','posting.apply_payment'),('sup','posting.apply_payment'),('mgr','posting.apply_payment'),
    ('cash','posting.reverse'),('fin','posting.reverse'),('sup','posting.reverse'),('mgr','posting.reverse'),
    -- alloc: deposit allocation (cash + fin + mgr)
    ('cash','deposit.allocate'),('fin','deposit.allocate'),('mgr','deposit.allocate'),
    -- close: case closure/reopen (fin + mgr)
    ('fin','case.close'),('mgr','case.close'),
    ('fin','case.reopen'),('mgr','case.reopen'),
    -- ar: patient dispute follow-up (ar + sup + mgr)
    ('ar','patient_dispute.open'),('sup','patient_dispute.open'),('mgr','patient_dispute.open'),
    ('ar','patient_dispute.resolve'),('sup','patient_dispute.resolve'),('mgr','patient_dispute.resolve'),
    -- pat: patient balances (billing + ar + fin + mgr); write-off request follows the same group
    ('billing','patient_payment.apply'),('ar','patient_payment.apply'),('fin','patient_payment.apply'),('mgr','patient_payment.apply'),
    ('billing','writeoff.request'),('ar','writeoff.request'),('fin','writeoff.request'),('mgr','writeoff.request'),
    -- ovr: approval decisions, write-off posting, AI review (sup + mgr; AI review also compliance + AI governance)
    ('sup','approval.decide'),('mgr','approval.decide'),
    ('sup','writeoff.post'),('mgr','writeoff.post'),
    ('sup','ai.review'),('mgr','ai.review'),('comp','ai.review'),('pl2','ai.review'),
    -- payer-portal commands
    ('py4','appeal.record_decision'),('py5','appeal.record_decision'),
    ('py1','records_request.decide'),('py4','records_request.decide')
  ) as g(role_key, permission_key)
  where not exists (select 1 from app.role_permission rp where rp.role_key = g.role_key and rp.permission_key = g.permission_key);

  -- ---------------------------------------------------------------- approval limits (prototype `lim`: sup 2500, mgr 10000)
  insert into app.approval_limit (tenant_id, role_key, kind, max_amount)
  select v_tenant, x.role_key, x.kind, x.max_amount from (values
    ('sup','appeal',2500.00), ('mgr','appeal',10000.00),
    ('sup','write_off',2500.00), ('mgr','write_off',10000.00)
  ) as x(role_key, kind, max_amount)
  where not exists (select 1 from app.approval_limit al where al.tenant_id = v_tenant and al.role_key = x.role_key and al.kind = x.kind);

  -- ---------------------------------------------------------------- payers (13, from the Part 3 "Payers and orgs" sheet)
  insert into app.payer (payer_id, tenant_id, name, payer_code, payer_type, status)
  select app.uuid_v7(), v_tenant, x.name, x.payer_code, x.payer_type, 'active'
  from (values
    ('MCR-FFS','Medicare Part B (synthetic)','medicare'),
    ('MA-A','Advantage Plan A','medicare'),
    ('MA-B','Advantage Plan B','medicare'),
    ('MCD-FFS1','State 1 Medicaid FFS','medicaid'),
    ('MCD-MCO1','State 1 Medicaid MCO A','medicaid'),
    ('MCD-MCO2','State 2 Medicaid MCO B','medicaid'),
    ('COM-A','Payer A','commercial'),
    ('COM-B','Payer B','commercial'),
    ('COM-C','Payer C','commercial'),
    ('COM-D','Payer D','commercial'),
    ('WC-1','Carrier WC-1','other'),
    ('AU-1','Carrier AU-1','other'),
    ('LI-1','Carrier LI-1','other')
  ) as x(payer_code, name, payer_type)
  where not exists (select 1 from app.payer p where p.tenant_id = v_tenant and p.payer_code = x.payer_code);

  -- ---------------------------------------------------------------- payer_config (filing/appeal/records windows)
  -- Ruling: the Part 3 "Payers and orgs" notes state filing days for COM-A/B/C/D and MCD-FFS1/MCO1 explicitly;
  -- the others (MCR-FFS, MA-A/B, WC-1, AU-1, LI-1) have no stated day-count, so the controller chose defaults
  -- consistent with the sheet's qualitative notes (e.g. MCR-FFS "12-month filing" -> 365 days).
  insert into app.payer_config (payer_config_id, tenant_id, payer_id, timely_filing_days, appeal_levels, records_request_days, effective_from)
  select app.uuid_v7(), v_tenant, p.payer_id, x.timely_filing_days, x.appeal_levels, 30, date '2026-01-01'
  from app.payer p
  join (values
    ('MCR-FFS',365,5), ('MA-A',90,2), ('MA-B',90,2),
    ('MCD-FFS1',365,1), ('MCD-MCO1',180,1), ('MCD-MCO2',90,2),
    ('COM-A',365,2), ('COM-B',180,1), ('COM-C',120,1), ('COM-D',365,2),
    ('WC-1',180,1), ('AU-1',180,1), ('LI-1',180,1)
  ) as x(payer_code, timely_filing_days, appeal_levels) on x.payer_code = p.payer_code
  where p.tenant_id = v_tenant
    and not exists (select 1 from app.payer_config pc where pc.tenant_id = v_tenant and pc.payer_id = p.payer_id);

  -- ---------------------------------------------------------------- clearinghouses + connections
  insert into app.clearinghouse (clearinghouse_id, tenant_id, name, clearinghouse_code, status)
  select app.uuid_v7(), v_tenant, x.name, x.code, 'active'
  from (values ('CH-1','Clearinghouse One'), ('CH-2','Clearinghouse Two')) as x(code, name)
  where not exists (select 1 from app.clearinghouse c where c.tenant_id = v_tenant and c.clearinghouse_code = x.code);

  -- CH-1: primary route for every payer. CH-2: secondary/failover route, wired for the two busiest
  -- commercial payers only (per the sheet's "Secondary route and failover tests" note).
  insert into app.clearinghouse_connection (clearinghouse_connection_id, tenant_id, clearinghouse_id, payer_id, protocol, endpoint_label, status)
  select app.uuid_v7(), v_tenant, ch.clearinghouse_id, p.payer_id, 'x12', ch.clearinghouse_code || ' to ' || p.name, 'active'
  from app.payer p
  join app.clearinghouse ch on ch.tenant_id = v_tenant and ch.clearinghouse_code = 'CH-1'
  where p.tenant_id = v_tenant
    and not exists (select 1 from app.clearinghouse_connection cc
                     where cc.tenant_id = v_tenant and cc.clearinghouse_id = ch.clearinghouse_id and cc.payer_id = p.payer_id);

  insert into app.clearinghouse_connection (clearinghouse_connection_id, tenant_id, clearinghouse_id, payer_id, protocol, endpoint_label, status)
  select app.uuid_v7(), v_tenant, ch.clearinghouse_id, p.payer_id, 'x12', ch.clearinghouse_code || ' to ' || p.name, 'active'
  from app.payer p
  join app.clearinghouse ch on ch.tenant_id = v_tenant and ch.clearinghouse_code = 'CH-2'
  where p.tenant_id = v_tenant and p.payer_code in ('COM-A','COM-B')
    and not exists (select 1 from app.clearinghouse_connection cc
                     where cc.tenant_id = v_tenant and cc.clearinghouse_id = ch.clearinghouse_id and cc.payer_id = p.payer_id);

  -- ---------------------------------------------------------------- rule pack (deadline/appeal-level policy, descriptive)
  insert into app.rule_pack (rule_pack_id, tenant_id, name, version, effective_from, status)
  select app.uuid_v7(), v_tenant, 'Payer timely filing and appeal levels', 1, date '2026-01-01', 'active'
  where not exists (select 1 from app.rule_pack rp where rp.tenant_id = v_tenant and rp.name = 'Payer timely filing and appeal levels');

  -- Skipped until the pl3 (rules owner) app_user exists (make-users.ps1 runs after this script);
  -- re-running this file once that user exists backfills the rule rows.
  if exists (select 1 from app.app_user where tenant_id = v_tenant and role_key = 'pl3') then
    insert into app.rule (rule_id, tenant_id, rule_pack_id, rule_key, payload, effective_from, owner, approved_by, approved_at)
    select app.uuid_v7(), v_tenant, rp.rule_pack_id, 'filing.' || p.payer_code,
           jsonb_build_object('payer_code', p.payer_code, 'timely_filing_days', pc.timely_filing_days, 'appeal_levels', pc.appeal_levels),
           date '2026-01-01', u_pl3.user_id, u_pl3.user_id, now()
    from app.payer p
    join app.payer_config pc on pc.tenant_id = v_tenant and pc.payer_id = p.payer_id
    join app.rule_pack rp on rp.tenant_id = v_tenant and rp.name = 'Payer timely filing and appeal levels'
    join app.app_user u_pl3 on u_pl3.tenant_id = v_tenant and u_pl3.role_key = 'pl3'
    where p.tenant_id = v_tenant
      and not exists (select 1 from app.rule r where r.tenant_id = v_tenant and r.rule_pack_id = rp.rule_pack_id and r.rule_key = 'filing.' || p.payer_code);
  end if;
end $$;
