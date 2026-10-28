-- ElisCaretex V2 - Validation - 202610280005_company_document_areas
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all company document area checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_admin uuid; v_staff uuid; v_staff_areas text[]; v_other text;
  v_doc_mine uuid := gen_random_uuid(); v_doc_other uuid := gen_random_uuid(); v_doc_all uuid := gen_random_uuid();
  v jsonb; v_status text;
begin
  -- Fixtures: an Administrator and a personal account without a Company
  -- Documents grant. The staff account gets FINISH through a temporary
  -- Staff Master default area if it has no area yet.
  select auth_user_id into v_admin from public.account_access_profiles where account_type='USER' and job_title_code='ADMINISTRATOR' limit 1;
  select a.auth_user_id into v_staff from public.company_document_audience() a
    where not exists(select 1 from public.account_permission_grants g where g.auth_user_id=a.auth_user_id and g.module_code='COMPANY_DOCUMENTS')
      and not exists(select 1 from public.account_roles ar join public.roles r on r.role_id=ar.role_id where ar.auth_user_id=a.auth_user_id and ar.active and r.role_code in ('ADMIN','MANAGER','AUDITOR'))
    limit 1;
  if v_admin is null or v_staff is null then raise exception 'FAIL: fixtures (admin %, staff %)',v_admin,v_staff; end if;
  if cardinality(public.company_document_person_areas(v_staff))=0 then
    if not exists(select 1 from public.staff_members where auth_user_id=v_staff and deleted_at is null) then
      insert into public.staff_members(auth_user_id,employee_code,display_name,active) values (v_staff,'VAL-0005','Validation 0005',true);
    end if;
    update public.staff_members set default_area_id=(select area_id from public.areas where area_code='FINISH')
    where auth_user_id=v_staff and deleted_at is null;
  end if;
  v_staff_areas := public.company_document_person_areas(v_staff);
  if cardinality(v_staff_areas)=0 then raise exception 'FAIL 1: staff has no area'; end if;
  select a into v_other from unnest(array['SORTING','FINISH','MOP','DISTRIBUTION','CLEANER','LABEL','MAINTENANCE']) a where not (a=any(v_staff_areas)) limit 1;

  insert into storage.objects(bucket_id,name,owner) values
    ('company-documents',v_doc_mine::text||'/a.pdf',v_admin),('company-documents',v_doc_other::text||'/b.pdf',v_admin),('company-documents',v_doc_all::text||'/c.pdf',v_admin);

  -- 2. Unknown areas are refused; a document can have several areas.
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  begin
    perform public.create_company_document(jsonb_build_object('document_id',v_doc_mine,'category','SSOW','title','Area SSOW','storage_path',v_doc_mine::text||'/a.pdf','original_file_name','a.pdf','mime_type','application/pdf','areas',jsonb_build_array('KITCHEN')));
    raise exception 'FAIL 2: unknown area accepted';
  exception when invalid_parameter_value then null; end;
  perform public.create_company_document(jsonb_build_object('document_id',v_doc_mine,'category','SSOW','title','Validation SSOW mine','storage_path',v_doc_mine::text||'/a.pdf','original_file_name','a.pdf','mime_type','application/pdf','areas',to_jsonb(array[v_staff_areas[1],v_other])));
  perform public.create_company_document(jsonb_build_object('document_id',v_doc_other,'category','SSOW','title','Validation SSOW other','storage_path',v_doc_other::text||'/b.pdf','original_file_name','b.pdf','mime_type','application/pdf','areas',jsonb_build_array(v_other)));
  perform public.create_company_document(jsonb_build_object('document_id',v_doc_all,'category','POLICY','title','Validation policy all','storage_path',v_doc_all::text||'/c.pdf','original_file_name','c.pdf','mime_type','application/pdf'));
  if (select count(*) from public.company_document_areas where document_id=v_doc_mine)<>2 then raise exception 'FAIL 2: two areas not stored'; end if;

  -- 3. Staff sees its area and the all-areas document, not the other area.
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff,'role','authenticated')::text, true);
  v := public.get_my_company_documents();
  if not exists(select 1 from jsonb_array_elements(v->'documents') x where (x->>'document_id')::uuid=v_doc_mine and x->>'status'='PENDING') then raise exception 'FAIL 3: own-area document missing'; end if;
  if not exists(select 1 from jsonb_array_elements(v->'documents') x where (x->>'document_id')::uuid=v_doc_all) then raise exception 'FAIL 3: all-areas document missing'; end if;
  if exists(select 1 from jsonb_array_elements(v->'documents') x where (x->>'document_id')::uuid=v_doc_other) then raise exception 'FAIL 3: other-area document listed'; end if;
  if not public.can_view_company_document_object(v_doc_mine::text||'/a.pdf') then raise exception 'FAIL 3: own-area file not readable'; end if;
  if public.can_view_company_document_object(v_doc_other::text||'/b.pdf') then raise exception 'FAIL 3: other-area file readable'; end if;
  begin
    perform public.acknowledge_company_document(v_doc_other,1);
    raise exception 'FAIL 3: other-area document confirmed';
  exception when insufficient_privilege then null; end;
  perform public.acknowledge_company_document(v_doc_mine,1);

  -- 4. The admin sees every document; the other-area one is not pending for an admin without that area.
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  v := public.get_company_documents_admin();
  if exists(select 1 from jsonb_array_elements(v->'statuses') x where (x->>'document_id')::uuid=v_doc_other and (x->>'auth_user_id')::uuid=v_staff) then
    raise exception 'FAIL 4: staff counted for an other-area document';
  end if;
  select x->>'status' into v_status from jsonb_array_elements(v->'statuses') x where (x->>'document_id')::uuid=v_doc_mine and (x->>'auth_user_id')::uuid=v_staff;
  if v_status is distinct from 'ACKNOWLEDGED' then raise exception 'FAIL 4: own-area status is %',v_status; end if;
  if not exists(select 1 from jsonb_array_elements(v->'statuses') x where (x->>'document_id')::uuid=v_doc_all and (x->>'auth_user_id')::uuid=v_staff) then
    raise exception 'FAIL 4: all-areas document not counted for staff';
  end if;
  if not exists(select 1 from jsonb_array_elements(public.get_my_company_documents()->'documents') x where (x->>'document_id')::uuid=v_doc_other) then
    raise exception 'FAIL 4: admin does not see the other-area document';
  end if;

  -- 5. Changing areas is logged; clearing them makes the document for everyone.
  perform public.update_company_document_details(v_doc_other,jsonb_build_object('areas','[]'::jsonb),1);
  if not exists(select 1 from public.company_document_history where document_id=v_doc_other and event_type='DETAILS_UPDATED' and change_note like 'Areas: All areas%') then
    raise exception 'FAIL 5: area change not logged';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff,'role','authenticated')::text, true);
  if not exists(select 1 from jsonb_array_elements(public.get_my_company_documents()->'documents') x where (x->>'document_id')::uuid=v_doc_other) then
    raise exception 'FAIL 5: all-areas document still hidden';
  end if;

  -- 6. Helpers stay closed to clients.
  if has_function_privilege('authenticated','public.company_document_person_areas(uuid)','execute')
     or has_function_privilege('authenticated','public.company_document_set_areas(uuid,jsonb)','execute')
     or has_function_privilege('authenticated','public.company_document_audience()','execute') then
    raise exception 'FAIL 6: an internal helper is open to clients';
  end if;

  raise exception 'PASSED: all company document area checks (nothing was kept)';
end $$;
