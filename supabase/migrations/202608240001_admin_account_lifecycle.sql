-- Account lifecycle fields for the administrator account directory.

create or replace function public.get_admin_account_access_directory(p_search text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_search text := lower(nullif(trim(p_search),''));
begin
  if not public.has_any_role(array['ADMIN']) then
    raise exception using errcode='42501', message='Only administrators can view application accounts and access.';
  end if;

  return jsonb_build_object(
    'summary',jsonb_build_object(
      'total_accounts',(select count(*) from auth.users),
      'linked_staff',(select count(*) from auth.users u join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null),
      'terminal_accounts',(select count(*) from public.production_station_devices where active=true),
      'unlinked_accounts',(select count(*) from auth.users u left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null where sm.staff_id is null)
    ),
    'available_roles',coalesce((
      select jsonb_agg(jsonb_build_object('role_code',r.role_code,'role_name',r.role_name) order by r.role_name)
      from public.roles r
      where r.active=true
    ),'[]'::jsonb),
    'accounts',coalesce((
      select jsonb_agg(jsonb_build_object(
        'auth_user_id',u.id,
        'email',u.email,
        'is_active',(u.banned_until is null or u.banned_until <= now()),
        'created_at',u.created_at,
        'last_sign_in_at',u.last_sign_in_at,
        'staff_id',sm.staff_id,
        'employee_code',sm.employee_code,
        'display_name',sm.display_name,
        'staff_active',sm.active,
        'role_codes',coalesce((
          select jsonb_agg(r.role_code order by r.role_code)
          from public.staff_roles sr
          join public.roles r on r.role_id=sr.role_id and r.active=true
          where sr.staff_id=sm.staff_id and sr.active=true
            and sr.effective_from<=current_date
            and (sr.effective_until is null or sr.effective_until>=current_date)
        ),'[]'::jsonb),
        'terminal',(
          select jsonb_build_object(
            'device_code',psd.device_code,
            'device_name',psd.device_name,
            'station_code',s.station_code,
            'station_name',s.station_name,
            'area_code',a.area_code,
            'active',psd.active
          )
          from public.production_station_devices psd
          join public.stations s on s.station_id=psd.station_id
          join public.areas a on a.area_id=s.area_id
          where psd.device_auth_user_id=u.id
          limit 1
        )
      ) order by lower(coalesce(sm.display_name,u.email)),u.created_at desc)
      from auth.users u
      left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null
      where v_search is null
        or lower(coalesce(u.email,'')) like '%'||v_search||'%'
        or lower(coalesce(sm.display_name,'')) like '%'||v_search||'%'
        or lower(coalesce(sm.employee_code,'')) like '%'||v_search||'%'
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_admin_account_access_directory(text) from public,anon;
grant execute on function public.get_admin_account_access_directory(text) to authenticated;
