-- Validation for scoped Accounts & Access administration.

do $$
begin
  if to_regprocedure('public.current_account_permission_scope(text)') is null then
    raise exception 'current_account_permission_scope(text) is missing';
  end if;

  if to_regprocedure('public.get_admin_account_job_access()') is null then
    raise exception 'get_admin_account_job_access() is missing';
  end if;

  if to_regprocedure('public.get_admin_account_access_directory(text)') is null then
    raise exception 'get_admin_account_access_directory(text) is missing';
  end if;

  if has_function_privilege('anon', 'public.current_account_permission_scope(text)', 'execute') then
    raise exception 'anon must not execute current_account_permission_scope(text)';
  end if;

  if has_function_privilege('anon', 'public.get_admin_account_job_access()', 'execute') then
    raise exception 'anon must not execute get_admin_account_job_access()';
  end if;

  if has_function_privilege('anon', 'public.get_admin_account_access_directory(text)', 'execute') then
    raise exception 'anon must not execute get_admin_account_access_directory(text)';
  end if;
end
$$;
