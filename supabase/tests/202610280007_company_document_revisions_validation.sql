-- ElisCaretex V2 - Validation - 202610280007_company_document_revisions
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all company document revision checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"
-- Note: the 202610280001 and 202610280006 validations call the RPCs without a
-- revision (and 0001 with the removed "keep confirmations" argument), so they
-- describe the state before this migration.

do $$
declare
  v_admin uuid; v_staff uuid;
  v_doc uuid := gen_random_uuid();
  v_path1 text; v_path2 text; v_path3 text;
  v jsonb; v_status text;
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_file jsonb;
begin
  select auth_user_id into v_admin from public.account_access_profiles where account_type='USER' and job_title_code='ADMINISTRATOR' limit 1;
  select a.auth_user_id into v_staff from public.company_document_audience() a
    where not exists(select 1 from public.account_permission_grants g where g.auth_user_id=a.auth_user_id and g.module_code='COMPANY_DOCUMENTS')
      and not exists(select 1 from public.account_roles ar join public.roles r on r.role_id=ar.role_id where ar.auth_user_id=a.auth_user_id and ar.active and r.role_code in ('ADMIN','MANAGER','AUDITOR'))
    limit 1;
  if v_admin is null or v_staff is null then raise exception 'FAIL: fixtures (admin %, staff %)',v_admin,v_staff; end if;

  v_path1 := v_doc::text || '/v1.pdf'; v_path2 := v_doc::text || '/v2.pdf'; v_path3 := v_doc::text || '/v3.pdf';
  insert into storage.objects(bucket_id,name,owner) values ('company-documents',v_path1,v_admin),('company-documents',v_path2,v_admin),('company-documents',v_path3,v_admin);
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);

  -- 1. Publishing needs a revision number and a date that is not in the future.
  v_file := jsonb_build_object('document_id',v_doc,'category','SSOW','title','Validation revision SSOW','storage_path',v_path1,'original_file_name','v1.pdf','mime_type','application/pdf');
  begin
    perform public.create_company_document(v_file || jsonb_build_object('revision_date',v_today));
    raise exception 'FAIL 1: published without a revision number';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.create_company_document(v_file || jsonb_build_object('revision_number','3'));
    raise exception 'FAIL 1: published without a revision date';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.create_company_document(v_file || jsonb_build_object('revision_number','3','revision_date',v_today+1));
    raise exception 'FAIL 1: published with a future revision date';
  exception when invalid_parameter_value then null; end;
  perform public.create_company_document(v_file || jsonb_build_object('revision_number',' 3 ','revision_date',v_today-30));
  if not exists(select 1 from public.company_documents where document_id=v_doc and revision_number='3' and revision_date=v_today-30) then raise exception 'FAIL 1: revision not stored'; end if;
  if not exists(select 1 from public.company_document_history where document_id=v_doc and event_type='PUBLISHED' and revision_number='3') then raise exception 'FAIL 1: revision not in the log'; end if;

  -- 2. Staff see the revision and confirm it.
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff,'role','authenticated')::text, true);
  select x into v from jsonb_array_elements(public.get_my_company_documents()->'documents') x where (x->>'document_id')::uuid=v_doc;
  if v->>'revision_number' is distinct from '3' or (v->>'revision_date')::date<>v_today-30 then raise exception 'FAIL 2: staff do not see the revision (%)',v; end if;
  perform public.acknowledge_company_document(v_doc,1);

  -- 3. A new version needs a different revision number and a date not earlier than the current one.
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  begin
    perform public.replace_company_document_file(v_doc,jsonb_build_object('storage_path',v_path2,'original_file_name','v2.pdf','mime_type','application/pdf','revision_number','3','revision_date',v_today),'Same revision',1);
    raise exception 'FAIL 3: same revision number accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.replace_company_document_file(v_doc,jsonb_build_object('storage_path',v_path2,'original_file_name','v2.pdf','mime_type','application/pdf','revision_number','4','revision_date',v_today-31),'Older date',1);
    raise exception 'FAIL 3: earlier revision date accepted';
  exception when invalid_parameter_value then null; end;
  if to_regprocedure('public.replace_company_document_file(uuid,jsonb,text,boolean,integer)') is not null then raise exception 'FAIL 3: the keep-confirmations signature still exists'; end if;

  -- 4. Every new file asks everyone to read and confirm again.
  v := public.replace_company_document_file(v_doc,jsonb_build_object('storage_path',v_path2,'original_file_name','v2.pdf','mime_type','application/pdf','revision_number','4','revision_date',v_today),'Lock-out step added',1);
  if v->>'old_storage_path'<>v_path1 then raise exception 'FAIL 4: old path not returned'; end if;
  if (v->'document'->>'acknowledgement_version')::int<>2 or v->'document'->>'revision_number'<>'4' then raise exception 'FAIL 4: document not moved to revision 4 / version 2'; end if;
  if not exists(select 1 from public.company_document_history where document_id=v_doc and event_type='NEW_VERSION' and revision_number='4' and revision_date=v_today and reconfirmation_required) then raise exception 'FAIL 4: new version not logged with its revision'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff,'role','authenticated')::text, true);
  select x->>'status' into v_status from jsonb_array_elements(public.get_my_company_documents()->'documents') x where (x->>'document_id')::uuid=v_doc;
  if v_status is distinct from 'RECONFIRM' then raise exception 'FAIL 4: staff status after a new file is %',v_status; end if;

  -- 5. A revision typo can be corrected in the details, and the correction is logged.
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  perform public.update_company_document_details(v_doc,jsonb_build_object('revision_number','4.1','revision_date',v_today),2);
  if not exists(select 1 from public.company_document_history where document_id=v_doc and event_type='DETAILS_UPDATED' and change_note like 'Revision corrected to Rev 4.1%(was Rev 4%') then raise exception 'FAIL 5: revision correction not logged'; end if;
  begin
    perform public.update_company_document_details(v_doc,jsonb_build_object('revision_number',''),3);
    raise exception 'FAIL 5: revision number removed';
  exception when invalid_parameter_value then null; end;

  -- 6. Helpers stay closed to clients.
  if has_function_privilege('authenticated','public.company_document_check_revision(jsonb,text,date)','execute')
     or has_function_privilege('anon','public.replace_company_document_file(uuid,jsonb,text,integer)','execute') then
    raise exception 'FAIL 6: a helper or RPC is open to the wrong role';
  end if;

  raise exception 'PASSED: all company document revision checks (nothing was kept)';
end $$;
