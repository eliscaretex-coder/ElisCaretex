do $$
begin
  if (select count(*) from public.account_job_titles where active) <> 13 then
    raise exception 'Expected 13 active account job titles';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public' and table_name = 'account_access_profiles' and column_name = 'job_title_code'
  ) then
    raise exception 'account_access_profiles.job_title_code is missing';
  end if;

  if not exists (
    select 1
    from information_schema.routines
    where routine_schema = 'public' and routine_name = 'get_admin_account_job_access'
  ) then
    raise exception 'get_admin_account_job_access is missing';
  end if;

  if exists (
    select 1 from public.account_access_profiles
    where account_type = 'TERMINAL' and login_method <> 'TERMINAL'
  ) then
    raise exception 'A terminal account has an invalid login method';
  end if;

  if not exists (
    select 1 from public.account_access_profiles ap
    join public.account_roles ar on ar.auth_user_id=ap.auth_user_id and ar.active
    join public.roles r on r.role_id=ar.role_id and r.role_code='ADMIN'
    where ap.job_title_code='ADMINISTRATOR'
  ) then
    raise exception 'The administrator was not migrated to the explicit account model';
  end if;
end
$$;
