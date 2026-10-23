-- =====================================================================
-- ElisCaretex V2
-- Close the orphan Distribution Roster RPCs and apply the driver
-- reinstatement fix that never reached the database
--
-- 1. The live database still holds a second Distribution Roster write path
--    (save_distribution_roster_draft / publish_distribution_roster(date,text)
--    and helpers). It came from a migration applied outside this repository
--    (distribution_roster_driver_matrix_corrected_20260817), the frontend no
--    longer calls it, and it allowed PLANNER and ROSTER_MANAGER to publish
--    a Distribution Roster without the fixes of 202610170002, 202610190007
--    and 202610190008. The current path (save/publish_distribution_roster_week)
--    is gated by require_distribution_plan_access. Execution is revoked here
--    rather than dropping the functions, so nothing is lost.
--    The functions only call each other, always as SECURITY DEFINER.
--
-- 2. 202610190004_driver_reinstate_keeps_scheduled_status.sql is committed
--    but the live reinstate_distribution_driver still forced ACTIVE /
--    AVAILABLE. The function below is that file's definition, unchanged.
-- =====================================================================

begin;

do $$
declare
  v_fn regprocedure;
begin
  for v_fn in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (
        (p.proname = 'publish_distribution_roster'
          and pg_get_function_identity_arguments(p.oid) = 'p_week_start date, p_change_reason text')
        or p.proname in (
          'save_distribution_roster_draft',
          'get_distribution_roster_context',
          'get_distribution_roster_history',
          'require_distribution_roster_read_access',
          'require_distribution_roster_manage_access',
          'distribution_route_valid_on_date'
        )
      )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_fn);
  end loop;
end;
$$;

create or replace function public.reinstate_distribution_driver(
  p_driver_id uuid,
  p_expected_row_version integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before public.distribution_drivers%rowtype;
  v_driver public.distribution_drivers%rowtype;
  v_staff_updated boolean := false;
begin
  perform public.require_distribution_master_access();

  if nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason for the reinstatement is required.';
  end if;

  select d.* into v_before
  from public.distribution_drivers d
  where d.driver_id = p_driver_id and d.deleted_at is null
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Driver was not found.';
  end if;
  if p_expected_row_version is not null and v_before.row_version <> p_expected_row_version then
    raise exception using errcode = '40001', message = 'This driver was changed by someone else. Reload and try again.';
  end if;
  if v_before.employment_status <> 'INACTIVE' and v_before.deactivated_on is null then
    raise exception using errcode = '22023', message = 'This driver has no recorded exit.';
  end if;

  -- A scheduled exit that has not taken effect keeps the driver's current
  -- employment and availability (for example SUSPENDED). Only a driver who has
  -- actually left is made ACTIVE and AVAILABLE again.
  update public.distribution_drivers d set
    employment_status = case when v_before.employment_status = 'INACTIVE' then 'ACTIVE' else d.employment_status end,
    availability_status = case when v_before.employment_status = 'INACTIVE' then 'AVAILABLE' else d.availability_status end,
    deactivated_on = null,
    deactivation_reason = null,
    exit_recorded_at = null,
    exit_recorded_by = null,
    updated_at = now(),
    updated_by = auth.uid(),
    row_version = d.row_version + 1
  where d.driver_id = p_driver_id
  returning * into v_driver;

  if v_driver.staff_id is not null then
    update public.staff_members sm set
      active = true,
      deactivated_on = null,
      deactivation_reason = null,
      updated_by = auth.uid(),
      row_version = sm.row_version + 1
    where sm.staff_id = v_driver.staff_id
      and sm.deleted_at is null
      and not sm.production_staff
      and sm.deactivation_reason like 'Driver exit:%';
    v_staff_updated := found;
  end if;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
  values (
    auth.uid(), public.current_staff_id(), 'REINSTATE_DISTRIBUTION_DRIVER',
    'distribution_drivers', p_driver_id::text, to_jsonb(v_before), to_jsonb(v_driver), trim(p_reason), 'DISTRIBUTION_UI'
  );

  return jsonb_build_object('driver', to_jsonb(v_driver), 'staff_access_updated', v_staff_updated);
end;
$$;

revoke all on function public.reinstate_distribution_driver(uuid,integer,text) from public, anon;
grant execute on function public.reinstate_distribution_driver(uuid,integer,text) to authenticated;

commit;
