-- Validation for action-level Staff Master authorization.

do $$
begin
  if to_regprocedure('public.staff_master_action_allowed(text)') is null then
    raise exception 'staff_master_action_allowed(text) is missing';
  end if;

  if to_regprocedure('public.enforce_staff_master_write_permission()') is null then
    raise exception 'enforce_staff_master_write_permission() is missing';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.staff_members'::regclass
      and tgname = 'enforce_staff_master_write_permission'
      and not tgisinternal
  ) then
    raise exception 'Staff Master write permission trigger is missing';
  end if;

  if has_function_privilege('anon', 'public.staff_master_action_allowed(text)', 'execute') then
    raise exception 'anon must not execute staff_master_action_allowed(text)';
  end if;

  if has_function_privilege('authenticated', 'public.staff_master_action_allowed(text)', 'execute') then
    raise exception 'authenticated must not directly execute staff_master_action_allowed(text)';
  end if;
end
$$;
