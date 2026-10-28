-- ElisCaretex V2 - Validation - 202610280001_company_documents
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all company document checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_admin uuid; v_staff uuid; v_viewer uuid; v_terminal uuid;
  v_doc uuid := gen_random_uuid();
  v_path1 text; v_path2 text; v_path3 text;
  v jsonb; v_row int; v_status text;
begin
  -- Fixtures from live accounts: an Administrator, a personal account without
  -- a Company Documents grant, a Production Supervisor (VIEW) and a terminal.
  select auth_user_id into v_admin from public.account_access_profiles where account_type='USER' and job_title_code='ADMINISTRATOR' limit 1;
  select a.auth_user_id into v_staff from public.company_document_audience() a
    where not exists(select 1 from public.account_permission_grants g where g.auth_user_id=a.auth_user_id and g.module_code='COMPANY_DOCUMENTS')
      and not exists(select 1 from public.account_roles ar join public.roles r on r.role_id=ar.role_id where ar.auth_user_id=a.auth_user_id and ar.active and r.role_code in ('ADMIN','MANAGER','AUDITOR'))
    limit 1;
  select auth_user_id into v_viewer from public.account_access_profiles where account_type='USER' and job_title_code='PRODUCTION_SUPERVISOR' limit 1;
  select device_auth_user_id into v_terminal from public.production_station_devices where active and device_auth_user_id is not null limit 1;
  if v_admin is null or v_staff is null or v_viewer is null or v_terminal is null then raise exception 'FAIL: fixtures (admin %, staff %, viewer %, terminal %)',v_admin,v_staff,v_viewer,v_terminal; end if;

  -- 1. Who must read: personal accounts, never terminals.
  if exists(select 1 from public.company_document_audience() where auth_user_id=v_terminal) then raise exception 'FAIL 1: a terminal is in the audience'; end if;
  if not exists(select 1 from public.company_document_audience() where auth_user_id=v_staff) then raise exception 'FAIL 1: staff not in the audience'; end if;

  v_path1 := v_doc::text || '/v1-policy.pdf';
  v_path2 := v_doc::text || '/v2-policy.pdf';
  v_path3 := v_doc::text || '/v3-policy.pdf';
  insert into storage.objects(bucket_id,name,owner) values ('company-documents',v_path1,v_admin),('company-documents',v_path2,v_admin),('company-documents',v_path3,v_admin);

  -- 2. A staff account cannot publish.
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff,'role','authenticated')::text, true);
  begin
    perform public.create_company_document(jsonb_build_object('document_id',v_doc,'category','POLICY','title','x','storage_path',v_path1,'original_file_name','p.pdf','mime_type','application/pdf'));
    raise exception 'FAIL 2: staff published a document';
  exception when insufficient_privilege then null; end;
  if public.can_view_company_document_object(v_path1) then raise exception 'FAIL 2: staff can read a file that is not published'; end if;

  -- 3. The admin publishes; a file that was not uploaded is refused.
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  begin
    perform public.create_company_document(jsonb_build_object('document_id',v_doc,'category','POLICY','title','Validation policy','storage_path',v_doc::text||'/missing.pdf','original_file_name','p.pdf','mime_type','application/pdf'));
    raise exception 'FAIL 3: a missing file was accepted';
  exception when invalid_parameter_value then null; end;
  perform public.create_company_document(jsonb_build_object('document_id',v_doc,'category','POLICY','reference_code','VAL-01','title','  Validation   policy ','storage_path',v_path1,'original_file_name','policy.pdf','mime_type','application/pdf','file_size_bytes',1000));
  if (select title from public.company_documents where document_id=v_doc)<>'Validation policy' then raise exception 'FAIL 3: title not cleaned'; end if;

  -- 4. Staff sees it pending, opens it, cannot confirm an old version, then confirms.
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff,'role','authenticated')::text, true);
  v := public.get_my_company_documents();
  if (select x->>'status' from jsonb_array_elements(v->'documents') x where (x->>'document_id')::uuid=v_doc)<>'PENDING' then raise exception 'FAIL 4: not pending'; end if;
  if not public.can_view_company_document_object(v_path1) then raise exception 'FAIL 4: staff cannot read the published file'; end if;
  if (public.record_company_document_open(v_doc)->>'status')<>'OPENED' then raise exception 'FAIL 4: open not recorded'; end if;
  begin
    perform public.acknowledge_company_document(v_doc,2);
    raise exception 'FAIL 4: a wrong version was confirmed';
  exception when serialization_failure then null; end;
  if (public.acknowledge_company_document(v_doc,1)->>'status')<>'ACKNOWLEDGED' then raise exception 'FAIL 4: confirmation not recorded'; end if;
  if exists(select 1 from public.company_documents d where d.document_id=v_doc
            and not exists(select 1 from public.company_document_reads r where r.document_id=d.document_id and r.auth_user_id=v_staff and r.acknowledged_at is not null)) then raise exception 'FAIL 4: read row missing'; end if;

  -- 5. A small correction keeps confirmations; a new version requiring confirmation does not.
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  begin
    perform public.replace_company_document_file(v_doc,jsonb_build_object('storage_path',v_path2,'original_file_name','policy-v2.pdf','mime_type','application/pdf'),'',false,1);
    raise exception 'FAIL 5: a new version without a change note was accepted';
  exception when invalid_parameter_value then null; end;
  v := public.replace_company_document_file(v_doc,jsonb_build_object('storage_path',v_path2,'original_file_name','policy-v2.pdf','mime_type','application/pdf'),'Typo fixed',false,1);
  if v->>'old_storage_path'<>v_path1 then raise exception 'FAIL 5: old path not returned'; end if;
  begin
    perform public.replace_company_document_file(v_doc,jsonb_build_object('storage_path',v_path3,'original_file_name','policy-v3.pdf','mime_type','application/pdf'),'Stale',true,1);
    raise exception 'FAIL 5: a stale row_version was accepted';
  exception when serialization_failure then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff,'role','authenticated')::text, true);
  if (select x->>'status' from jsonb_array_elements(public.get_my_company_documents()->'documents') x where (x->>'document_id')::uuid=v_doc)<>'ACKNOWLEDGED' then raise exception 'FAIL 5: correction removed the confirmation'; end if;
  if public.can_view_company_document_object(v_path1) then raise exception 'FAIL 5: the replaced file is still readable'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  perform public.replace_company_document_file(v_doc,jsonb_build_object('storage_path',v_path3,'original_file_name','policy-v3.pdf','mime_type','application/pdf'),'New procedure',true,2);
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff,'role','authenticated')::text, true);
  if (select x->>'status' from jsonb_array_elements(public.get_my_company_documents()->'documents') x where (x->>'document_id')::uuid=v_doc)<>'RECONFIRM' then raise exception 'FAIL 5: new version did not ask to confirm again'; end if;
  if (public.get_my_company_document_summary()->>'pending_count')::int<1 then raise exception 'FAIL 5: summary count'; end if;

  -- 6. A supervisor (VIEW) sees the read status but cannot change documents.
  perform set_config('request.jwt.claims', json_build_object('sub',v_viewer,'role','authenticated')::text, true);
  v := public.get_company_documents_admin();
  select x->>'status' into v_status from jsonb_array_elements(v->'statuses') x where (x->>'document_id')::uuid=v_doc and (x->>'auth_user_id')::uuid=v_staff;
  if v_status<>'RECONFIRM' then raise exception 'FAIL 6: status for staff is %',v_status; end if;
  if jsonb_array_length(v->'orphan_paths')<>0 then raise exception 'FAIL 6: orphan paths shown without MANAGE'; end if;
  begin
    perform public.set_company_document_status(v_doc,'ARCHIVED',null,3);
    raise exception 'FAIL 6: a viewer archived a document';
  exception when insufficient_privilege then null; end;

  -- 7. A terminal cannot read company documents.
  perform set_config('request.jwt.claims', json_build_object('sub',v_terminal,'role','authenticated')::text, true);
  begin
    perform public.get_my_company_documents();
    raise exception 'FAIL 7: a terminal read the documents';
  exception when insufficient_privilege then null; end;
  if public.can_view_company_document_object(v_path3) then raise exception 'FAIL 7: a terminal can read the file'; end if;

  -- 8. Archive hides it from staff; delete returns the file to remove and keeps the log.
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  perform public.set_company_document_status(v_doc,'ARCHIVED','Validation',3);
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff,'role','authenticated')::text, true);
  if exists(select 1 from jsonb_array_elements(public.get_my_company_documents()->'documents') x where (x->>'document_id')::uuid=v_doc) then raise exception 'FAIL 8: archived document listed'; end if;
  if public.can_view_company_document_object(v_path3) then raise exception 'FAIL 8: archived file readable by staff'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  v := public.set_company_document_status(v_doc,'DELETED','Validation',4);
  if v->>'old_storage_path'<>v_path3 or (v->'document'->>'storage_path') is not null then raise exception 'FAIL 8: delete did not release the file'; end if;
  select count(*) into v_row from public.company_document_history where document_id=v_doc;
  if v_row<>5 then raise exception 'FAIL 8: % history rows instead of 5',v_row; end if;
  if not exists(select 1 from public.company_document_reads where document_id=v_doc and auth_user_id=v_staff and acknowledged_at is not null) then raise exception 'FAIL 8: confirmations lost on delete'; end if;
  if (select jsonb_agg(x->>'event_type' order by (x->>'history_id')::bigint) from jsonb_array_elements(public.get_company_document_history(v_doc)) x)
     <>'["PUBLISHED","NEW_VERSION","NEW_VERSION","ARCHIVED","DELETED"]'::jsonb then raise exception 'FAIL 8: history events'; end if;

  -- 9. Anonymous callers cannot execute the RPCs.
  if has_function_privilege('anon','public.get_my_company_documents()','execute') or has_function_privilege('anon','public.create_company_document(jsonb)','execute') then
    raise exception 'FAIL 9: anon can execute company document RPCs';
  end if;
  if has_function_privilege('authenticated','public.company_document_audience()','execute') then
    raise exception 'FAIL 9: clients can list the audience directly';
  end if;

  raise exception 'PASSED: all company document checks (nothing was kept)';
end $$;
