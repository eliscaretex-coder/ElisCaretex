-- =====================================================================
-- ElisCaretex V2
-- Roster: republishing a week clears daily routes it no longer plans
--
-- Found in review (2026-10-19): a published week can now be edited and
-- published again. Publishing updated the daily route of every planned
-- entry but left untouched the routes the new version no longer plans, so
-- a driver set to Off kept showing on the Daily board (READY, old driver
-- and vehicle). From today onwards, a DRAFT or READY daily route that the
-- new version does not plan goes back to DRAFT with no driver or vehicle.
-- Dispatched, in-progress, completed and cancelled routes are not touched.
-- =====================================================================

begin;

create or replace function public.publish_distribution_roster_week(p_roster_version_id uuid, p_expected_row_version integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_roster public.distribution_roster_versions%rowtype;
  v_conflict record;
  v_entry public.distribution_roster_entries%rowtype;
  v_run_id uuid;
begin
  perform public.require_distribution_plan_access();

  select * into v_roster
  from public.distribution_roster_versions
  where distribution_roster_version_id = p_roster_version_id
  for update;

  if not found or v_roster.roster_status <> 'DRAFT' then
    raise exception using errcode = '22023', message = 'Only an existing Distribution roster draft can be published.';
  end if;
  if p_expected_row_version is not null and v_roster.row_version <> p_expected_row_version then
    raise exception using errcode = '40001', message = 'This roster was changed by another user. Reload it before publishing.';
  end if;
  if exists (
    select 1
    from public.distribution_roster_entries e
    where e.distribution_roster_version_id = p_roster_version_id
      and e.assignment_status = 'PLANNED'
      and (e.route_id is null or e.primary_driver_id is null or e.vehicle_id is null)
  ) then
    raise exception using errcode = '22023', message = 'Every planned route needs a primary driver, Route and Vehicle before publishing.';
  end if;

  perform public.validate_distribution_roster_version(p_roster_version_id);

  select r.business_date, r.run_id into v_conflict
  from public.distribution_roster_entries e
  join public.distribution_route_runs r
    on r.business_date = e.work_date
   and r.route_id = e.route_id
  where e.distribution_roster_version_id = p_roster_version_id
    and e.assignment_status = 'PLANNED'
    and r.run_status not in ('DRAFT', 'READY')
    and (
      r.primary_driver_id is distinct from e.primary_driver_id
      or r.support_driver_id is distinct from e.support_driver_id
      or r.vehicle_id is distinct from e.vehicle_id
    )
  limit 1;
  if found then
    raise exception using errcode = '22023', message = format('Roster cannot replace the operational run on %s.', v_conflict.business_date);
  end if;

  update public.distribution_roster_versions
  set roster_status = 'SUPERSEDED', updated_by = auth.uid(), row_version = row_version + 1
  where week_start = v_roster.week_start and roster_status = 'PUBLISHED';

  update public.distribution_roster_versions
  set roster_status = 'PUBLISHED', published_at = now(), published_by = auth.uid(),
      updated_by = auth.uid(), row_version = row_version + 1
  where distribution_roster_version_id = p_roster_version_id
  returning * into v_roster;

  -- Daily routes the new version no longer plans: free their driver and vehicle.
  with cleared as (
    update public.distribution_route_runs r
    set run_status = 'DRAFT', primary_driver_id = null, support_driver_id = null, vehicle_id = null,
        updated_by = auth.uid(), row_version = r.row_version + 1
    where r.business_date between v_roster.week_start and v_roster.week_start + 6
      and r.business_date >= current_date
      and r.run_status in ('DRAFT', 'READY')
      and (r.run_status = 'READY' or r.primary_driver_id is not null or r.support_driver_id is not null or r.vehicle_id is not null)
      and not exists (
        select 1 from public.distribution_roster_entries e
        where e.distribution_roster_version_id = p_roster_version_id
          and e.assignment_status = 'PLANNED'
          and e.work_date = r.business_date
          and e.route_id = r.route_id
      )
    returning r.run_id
  )
  insert into public.distribution_run_events(run_id, event_type, event_payload, recorded_by)
  select run_id, 'ROSTER_REMOVED', jsonb_build_object('distribution_roster_version_id', p_roster_version_id), auth.uid()
  from cleared;

  for v_entry in
    select *
    from public.distribution_roster_entries
    where distribution_roster_version_id = p_roster_version_id
      and assignment_status = 'PLANNED'
    order by work_date, route_code_snapshot
  loop
    insert into public.distribution_route_runs(
      business_date, route_id, run_status, primary_driver_id, support_driver_id,
      vehicle_id, dispatch_notes, created_by, updated_by
    )
    values (
      v_entry.work_date, v_entry.route_id, 'READY', v_entry.primary_driver_id,
      v_entry.support_driver_id, v_entry.vehicle_id, v_entry.entry_note,
      auth.uid(), auth.uid()
    )
    on conflict (business_date, route_id) do update
    set run_status = 'READY',
        primary_driver_id = excluded.primary_driver_id,
        support_driver_id = excluded.support_driver_id,
        vehicle_id = excluded.vehicle_id,
        dispatch_notes = excluded.dispatch_notes,
        updated_by = auth.uid(),
        row_version = public.distribution_route_runs.row_version + 1
    where public.distribution_route_runs.run_status in ('DRAFT', 'READY')
    returning run_id into v_run_id;

    if v_run_id is null then
      select run_id into v_run_id
      from public.distribution_route_runs
      where business_date = v_entry.work_date and route_id = v_entry.route_id;
    end if;

    perform public.sync_distribution_route_run_stops(v_run_id);
    insert into public.distribution_run_events(run_id, event_type, event_payload, recorded_by)
    values (
      v_run_id,
      'ROSTER_PUBLISHED',
      jsonb_build_object('distribution_roster_version_id', p_roster_version_id),
      auth.uid()
    );
    v_run_id := null;
  end loop;

  insert into public.distribution_roster_events(
    distribution_roster_version_id, event_type, event_payload, recorded_by
  )
  values (
    p_roster_version_id,
    'PUBLISHED',
    jsonb_build_object('published_at', v_roster.published_at),
    auth.uid()
  );

  return public.get_distribution_roster_week(v_roster.week_start, p_roster_version_id);
end;
$$;

revoke all on function public.publish_distribution_roster_week(uuid, integer) from public, anon;
grant execute on function public.publish_distribution_roster_week(uuid, integer) to authenticated;

commit;
