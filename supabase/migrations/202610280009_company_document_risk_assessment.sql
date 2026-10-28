-- =====================================================================
-- ElisCaretex V2
-- Company Documents: Risk assessment section
--
-- Owner request 2026-10-28: a third section for Risk assessment documents,
-- next to Company policies and SSOW. Same rules as the other sections
-- (areas, revision, confirmation, one stored file per document).
-- =====================================================================

begin;

alter table public.company_documents drop constraint company_documents_category_check;
alter table public.company_documents add constraint company_documents_category_check
  check (category in ('POLICY','SSOW','RISK_ASSESSMENT'));

create or replace function public.create_company_document(p_document jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.company_documents%rowtype; v_areas text[];
begin
  if not public.can_manage_company_documents() then raise exception using errcode='42501',message='Company Documents management access is required.'; end if;
  if upper(coalesce(p_document->>'category','')) not in ('POLICY','SSOW','RISK_ASSESSMENT') then raise exception using errcode='22023',message='Choose Company policy, SSOW or Risk assessment.'; end if;
  if public.company_document_clean_text(p_document->>'title',160) is null then raise exception using errcode='22023',message='Enter the document title.'; end if;
  perform public.company_document_check_revision(p_document,null,null);
  if not public.company_document_file_exists(nullif(p_document->>'document_id','')::uuid,p_document->>'storage_path') then raise exception using errcode='22023',message='Upload the file before saving the document.'; end if;
  insert into public.company_documents(document_id,category,reference_code,title,description,requires_acknowledgement,revision_number,revision_date,storage_path,original_file_name,mime_type,file_size_bytes,version_published_by,created_by,updated_by)
  values((p_document->>'document_id')::uuid,upper(p_document->>'category'),public.company_document_clean_text(p_document->>'reference_code',40),
    public.company_document_clean_text(p_document->>'title',160),nullif(trim(p_document->>'description'),''),
    coalesce((p_document->>'requires_acknowledgement')::boolean,true),
    public.company_document_clean_text(p_document->>'revision_number',20),(p_document->>'revision_date')::date,p_document->>'storage_path',p_document->>'original_file_name',
    p_document->>'mime_type',nullif(p_document->>'file_size_bytes','')::bigint,auth.uid(),auth.uid(),auth.uid())
  returning * into v_row;
  v_areas:=public.company_document_set_areas(v_row.document_id,coalesce(p_document->'areas','[]'::jsonb));
  insert into public.company_document_history(document_id,event_type,version_number,title,original_file_name,file_size_bytes,revision_number,revision_date,change_note,recorded_by)
  values(v_row.document_id,'PUBLISHED',1,v_row.title,v_row.original_file_name,v_row.file_size_bytes,v_row.revision_number,v_row.revision_date,
    concat_ws('; ',public.company_document_clean_text(p_document->>'change_note',400),'Areas: '||public.company_document_area_label(v_areas)),auth.uid());
  return to_jsonb(v_row) || jsonb_build_object('areas',to_jsonb(v_areas));
end;$$;

create or replace function public.update_company_document_details(p_document_id uuid,p_details jsonb,p_row_version integer)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.company_documents%rowtype; v_row public.company_documents%rowtype; v_old_areas text[]; v_areas text[];
begin
  if not public.can_manage_company_documents() then raise exception using errcode='42501',message='Company Documents management access is required.'; end if;
  select * into v_old from public.company_documents where document_id=p_document_id and document_status<>'DELETED' for update;
  if not found then raise exception using errcode='P0002',message='Document not found.'; end if;
  if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='Someone else changed this document. Reload and try again.'; end if;
  if p_details ? 'revision_number' or p_details ? 'revision_date' then
    perform public.company_document_check_revision(jsonb_build_object(
      'revision_number',case when p_details ? 'revision_number' then p_details->>'revision_number' else v_old.revision_number end,
      'revision_date',case when p_details ? 'revision_date' then p_details->>'revision_date' else v_old.revision_date::text end),null,null);
  end if;
  if upper(coalesce(nullif(p_details->>'category',''),v_old.category)) not in ('POLICY','SSOW','RISK_ASSESSMENT') then
    raise exception using errcode='22023',message='Choose Company policy, SSOW or Risk assessment.';
  end if;
  v_old_areas:=public.company_document_area_codes(p_document_id);
  v_areas:=case when p_details ? 'areas' then public.company_document_set_areas(p_document_id,p_details->'areas') else v_old_areas end;
  update public.company_documents set
    category=coalesce(upper(nullif(p_details->>'category','')),category),
    reference_code=case when p_details ? 'reference_code' then public.company_document_clean_text(p_details->>'reference_code',40) else reference_code end,
    title=coalesce(public.company_document_clean_text(p_details->>'title',160),title),
    description=case when p_details ? 'description' then nullif(trim(p_details->>'description'),'') else description end,
    requires_acknowledgement=coalesce((p_details->>'requires_acknowledgement')::boolean,requires_acknowledgement),
    revision_number=case when p_details ? 'revision_number' then public.company_document_clean_text(p_details->>'revision_number',20) else revision_number end,
    revision_date=case when p_details ? 'revision_date' then (p_details->>'revision_date')::date else revision_date end,
    updated_at=now(),updated_by=auth.uid(),row_version=row_version+1
  where document_id=p_document_id returning * into v_row;
  if (v_row.category,v_row.reference_code,v_row.title,v_row.description,v_row.requires_acknowledgement,v_areas,v_row.revision_number,v_row.revision_date)
     is distinct from (v_old.category,v_old.reference_code,v_old.title,v_old.description,v_old.requires_acknowledgement,v_old_areas,v_old.revision_number,v_old.revision_date) then
    insert into public.company_document_history(document_id,event_type,version_number,title,original_file_name,file_size_bytes,revision_number,revision_date,change_note,recorded_by)
    values(v_row.document_id,'DETAILS_UPDATED',v_row.current_version,v_row.title,v_row.original_file_name,v_row.file_size_bytes,v_row.revision_number,v_row.revision_date,
      left(concat_ws('; ',
        case when v_row.title is distinct from v_old.title then format('Title was "%s"',v_old.title) end,
        case when v_row.category is distinct from v_old.category then format('Section changed to %s',case v_row.category when 'SSOW' then 'SSOW' when 'RISK_ASSESSMENT' then 'Risk assessment' else 'Company policy' end) end,
        case when v_row.reference_code is distinct from v_old.reference_code then format('Reference %s',coalesce(v_row.reference_code,'removed')) end,
        case when v_row.description is distinct from v_old.description then 'Description updated' end,
        case when v_row.requires_acknowledgement is distinct from v_old.requires_acknowledgement then case when v_row.requires_acknowledgement then 'Confirmation now required' else 'Confirmation no longer required' end end,
        case when (v_row.revision_number,v_row.revision_date) is distinct from (v_old.revision_number,v_old.revision_date)
          then format('Revision corrected to %s (was %s)',public.company_document_revision_label(v_row.revision_number,v_row.revision_date),public.company_document_revision_label(v_old.revision_number,v_old.revision_date)) end,
        case when v_areas is distinct from v_old_areas then format('Areas: %s (was %s)',public.company_document_area_label(v_areas),public.company_document_area_label(v_old_areas)) end),500),
      auth.uid());
  end if;
  return to_jsonb(v_row) || jsonb_build_object('areas',to_jsonb(v_areas));
end;$$;

revoke all on function public.create_company_document(jsonb),public.update_company_document_details(uuid,jsonb,integer) from public,anon;
grant execute on function public.create_company_document(jsonb),public.update_company_document_details(uuid,jsonb,integer) to authenticated;

commit;
