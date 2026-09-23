-- Sorting terminals can operate the MOP workspace without a linked personal Staff record.
-- MOP Types remains governed by its own ADMIN / MANAGER checks.

create or replace function public.begin_mop_operational_scope()
returns void
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_sorting_terminal boolean := false;
begin
  if auth.uid() is null
     or not public.has_any_role(array[
       'ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR','MOP_OPERATOR'
     ]) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow access to MOP Production.';
  end if;

  v_sorting_terminal := coalesce(
    public.production_station_device_context('SORTING')->>'device_code',
    ''
  ) <> '';

  if public.current_staff_id() is null and not v_sorting_terminal then
    raise exception using
      errcode='42501',
      message='MOP Production requires an active staff account or a registered Sorting terminal.';
  end if;

  perform set_config('eliscaretex.mop_operational_scope','on',true);
end;
$$;

revoke all on function public.begin_mop_operational_scope() from public,anon;

comment on function public.begin_mop_operational_scope() is
  'Authorizes MOP operational RPCs for allowed staff roles or an active Sorting terminal. MOP type maintenance remains ADMIN/MANAGER only.';
