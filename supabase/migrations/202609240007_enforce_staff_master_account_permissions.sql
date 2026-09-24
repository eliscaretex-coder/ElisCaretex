-- Enforce Staff Master action grants at the data boundary.
-- Existing SECURITY DEFINER RPCs remain responsible for validation and audit,
-- while this trigger prevents an RPC from performing a stronger action than
-- the caller's current account grant permits.

create or replace function public.staff_master_action_allowed(p_action text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_uses_explicit_permissions boolean;
begin
  if auth.uid() is null then
    return false;
  end if;

  select exists (
    select 1
    from public.account_permission_grants g
    where g.auth_user_id = auth.uid()
  ) into v_uses_explicit_permissions;

  if v_uses_explicit_permissions then
    return public.has_account_permission('STAFF_MASTER', p_action, 'PRODUCTION');
  end if;

  -- Temporary compatibility for accounts that have not yet been migrated to
  -- explicit grants. Once migrated, their grant is always authoritative.
  if upper(trim(p_action)) = 'VIEW' then
    return public.has_any_role(array['ADMIN', 'MANAGER', 'ROSTER_MANAGER', 'SUPERVISOR', 'AUDITOR']);
  end if;
  return public.has_any_role(array['ADMIN', 'MANAGER']);
end;
$$;

create or replace function public.require_staff_master_read_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.staff_master_action_allowed('VIEW') then
    raise exception using errcode = '42501', message = 'You do not have permission to view Staff Master.';
  end if;
end;
$$;

create or replace function public.require_staff_master_manage_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not (
    public.staff_master_action_allowed('CREATE')
    or public.staff_master_action_allowed('EDIT')
    or public.staff_master_action_allowed('MANAGE')
  ) then
    raise exception using errcode = '42501', message = 'You do not have permission to maintain Staff Master.';
  end if;
end;
$$;

create or replace function public.enforce_staff_master_write_permission()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_action text;
begin
  -- Trusted database maintenance and service operations do not carry an end
  -- user identity. Signed-in application RPC calls always carry auth.uid().
  if auth.uid() is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_action := 'CREATE';
  elsif new.active is distinct from old.active
     or new.production_staff is distinct from old.production_staff
     or new.deleted_at is distinct from old.deleted_at then
    v_action := 'MANAGE';
  else
    v_action := 'EDIT';
  end if;

  if not public.staff_master_action_allowed(v_action) then
    raise exception using
      errcode = '42501',
      message = format('Your account does not have %s permission for Staff Master.', initcap(lower(v_action)));
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_staff_master_write_permission on public.staff_members;
create trigger enforce_staff_master_write_permission
before insert or update on public.staff_members
for each row execute function public.enforce_staff_master_write_permission();

revoke all on function public.staff_master_action_allowed(text) from public, anon, authenticated;
revoke all on function public.enforce_staff_master_write_permission() from public, anon, authenticated;
revoke all on function public.require_staff_master_read_role() from public, anon, authenticated;
revoke all on function public.require_staff_master_manage_role() from public, anon, authenticated;

comment on function public.staff_master_action_allowed(text) is
  'Internal action-level authorization for Staff Master with legacy-role fallback only for accounts not yet migrated to explicit grants.';
comment on function public.enforce_staff_master_write_permission() is
  'Enforces CREATE, EDIT or MANAGE Staff Master permission for authenticated writes to staff_members.';
