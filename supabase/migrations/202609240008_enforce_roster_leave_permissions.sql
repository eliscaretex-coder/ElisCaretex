-- Enforce action-level permissions for Production Roster and leave governance.

create or replace function public.production_roster_action_allowed(p_action text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare v_uses_explicit_permissions boolean;
begin
  if auth.uid() is null then return false; end if;
  select exists(select 1 from public.account_permission_grants g where g.auth_user_id=auth.uid())
    into v_uses_explicit_permissions;
  if v_uses_explicit_permissions then
    return public.has_account_permission('PRODUCTION_ROSTER',p_action,'PRODUCTION');
  end if;
  if upper(trim(p_action))='VIEW' then
    return public.has_any_role(array['ADMIN','MANAGER','ROSTER_MANAGER','SUPERVISOR','AUDITOR']);
  end if;
  if upper(trim(p_action)) in ('CREATE','EDIT','APPROVE') then
    return public.has_any_role(array['ADMIN','MANAGER','ROSTER_MANAGER','SUPERVISOR']);
  end if;
  return public.has_any_role(array['ADMIN','MANAGER','ROSTER_MANAGER']);
end;
$$;

create or replace function public.require_production_roster_manage_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.production_roster_action_allowed('EDIT') then
    raise exception using errcode='42501',message='You do not have permission to edit the Production Roster.';
  end if;
end;
$$;

create or replace function public.enforce_production_leave_request_permission()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare v_own_staff_id uuid:=public.current_staff_id();
begin
  if auth.uid() is null then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;
  if tg_op='INSERT' then
    if not ((new.staff_id=v_own_staff_id and public.has_account_permission('LEAVE','CREATE','OWN'))
      or public.production_roster_action_allowed('CREATE')) then
      raise exception using errcode='42501',message='You do not have permission to submit this leave request.';
    end if;
    return new;
  end if;
  if tg_op='DELETE' then
    if not public.production_roster_action_allowed('MANAGE') then
      raise exception using errcode='42501',message='Manage permission is required to delete a leave request.';
    end if;
    return old;
  end if;
  if new.status is distinct from old.status
     or new.reviewed_at is distinct from old.reviewed_at
     or new.reviewed_by is distinct from old.reviewed_by
     or new.decision_source is distinct from old.decision_source then
    if not public.production_roster_action_allowed('APPROVE') then
      raise exception using errcode='42501',message='Approve permission is required to decide a leave request.';
    end if;
  elsif not ((new.staff_id=v_own_staff_id and public.has_account_permission('LEAVE','EDIT','OWN'))
      or public.production_roster_action_allowed('EDIT')) then
    raise exception using errcode='42501',message='You do not have permission to edit this leave request.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_production_leave_request_permission on public.production_roster_leave_requests;
create trigger enforce_production_leave_request_permission
before insert or update or delete on public.production_roster_leave_requests
for each row execute function public.enforce_production_leave_request_permission();

create or replace function public.enforce_production_leave_gm_permission()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is not null and not public.production_roster_action_allowed('APPROVE') then
    raise exception using errcode='42501',message='Approve permission is required for General Manager leave review.';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

drop trigger if exists enforce_production_leave_gm_permission on public.production_roster_leave_gm_reviews;
create trigger enforce_production_leave_gm_permission
before insert or update or delete on public.production_roster_leave_gm_reviews
for each row execute function public.enforce_production_leave_gm_permission();

create or replace function public.enforce_production_leave_settings_permission()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is not null
     and coalesce(new.config_key,old.config_key)='PRODUCTION_ROSTER_LEAVE_GOVERNANCE'
     and not public.production_roster_action_allowed('MANAGE') then
    raise exception using errcode='42501',message='Manage permission is required to change leave approval settings.';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

drop trigger if exists enforce_production_leave_settings_permission on public.app_config;
create trigger enforce_production_leave_settings_permission
before insert or update or delete on public.app_config
for each row execute function public.enforce_production_leave_settings_permission();

revoke all on function public.production_roster_action_allowed(text) from public,anon,authenticated;
revoke all on function public.enforce_production_leave_request_permission() from public,anon,authenticated;
revoke all on function public.enforce_production_leave_gm_permission() from public,anon,authenticated;
revoke all on function public.enforce_production_leave_settings_permission() from public,anon,authenticated;
revoke all on function public.require_production_roster_manage_role() from public,anon,authenticated;

comment on function public.production_roster_action_allowed(text) is 'Internal action-level authorization for Production Roster.';
