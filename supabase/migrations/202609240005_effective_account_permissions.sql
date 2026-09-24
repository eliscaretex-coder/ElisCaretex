-- Return effective per-account grants with the authenticated shell profile.

create or replace function public.get_current_account_access()
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object(
    'display_name',coalesce(ap.display_name,sm.display_name,u.email,'Signed in'),
    'employee_code',sm.employee_code,
    'account_type',coalesce(ap.account_type,case when psd.station_device_id is not null then 'TERMINAL' else 'LEGACY_STAFF' end),
    'job_title_code',ap.job_title_code,
    'login_method',ap.login_method,
    'role_codes',coalesce((
      select jsonb_agg(r.role_code order by r.role_code) from public.roles r
      where r.active=true and (
        exists (select 1 from public.account_roles ar where ar.auth_user_id=u.id and ar.role_id=r.role_id and ar.active=true)
        or (not exists (select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=u.id)
          and exists (select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active=true and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)))
      )
    ),'[]'::jsonb),
    'roles',coalesce((
      select jsonb_agg(jsonb_build_object('role_code',r.role_code,'role_name',r.role_name) order by r.role_name) from public.roles r
      where r.active=true and (
        exists (select 1 from public.account_roles ar where ar.auth_user_id=u.id and ar.role_id=r.role_id and ar.active=true)
        or (not exists (select 1 from public.account_access_profiles ap2 where ap2.auth_user_id=u.id)
          and exists (select 1 from public.staff_roles sr where sr.staff_id=sm.staff_id and sr.role_id=r.role_id and sr.active=true and sr.effective_from<=current_date and (sr.effective_until is null or sr.effective_until>=current_date)))
      )
    ),'[]'::jsonb),
    'permissions',coalesce((
      select jsonb_agg(jsonb_build_object(
        'module_code',g.module_code,'access_scope',g.access_scope,
        'can_view',g.can_view,'can_create',g.can_create,'can_edit',g.can_edit,
        'can_approve',g.can_approve,'can_manage',g.can_manage
      ) order by m.display_order,m.module_name)
      from public.account_permission_grants g
      join public.application_modules m on m.module_code=g.module_code and m.active
      where g.auth_user_id=u.id and g.active and g.effective_from<=current_date
        and (g.effective_until is null or g.effective_until>=current_date)
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
