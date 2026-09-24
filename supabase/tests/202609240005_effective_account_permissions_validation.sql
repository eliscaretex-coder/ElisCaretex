do $$
begin
  if not exists (
    select 1 from information_schema.routines
    where routine_schema='public' and routine_name='get_current_account_access'
  ) then
    raise exception 'get_current_account_access is missing';
  end if;

  if exists (
    select 1
    from public.account_access_profiles ap
    where ap.account_type='USER' and ap.job_title_code is not null
      and not exists (
        select 1 from public.account_permission_grants g
        where g.auth_user_id=ap.auth_user_id and g.active
      )
  ) then
    raise exception 'A titled personal account has no explicit permission grants';
  end if;

  if exists (
    select 1 from public.account_access_profiles ap
    join public.production_station_devices d on d.device_auth_user_id=ap.auth_user_id and d.active
    where ap.account_type<>'TERMINAL'
  ) then
    raise exception 'An active production terminal has a non-terminal account profile';
  end if;
end
$$;
