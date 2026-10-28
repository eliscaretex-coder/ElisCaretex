-- =====================================================================
-- ElisCaretex V2
-- Company Documents by area
--
-- Owner request 2026-10-28: SSOW documents are written per area (Sorting,
-- Finish, MOP, Distribution, Cleaner, Label, Maintenance) and some apply to
-- several areas. A manager chooses which areas a document is for; staff see
-- and confirm only the documents of their areas. A document with no area is
-- for everyone (the behaviour of 202610280001).
--
-- A person's areas come from what the platform already knows:
-- * Staff Master default area: SORTING and WASHING -> SORTING, FINISH, MOP,
--   DISTRIBUTION;
-- * Staff Master primary operational role: CLEANER, LABEL, MAINTENANCE,
--   SORTING_AREA -> SORTING, DRIVER -> DISTRIBUTION;
-- * account job title: CLEANER, LABEL_OPERATIVE, MAINTENANCE, DRIVER and
--   LOGISTICS_MANAGER -> DISTRIBUTION;
-- * an active Distribution driver record -> DISTRIBUTION.
--
-- Managers and status viewers (COMPANY_DOCUMENTS MANAGE or VIEW) still see
-- every document; one outside their areas is shown as "Other area" and is
-- not counted as pending for them.
-- =====================================================================

begin;

create table public.company_document_areas (
  document_id uuid not null references public.company_documents(document_id) on delete restrict,
  area_code text not null check (area_code in ('SORTING','FINISH','MOP','DISTRIBUTION','CLEANER','LABEL','MAINTENANCE')),
  created_at timestamptz not null default now(),
  primary key (document_id,area_code)
);

alter table public.company_document_areas enable row level security;
revoke all on public.company_document_areas from public,anon,authenticated;

-- Areas of one account, derived from Staff Master, the account job title and
-- the Distribution driver record.
create or replace function public.company_document_person_areas(p_auth_user_id uuid)
returns text[] language sql stable security definer set search_path=public,auth,pg_temp as $$
  select coalesce(array_agg(distinct x order by x) filter (where x is not null),array[]::text[]) from (
    select case a.area_code when 'SORTING' then 'SORTING' when 'WASHING' then 'SORTING' when 'FINISH' then 'FINISH'
                            when 'MOP' then 'MOP' when 'DISTRIBUTION' then 'DISTRIBUTION' end as x
    from public.staff_members sm join public.areas a on a.area_id=sm.default_area_id
    where sm.auth_user_id=p_auth_user_id and sm.deleted_at is null
    union all
    select case o.role_code when 'CLEANER' then 'CLEANER' when 'LABEL' then 'LABEL' when 'MAINTENANCE' then 'MAINTENANCE'
                            when 'SORTING_AREA' then 'SORTING' when 'DRIVER' then 'DISTRIBUTION' end
    from public.staff_members sm join public.operational_roles o on o.operational_role_id=sm.primary_operational_role_id
    where sm.auth_user_id=p_auth_user_id and sm.deleted_at is null
    union all
    select case ap.job_title_code when 'CLEANER' then 'CLEANER' when 'LABEL_OPERATIVE' then 'LABEL' when 'MAINTENANCE' then 'MAINTENANCE'
                                  when 'DRIVER' then 'DISTRIBUTION' when 'LOGISTICS_MANAGER' then 'DISTRIBUTION' end
    from public.account_access_profiles ap where ap.auth_user_id=p_auth_user_id
    union all
    select 'DISTRIBUTION' from public.distribution_drivers d join public.staff_members sm on sm.staff_id=d.staff_id
    where sm.auth_user_id=p_auth_user_id and sm.deleted_at is null and d.deleted_at is null and d.employment_status='ACTIVE'
  ) t
$$;

create or replace function public.company_document_area_codes(p_document_id uuid)
returns text[] language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce(array_agg(area_code order by area_code),array[]::text[]) from public.company_document_areas where document_id=p_document_id
$$;

-- A document with no area is for everyone; otherwise the person needs one of its areas.
create or replace function public.company_document_for_areas(p_document_id uuid,p_person_areas text[])
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select not exists(select 1 from public.company_document_areas where document_id=p_document_id)
      or exists(select 1 from public.company_document_areas where document_id=p_document_id and area_code=any(coalesce(p_person_areas,array[]::text[])))
$$;

-- Validates and stores the areas sent by the page (a JSON array of codes).
create or replace function public.company_document_set_areas(p_document_id uuid,p_areas jsonb)
returns text[] language plpgsql security definer set search_path=public,pg_temp as $$
declare v_areas text[];
begin
  if p_areas is null or jsonb_typeof(p_areas)<>'array' then
    raise exception using errcode='22023',message='Areas must be a list.';
  end if;
  select coalesce(array_agg(distinct upper(trim(value)) order by upper(trim(value))),array[]::text[]) into v_areas
  from jsonb_array_elements_text(p_areas) where trim(value)<>'';
  if exists(select 1 from unnest(v_areas) a where a not in ('SORTING','FINISH','MOP','DISTRIBUTION','CLEANER','LABEL','MAINTENANCE')) then
    raise exception using errcode='22023',message='Unknown area.';
  end if;
  delete from public.company_document_areas where document_id=p_document_id and not (area_code=any(v_areas));
  insert into public.company_document_areas(document_id,area_code) select p_document_id,a from unnest(v_areas) a on conflict do nothing;
  return v_areas;
end;$$;

create or replace function public.company_document_area_label(p_areas text[])
returns text language sql immutable set search_path=pg_temp as $$
  select case when coalesce(cardinality(p_areas),0)=0 then 'All areas' else array_to_string(array(
    select case a when 'SORTING' then 'Sorting' when 'FINISH' then 'Finish' when 'MOP' then 'MOP' when 'DISTRIBUTION' then 'Distribution'
                  when 'CLEANER' then 'Cleaner' when 'LABEL' then 'Label' when 'MAINTENANCE' then 'Maintenance' else a end
    from unnest(p_areas) a),', ') end
$$;

-- The audience gains each person's areas (new result column, so drop first).
drop function public.company_document_audience();
create function public.company_document_audience()
returns table(auth_user_id uuid,display_name text,employee_code text,job_title_name text,areas text[])
language sql stable security definer set search_path=public,auth,pg_temp as $$
  select u.id,
         coalesce(ap.display_name,sm.display_name,u.email,'Account'),
         sm.employee_code,
         coalesce(jt.job_title_name,case when ap.auth_user_id is null then 'Staff' else null end),
         public.company_document_person_areas(u.id)
  from auth.users u
  left join public.account_access_profiles ap on ap.auth_user_id=u.id
  left join public.account_job_titles jt on jt.job_title_code=ap.job_title_code
  left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null
  where u.deleted_at is null
    and (u.banned_until is null or u.banned_until<now())
    and (ap.account_type='USER' or (ap.auth_user_id is null and sm.staff_id is not null))
    and not exists(select 1 from public.production_station_devices d where d.device_auth_user_id=u.id)
    and (sm.staff_id is null or (sm.active and (sm.deactivated_on is null or sm.deactivated_on>=current_date)))
$$;

create or replace function public.can_view_company_document_object(p_object_name text)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.can_manage_company_documents()
    or public.can_view_company_document_status()
    or (public.can_read_company_documents() and exists(
      select 1 from public.company_documents d
      where d.storage_path=p_object_name and d.document_status='ACTIVE'
        and public.company_document_for_areas(d.document_id,public.company_document_person_areas(auth.uid()))))
$$;

-- Staff RPCs -------------------------------------------------------------

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
      'version_published_at',d.version_published_at,'storage_bucket',d.storage_bucket,'storage_path',d.storage_path,
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

create or replace function public.get_my_company_document_summary()
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object('pending_count',case when not public.can_read_company_documents() then 0 else (
    select count(*) from public.company_documents d
    where d.document_status='ACTIVE' and d.requires_acknowledgement
      and public.company_document_for_areas(d.document_id,public.company_document_person_areas(auth.uid()))
      and not exists(select 1 from public.company_document_reads r where r.document_id=d.document_id and r.auth_user_id=auth.uid()
                     and r.acknowledged_at is not null and r.version_number>=d.acknowledgement_version)) end)
$$;

create or replace function public.record_company_document_open(p_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_doc public.company_documents%rowtype;
begin
  if not public.can_read_company_documents() then raise exception using errcode='42501',message='Sign in with a staff account to read company documents.'; end if;
  select * into v_doc from public.company_documents where document_id=p_document_id and document_status='ACTIVE';
  if not found then raise exception using errcode='P0002',message='This document is no longer available.'; end if;
  if not public.company_document_for_areas(v_doc.document_id,public.company_document_person_areas(auth.uid())) then
    if public.can_manage_company_documents() or public.can_view_company_document_status() then
      return jsonb_build_object('status','OTHER_AREA');
    end if;
    raise exception using errcode='42501',message='This document is not for your area.';
  end if;
  insert into public.company_document_reads(document_id,version_number,auth_user_id,first_opened_at,last_opened_at,open_count)
  values(v_doc.document_id,v_doc.current_version,auth.uid(),now(),now(),1)
  on conflict(document_id,version_number,auth_user_id) do update set
    first_opened_at=coalesce(public.company_document_reads.first_opened_at,excluded.first_opened_at),
    last_opened_at=now(),open_count=public.company_document_reads.open_count+1;
  return public.company_document_person_status(v_doc,auth.uid());
end;$$;

create or replace function public.acknowledge_company_document(p_document_id uuid,p_version integer)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_doc public.company_documents%rowtype;
begin
  if not public.can_read_company_documents() then raise exception using errcode='42501',message='Sign in with a staff account to read company documents.'; end if;
  select * into v_doc from public.company_documents where document_id=p_document_id and document_status='ACTIVE';
  if not found then raise exception using errcode='P0002',message='This document is no longer available.'; end if;
  if not public.company_document_for_areas(v_doc.document_id,public.company_document_person_areas(auth.uid())) then
    raise exception using errcode='42501',message='This document is not for your area.';
  end if;
  if not v_doc.requires_acknowledgement then raise exception using errcode='22023',message='This document does not need confirmation.'; end if;
  if p_version is distinct from v_doc.current_version then
    raise exception using errcode='40001',message='A new version of this document was published. Open it again before confirming.';
  end if;
  insert into public.company_document_reads(document_id,version_number,auth_user_id,first_opened_at,last_opened_at,open_count,acknowledged_at)
  values(v_doc.document_id,v_doc.current_version,auth.uid(),now(),now(),1,now())
  on conflict(document_id,version_number,auth_user_id) do update set
    acknowledged_at=coalesce(public.company_document_reads.acknowledged_at,now());
  return public.company_document_person_status(v_doc,auth.uid());
end;$$;

-- Manager RPCs -----------------------------------------------------------

create or replace function public.get_company_documents_admin()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_manage boolean:=public.can_manage_company_documents();
begin
  if not (v_manage or public.can_view_company_document_status()) then raise exception using errcode='42501',message='Company Documents access is required.'; end if;
  return (with people as materialized (select * from public.company_document_audience())
  select jsonb_build_object(
    'can_manage',v_manage,
    'people',coalesce((select jsonb_agg(to_jsonb(a) order by a.display_name) from people a),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object(
        'areas',to_jsonb(public.company_document_area_codes(d.document_id)),
        'updated_by_name',(select coalesce(ap.display_name,u.email) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=d.version_published_by)
      ) order by d.category,d.title) from public.company_documents d where d.document_status<>'DELETED'),'[]'::jsonb),
    -- One row per person who must read each active document (only the people
    -- of the document's areas).
    'statuses',coalesce((select jsonb_agg(jsonb_build_object('document_id',d.document_id,'auth_user_id',a.auth_user_id) || public.company_document_person_status(d,a.auth_user_id))
        from public.company_documents d cross join people a
        where d.document_status='ACTIVE' and public.company_document_for_areas(d.document_id,a.areas)),'[]'::jsonb),
    'orphan_paths',case when v_manage then coalesce((select jsonb_agg(o.name) from storage.objects o
        where o.bucket_id='company-documents' and o.created_at<now()-interval '1 hour'
          and not exists(select 1 from public.company_documents d where d.storage_path=o.name)),'[]'::jsonb) else '[]'::jsonb end
  ));
end;$$;

create or replace function public.create_company_document(p_document jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.company_documents%rowtype; v_areas text[];
begin
  if not public.can_manage_company_documents() then raise exception using errcode='42501',message='Company Documents management access is required.'; end if;
  if upper(coalesce(p_document->>'category','')) not in ('POLICY','SSOW') then raise exception using errcode='22023',message='Choose Company policy or SSOW.'; end if;
  if public.company_document_clean_text(p_document->>'title',160) is null then raise exception using errcode='22023',message='Enter the document title.'; end if;
  if not public.company_document_file_exists(nullif(p_document->>'document_id','')::uuid,p_document->>'storage_path') then raise exception using errcode='22023',message='Upload the file before saving the document.'; end if;
  insert into public.company_documents(document_id,category,reference_code,title,description,requires_acknowledgement,storage_path,original_file_name,mime_type,file_size_bytes,version_published_by,created_by,updated_by)
  values((p_document->>'document_id')::uuid,upper(p_document->>'category'),public.company_document_clean_text(p_document->>'reference_code',40),
    public.company_document_clean_text(p_document->>'title',160),nullif(trim(p_document->>'description'),''),
    coalesce((p_document->>'requires_acknowledgement')::boolean,true),p_document->>'storage_path',p_document->>'original_file_name',
    p_document->>'mime_type',nullif(p_document->>'file_size_bytes','')::bigint,auth.uid(),auth.uid(),auth.uid())
  returning * into v_row;
  v_areas:=public.company_document_set_areas(v_row.document_id,coalesce(p_document->'areas','[]'::jsonb));
  insert into public.company_document_history(document_id,event_type,version_number,title,original_file_name,file_size_bytes,change_note,recorded_by)
  values(v_row.document_id,'PUBLISHED',1,v_row.title,v_row.original_file_name,v_row.file_size_bytes,
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
  v_old_areas:=public.company_document_area_codes(p_document_id);
  v_areas:=case when p_details ? 'areas' then public.company_document_set_areas(p_document_id,p_details->'areas') else v_old_areas end;
  update public.company_documents set
    category=coalesce(upper(nullif(p_details->>'category','')),category),
    reference_code=case when p_details ? 'reference_code' then public.company_document_clean_text(p_details->>'reference_code',40) else reference_code end,
    title=coalesce(public.company_document_clean_text(p_details->>'title',160),title),
    description=case when p_details ? 'description' then nullif(trim(p_details->>'description'),'') else description end,
    requires_acknowledgement=coalesce((p_details->>'requires_acknowledgement')::boolean,requires_acknowledgement),
    updated_at=now(),updated_by=auth.uid(),row_version=row_version+1
  where document_id=p_document_id returning * into v_row;
  if (v_row.category,v_row.reference_code,v_row.title,v_row.description,v_row.requires_acknowledgement,v_areas)
     is distinct from (v_old.category,v_old.reference_code,v_old.title,v_old.description,v_old.requires_acknowledgement,v_old_areas) then
    insert into public.company_document_history(document_id,event_type,version_number,title,original_file_name,file_size_bytes,change_note,recorded_by)
    values(v_row.document_id,'DETAILS_UPDATED',v_row.current_version,v_row.title,v_row.original_file_name,v_row.file_size_bytes,
      left(concat_ws('; ',
        case when v_row.title is distinct from v_old.title then format('Title was "%s"',v_old.title) end,
        case when v_row.category is distinct from v_old.category then format('Section changed to %s',case v_row.category when 'SSOW' then 'SSOW' else 'Company policy' end) end,
        case when v_row.reference_code is distinct from v_old.reference_code then format('Reference %s',coalesce(v_row.reference_code,'removed')) end,
        case when v_row.description is distinct from v_old.description then 'Description updated' end,
        case when v_row.requires_acknowledgement is distinct from v_old.requires_acknowledgement then case when v_row.requires_acknowledgement then 'Confirmation now required' else 'Confirmation no longer required' end end,
        case when v_areas is distinct from v_old_areas then format('Areas: %s (was %s)',public.company_document_area_label(v_areas),public.company_document_area_label(v_old_areas)) end),500),
      auth.uid());
  end if;
  return to_jsonb(v_row) || jsonb_build_object('areas',to_jsonb(v_areas));
end;$$;

-- Grants ----------------------------------------------------------------

revoke all on function
  public.company_document_person_areas(uuid),public.company_document_area_codes(uuid),
  public.company_document_for_areas(uuid,text[]),public.company_document_set_areas(uuid,jsonb),
  public.company_document_area_label(text[]),public.company_document_audience(),
  public.can_view_company_document_object(text),public.get_my_company_documents(),public.get_my_company_document_summary(),
  public.record_company_document_open(uuid),public.acknowledge_company_document(uuid,integer),
  public.get_company_documents_admin(),public.create_company_document(jsonb),public.update_company_document_details(uuid,jsonb,integer)
from public,anon,authenticated;

grant execute on function
  public.can_view_company_document_object(text),public.get_my_company_documents(),public.get_my_company_document_summary(),
  public.record_company_document_open(uuid),public.acknowledge_company_document(uuid,integer),
  public.get_company_documents_admin(),public.create_company_document(jsonb),public.update_company_document_details(uuid,jsonb,integer)
to authenticated;

commit;
