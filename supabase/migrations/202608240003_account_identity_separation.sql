-- Separate application identities and permissions from operational Staff Master.

create table if not exists public.account_access_profiles (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  account_type text not null default 'USER' check (account_type in ('USER','TERMINAL')),
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.account_roles (
  account_role_id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  role_id uuid not null references public.roles(role_id) on delete restrict,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (auth_user_id, role_id)
);

alter table public.account_access_profiles enable row level security;
alter table public.account_roles enable row level security;
revoke all on public.account_access_profiles, public.account_roles from anon, authenticated;

create or replace function public.has_any_role(p_role_codes text[])
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select auth.uid() is not null and exists (
    select 1 from public.roles r
    where r.active=true and r.role_code=any(p_role_codes) and (
      exists (
        select 1 from public.account_access_profiles ap
        join public.account_roles ar on ar.auth_user_id=ap.auth_user_id and ar.role_id=r.role_id and ar.active=true
        where ap.auth_user_id=auth.uid()
      )
      or (
        not exists (select 1 from public.account_access_profiles ap where ap.auth_user_id=auth.uid())
        and exists (
          select 1 from public.staff_members sm join public.staff_roles sr on sr.staff_id=sm.staff_id and sr.role_id=r.role_id
          where sm.auth_user_id=auth.uid() and sm.active=true and sm.deleted_at is null and sr.active=true
            and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)
        )
      )
    )
  );
$$;

create or replace function public.get_current_account_access()
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object(
    'display_name',coalesce(ap.display_name,sm.display_name,u.email,'Signed in'),
    'employee_code',sm.employee_code,
    'account_type',coalesce(ap.account_type,case when psd.station_device_id is not null then 'TERMINAL' else 'LEGACY_STAFF' end),
    'role_codes',coalesce((
      select jsonb_agg(r.role_code order by r.role_code) from public.roles r
      where r.active=true and (
        exists (select 1 from public.account_access_profiles ap2 join public.account_roles ar on ar.auth_user_id=ap2.auth_user_id and ar.role_id=r.role_id and ar.active=true where ap2.auth_user_id=auth.uid())
        or (not exists (select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=auth.uid()) and exists (select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active=true and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)))
      )
    ),'[]'::jsonb),
    'roles',coalesce((
      select jsonb_agg(jsonb_build_object('role_code',r.role_code,'role_name',r.role_name) order by r.role_name) from public.roles r
      where r.active=true and (
        exists (select 1 from public.account_access_profiles ap2 join public.account_roles ar on ar.auth_user_id=ap2.auth_user_id and ar.role_id=r.role_id and ar.active=true where ap2.auth_user_id=auth.uid())
        or (not exists (select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=auth.uid()) and exists (select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active=true and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)))
      )
    ),'[]'::jsonb)
  )
  from auth.users u
  left join public.account_access_profiles ap on ap.auth_user_id=u.id
  left join public.staff_members sm on sm.auth_user_id=u.id and sm.active=true and sm.deleted_at is null
  left join public.production_station_devices psd on psd.device_auth_user_id=u.id and psd.active=true
  where u.id=auth.uid();
$$;

revoke all on function public.get_current_account_access() from public,anon;
grant execute on function public.get_current_account_access() to authenticated;
