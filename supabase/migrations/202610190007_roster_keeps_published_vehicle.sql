-- =====================================================================
-- ElisCaretex V2
-- Roster: keep a published vehicle assignment that is now off road
--
-- Owner report (2026-10-19): after 202610190005 the weekly roster could not
-- be saved at all, because one published day (route 612 today) uses a
-- vehicle that became off road. Saving re-validates the whole week, so any
-- edit failed. A blocked vehicle still cannot be newly chosen, but a day
-- already published with it is kept and only flagged in the roster, so the
-- planner can reassign it when convenient. The daily route plan follows
-- the same rule for the vehicle a route already has.
-- =====================================================================

begin;

create or replace function public.validate_distribution_roster_version(p_roster_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare v_conflict record;
begin
  select a.work_date, a.driver_id into v_conflict from (
    select work_date, primary_driver_id as driver_id from public.distribution_roster_entries where distribution_roster_version_id = p_roster_version_id and primary_driver_id is not null
    union all select work_date, support_driver_id from public.distribution_roster_entries where distribution_roster_version_id = p_roster_version_id and assignment_status = 'PLANNED' and support_driver_id is not null
  ) a group by a.work_date, a.driver_id having count(*) > 1 limit 1;
  if found then raise exception using errcode = '23505', message = format('A driver has more than one roster state on %s.', v_conflict.work_date); end if;

  select e.work_date, e.vehicle_id into v_conflict from public.distribution_roster_entries e join public.fleet_vehicles v on v.vehicle_id = e.vehicle_id
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED' and e.vehicle_id is not null
  group by e.work_date, e.vehicle_id, v.vehicle_type having count(*) > case when v.vehicle_type = 'VAN' then 2 else 1 end limit 1;
  if found then raise exception using errcode = '23505', message = format('This vehicle exceeds its daily route limit on %s.', v_conflict.work_date); end if;

  select e.work_date, d.display_name into v_conflict from public.distribution_roster_entries e
  join lateral (values (e.primary_driver_id), (e.support_driver_id)) x(driver_id) on x.driver_id is not null
  join public.distribution_drivers d on d.driver_id = x.driver_id
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED'
    and (d.deleted_at is not null or d.employment_status <> 'ACTIVE' or d.availability_status <> 'AVAILABLE') limit 1;
  if found then raise exception using errcode = '22023', message = format('Driver %s is not available for the roster.', v_conflict.display_name); end if;

  select e.work_date, d.display_name into v_conflict from public.distribution_roster_entries e
  join lateral (values (e.primary_driver_id), (e.support_driver_id)) x(driver_id) on x.driver_id is not null
  join public.distribution_drivers d on d.driver_id = x.driver_id
  join public.distribution_driver_absences a on a.driver_id = d.driver_id and a.absence_status = 'APPROVED' and e.work_date between a.starts_on and a.ends_on
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED' limit 1;
  if found then raise exception using errcode = '22023', message = format('Driver %s has approved leave on %s.', v_conflict.display_name, v_conflict.work_date); end if;

  select e.work_date, e.vehicle_registration_snapshot as registration_number, public.distribution_vehicle_block_reason(e.vehicle_id, e.work_date) as reason
  into v_conflict
  from public.distribution_roster_entries e
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED' and e.vehicle_id is not null
    and e.work_date >= current_date
    and public.distribution_vehicle_block_reason(e.vehicle_id, e.work_date) is not null
    -- An assignment already in the published roster stays; the roster warns on it instead.
    and not exists (
      select 1 from public.distribution_roster_entries p
      join public.distribution_roster_versions pv on pv.distribution_roster_version_id = p.distribution_roster_version_id
      join public.distribution_roster_versions cv on cv.distribution_roster_version_id = e.distribution_roster_version_id
      where pv.roster_status = 'PUBLISHED' and pv.week_start = cv.week_start
        and pv.distribution_roster_version_id <> e.distribution_roster_version_id
        and p.assignment_status = 'PLANNED' and p.work_date = e.work_date
        and p.route_id is not distinct from e.route_id and p.vehicle_id = e.vehicle_id
    )
  order by e.work_date limit 1;
  if found then raise exception using errcode = '22023', message = format('Vehicle %s cannot be used on %s: %s.', v_conflict.registration_number, to_char(v_conflict.work_date, 'Dy DD Mon'), v_conflict.reason); end if;
end;
$$;

revoke all on function public.validate_distribution_roster_version(uuid) from public, anon, authenticated;

-- Daily route plan: the same rule for the vehicle a route already has.
create or replace function public.save_distribution_route_run(p_run jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare v_id uuid := nullif(p_run ->> 'run_id','')::uuid; v_date date := (p_run ->> 'business_date')::date;
  v_route uuid := (p_run ->> 'route_id')::uuid; v_primary uuid := nullif(p_run ->> 'primary_driver_id','')::uuid;
  v_support uuid := nullif(p_run ->> 'support_driver_id','')::uuid; v_vehicle uuid := nullif(p_run ->> 'vehicle_id','')::uuid;
  v_status text := upper(coalesce(nullif(p_run ->> 'run_status',''), 'DRAFT')); v_run_id uuid; v_expected integer := nullif(p_run ->> 'row_version','')::integer;
  v_vehicle_block text;
begin
  perform public.require_distribution_plan_access();
  if v_date is null or extract(isodow from v_date) = 7 then raise exception using errcode = '22023', message = 'Choose a valid Distribution operating date.'; end if;
  if v_status not in ('DRAFT','READY') then raise exception using errcode = '22023', message = 'Use the dispatch action to change an operational route status.'; end if;
  if v_primary is not null and v_primary = v_support then raise exception using errcode = '22023', message = 'Primary and support driver must be different.'; end if;
  if not exists (select 1 from public.distribution_routes where route_id = v_route and active and deleted_at is null) then raise exception using errcode = '22023', message = 'Choose an active Route.'; end if;
  if v_primary is not null and not exists (select 1 from public.distribution_drivers where driver_id = v_primary and deleted_at is null and employment_status = 'ACTIVE' and availability_status = 'AVAILABLE') then raise exception using errcode = '22023', message = 'The selected primary driver is unavailable.'; end if;
  if v_support is not null and not exists (select 1 from public.distribution_drivers where driver_id = v_support and deleted_at is null and employment_status = 'ACTIVE' and availability_status = 'AVAILABLE') then raise exception using errcode = '22023', message = 'The selected support driver is unavailable.'; end if;
  -- The vehicle the route already has (from the published roster) can stay; only a new choice is checked.
  if v_vehicle is not null and not exists (select 1 from public.distribution_route_runs x where x.business_date = v_date and x.route_id = v_route and x.vehicle_id = v_vehicle) then
    v_vehicle_block := public.distribution_vehicle_block_reason(v_vehicle, v_date);
    if v_vehicle_block is not null then raise exception using errcode = '22023', message = 'The selected vehicle cannot be used on this date: '||v_vehicle_block||'.'; end if;
  end if;
  if exists (select 1 from public.distribution_driver_absences a where a.absence_status = 'APPROVED' and v_date between a.starts_on and a.ends_on and a.driver_id in (v_primary, v_support)) then raise exception using errcode = '22023', message = 'A selected driver has approved leave on this date.'; end if;
  if exists (select 1 from public.distribution_route_runs x where x.business_date = v_date and x.run_id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid) and x.run_status not in ('CANCELLED','COMPLETED') and (x.vehicle_id = v_vehicle and v_vehicle is not null or x.primary_driver_id in (v_primary,v_support) or x.support_driver_id in (v_primary,v_support))) then raise exception using errcode = '23505', message = 'The selected driver or vehicle is already allocated to another active Route.'; end if;
  insert into public.distribution_route_runs(run_id,business_date,route_id,run_status,primary_driver_id,support_driver_id,vehicle_id,dispatch_notes,created_by,updated_by)
  values (coalesce(v_id,gen_random_uuid()),v_date,v_route,v_status,v_primary,v_support,v_vehicle,nullif(p_run ->> 'dispatch_notes',''),auth.uid(),auth.uid())
  on conflict (business_date,route_id) do update set
    primary_driver_id=excluded.primary_driver_id, support_driver_id=excluded.support_driver_id, vehicle_id=excluded.vehicle_id,
    run_status=excluded.run_status, dispatch_notes=excluded.dispatch_notes, updated_by=auth.uid(), row_version=public.distribution_route_runs.row_version+1
  where v_expected is null or public.distribution_route_runs.row_version = v_expected
  returning run_id into v_run_id;
  if v_run_id is null then raise exception using errcode = '40001', message = 'This Route changed in another session. Refresh before saving again.'; end if;
  perform public.sync_distribution_route_run_stops(v_run_id);
  insert into public.distribution_run_events(run_id,event_type,event_payload,recorded_by) values (v_run_id,'RUN_SAVED',jsonb_build_object('status',v_status),auth.uid());
  return public.get_distribution_route_run_detail(v_run_id);
end;
$$;

revoke all on function public.save_distribution_route_run(jsonb) from public, anon;
grant execute on function public.save_distribution_route_run(jsonb) to authenticated;

commit;
