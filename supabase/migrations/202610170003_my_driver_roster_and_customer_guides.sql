begin;

insert into public.application_modules(module_code,module_name,module_group,display_order)
values ('MY_DRIVER_ROSTER','My Driver Roster','SELF_SERVICE',11)
on conflict(module_code) do update set module_name=excluded.module_name,module_group=excluded.module_group,display_order=excluded.display_order,active=true;

insert into public.account_job_titles(job_title_code,job_title_name,department_scope,hierarchy_rank)
values ('DRIVER','Driver','DISTRIBUTION',70)
on conflict(job_title_code) do update set job_title_name=excluded.job_title_name,department_scope=excluded.department_scope,hierarchy_rank=excluded.hierarchy_rank,active=true;

insert into public.job_title_legacy_roles(job_title_code,role_code)
values ('DRIVER','DISTRIBUTION_OPERATOR') on conflict do nothing;

insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage) values
 ('DRIVER','MY_DRIVER_ROSTER','OWN',true,true,true,false,false),
 ('LOGISTICS_MANAGER','MY_DRIVER_ROSTER','DISTRIBUTION',true,true,true,true,true),
 ('GENERAL_MANAGER','MY_DRIVER_ROSTER','ALL',true,false,false,true,false)
on conflict(job_title_code,module_code) do update set access_scope=excluded.access_scope,can_view=excluded.can_view,can_create=excluded.can_create,can_edit=excluded.can_edit,can_approve=excluded.can_approve,can_manage=excluded.can_manage;

insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage)
select 'ADMINISTRATOR','MY_DRIVER_ROSTER','ALL',true,true,true,true,true
on conflict(job_title_code,module_code) do update set access_scope='ALL',can_view=true,can_create=true,can_edit=true,can_approve=true,can_manage=true;

create table public.customer_driver_guides (
  guide_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  title text not null,
  description text,
  storage_bucket text not null default 'customer-driver-guides',
  storage_path text not null unique,
  original_file_name text not null,
  mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  sort_order integer not null default 10,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint customer_driver_guides_title_check check (length(trim(title)) between 1 and 160),
  constraint customer_driver_guides_path_check check (storage_bucket='customer-driver-guides' and storage_path like customer_id::text || '/%')
);

create index customer_driver_guides_customer_idx on public.customer_driver_guides(customer_id,active,sort_order);
alter table public.customer_driver_guides enable row level security;
revoke all on public.customer_driver_guides from public,anon,authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('customer-driver-guides','customer-driver-guides',false,15728640,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create or replace function public.current_distribution_driver_id()
returns uuid language sql stable security definer set search_path=public,auth,pg_temp as $$
  select d.driver_id from public.distribution_drivers d join public.staff_members s on s.staff_id=d.staff_id
  where s.auth_user_id=auth.uid() and s.active and s.deleted_at is null and d.employment_status='ACTIVE' and d.deleted_at is null limit 1
$$;

create or replace function public.can_manage_driver_guides()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select auth.uid() is not null and public.has_account_permission('DISTRIBUTION','MANAGE',null)
$$;

create or replace function public.can_view_driver_guide_customer(p_customer_id uuid)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.can_manage_driver_guides() or exists(
    select 1 from public.distribution_route_run_stops s
    join public.distribution_route_runs r on r.run_id=s.run_id
    join public.distribution_roster_entries e on e.work_date=r.business_date and e.route_id=r.route_id
    join public.distribution_roster_versions v on v.distribution_roster_version_id=e.distribution_roster_version_id and v.roster_status='PUBLISHED'
    where s.customer_id=p_customer_id and public.current_distribution_driver_id() in (e.primary_driver_id,e.support_driver_id)
  )
$$;

create or replace function public.can_view_driver_guide_object(p_object_name text)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
 select exists(select 1 from public.customer_driver_guides g where g.storage_path=p_object_name and g.active and public.can_view_driver_guide_customer(g.customer_id))
$$;

create policy customer_driver_guides_select on storage.objects for select to authenticated
using (bucket_id='customer-driver-guides' and public.can_view_driver_guide_object(name));
create policy customer_driver_guides_insert on storage.objects for insert to authenticated
with check (bucket_id='customer-driver-guides' and public.can_manage_driver_guides());
create policy customer_driver_guides_update on storage.objects for update to authenticated
using (bucket_id='customer-driver-guides' and public.can_manage_driver_guides()) with check (bucket_id='customer-driver-guides' and public.can_manage_driver_guides());
create policy customer_driver_guides_delete on storage.objects for delete to authenticated
using (bucket_id='customer-driver-guides' and public.can_manage_driver_guides());

create or replace function public.get_my_driver_roster(p_week_start date default null)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_driver uuid:=public.current_distribution_driver_id(); v_week date:=coalesce(p_week_start,date_trunc('week',current_date)::date); v_version uuid;
begin
 if auth.uid() is null then raise exception using errcode='42501',message='Sign in is required.'; end if;
 if v_driver is null and not public.can_manage_driver_guides() then raise exception using errcode='42501',message='This account is not linked to an active Distribution driver.'; end if;
 if v_week<>date_trunc('week',v_week)::date then raise exception using errcode='22023',message='The week must start on Monday.'; end if;
 select distribution_roster_version_id into v_version from public.distribution_roster_versions where week_start=v_week and roster_status='PUBLISHED' order by version_number desc limit 1;
 return jsonb_build_object('week_start',v_week,'week_end',v_week+6,'driver_id',v_driver,
  'driver',case when v_driver is null then null else (select to_jsonb(d) from public.distribution_drivers d where d.driver_id=v_driver) end,
  'entries',coalesce((select jsonb_agg(to_jsonb(e) order by e.work_date) from public.distribution_roster_entries e where e.distribution_roster_version_id=v_version and (v_driver is null or v_driver in(e.primary_driver_id,e.support_driver_id))),'[]'::jsonb),
  'requests',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from public.distribution_driver_absences a where a.driver_id=v_driver),'[]'::jsonb)
 );
end;$$;

create or replace function public.get_my_driver_route(p_roster_entry_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_driver uuid:=public.current_distribution_driver_id(); v_entry public.distribution_roster_entries%rowtype; v_run uuid;
begin
 select e.* into v_entry from public.distribution_roster_entries e join public.distribution_roster_versions v on v.distribution_roster_version_id=e.distribution_roster_version_id and v.roster_status='PUBLISHED' where e.distribution_roster_entry_id=p_roster_entry_id;
 if not found or (not public.can_manage_driver_guides() and (v_driver is null or v_driver not in(v_entry.primary_driver_id,v_entry.support_driver_id))) then raise exception using errcode='42501',message='This route is not assigned to your account.'; end if;
 select run_id into v_run from public.distribution_route_runs where business_date=v_entry.work_date and route_id=v_entry.route_id limit 1;
 return jsonb_build_object('entry',to_jsonb(v_entry),'stops',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('guides',coalesce((select jsonb_agg(to_jsonb(g) order by g.sort_order,g.title) from public.customer_driver_guides g where g.customer_id=s.customer_id and g.active),'[]'::jsonb)) order by s.stop_order) from public.distribution_route_run_stops s where s.run_id=v_run),'[]'::jsonb));
end;$$;

create or replace function public.submit_my_driver_leave_request(p_type text,p_start date,p_end date,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_driver uuid:=public.current_distribution_driver_id(); v_row public.distribution_driver_absences%rowtype; v_type text:=upper(trim(p_type));
begin
 if v_driver is null then raise exception using errcode='42501',message='This account is not linked to an active Distribution driver.'; end if;
 if v_type not in('HOLIDAY','DAY_OFF') or p_start is null or p_end is null or p_end<p_start then raise exception using errcode='22023',message='Enter a valid Holiday or Day off request.'; end if;
 if exists(select 1 from public.distribution_driver_absences where driver_id=v_driver and absence_status in('REQUESTED','APPROVED') and starts_on<=p_end and ends_on>=p_start) then raise exception using errcode='23505',message='A request already covers part of these dates.'; end if;
 insert into public.distribution_driver_absences(driver_id,absence_type,starts_on,ends_on,absence_status,notes,created_by,updated_by) values(v_driver,v_type,p_start,p_end,'REQUESTED',nullif(trim(p_reason),''),auth.uid(),auth.uid()) returning * into v_row;
 return to_jsonb(v_row);
end;$$;

create or replace function public.get_driver_guide_admin(p_customer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
 if not public.can_manage_driver_guides() then raise exception using errcode='42501',message='Distribution management access is required.'; end if;
 return jsonb_build_object('customers',coalesce((select jsonb_agg(jsonb_build_object('customer_id',c.customer_id,'customer_code',c.customer_code,'customer_name',c.customer_name) order by c.customer_name) from public.customers c where c.active and c.deleted_at is null),'[]'::jsonb),'guides',coalesce((select jsonb_agg(to_jsonb(g) order by g.sort_order,g.title) from public.customer_driver_guides g where p_customer_id is null or g.customer_id=p_customer_id),'[]'::jsonb));
end;$$;

create or replace function public.save_driver_guide(p_guide jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_driver_guides%rowtype;
begin
 if not public.can_manage_driver_guides() then raise exception using errcode='42501',message='Distribution management access is required.'; end if;
 insert into public.customer_driver_guides(customer_id,title,description,storage_path,original_file_name,mime_type,sort_order,created_by,updated_by)
 values((p_guide->>'customer_id')::uuid,trim(p_guide->>'title'),nullif(trim(p_guide->>'description'),''),p_guide->>'storage_path',p_guide->>'original_file_name',p_guide->>'mime_type',coalesce((p_guide->>'sort_order')::integer,10),auth.uid(),auth.uid()) returning * into v_row;
 return to_jsonb(v_row);
end;$$;

create or replace function public.set_driver_guide_active(p_guide_id uuid,p_active boolean)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_driver_guides%rowtype;
begin
 if not public.can_manage_driver_guides() then raise exception using errcode='42501',message='Distribution management access is required.'; end if;
 update public.customer_driver_guides set active=p_active,updated_at=now(),updated_by=auth.uid(),row_version=row_version+1 where guide_id=p_guide_id returning * into v_row;
 if not found then raise exception using errcode='P0002',message='Guide not found.'; end if; return to_jsonb(v_row);
end;$$;

revoke all on function public.current_distribution_driver_id(),public.can_manage_driver_guides(),public.can_view_driver_guide_customer(uuid),public.can_view_driver_guide_object(text),public.get_my_driver_roster(date),public.get_my_driver_route(uuid),public.submit_my_driver_leave_request(text,date,date,text),public.get_driver_guide_admin(uuid),public.save_driver_guide(jsonb),public.set_driver_guide_active(uuid,boolean) from public,anon;
grant execute on function public.current_distribution_driver_id(),public.can_manage_driver_guides(),public.can_view_driver_guide_customer(uuid),public.can_view_driver_guide_object(text),public.get_my_driver_roster(date),public.get_my_driver_route(uuid),public.submit_my_driver_leave_request(text,date,date,text),public.get_driver_guide_admin(uuid),public.save_driver_guide(jsonb),public.set_driver_guide_active(uuid,boolean) to authenticated;

commit;
