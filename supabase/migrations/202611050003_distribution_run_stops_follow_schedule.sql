-- Distribution route runs: the stop list follows the published customer schedule.
--
-- Problem (checked 05/11/2026): sync_distribution_route_run_stops only inserted or updated
-- stops. When a customer schedule got a new version, its delivery days got new ids, so the
-- run kept the stop of the old version and added a second one for the new version. Route 617
-- on 06/11 showed "Stops 0/18" for 11 customers, and the driver saw 7 customers twice in My
-- Driver Roster. 41 duplicate stops were waiting in the runs from 05/11 onwards. A customer
-- moved to another route or removed from the day also stayed on the run.
--
-- Change:
--   1. sync_distribution_route_run_stops removes scheduled stops that are still PLANNED and
--      are no longer in the schedule for that day and route. Stops already reported
--      (Loaded, Delivered, Skipped...) and manual stops are never removed, and a customer
--      that already has a reported stop on the run is not added a second time.
--   2. When a customer schedule version is published, superseded, cancelled or has its dates
--      changed, the Draft/Ready runs from today onwards are synchronised again, so the
--      driver's list matches the schedule without republishing the roster. Errors there never
--      block the schedule change (warning only).
--   3. One-off: the Draft/Ready runs from today onwards are synchronised now.

create or replace function public.sync_distribution_route_run_stops(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare v_run public.distribution_route_runs%rowtype;
begin
  select * into v_run from public.distribution_route_runs where run_id = p_run_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'Distribution route run was not found.'; end if;
  if v_run.run_status not in ('DRAFT','READY') then
    raise exception using errcode = '22023', message = 'Only Draft or Ready runs can be synchronized with the published schedule.';
  end if;

  -- Stops of an older schedule version, or of a customer no longer on this route and day.
  delete from public.distribution_route_run_stops s
  where s.run_id = p_run_id
    and s.stop_kind = 'SCHEDULED'
    and s.stop_status = 'PLANNED'
    and not exists (
      select 1 from public.distribution_source_stops(v_run.business_date, v_run.route_id) x
      where x.source_schedule_day_id = s.source_schedule_day_id
    );

  insert into public.distribution_route_run_stops (
    run_id, source_schedule_day_id, customer_id, stop_kind, stop_order, customer_code_snapshot,
    customer_name_snapshot, eircode_snapshot, delivery_window_start, delivery_window_end,
    planned_product_codes, planned_trolley_total, planned_trolley_summary, estimated_kg,
    stop_units, distribution_instructions, created_by, updated_by
  )
  select p_run_id, s.source_schedule_day_id, s.customer_id, 'SCHEDULED',
    coalesce(s.source_delivery_order, 10000), s.customer_code, s.customer_name, s.eircode,
    s.delivery_window_start, s.delivery_window_end, s.planned_product_codes,
    s.planned_trolley_total, s.planned_trolley_summary, s.estimated_kg, s.stop_units,
    concat_ws(E'\n', s.distribution_instructions, s.day_alert), auth.uid(), auth.uid()
  from public.distribution_source_stops(v_run.business_date, v_run.route_id) s
  -- A customer whose stop was already reported keeps that stop only.
  where not exists (
    select 1 from public.distribution_route_run_stops r
    where r.run_id = p_run_id and r.stop_kind = 'SCHEDULED' and r.customer_id = s.customer_id
      and r.stop_status <> 'PLANNED' and r.source_schedule_day_id is distinct from s.source_schedule_day_id
  )
  on conflict (run_id, source_schedule_day_id) where source_schedule_day_id is not null do update set
    stop_order = excluded.stop_order,
    customer_code_snapshot = excluded.customer_code_snapshot,
    customer_name_snapshot = excluded.customer_name_snapshot,
    eircode_snapshot = excluded.eircode_snapshot,
    delivery_window_start = excluded.delivery_window_start,
    delivery_window_end = excluded.delivery_window_end,
    planned_product_codes = excluded.planned_product_codes,
    planned_trolley_total = excluded.planned_trolley_total,
    planned_trolley_summary = excluded.planned_trolley_summary,
    estimated_kg = excluded.estimated_kg,
    stop_units = excluded.stop_units,
    distribution_instructions = excluded.distribution_instructions,
    updated_by = auth.uid(), row_version = public.distribution_route_run_stops.row_version + 1
  where public.distribution_route_run_stops.stop_status = 'PLANNED';
end;
$$;

revoke all on function public.sync_distribution_route_run_stops(uuid) from public, anon, authenticated;

-- Internal: synchronise every Draft/Ready run from today onwards. Never raises.
create or replace function public.distribution_resync_open_runs()
returns integer
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare v_run_id uuid; v_count integer := 0;
begin
  for v_run_id in
    select run_id from public.distribution_route_runs
    where business_date >= current_date and run_status in ('DRAFT','READY')
    order by business_date, route_id
  loop
    begin
      perform public.sync_distribution_route_run_stops(v_run_id);
      v_count := v_count + 1;
    exception when others then
      raise warning 'Distribution run % could not be synchronised with the schedule: %', v_run_id, sqlerrm;
    end;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.distribution_resync_open_runs() from public, anon, authenticated;

create or replace function public.customer_schedule_versions_resync_distribution_runs()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.distribution_resync_open_runs();
  return null;
exception when others then
  raise warning 'Distribution runs were not synchronised after the schedule change: %', sqlerrm;
  return null;
end;
$$;

revoke all on function public.customer_schedule_versions_resync_distribution_runs() from public, anon, authenticated;

drop trigger if exists customer_schedule_versions_resync_distribution_runs on public.customer_schedule_versions;
create trigger customer_schedule_versions_resync_distribution_runs
after insert or update of status, effective_from, effective_until on public.customer_schedule_versions
for each statement execute function public.customer_schedule_versions_resync_distribution_runs();

-- One-off clean-up of the runs from today onwards.
select public.distribution_resync_open_runs();
