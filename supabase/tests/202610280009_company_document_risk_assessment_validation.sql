-- ElisCaretex V2 - Validation - 202610280009_company_document_risk_assessment
-- One DO block; it always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: risk assessment section checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_admin uuid; v_doc uuid := gen_random_uuid(); v_path text; v_today date := (now() at time zone 'Europe/Dublin')::date;
begin
  select auth_user_id into v_admin from public.account_access_profiles where account_type='USER' and job_title_code='ADMINISTRATOR' limit 1;
  if v_admin is null then raise exception 'FAIL: no administrator fixture'; end if;
  v_path := v_doc::text || '/ra.pdf';
  insert into storage.objects(bucket_id,name,owner) values ('company-documents',v_path,v_admin);
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);

  -- 1. A risk assessment can be published.
  perform public.create_company_document(jsonb_build_object('document_id',v_doc,'category','risk_assessment','title','Validation RA','storage_path',v_path,
    'original_file_name','ra.pdf','mime_type','application/pdf','revision_number','1','revision_date',v_today));
  if not exists(select 1 from public.company_documents where document_id=v_doc and category='RISK_ASSESSMENT') then raise exception 'FAIL 1: not stored as RISK_ASSESSMENT'; end if;

  -- 2. Moving it to another section is logged; unknown sections are refused.
  perform public.update_company_document_details(v_doc,jsonb_build_object('category','SSOW'),1);
  perform public.update_company_document_details(v_doc,jsonb_build_object('category','RISK_ASSESSMENT'),2);
  if not exists(select 1 from public.company_document_history where document_id=v_doc and change_note like '%Section changed to Risk assessment%') then raise exception 'FAIL 2: section change not logged'; end if;
  begin
    perform public.update_company_document_details(v_doc,jsonb_build_object('category','KITCHEN'),3);
    raise exception 'FAIL 2: unknown section accepted';
  exception when invalid_parameter_value then null; end;

  raise exception 'PASSED: risk assessment section checks (nothing was kept)';
end $$;
