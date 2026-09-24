-- Human job titles and changeable personal login methods.

create table if not exists public.account_job_titles (
  job_title_code text primary key,
  job_title_name text not null,
  department_scope text not null check (department_scope in ('ADMINISTRATION','MANAGEMENT','PRODUCTION','DISTRIBUTION','MAINTENANCE','CUSTOMER_SERVICE','CROSS_DEPARTMENT')),
  hierarchy_rank integer not null,
  active boolean not null default true
);

insert into public.account_job_titles(job_title_code,job_title_name,department_scope,hierarchy_rank) values
 ('ADMINISTRATOR','Administrator','ADMINISTRATION',1),
 ('IT_MANAGER','IT Manager','ADMINISTRATION',10),
 ('GENERAL_MANAGER','General Manager','MANAGEMENT',20),
 ('PRODUCTION_MANAGER','Production Manager','PRODUCTION',30),
 ('LOGISTICS_MANAGER','Logistics Manager','DISTRIBUTION',30),
 ('MAINTENANCE','Maintenance','MAINTENANCE',50),
 ('PRODUCTION_SUPERVISOR','Production Supervisor','PRODUCTION',40),
 ('TEAM_LEADER','Team Leader','PRODUCTION',60),
 ('GENERAL_OPERATIVE','General Operative','PRODUCTION',70),
 ('LABEL_OPERATIVE','Label Operative','PRODUCTION',70),
 ('CLEANER','Cleaner','CROSS_DEPARTMENT',70),
 ('AUDITOR','Auditor','CROSS_DEPARTMENT',40),
 ('CUSTOMER_SERVICE','Customer Service','CUSTOMER_SERVICE',50)
on conflict(job_title_code) do update set job_title_name=excluded.job_title_name,department_scope=excluded.department_scope,hierarchy_rank=excluded.hierarchy_rank,active=true;

create table if not exists public.job_title_legacy_roles (
  job_title_code text not null references public.account_job_titles(job_title_code) on delete cascade,
  role_code text not null references public.roles(role_code) on delete cascade,
  primary key(job_title_code,role_code)
);

insert into public.job_title_legacy_roles(job_title_code,role_code) values
 ('ADMINISTRATOR','ADMIN'),('GENERAL_MANAGER','MANAGER'),('PRODUCTION_MANAGER','MANAGER'),
 ('LOGISTICS_MANAGER','DISTRIBUTION_OPERATOR'),('PRODUCTION_SUPERVISOR','SUPERVISOR'),('AUDITOR','AUDITOR')
on conflict do nothing;

create table if not exists public.job_title_permission_templates (
  job_title_code text not null references public.account_job_titles(job_title_code) on delete cascade,
  module_code text not null references public.application_modules(module_code) on delete cascade,
  access_scope text not null check (access_scope in ('OWN','TEAM','PRODUCTION','DISTRIBUTION','ALL')),
  can_view boolean not null default false,
  can_create boolean not null default false,
  can_edit boolean not null default false,
  can_approve boolean not null default false,
  can_manage boolean not null default false,
  primary key(job_title_code,module_code)
);

insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage)
select jt.job_title_code,m.module_code,'ALL',true,true,true,true,true from public.account_job_titles jt cross join public.application_modules m where jt.job_title_code='ADMINISTRATOR'
on conflict do nothing;

insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage) values
 ('GENERAL_OPERATIVE','MY_ROSTER','OWN',true,false,false,false,false),('GENERAL_OPERATIVE','LEAVE','OWN',true,true,true,false,false),('GENERAL_OPERATIVE','NOTIFICATIONS','OWN',true,false,false,false,false),('GENERAL_OPERATIVE','TRAINING','OWN',true,false,false,false,false),('GENERAL_OPERATIVE','STAFF_FORMS','OWN',true,true,false,false,false),
 ('TEAM_LEADER','MY_ROSTER','OWN',true,false,false,false,false),('TEAM_LEADER','LEAVE','OWN',true,true,true,false,false),('TEAM_LEADER','NOTIFICATIONS','OWN',true,false,false,false,false),('TEAM_LEADER','TRAINING','OWN',true,false,false,false,false),('TEAM_LEADER','STAFF_FORMS','OWN',true,true,false,false,false),
 ('LABEL_OPERATIVE','MY_ROSTER','OWN',true,false,false,false,false),('LABEL_OPERATIVE','LEAVE','OWN',true,true,true,false,false),('LABEL_OPERATIVE','NOTIFICATIONS','OWN',true,false,false,false,false),('LABEL_OPERATIVE','TRAINING','OWN',true,false,false,false,false),('LABEL_OPERATIVE','STAFF_FORMS','OWN',true,true,false,false,false),
 ('CLEANER','MY_ROSTER','OWN',true,false,false,false,false),('CLEANER','LEAVE','OWN',true,true,true,false,false),('CLEANER','NOTIFICATIONS','OWN',true,false,false,false,false),('CLEANER','TRAINING','OWN',true,false,false,false,false),('CLEANER','STAFF_FORMS','OWN',true,true,false,false,false),
 ('MAINTENANCE','MY_ROSTER','OWN',true,false,false,false,false),('MAINTENANCE','LEAVE','OWN',true,true,true,false,false),('MAINTENANCE','NOTIFICATIONS','OWN',true,false,false,false,false),('MAINTENANCE','TRAINING','OWN',true,false,false,false,false),('MAINTENANCE','STAFF_FORMS','OWN',true,true,false,false,false),
 ('PRODUCTION_SUPERVISOR','PRODUCTION_ROSTER','PRODUCTION',true,true,true,true,false),('PRODUCTION_SUPERVISOR','STAFF_MASTER','PRODUCTION',true,false,true,false,false),('PRODUCTION_SUPERVISOR','ACCOUNTS_ACCESS','PRODUCTION',true,true,true,false,false),('PRODUCTION_SUPERVISOR','SORTING','PRODUCTION',true,true,true,true,false),('PRODUCTION_SUPERVISOR','FINISH','PRODUCTION',true,true,true,true,false),('PRODUCTION_SUPERVISOR','MOP','PRODUCTION',true,true,true,true,false),('PRODUCTION_SUPERVISOR','STOCK','PRODUCTION',true,true,true,true,false),
 ('PRODUCTION_MANAGER','PRODUCTION_ROSTER','PRODUCTION',true,true,true,true,true),('PRODUCTION_MANAGER','STAFF_MASTER','PRODUCTION',true,true,true,true,true),('PRODUCTION_MANAGER','ACCOUNTS_ACCESS','PRODUCTION',true,true,true,true,false),
 ('LOGISTICS_MANAGER','DISTRIBUTION','DISTRIBUTION',true,true,true,true,true),('LOGISTICS_MANAGER','TROLLEYS','DISTRIBUTION',true,true,true,true,true),('LOGISTICS_MANAGER','ACCOUNTS_ACCESS','DISTRIBUTION',true,true,true,true,false),
 ('GENERAL_MANAGER','PRODUCTION_ROSTER','ALL',true,false,false,true,false),('GENERAL_MANAGER','DISTRIBUTION','ALL',true,false,false,true,false),('GENERAL_MANAGER','STAFF_MASTER','ALL',true,false,false,true,false),('GENERAL_MANAGER','ACCOUNTS_ACCESS','ALL',true,true,true,true,false),
 ('IT_MANAGER','ACCOUNTS_ACCESS','ALL',true,true,true,true,true),('IT_MANAGER','NOTIFICATIONS','ALL',true,true,true,false,true),
 ('AUDITOR','PRODUCTION_ROSTER','ALL',true,false,false,false,false),('AUDITOR','DISTRIBUTION','ALL',true,false,false,false,false),('AUDITOR','STAFF_MASTER','ALL',true,false,false,false,false),
 ('CUSTOMER_SERVICE','CUSTOMERS','ALL',true,true,true,false,false),('CUSTOMER_SERVICE','NOTIFICATIONS','TEAM',true,true,true,false,false)
on conflict do nothing;

alter table public.account_access_profiles add column if not exists job_title_code text references public.account_job_titles(job_title_code) on delete restrict;
alter table public.account_access_profiles add column if not exists login_method text not null default 'EMAIL' check (login_method in ('EMAIL','USERNAME','TERMINAL'));
alter table public.account_access_profiles add column if not exists login_identifier text;

update public.account_access_profiles ap set job_title_code='ADMINISTRATOR'
where job_title_code is null and exists(select 1 from public.account_roles ar join public.roles r on r.role_id=ar.role_id where ar.auth_user_id=ap.auth_user_id and ar.active and r.role_code='ADMIN');
update public.account_access_profiles ap set login_method='TERMINAL',login_identifier=psd.device_code
from public.production_station_devices psd where psd.device_auth_user_id=ap.auth_user_id;

alter table public.account_job_titles enable row level security;
alter table public.job_title_legacy_roles enable row level security;
alter table public.job_title_permission_templates enable row level security;
revoke all on public.account_job_titles,public.job_title_legacy_roles,public.job_title_permission_templates from public,anon,authenticated;

create or replace function public.get_admin_account_job_access()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
 if not public.has_account_permission('ACCOUNTS_ACCESS','VIEW',null) then raise exception using errcode='42501',message='This account cannot view Accounts & Access.'; end if;
 return jsonb_build_object(
  'job_titles',coalesce((select jsonb_agg(jsonb_build_object(
    'job_title_code',jt.job_title_code,'job_title_name',jt.job_title_name,'department_scope',jt.department_scope,
    'legacy_roles',coalesce((select jsonb_agg(jlr.role_code order by jlr.role_code) from public.job_title_legacy_roles jlr where jlr.job_title_code=jt.job_title_code),'[]'::jsonb),
    'permissions',coalesce((select jsonb_agg(to_jsonb(t)-'job_title_code' order by t.module_code) from public.job_title_permission_templates t where t.job_title_code=jt.job_title_code),'[]'::jsonb)
  ) order by jt.hierarchy_rank,jt.job_title_name) from public.account_job_titles jt where jt.active),'[]'::jsonb),
  'profiles',coalesce((select jsonb_agg(jsonb_build_object('auth_user_id',ap.auth_user_id,'job_title_code',ap.job_title_code,'login_method',ap.login_method,'login_identifier',ap.login_identifier)) from public.account_access_profiles ap),'[]'::jsonb)
 );
end;$$;

create or replace function public.can_view_admin_account_access()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
 select auth.uid() is not null and public.has_account_permission('ACCOUNTS_ACCESS','VIEW',null);
$$;

revoke all on function public.get_admin_account_job_access(),public.can_view_admin_account_access() from public,anon;
grant execute on function public.get_admin_account_job_access(),public.can_view_admin_account_access() to authenticated;
