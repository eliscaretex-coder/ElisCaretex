-- =====================================================================
-- ElisCaretex V2
-- Company Documents: company policies and SSOW (safe systems of work)
--
-- Owner request 2026-10-28:
-- * every staff member with a login sees the company policies and SSOW
--   documents (PDF or photo) and confirms that they have read each one;
-- * managers publish documents, replace them with new versions and see who
--   has and has not read them;
-- * files live in Supabase Storage (private bucket), never in the database;
-- * a new version keeps an update log, but only the current file is kept:
--   the browser removes the previous file right after the replacement.
--
-- Permissions (module COMPANY_DOCUMENTS):
-- * viewing and confirming needs no grant: any enabled personal account
--   (not a production terminal) can do it;
-- * VIEW grant = see the read status of every document and person;
-- * MANAGE grant = publish, replace, edit, archive and delete documents.
-- Legacy accounts without an access profile fall back to the ADMIN/MANAGER
-- roles (account_module_allowed, 202610230008).
--
-- Who must read: every enabled personal account (USER profile, or a legacy
-- staff login without a profile). Terminals and disabled or banned accounts
-- are left out.
--
-- Confirmations are per version. When a manager uploads a new version they
-- choose whether staff must confirm again (acknowledgement_version moves to
-- the new version) or whether earlier confirmations still count (a small
-- correction).
-- =====================================================================

begin;

-- 1. Module and permission templates -----------------------------------

insert into public.application_modules(module_code,module_name,module_group,display_order)
values ('COMPANY_DOCUMENTS','Company Documents','SELF_SERVICE',35)
on conflict(module_code) do update set module_name=excluded.module_name,module_group=excluded.module_group,display_order=excluded.display_order,active=true;

with rows(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage) as (values
  ('ADMINISTRATOR','COMPANY_DOCUMENTS','ALL',true,true,true,true,true),
  ('IT_MANAGER','COMPANY_DOCUMENTS','ALL',true,true,true,true,true),
  ('GENERAL_MANAGER','COMPANY_DOCUMENTS','ALL',true,true,true,true,true),
  ('PRODUCTION_MANAGER','COMPANY_DOCUMENTS','ALL',true,true,true,true,true),
  ('LOGISTICS_MANAGER','COMPANY_DOCUMENTS','ALL',true,true,true,true,true),
  ('PRODUCTION_SUPERVISOR','COMPANY_DOCUMENTS','ALL',true,false,false,false,false),
  ('AUDITOR','COMPANY_DOCUMENTS','ALL',true,false,false,false,false)
), templates as (
  insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage)
  select * from rows
  on conflict(job_title_code,module_code) do update set access_scope=excluded.access_scope,can_view=excluded.can_view,can_create=excluded.can_create,can_edit=excluded.can_edit,can_approve=excluded.can_approve,can_manage=excluded.can_manage
  returning 1
)
-- Existing accounts of these titles receive the new module (additions only).
insert into public.account_permission_grants(auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage,granted_by_auth_user_id)
select ap.auth_user_id,r.module_code,r.access_scope,r.can_view,r.can_create,r.can_edit,r.can_approve,r.can_manage,null
from rows r
join public.account_access_profiles ap on ap.job_title_code=r.job_title_code and ap.account_type='USER'
on conflict (auth_user_id,module_code) do update set
  can_view=public.account_permission_grants.can_view or excluded.can_view,
  can_create=public.account_permission_grants.can_create or excluded.can_create,
  can_edit=public.account_permission_grants.can_edit or excluded.can_edit,
  can_approve=public.account_permission_grants.can_approve or excluded.can_approve,
  can_manage=public.account_permission_grants.can_manage or excluded.can_manage,
  updated_at=now();

-- 2. Tables -------------------------------------------------------------

create table public.company_documents (
  document_id uuid primary key,
  category text not null check (category in ('POLICY','SSOW')),
  reference_code text,
  title text not null,
  description text,
  requires_acknowledgement boolean not null default true,
  document_status text not null default 'ACTIVE' check (document_status in ('ACTIVE','ARCHIVED','DELETED')),
  current_version integer not null default 1 check (current_version>=1),
  acknowledgement_version integer not null default 1,
  storage_bucket text not null default 'company-documents',
  storage_path text unique,
  original_file_name text,
  mime_type text check (mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  file_size_bytes bigint check (file_size_bytes is null or file_size_bytes>0),
  version_published_at timestamptz not null default now(),
  version_published_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint company_documents_title_check check (length(trim(title)) between 1 and 160),
  constraint company_documents_reference_check check (reference_code is null or length(trim(reference_code)) between 1 and 40),
  constraint company_documents_description_check check (description is null or length(description)<=1000),
  constraint company_documents_ack_version_check check (acknowledgement_version between 1 and current_version),
  constraint company_documents_path_check check (storage_bucket='company-documents' and (storage_path is null or storage_path like document_id::text || '/%')),
  -- Only a deleted document has no file.
  constraint company_documents_file_check check (
    (document_status='DELETED' and storage_path is null)
    or (document_status<>'DELETED' and storage_path is not null and original_file_name is not null and mime_type is not null)
  )
);

create index company_documents_list_idx on public.company_documents(document_status,category,title);

-- Update log: one row per publish, new version, detail change and status change.
-- Only metadata is kept; the replaced file itself is removed from Storage.
create table public.company_document_history (
  history_id bigint generated always as identity primary key,
  document_id uuid not null references public.company_documents(document_id) on delete restrict,
  event_type text not null check (event_type in ('PUBLISHED','NEW_VERSION','DETAILS_UPDATED','ARCHIVED','RESTORED','DELETED')),
  version_number integer not null,
  title text not null,
  original_file_name text,
  file_size_bytes bigint,
  change_note text check (change_note is null or length(change_note)<=500),
  reconfirmation_required boolean,
  recorded_at timestamptz not null default now(),
  recorded_by uuid references auth.users(id) on delete set null
);

create index company_document_history_doc_idx on public.company_document_history(document_id,recorded_at desc);

-- Who opened and who confirmed each version.
create table public.company_document_reads (
  document_id uuid not null references public.company_documents(document_id) on delete restrict,
  version_number integer not null,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  first_opened_at timestamptz,
  last_opened_at timestamptz,
  open_count integer not null default 0,
  acknowledged_at timestamptz,
  primary key (document_id,version_number,auth_user_id)
);

create index company_document_reads_user_idx on public.company_document_reads(auth_user_id,document_id);

alter table public.company_documents enable row level security;
alter table public.company_document_history enable row level security;
alter table public.company_document_reads enable row level security;
revoke all on public.company_documents,public.company_document_history,public.company_document_reads from public,anon,authenticated;

-- 3. Storage bucket (private) ------------------------------------------

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('company-documents','company-documents',false,20971520,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

-- 4. Access helpers ----------------------------------------------------

create or replace function public.can_manage_company_documents()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.account_module_allowed(array['COMPANY_DOCUMENTS'],'MANAGE',array['ADMIN','MANAGER'])
$$;

create or replace function public.can_view_company_document_status()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.account_module_allowed(array['COMPANY_DOCUMENTS'],'VIEW',array['ADMIN','MANAGER','AUDITOR'])
$$;

-- People who must read the documents: enabled personal accounts.
create or replace function public.company_document_audience()
returns table(auth_user_id uuid,display_name text,employee_code text,job_title_name text)
language sql stable security definer set search_path=public,auth,pg_temp as $$
  select u.id,
         coalesce(ap.display_name,sm.display_name,u.email,'Account'),
         sm.employee_code,
         coalesce(jt.job_title_name,case when ap.auth_user_id is null then 'Staff' else null end)
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

create or replace function public.can_read_company_documents()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.current_account_is_enabled()
    and (exists(select 1 from public.company_document_audience() a where a.auth_user_id=auth.uid())
         or public.can_manage_company_documents()
         or public.can_view_company_document_status())
$$;

create or replace function public.can_view_company_document_object(p_object_name text)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.can_manage_company_documents()
    or (public.can_read_company_documents() and exists(
      select 1 from public.company_documents d
      where d.storage_path=p_object_name and d.document_status='ACTIVE'))
$$;

drop policy if exists company_documents_select on storage.objects;
drop policy if exists company_documents_insert on storage.objects;
drop policy if exists company_documents_delete on storage.objects;
create policy company_documents_select on storage.objects for select to authenticated
using (bucket_id='company-documents' and public.can_view_company_document_object(name));
create policy company_documents_insert on storage.objects for insert to authenticated
with check (bucket_id='company-documents' and public.can_manage_company_documents());
create policy company_documents_delete on storage.objects for delete to authenticated
using (bucket_id='company-documents' and public.can_manage_company_documents());

-- Status of one person for one document, used by staff and manager views.
-- ACKNOWLEDGED: confirmed the version that counts. RECONFIRM: confirmed an
-- older version, a newer one must be confirmed. OPENED: opened, not confirmed.
-- PENDING: never opened. INFORMATION: no confirmation required.
create or replace function public.company_document_person_status(p_document public.company_documents,p_auth_user_id uuid)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  with r as (
    select
      max(version_number) filter (where acknowledged_at is not null) as acknowledged_version,
      max(acknowledged_at) as acknowledged_at,
      max(last_opened_at) filter (where version_number=p_document.current_version) as opened_at,
      max(last_opened_at) as any_opened_at
    from public.company_document_reads
    where document_id=p_document.document_id and auth_user_id=p_auth_user_id
  )
  select jsonb_build_object(
    'status',case
      when not p_document.requires_acknowledgement then 'INFORMATION'
      when r.acknowledged_version>=p_document.acknowledgement_version then 'ACKNOWLEDGED'
      when r.acknowledged_version is not null then 'RECONFIRM'
      when r.opened_at is not null then 'OPENED'
      else 'PENDING' end,
    'acknowledged_version',r.acknowledged_version,
    'acknowledged_at',r.acknowledged_at,
    'opened_at',coalesce(r.opened_at,r.any_opened_at)
  ) from r
$$;

-- 5. Staff RPCs --------------------------------------------------------

create or replace function public.get_my_company_documents()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_docs jsonb;
begin
  if not public.can_read_company_documents() then raise exception using errcode='42501',message='Sign in with a staff account to read company documents.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'document_id',d.document_id,'category',d.category,'reference_code',d.reference_code,'title',d.title,
      'description',d.description,'requires_acknowledgement',d.requires_acknowledgement,
      'current_version',d.current_version,'acknowledgement_version',d.acknowledgement_version,
      'version_published_at',d.version_published_at,'storage_bucket',d.storage_bucket,'storage_path',d.storage_path,
      'original_file_name',d.original_file_name,'mime_type',d.mime_type,'file_size_bytes',d.file_size_bytes,
      'last_change_note',(select h.change_note from public.company_document_history h where h.document_id=d.document_id and h.event_type in ('PUBLISHED','NEW_VERSION') order by h.recorded_at desc limit 1)
    ) || public.company_document_person_status(d,auth.uid()) order by d.category,d.title),'[]'::jsonb)
  into v_docs
  from public.company_documents d where d.document_status='ACTIVE';
  return jsonb_build_object(
    'can_manage',public.can_manage_company_documents(),
    'can_view_status',public.can_view_company_document_status(),
    'documents',v_docs,
    'pending_count',(select count(*) from jsonb_array_elements(v_docs) x where x->>'status' in ('PENDING','OPENED','RECONFIRM'))
  );
end;$$;

create or replace function public.get_my_company_document_summary()
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object('pending_count',case when not public.can_read_company_documents() then 0 else (
    select count(*) from public.company_documents d
    where d.document_status='ACTIVE' and d.requires_acknowledgement
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

-- 6. Manager RPCs ------------------------------------------------------

create or replace function public.get_company_documents_admin()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_manage boolean:=public.can_manage_company_documents();
begin
  if not (v_manage or public.can_view_company_document_status()) then raise exception using errcode='42501',message='Company Documents access is required.'; end if;
  return jsonb_build_object(
    'can_manage',v_manage,
    'people',coalesce((select jsonb_agg(to_jsonb(a) order by a.display_name) from public.company_document_audience() a),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object(
        'updated_by_name',(select coalesce(ap.display_name,u.email) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=d.version_published_by)
      ) order by d.category,d.title) from public.company_documents d where d.document_status<>'DELETED'),'[]'::jsonb),
    'statuses',coalesce((select jsonb_agg(jsonb_build_object('document_id',d.document_id,'auth_user_id',a.auth_user_id) || public.company_document_person_status(d,a.auth_user_id))
        from public.company_documents d cross join public.company_document_audience() a where d.document_status='ACTIVE'),'[]'::jsonb),
    -- Files in the bucket that no document points to any more (for example a
    -- replacement whose clean-up did not finish). The manager page removes them.
    'orphan_paths',case when v_manage then coalesce((select jsonb_agg(o.name) from storage.objects o
        where o.bucket_id='company-documents' and o.created_at<now()-interval '1 hour'
          and not exists(select 1 from public.company_documents d where d.storage_path=o.name)),'[]'::jsonb) else '[]'::jsonb end
  );
end;$$;

create or replace function public.get_company_document_history(p_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
  if not (public.can_manage_company_documents() or public.can_view_company_document_status()) then raise exception using errcode='42501',message='Company Documents access is required.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(h) || jsonb_build_object('recorded_by_name',(select coalesce(ap.display_name,u.email) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=h.recorded_by)) order by h.recorded_at desc,h.history_id desc)
    from public.company_document_history h where h.document_id=p_document_id),'[]'::jsonb);
end;$$;

-- The file must already be uploaded to the document's folder.
create or replace function public.company_document_file_exists(p_document_id uuid,p_path text)
returns boolean language sql stable security definer set search_path=public,storage,pg_temp as $$
  select coalesce(p_path like p_document_id::text || '/%',false)
    and exists(select 1 from storage.objects o where o.bucket_id='company-documents' and o.name=p_path)
$$;

create or replace function public.company_document_clean_text(p_value text,p_max integer)
returns text language sql immutable set search_path=public,pg_temp as $$
  select nullif(left(trim(regexp_replace(coalesce(p_value,''),'\s+',' ','g')),p_max),'')
$$;

create or replace function public.create_company_document(p_document jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.company_documents%rowtype;
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
  insert into public.company_document_history(document_id,event_type,version_number,title,original_file_name,file_size_bytes,change_note,recorded_by)
  values(v_row.document_id,'PUBLISHED',1,v_row.title,v_row.original_file_name,v_row.file_size_bytes,public.company_document_clean_text(p_document->>'change_note',500),auth.uid());
  return to_jsonb(v_row);
end;$$;

create or replace function public.update_company_document_details(p_document_id uuid,p_details jsonb,p_row_version integer)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.company_documents%rowtype; v_row public.company_documents%rowtype;
begin
  if not public.can_manage_company_documents() then raise exception using errcode='42501',message='Company Documents management access is required.'; end if;
  select * into v_old from public.company_documents where document_id=p_document_id and document_status<>'DELETED' for update;
  if not found then raise exception using errcode='P0002',message='Document not found.'; end if;
  if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='Someone else changed this document. Reload and try again.'; end if;
  update public.company_documents set
    category=coalesce(upper(nullif(p_details->>'category','')),category),
    reference_code=case when p_details ? 'reference_code' then public.company_document_clean_text(p_details->>'reference_code',40) else reference_code end,
    title=coalesce(public.company_document_clean_text(p_details->>'title',160),title),
    description=case when p_details ? 'description' then nullif(trim(p_details->>'description'),'') else description end,
    requires_acknowledgement=coalesce((p_details->>'requires_acknowledgement')::boolean,requires_acknowledgement),
    updated_at=now(),updated_by=auth.uid(),row_version=row_version+1
  where document_id=p_document_id returning * into v_row;
  if (v_row.category,v_row.reference_code,v_row.title,v_row.description,v_row.requires_acknowledgement)
     is distinct from (v_old.category,v_old.reference_code,v_old.title,v_old.description,v_old.requires_acknowledgement) then
    insert into public.company_document_history(document_id,event_type,version_number,title,original_file_name,file_size_bytes,change_note,recorded_by)
    values(v_row.document_id,'DETAILS_UPDATED',v_row.current_version,v_row.title,v_row.original_file_name,v_row.file_size_bytes,
      concat_ws('; ',
        case when v_row.title is distinct from v_old.title then format('Title was "%s"',v_old.title) end,
        case when v_row.category is distinct from v_old.category then format('Section changed to %s',case v_row.category when 'SSOW' then 'SSOW' else 'Company policy' end) end,
        case when v_row.reference_code is distinct from v_old.reference_code then format('Reference %s',coalesce(v_row.reference_code,'removed')) end,
        case when v_row.description is distinct from v_old.description then 'Description updated' end,
        case when v_row.requires_acknowledgement is distinct from v_old.requires_acknowledgement then case when v_row.requires_acknowledgement then 'Confirmation now required' else 'Confirmation no longer required' end end),
      auth.uid());
  end if;
  return to_jsonb(v_row);
end;$$;

-- Replaces the file with a new version. Returns the previous storage path so
-- the browser can remove the old file (only one physical file is kept).
create or replace function public.replace_company_document_file(p_document_id uuid,p_file jsonb,p_change_note text,p_require_reconfirmation boolean,p_row_version integer)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.company_documents%rowtype; v_row public.company_documents%rowtype;
begin
  if not public.can_manage_company_documents() then raise exception using errcode='42501',message='Company Documents management access is required.'; end if;
  select * into v_old from public.company_documents where document_id=p_document_id and document_status<>'DELETED' for update;
  if not found then raise exception using errcode='P0002',message='Document not found.'; end if;
  if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='Someone else changed this document. Reload and try again.'; end if;
  if nullif(p_file->>'storage_path','') is null or p_file->>'storage_path'=v_old.storage_path then raise exception using errcode='22023',message='Upload the new file before saving the new version.'; end if;
  if not public.company_document_file_exists(p_document_id,p_file->>'storage_path') then raise exception using errcode='22023',message='The new file was not found in storage. Upload it again.'; end if;
  if public.company_document_clean_text(p_change_note,500) is null then raise exception using errcode='22023',message='Describe what changed in this version.'; end if;
  update public.company_documents set
    storage_path=p_file->>'storage_path',original_file_name=p_file->>'original_file_name',mime_type=p_file->>'mime_type',
    file_size_bytes=nullif(p_file->>'file_size_bytes','')::bigint,
    current_version=current_version+1,
    acknowledgement_version=case when coalesce(p_require_reconfirmation,true) then current_version+1 else acknowledgement_version end,
    version_published_at=now(),version_published_by=auth.uid(),
    updated_at=now(),updated_by=auth.uid(),row_version=row_version+1
  where document_id=p_document_id returning * into v_row;
  insert into public.company_document_history(document_id,event_type,version_number,title,original_file_name,file_size_bytes,change_note,reconfirmation_required,recorded_by)
  values(v_row.document_id,'NEW_VERSION',v_row.current_version,v_row.title,v_row.original_file_name,v_row.file_size_bytes,
    public.company_document_clean_text(p_change_note,500),coalesce(p_require_reconfirmation,true),auth.uid());
  return jsonb_build_object('document',to_jsonb(v_row),'old_storage_path',v_old.storage_path);
end;$$;

-- ARCHIVED hides the document from staff and keeps its file (can be restored).
-- DELETED removes the file (returned for the browser to delete) but keeps the
-- update log and the read confirmations.
create or replace function public.set_company_document_status(p_document_id uuid,p_status text,p_note text,p_row_version integer)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.company_documents%rowtype; v_row public.company_documents%rowtype; v_status text:=upper(trim(p_status));
begin
  if not public.can_manage_company_documents() then raise exception using errcode='42501',message='Company Documents management access is required.'; end if;
  if v_status not in ('ACTIVE','ARCHIVED','DELETED') then raise exception using errcode='22023',message='Unknown document status.'; end if;
  select * into v_old from public.company_documents where document_id=p_document_id for update;
  if not found or v_old.document_status='DELETED' then raise exception using errcode='P0002',message='Document not found.'; end if;
  if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='Someone else changed this document. Reload and try again.'; end if;
  if v_old.document_status=v_status then return jsonb_build_object('document',to_jsonb(v_old),'old_storage_path',null); end if;
  update public.company_documents set document_status=v_status,
    storage_path=case when v_status='DELETED' then null else storage_path end,
    original_file_name=case when v_status='DELETED' then null else original_file_name end,
    mime_type=case when v_status='DELETED' then null else mime_type end,
    file_size_bytes=case when v_status='DELETED' then null else file_size_bytes end,
    updated_at=now(),updated_by=auth.uid(),row_version=row_version+1
  where document_id=p_document_id returning * into v_row;
  insert into public.company_document_history(document_id,event_type,version_number,title,original_file_name,file_size_bytes,change_note,recorded_by)
  values(v_row.document_id,case v_status when 'ACTIVE' then 'RESTORED' when 'ARCHIVED' then 'ARCHIVED' else 'DELETED' end,
    v_row.current_version,v_row.title,v_old.original_file_name,v_old.file_size_bytes,public.company_document_clean_text(p_note,500),auth.uid());
  return jsonb_build_object('document',to_jsonb(v_row),'old_storage_path',case when v_status='DELETED' then v_old.storage_path end);
end;$$;

-- 7. Grants ------------------------------------------------------------
-- Internal helpers (the audience list in particular) stay closed to clients.

revoke all on function
  public.can_manage_company_documents(),public.can_view_company_document_status(),public.company_document_audience(),
  public.can_read_company_documents(),public.can_view_company_document_object(text),
  public.company_document_person_status(public.company_documents,uuid),
  public.get_my_company_documents(),public.get_my_company_document_summary(),public.record_company_document_open(uuid),
  public.acknowledge_company_document(uuid,integer),public.get_company_documents_admin(),public.get_company_document_history(uuid),
  public.company_document_file_exists(uuid,text),public.company_document_clean_text(text,integer),public.create_company_document(jsonb),
  public.update_company_document_details(uuid,jsonb,integer),public.replace_company_document_file(uuid,jsonb,text,boolean,integer),
  public.set_company_document_status(uuid,text,text,integer)
from public,anon,authenticated;

-- Storage policies run as the caller, so the two policy helpers need EXECUTE.
grant execute on function
  public.can_manage_company_documents(),public.can_view_company_document_object(text),
  public.get_my_company_documents(),public.get_my_company_document_summary(),public.record_company_document_open(uuid),
  public.acknowledge_company_document(uuid,integer),public.get_company_documents_admin(),public.get_company_document_history(uuid),
  public.create_company_document(jsonb),public.update_company_document_details(uuid,jsonb,integer),
  public.replace_company_document_file(uuid,jsonb,text,boolean,integer),public.set_company_document_status(uuid,text,text,integer)
to authenticated;

commit;
