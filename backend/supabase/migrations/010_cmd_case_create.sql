-- 010_cmd_case_create: lets a real user originate a brand-new case from the UI instead of every case only ever
-- coming from the seed script. Two commands:
--   api.cmd_case_create    -- new patient + claim (+ lines, + diagnoses) + case + case_claim, one transaction
--   api.cmd_deposit_create -- an ad-hoc bank deposit, so a self-created case can later reach deposit.allocate /
--                             case.close (api.case_blockers blocks closure on 'Cash is not reconciled yet'
--                             whenever paid <> deposit_allocated; there was previously no way to create a deposit
--                             outside the seed).
-- Same command convention as 006_cmd_claims.sql (ctx -> require_portal -> authorize -> validate -> begin_cmd ->
-- guard -> mutate -> finish_cmd). Permission keys 'case.create' and 'deposit.create' and their role grants are
-- added in backend/seed/010_reference.sql, not here (that file is the one place permissions/role grants live).

-- ================================================================ api.cmd_case_create
create function api.cmd_case_create(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd      constant text := 'case.create';
  v_ctx      app.ctx_t;
  v_cached   jsonb;
  v_patient  jsonb;
  v_lines    jsonb;
  v_dx       jsonb;
  v_payer_id uuid;
  v_prov_id  uuid;
  v_svc_date date;
  v_first    text;
  v_last     text;
  v_dob      date;
  v_sex      text;
  v_title    text;
  l          jsonb;
  v_n        integer := 0;
  v_pat_id   uuid := app.uuid_v7();
  v_claim_id uuid := app.uuid_v7();
  v_case_id  uuid := app.uuid_v7();
  v_k        integer;
  v_number   text;
  v_mrn      text;
  v_line_no  integer;
  v_seq      integer;
  v_line_count integer;
  v_dx_count   integer;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('case.create');

  v_patient  := p_args -> 'patient';
  if jsonb_typeof(v_patient) is distinct from 'object' then
    perform app.refuse('MR005', 'patient_required', 'patient', 'A patient object is required');
  end if;
  v_first := app.arg_text(v_patient, 'first_name', true, 80);
  v_last  := app.arg_text(v_patient, 'last_name', true, 80);
  v_dob   := app.arg_date(v_patient, 'dob', true);
  v_sex   := app.arg_enum(v_patient, 'sex', array['female','male','other','unknown'], false);

  v_payer_id := app.arg_uuid(p_args, 'payer_id');
  v_prov_id  := app.arg_uuid(p_args, 'provider_id', false);
  v_svc_date := app.arg_date(p_args, 'service_date', false);
  v_title    := app.arg_text(p_args, 'case_title', false, 200);

  v_lines := p_args -> 'lines';
  if jsonb_typeof(v_lines) is distinct from 'array' or jsonb_array_length(v_lines) = 0 then
    perform app.refuse('MR005', 'lines_required', 'lines', 'Send at least one service line');
  end if;
  if jsonb_array_length(v_lines) > 50 then
    perform app.refuse('MR005', 'too_many_lines', 'lines', 'A new case may carry at most 50 service lines');
  end if;
  for l in select x.value from jsonb_array_elements(v_lines) x loop
    if jsonb_typeof(l) is distinct from 'object' then
      perform app.refuse('MR005', 'invalid_line', 'lines', 'Each service line is an object');
    end if;
    perform app.arg_text(l, 'procedure_code', true, 20);
    perform app.valid_money(app.arg_numeric(l, 'billed'), 'billed');
  end loop;

  v_dx := coalesce(p_args -> 'diagnoses', '[]'::jsonb);
  if jsonb_typeof(v_dx) is distinct from 'array' then
    perform app.refuse('MR005', 'invalid_diagnoses', 'diagnoses', 'diagnoses must be an array');
  end if;
  if jsonb_array_length(v_dx) > 12 then
    perform app.refuse('MR005', 'too_many_diagnoses', 'diagnoses', 'A claim may carry at most 12 diagnoses');
  end if;
  for l in select x.value from jsonb_array_elements(v_dx) x loop
    perform app.arg_text(l, 'icd10_code', true, 20);
  end loop;

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  perform app.scoped_row('payer', v_payer_id);
  if v_prov_id is not null then
    perform app.scoped_row('provider', v_prov_id);
  end if;

  select count(*) + 30001 into v_k from app.claim c where c.tenant_id = v_ctx.tenant_id;
  loop
    v_number := 'CLM-' || v_k;
    v_mrn    := 'MRN-' || v_k;
    exit when not exists (select 1 from app.claim c where c.tenant_id = v_ctx.tenant_id and c.claim_number = v_number)
          and not exists (select 1 from app."case" c where c.tenant_id = v_ctx.tenant_id and c.case_number = v_number)
          and not exists (select 1 from app.patient p where p.tenant_id = v_ctx.tenant_id and p.mrn = v_mrn);
    v_k := v_k + 1;
  end loop;

  insert into app.patient (patient_id, tenant_id, mrn, first_name, last_name, dob, sex)
  values (v_pat_id, v_ctx.tenant_id, v_mrn, v_first, v_last, v_dob, v_sex);

  insert into app.claim (claim_id, tenant_id, claim_number, patient_id, provider_id, payer_id,
                         frequency_code, status, service_from, service_to)
  values (v_claim_id, v_ctx.tenant_id, v_number, v_pat_id, v_prov_id, v_payer_id,
          '1', 'draft', v_svc_date, v_svc_date);

  v_line_no := 0;
  for l in select x.value from jsonb_array_elements(v_lines) x loop
    v_line_no := v_line_no + 1;
    insert into app.claim_service_line (tenant_id, claim_id, line_number, procedure_code, units, billed, service_date)
    values (v_ctx.tenant_id, v_claim_id, v_line_no, l ->> 'procedure_code',
            coalesce((l ->> 'units')::numeric, 1), (l ->> 'billed')::numeric, v_svc_date);
  end loop;
  v_line_count := v_line_no;

  v_seq := 0;
  for l in select x.value from jsonb_array_elements(v_dx) x loop
    v_seq := v_seq + 1;
    insert into app.claim_diagnosis (tenant_id, claim_id, sequence, icd10_code)
    values (v_ctx.tenant_id, v_claim_id, v_seq, l ->> 'icd10_code');
  end loop;
  v_dx_count := v_seq;

  insert into app."case" (case_id, tenant_id, case_number, patient_id, title)
  values (v_case_id, v_ctx.tenant_id, v_number, v_pat_id, v_title);
  insert into app.case_claim (tenant_id, case_id, claim_id)
  values (v_ctx.tenant_id, v_case_id, v_claim_id);

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('patient_id', v_pat_id, 'claim_id', v_claim_id, 'case_id', v_case_id,
                       'case_number', v_number, 'claim_number', v_number, 'mrn', v_mrn,
                       'line_count', v_line_count, 'diagnosis_count', v_dx_count, 'status', 'draft'),
    'case.created', v_case_id);
end;
$$;

comment on function api.cmd_case_create(text, jsonb) is
$c$case.create (portal: provider; permission 'case.create'). Originates a brand-new patient, claim (draft,
  frequency_code '1') and case from the UI, instead of only ever coming from the seed script.
args: { patient: { first_name, last_name, dob YYYY-MM-DD, sex female|male|other|unknown (optional) },
  payer_id uuid (required), provider_id uuid (optional), service_date YYYY-MM-DD (optional, applied to the claim
  and every line), case_title text (optional),
  lines: [ { procedure_code text, billed number >= 0 (2 dp), units number (optional, default 1) } ] (1..50),
  diagnoses: [ { icd10_code text } ] (0..12) }
Guards: payer (and provider, if given) in the caller's tenant (MR004); at least one line, each with a procedure
  code and a valid billed amount (MR005); the generated claim/case number and patient MRN share one counter and are
  retried past any collision, the same shape as cmd_claim_create_replacement's '<original>-R<n>' loop.
Writes: patient, claim (draft), claim_service_line per line, claim_diagnosis per diagnosis, case (open), case_claim.
result: { patient_id, claim_id, case_id, case_number, claim_number, mrn, line_count, diagnosis_count, status }
event: case.created (aggregate = the new case_id).$c$;

-- ================================================================ api.cmd_deposit_create
create function api.cmd_deposit_create(p_idem text, p_args jsonb) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_cmd      constant text := 'deposit.create';
  v_ctx      app.ctx_t;
  v_cached   jsonb;
  v_payer_id uuid;
  v_amount   numeric;
  v_ref      text;
  v_date     date;
  v_dep_id   uuid := app.uuid_v7();
  v_k        integer;
begin
  v_ctx := app.ctx();
  perform app.require_portal('provider');
  perform app.authorize('deposit.create');

  v_payer_id := app.arg_uuid(p_args, 'payer_id');
  v_amount   := app.valid_amount(app.arg_numeric(p_args, 'amount'));
  v_ref      := app.arg_text(p_args, 'bank_reference', false, 80);
  v_date     := coalesce(app.arg_date(p_args, 'deposit_date', false), current_date);

  v_cached := app.begin_cmd(c_cmd, p_idem, p_args);
  if v_cached is not null then
    return v_cached;
  end if;

  perform app.scoped_row('payer', v_payer_id);

  if v_ref is null then
    select count(*) + 1 into v_k from app.deposit d where d.tenant_id = v_ctx.tenant_id;
    loop
      v_ref := 'DEP-' || v_k;
      exit when not exists (select 1 from app.deposit d where d.tenant_id = v_ctx.tenant_id and d.bank_reference = v_ref);
      v_k := v_k + 1;
    end loop;
  elsif exists (select 1 from app.deposit d where d.tenant_id = v_ctx.tenant_id and d.bank_reference = v_ref) then
    perform app.refuse('MR002', 'duplicate_bank_reference', 'deposit',
      format('A deposit with bank reference %s already exists', v_ref));
  end if;

  insert into app.deposit (deposit_id, tenant_id, payer_id, bank_reference, amount, deposit_date, status)
  values (v_dep_id, v_ctx.tenant_id, v_payer_id, v_ref, v_amount, v_date, 'open');

  return app.finish_cmd(c_cmd, p_idem, p_args,
    jsonb_build_object('deposit_id', v_dep_id, 'bank_reference', v_ref, 'amount', v_amount,
                       'deposit_date', v_date, 'status', 'open'),
    'deposit.created', v_dep_id);
end;
$$;

comment on function api.cmd_deposit_create(text, jsonb) is
$c$deposit.create (portal: provider; permission 'deposit.create'). Records an ad-hoc bank deposit so a
  self-created case can later reach deposit.allocate and case.close (api.case_blockers blocks closure while
  paid <> deposit_allocated). Previously only the seed script could create a deposit row.
args: { payer_id uuid (required), amount number > 0 (2 dp, required), bank_reference text (optional, auto-generated
  'DEP-<n>' if absent; MR002 duplicate_bank_reference if given and already used), deposit_date YYYY-MM-DD (optional,
  default today) }
Guards: payer in the caller's tenant (MR004); amount > 0 (MR005); bank_reference unique per tenant (MR002 if the
  caller supplied a reference already in use; auto-generated references are retried past any collision).
Writes: deposit (status 'open').
result: { deposit_id, bank_reference, amount, deposit_date, status }
event: deposit.created (aggregate = the new deposit_id).$c$;

revoke all on function api.cmd_case_create(text, jsonb) from public, anon;
revoke all on function api.cmd_deposit_create(text, jsonb) from public, anon;
grant execute on function api.cmd_case_create(text, jsonb) to authenticated;
grant execute on function api.cmd_deposit_create(text, jsonb) to authenticated;
