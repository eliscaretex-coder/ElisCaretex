-- Flexible account permissions and employee privacy acknowledgement foundation.

create table if not exists public.application_modules (
  module_code text primary key,
  module_name text not null,
  module_group text not null check (module_group in ('SELF_SERVICE','PRODUCTION','DISTRIBUTION','PEOPLE','ADMINISTRATION')),
  display_order integer not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.application_modules (module_code,module_name,module_group,display_order) values
 ('MY_ROSTER','My Roster','SELF_SERVICE',10),
 ('LEAVE','Holiday and Day Off','SELF_SERVICE',20),
 ('NOTIFICATIONS','Notifications','SELF_SERVICE',30),
 ('TRAINING','Training','SELF_SERVICE',40),
 ('STAFF_FORMS','Staff forms','SELF_SERVICE',50),
 ('CUSTOMERS','Customers','PRODUCTION',100),
 ('PRODUCTION_ROSTER','Production Roster','PRODUCTION',110),
 ('SORTING','Sorting','PRODUCTION',120),
 ('FINISH','Finish','PRODUCTION',130),
 ('MOP','MOP Production','PRODUCTION',140),
 ('STOCK','Stock','PRODUCTION',150),
 ('PRODUCTION_TRACKER','Production Tracker','PRODUCTION',160),
 ('DISTRIBUTION','Distribution','DISTRIBUTION',200),
 ('TROLLEYS','Trolleys','DISTRIBUTION',210),
 ('STAFF_MASTER','Staff Master','PEOPLE',300),
 ('ACCOUNTS_ACCESS','Accounts & Access','ADMINISTRATION',400)
on conflict (module_code) do update set module_name=excluded.module_name,module_group=excluded.module_group,display_order=excluded.display_order,active=true;

create table if not exists public.account_permission_grants (
  account_permission_id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  module_code text not null references public.application_modules(module_code) on delete restrict,
  access_scope text not null default 'OWN' check (access_scope in ('OWN','TEAM','PRODUCTION','DISTRIBUTION','ALL')),
  can_view boolean not null default false,
  can_create boolean not null default false,
  can_edit boolean not null default false,
  can_approve boolean not null default false,
  can_manage boolean not null default false,
  effective_from date not null default current_date,
  effective_until date,
  active boolean not null default true,
  granted_by_auth_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (auth_user_id,module_code),
  check (effective_until is null or effective_until >= effective_from),
  check (can_view or can_create or can_edit or can_approve or can_manage)
);

create table if not exists public.privacy_notice_versions (
  privacy_notice_id uuid primary key default gen_random_uuid(),
  version_code text not null unique,
  title text not null,
  published_on date not null,
  document_path text not null,
  active boolean not null default false,
  created_at timestamptz not null default now()
);

create unique index if not exists privacy_notice_one_active_idx on public.privacy_notice_versions ((active)) where active;

insert into public.privacy_notice_versions(version_code,title,published_on,document_path,active)
values ('2026-09-24-INTERIM','Employee Privacy Notice',date '2026-09-24','pages/privacy.html',true)
on conflict (version_code) do update set title=excluded.title,published_on=excluded.published_on,document_path=excluded.document_path,active=true;

create table if not exists public.account_privacy_acknowledgements (
  acknowledgement_id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  privacy_notice_id uuid not null references public.privacy_notice_versions(privacy_notice_id) on delete restrict,
  acknowledged_at timestamptz not null default now(),
  acknowledgement_kind text not null default 'NOTICE_READ' check (acknowledgement_kind='NOTICE_READ'),
  unique (auth_user_id,privacy_notice_id)
);

alter table public.application_modules enable row level security;
alter table public.account_permission_grants enable row level security;
alter table public.privacy_notice_versions enable row level security;
alter table public.account_privacy_acknowledgements enable row level security;
revoke all on public.application_modules,public.account_permission_grants,public.privacy_notice_versions,public.account_privacy_acknowledgements from public,anon,authenticated;

create or replace function public.has_account_permission(p_module_code text,p_action text,p_scope text default null)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select auth.uid() is not null and (
    public.has_any_role(array['ADMIN']) or exists(
      select 1 from public.account_permission_grants apg
      where apg.auth_user_id=auth.uid() and apg.module_code=upper(trim(p_module_code)) and apg.active
        and apg.effective_from<=current_date and (apg.effective_until is null or apg.effective_until>=current_date)
        and (p_scope is null or apg.access_scope=upper(trim(p_scope)) or apg.access_scope='ALL')
        and case upper(trim(p_action))
          when 'VIEW' then apg.can_view or apg.can_create or apg.can_edit or apg.can_approve or apg.can_manage
          when 'CREATE' then apg.can_create or apg.can_manage
          when 'EDIT' then apg.can_edit or apg.can_manage
          when 'APPROVE' then apg.can_approve or apg.can_manage
          when 'MANAGE' then apg.can_manage
          else false end
    )
  );
$$;

create or replace function public.get_my_privacy_notice_status()
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
 select coalesce((select jsonb_build_object(
   'version_code',pnv.version_code,'title',pnv.title,'published_on',pnv.published_on,'document_path',pnv.document_path,
   'acknowledged',exists(select 1 from public.account_privacy_acknowledgements apa where apa.auth_user_id=auth.uid() and apa.privacy_notice_id=pnv.privacy_notice_id)
 ) from public.privacy_notice_versions pnv where pnv.active limit 1),'{}'::jsonb);
$$;

create or replace function public.acknowledge_current_privacy_notice()
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_notice uuid;
begin
 if auth.uid() is null then raise exception using errcode='42501',message='Authentication is required.'; end if;
 select privacy_notice_id into v_notice from public.privacy_notice_versions where active limit 1;
 if v_notice is null then raise exception using errcode='P0002',message='No active privacy notice is configured.'; end if;
 insert into public.account_privacy_acknowledgements(auth_user_id,privacy_notice_id) values(auth.uid(),v_notice) on conflict do nothing;
 return public.get_my_privacy_notice_status();
end;$$;

create or replace function public.get_admin_account_access_directory(p_search text default null)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_search text:=lower(nullif(trim(p_search),''));
begin
 if not public.has_any_role(array['ADMIN']) then raise exception using errcode='42501',message='Only administrators can view application accounts and access.'; end if;
 return jsonb_build_object(
 'summary',jsonb_build_object('total_accounts',(select count(*) from auth.users),'linked_staff',(select count(*) from auth.users u join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null),'terminal_accounts',(select count(*) from public.production_station_devices where active=true),'unlinked_accounts',(select count(*) from auth.users u left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null where sm.staff_id is null)),
 'available_roles',coalesce((select jsonb_agg(jsonb_build_object('role_code',r.role_code,'role_name',r.role_name) order by r.role_name) from public.roles r where r.active=true),'[]'::jsonb),
 'available_modules',coalesce((select jsonb_agg(jsonb_build_object('module_code',m.module_code,'module_name',m.module_name,'module_group',m.module_group) order by m.display_order,m.module_name) from public.application_modules m where m.active),'[]'::jsonb),
 'accounts',coalesce((select jsonb_agg(jsonb_build_object(
  'auth_user_id',u.id,'email',u.email,'is_active',(u.banned_until is null or u.banned_until<=now()),'created_at',u.created_at,'last_sign_in_at',u.last_sign_in_at,
  'staff_id',sm.staff_id,'employee_code',sm.employee_code,'display_name',coalesce(ap.display_name,sm.display_name),'staff_active',sm.active,'account_type',coalesce(ap.account_type,case when psd.station_device_id is not null then 'TERMINAL' else 'LEGACY_STAFF' end),
  'role_codes',coalesce((select jsonb_agg(r.role_code order by r.role_code) from public.roles r where r.active=true and (
    exists(select 1 from public.account_roles ar where ar.auth_user_id=u.id and ar.role_id=r.role_id and ar.active)
    or (not exists(select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=u.id) and exists(select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)))
  )),'[]'::jsonb),
  'permissions',coalesce((select jsonb_agg(jsonb_build_object('module_code',g.module_code,'access_scope',g.access_scope,'can_view',g.can_view,'can_create',g.can_create,'can_edit',g.can_edit,'can_approve',g.can_approve,'can_manage',g.can_manage,'effective_from',g.effective_from,'effective_until',g.effective_until) order by g.module_code) from public.account_permission_grants g where g.auth_user_id=u.id and g.active),'[]'::jsonb),
  'terminal',case when psd.station_device_id is null then null else jsonb_build_object('device_code',psd.device_code,'device_name',psd.device_name,'station_code',s.station_code,'station_name',s.station_name,'area_code',a.area_code,'active',psd.active) end
 ) order by lower(coalesce(ap.display_name,sm.display_name,u.email)),u.created_at desc)
 from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null left join public.production_station_devices psd on psd.device_auth_user_id=u.id left join public.stations s on s.station_id=psd.station_id left join public.areas a on a.area_id=s.area_id
 where v_search is null or lower(coalesce(u.email,'')) like '%'||v_search||'%' or lower(coalesce(ap.display_name,sm.display_name,'')) like '%'||v_search||'%' or lower(coalesce(sm.employee_code,'')) like '%'||v_search||'%'),'[]'::jsonb)
 );
end;$$;

revoke all on function public.has_account_permission(text,text,text),public.get_my_privacy_notice_status(),public.acknowledge_current_privacy_notice(),public.get_admin_account_access_directory(text) from public,anon;
grant execute on function public.has_account_permission(text,text,text),public.get_my_privacy_notice_status(),public.acknowledge_current_privacy_notice() to authenticated;
grant execute on function public.get_admin_account_access_directory(text) to authenticated;
