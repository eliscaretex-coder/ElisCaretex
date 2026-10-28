-- =====================================================================
-- ElisCaretex V2
-- Company Documents: revision number and date, and a new file always asks
-- everyone to read again
--
-- Owner request 2026-10-28:
-- * Every written document carries a revision number and a revision date in
--   its footer. The manager enters both when publishing a document or a new
--   version, so staff and managers can see at a glance whether the file is the
--   current one. A new version must carry a different revision number, and
--   its date cannot be earlier than the previous one or in the future.
--   Existing documents keep an empty revision until a manager fills it in
--   (Edit details, which logs the correction).
-- * When a published document gets a new file, everyone who must read it has
--   to read and confirm it again. The "small correction, keep confirmations"
--   choice of 202610280001 is removed: replace_company_document_file loses its
--   p_require_reconfirmation argument and always moves acknowledgement_version
--   to the new version.
-- =====================================================================

begin;

alter table public.company_documents
  add column revision_number text,
  add column revision_date date,
  add constraint company_documents_revision_number_check check (revision_number is null or length(trim(revision_number)) between 1 and 20);

alter table public.company_document_history
  add column revision_number text,
  add column revision_date date;

-- Checks the revision of a document or of a new version. With a previous
-- revision, the new one must differ and must not be dated earlier.
create or replace function public.company_document_check_revision(p_revision jsonb,p_previous_number text,p_previous_date date)
returns void language plpgsql stable set search_path=public,pg_temp as $$
declare
  v_number text:=public.company_document_clean_text(p_revision->>'revision_number',20);
  v_date date;
begin
  if v_number is null then raise exception using errcode='22023',message='Enter the revision number shown on the document.'; end if;
  begin
    v_date:=nullif(p_revision->>'revision_date','')::date;
  exception when others then
    raise exception using errcode='22023',message='Enter a valid revision date.';
  end;
  if v_date is null then raise exception using errcode='22023',message='Enter the revision date shown on the document.'; end if;
  if v_date>(now() at time zone 'Europe/Dublin')::date then raise exception using errcode='22023',message='The revision date cannot be in the future.'; end if;
  if p_previous_number is not null and lower(v_number)=lower(trim(p_previous_number)) then
    raise exception using errcode='22023',message=format('The current file is already revision %s. Enter the revision number of the new file.',p_previous_number);
  end if;
  if p_previous_date is not null and v_date<p_previous_date then
    raise exception using errcode='22023',message=format('The revision date cannot be earlier than the current revision (%s).',to_char(p_previous_date,'DD Mon YYYY'));
  end if;
end;$$;

create or replace function public.company_document_revision_label(p_number text,p_date date)
returns text language sql immutable set search_path=public,pg_temp as $$
  select case when p_number is null and p_date is null then 'no revision'
    else concat_ws(' of ','Rev '||coalesce(p_number,'?'),to_char(p_date,'DD Mon YYYY')) end
$$;

create or replace function public.get_my_company_documents()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare
  v_docs jsonb;
  v_areas text[]:=public.company_document_person_areas(auth.uid());
  v_all boolean;
begin
  if not public.can_read_company_documents() then raise exception using errcode='42501',message='Sign in with a staff account to read company documents.'; end if;
  v_all:=public.can_manage_company_documents() or public.can_view_company_document_status();
  select coalesce(jsonb_agg(x.doc order by x.category,x.title),'[]'::jsonb) into v_docs from (
    select d.category,d.title,jsonb_build_object(
      'document_id',d.document_id,'category',d.category,'reference_code',d.reference_code,'title',d.title,
      'description',d.description,'requires_acknowledgement',d.requires_acknowledgement,
      'current_version',d.current_version,'acknowledgement_version',d.acknowledgement_version,
      'version_published_at',d.version_published_at,
      'revision_number',d.revision_number,'revision_date',d.revision_date,'storage_bucket',d.storage_bucket,'storage_path',d.storage_path,
      'original_file_name',d.original_file_name,'mime_type',d.mime_type,'file_size_bytes',d.file_size_bytes,
      'areas',to_jsonb(public.company_document_area_codes(d.document_id)),'for_me',v.for_me,
      'last_change_note',(select h.change_note from public.company_document_history h where h.document_id=d.document_id and h.event_type in ('PUBLISHED','NEW_VERSION') order by h.recorded_at desc limit 1)
    ) || public.company_document_person_status(d,auth.uid())
      || case when v.for_me then '{}'::jsonb else jsonb_build_object('status','OTHER_AREA') end as doc
    from public.company_documents d
    cross join lateral (select public.company_document_for_areas(d.document_id,v_areas) as for_me) v
    where d.document_status='ACTIVE' and (v.for_me or v_all)
  ) x;
  return jsonb_build_object(
    'can_manage',public.can_manage_company_documents(),
    'can_view_status',public.can_view_company_document_status(),
    'my_areas',to_jsonb(v_areas),
    'documents',v_docs,
    'pending_count',(select count(*) from jsonb_array_elements(v_docs) x where x->>'status' in ('PENDING','OPENED','RECONFIRM'))
  );
end;$$;

create or replace function public.create_company_document(p_document jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.company_documents%rowtype; v_areas text[];
begin
  if not public.can_manage_company_documents() then raise exception using errcode='42501',message='Company Documents management access is required.'; end if;
  if upper(coalesce(p_document->>'category','')) not in ('POLICY','SSOW') then raise exception using errcode='22023',message='Choose Company policy or SSOW.'; end if;
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
        case when v_row.category is distinct from v_old.category then format('Section changed to %s',case v_row.category when 'SSOW' then 'SSOW' else 'Company policy' end) end,
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

-- A new file always asks everyone to read and confirm again.
drop function public.replace_company_document_file(uuid,jsonb,text,boolean,integer);

create function public.replace_company_document_file(p_document_id uuid,p_file jsonb,p_change_note text,p_row_version integer)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.company_documents%rowtype; v_row public.company_documents%rowtype;
begin
  if not public.can_manage_company_documents() then raise exception using errcode='42501',message='Company Documents management access is required.'; end if;
  select * into v_old from public.company_documents where document_id=p_document_id and document_status<>'DELETED' for update;
  if not found then raise exception using errcode='P0002',message='Document not found.'; end if;
  if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='Someone else changed this document. Reload and try again.'; end if;
  perform public.company_document_check_revision(p_file,v_old.revision_number,v_old.revision_date);
  if nullif(p_file->>'storage_path','') is null or p_file->>'storage_path'=v_old.storage_path then raise exception using errcode='22023',message='Upload the new file before saving the new version.'; end if;
  if not public.company_document_file_exists(p_document_id,p_file->>'storage_path') then raise exception using errcode='22023',message='The new file was not found in storage. Upload it again.'; end if;
  if public.company_document_clean_text(p_change_note,500) is null then raise exception using errcode='22023',message='Describe what changed in this version.'; end if;
  update public.company_documents set
    storage_path=p_file->>'storage_path',original_file_name=p_file->>'original_file_name',mime_type=p_file->>'mime_type',
    file_size_bytes=nullif(p_file->>'file_size_bytes','')::bigint,
    revision_number=public.company_document_clean_text(p_file->>'revision_number',20),
    revision_date=(p_file->>'revision_date')::date,
    current_version=current_version+1,
    acknowledgement_version=current_version+1,
    version_published_at=now(),version_published_by=auth.uid(),
    updated_at=now(),updated_by=auth.uid(),row_version=row_version+1
  where document_id=p_document_id returning * into v_row;
  insert into public.company_document_history(document_id,event_type,version_number,title,original_file_name,file_size_bytes,revision_number,revision_date,change_note,reconfirmation_required,recorded_by)
  values(v_row.document_id,'NEW_VERSION',v_row.current_version,v_row.title,v_row.original_file_name,v_row.file_size_bytes,v_row.revision_number,v_row.revision_date,
    public.company_document_clean_text(p_change_note,500),v_row.requires_acknowledgement,auth.uid());
  return jsonb_build_object('document',to_jsonb(v_row),'old_storage_path',v_old.storage_path);
end;$$;

-- Grants ----------------------------------------------------------------

revoke all on function
  public.company_document_check_revision(jsonb,text,date),public.company_document_revision_label(text,date),
  public.get_my_company_documents(),public.create_company_document(jsonb),public.update_company_document_details(uuid,jsonb,integer),
  public.replace_company_document_file(uuid,jsonb,text,integer)
from public,anon,authenticated;

grant execute on function
  public.get_my_company_documents(),public.create_company_document(jsonb),public.update_company_document_details(uuid,jsonb,integer),
  public.replace_company_document_file(uuid,jsonb,text,integer)
to authenticated;

commit;
