-- =====================================================================
-- ElisCaretex V2
-- Fleet: dated off-road periods, return to service and vehicle metrics
--
-- Owner decisions (2026-10-19):
-- * Expired compliance documents only warn; they never block a vehicle.
-- * Every reported defect and every maintenance has an expected return
--   date. While a vehicle is off road (an OFF_ROAD defect or a planned or
--   in-progress maintenance), it cannot be selected in the roster or on a
--   daily route, from the start date until the day before the expected
--   return date.
-- * A vehicle comes back only when someone records the return in Fleet
--   (Return to service, or closing the defect / completing the
--   maintenance). An overdue return keeps blocking today until then.
-- * Fleet shows per-vehicle metrics: defects and days off road.
-- =====================================================================

begin;

-- Columns that already exist on ElisCaretex-dev from the CentralDB import
-- (2026-08-17) but that no migration declared.
alter table public.fleet_vehicle_defects add column if not exists expected_return_on date;
alter table public.fleet_vehicle_defects add column if not exists repair_date date;
alter table public.fleet_vehicle_defects add column if not exists vehicle_status_snapshot text;
alter table public.fleet_vehicle_maintenance add column if not exists repair_date date;

alter table public.fleet_vehicle_defects add column if not exists vehicle_condition text;
alter table public.fleet_vehicle_defects add column if not exists returned_on date;
alter table public.fleet_vehicle_maintenance add column if not exists expected_return_on date;
alter table public.fleet_vehicle_maintenance add column if not exists returned_on date;

-- Imported defects keep the condition the old system recorded.
update public.fleet_vehicle_defects
set vehicle_condition = case
  when lower(coalesce(vehicle_status_snapshot, '')) like 'out of service%' then 'OFF_ROAD'
  when lower(coalesce(vehicle_status_snapshot, '')) like 'restricted%' then 'RESTRICTED'
  else 'ROADWORTHY' end
where vehicle_condition is null;

update public.fleet_vehicle_defects
set returned_on = coalesce(repair_date, closed_at::date)
where returned_on is null and defect_status in ('CLOSED', 'CANCELLED');

update public.fleet_vehicle_maintenance
set expected_return_on = coalesce(ends_on, starts_on) + 1
where expected_return_on is null;

update public.fleet_vehicle_maintenance
set returned_on = coalesce(repair_date, completed_at::date, ends_on + 1, starts_on + 1)
where returned_on is null and maintenance_status = 'COMPLETED';

alter table public.fleet_vehicle_defects alter column vehicle_condition set default 'ROADWORTHY';
alter table public.fleet_vehicle_defects alter column vehicle_condition set not null;
alter table public.fleet_vehicle_defects drop constraint if exists fleet_vehicle_defects_condition_check;
alter table public.fleet_vehicle_defects add constraint fleet_vehicle_defects_condition_check
  check (vehicle_condition in ('ROADWORTHY', 'RESTRICTED', 'OFF_ROAD'));
alter table public.fleet_vehicle_maintenance drop constraint if exists fleet_vehicle_maintenance_return_check;
alter table public.fleet_vehicle_maintenance add constraint fleet_vehicle_maintenance_return_check
  check ((expected_return_on is null or expected_return_on > starts_on) and (returned_on is null or returned_on >= starts_on));

create index if not exists fleet_vehicle_defects_open_idx
  on public.fleet_vehicle_defects(vehicle_id) where defect_status in ('OPEN', 'IN_REPAIR');
create index if not exists fleet_vehicle_maintenance_open_idx
  on public.fleet_vehicle_maintenance(vehicle_id) where maintenance_status in ('PLANNED', 'IN_PROGRESS');

-- One rule for "can this vehicle work on this date?", used by the roster,
-- the daily route plan and the Fleet screen. Returns null when it can.
create or replace function public.distribution_vehicle_block_reason(p_vehicle_id uuid, p_work_date date)
returns text
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v public.fleet_vehicles%rowtype;
  v_item record;
begin
  select * into v from public.fleet_vehicles where vehicle_id = p_vehicle_id and deleted_at is null;
  if v.vehicle_id is null then return 'Vehicle not found'; end if;
  if not v.active then return 'Inactive vehicle'; end if;
  if coalesce(v.operational_status, '') <> 'AVAILABLE' then
    return case v.operational_status when 'MAINTENANCE' then 'In maintenance' else 'Out of service' end
      || ' (set in the vehicle record)';
  end if;

  select * into v_item from (
    select 'Off road: '||d.defect_category as label, d.reported_on::date as starts_on, d.expected_return_on
    from public.fleet_vehicle_defects d
    where d.vehicle_id = p_vehicle_id and d.defect_status in ('OPEN', 'IN_REPAIR') and d.vehicle_condition = 'OFF_ROAD'
    union all
    select 'In maintenance: '||m.maintenance_type, m.starts_on, m.expected_return_on
    from public.fleet_vehicle_maintenance m
    where m.vehicle_id = p_vehicle_id and m.maintenance_status in ('PLANNED', 'IN_PROGRESS')
  ) x
  where x.starts_on <= p_work_date
    and (x.expected_return_on is null
      or p_work_date < x.expected_return_on
      or (p_work_date = current_date and current_date >= x.expected_return_on))
  order by x.expected_return_on nulls first
  limit 1;

  if found then
    if v_item.expected_return_on is null then return v_item.label||' (no return date)'; end if;
    if p_work_date >= v_item.expected_return_on then
      return v_item.label||', return overdue since '||to_char(v_item.expected_return_on, 'DD Mon')||'. Record the return in Fleet';
    end if;
    return v_item.label||', back '||to_char(v_item.expected_return_on, 'DD Mon');
  end if;
  return null;
end;
$$;

revoke all on function public.distribution_vehicle_block_reason(uuid, date) from public, anon, authenticated;

-- Published roster days (today onwards) that use a vehicle while it is blocked.
create or replace function public.fleet_vehicle_roster_conflicts(p_vehicle_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'work_date', e.work_date, 'route_code', e.route_code_snapshot, 'driver_name', e.primary_driver_name_snapshot,
    'reason', public.distribution_vehicle_block_reason(e.vehicle_id, e.work_date)
  ) order by e.work_date, e.route_code_snapshot), '[]'::jsonb)
  from public.distribution_roster_entries e
  join public.distribution_roster_versions r on r.distribution_roster_version_id = e.distribution_roster_version_id
  where r.roster_status = 'PUBLISHED' and e.assignment_status = 'PLANNED' and e.vehicle_id = p_vehicle_id
    and e.work_date >= current_date
    and public.distribution_vehicle_block_reason(e.vehicle_id, e.work_date) is not null;
$$;

revoke all on function public.fleet_vehicle_roster_conflicts(uuid) from public, anon, authenticated;

-- Defects and maintenance in the last 12 months.
create or replace function public.fleet_vehicle_metrics(p_vehicle_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  with w as (select current_date - 365 as from_date),
  d as (
    select d.vehicle_condition, d.reported_on::date as period_start,
      case when d.defect_status in ('OPEN', 'IN_REPAIR') then current_date else coalesce(d.returned_on, d.repair_date, d.closed_at::date, d.reported_on::date) end as period_end
    from public.fleet_vehicle_defects d where d.vehicle_id = p_vehicle_id and d.defect_status <> 'CANCELLED'
  ),
  m as (
    select m.starts_on as period_start,
      case when m.maintenance_status = 'COMPLETED' then coalesce(m.returned_on, m.expected_return_on, m.starts_on + 1)
           when m.starts_on <= current_date then current_date else m.starts_on end as period_end
    from public.fleet_vehicle_maintenance m where m.vehicle_id = p_vehicle_id and m.maintenance_status <> 'CANCELLED'
  )
  select jsonb_build_object(
    'from_date', (select from_date from w),
    'defects_12m', (select count(*) from d, w where d.period_start >= w.from_date),
    'defects_total', (select count(*) from d),
    'off_road_defects_12m', (select count(*) from d, w where d.period_start >= w.from_date and d.vehicle_condition = 'OFF_ROAD'),
    'off_road_days_12m', (select coalesce(sum(greatest(0, least(d.period_end, current_date) - greatest(d.period_start, w.from_date))), 0) from d, w where d.vehicle_condition = 'OFF_ROAD'),
    'maintenance_12m', (select count(*) from m, w where m.period_start >= w.from_date and m.period_start <= current_date),
    'maintenance_days_12m', (select coalesce(sum(greatest(0, least(m.period_end, current_date) - greatest(m.period_start, w.from_date))), 0) from m, w),
    'last_defect_on', (select max(d.period_start) from d),
    'rostered_days_12m', (
      select count(distinct e.work_date) from public.distribution_roster_entries e
      join public.distribution_roster_versions r on r.distribution_roster_version_id = e.distribution_roster_version_id, w
      where r.roster_status = 'PUBLISHED' and e.assignment_status = 'PLANNED' and e.vehicle_id = p_vehicle_id
        and e.work_date between w.from_date and current_date),
    'actual_km_12m', (select coalesce(sum(k.actual_km), 0) from public.distribution_vehicle_weekly_mileage k, w where k.vehicle_id = p_vehicle_id and k.week_start >= w.from_date)
  );
$$;

revoke all on function public.fleet_vehicle_metrics(uuid) from public, anon, authenticated;

create or replace function public.get_fleet_vehicle_master()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_distribution_read_access();
  return coalesce((
    select jsonb_agg(
      to_jsonb(f) || jsonb_build_object(
        'open_defect_count', (
          select count(*) from public.fleet_vehicle_defects fd
          where fd.vehicle_id = f.vehicle_id and fd.defect_status in ('OPEN','IN_REPAIR')
        ),
        'unavailable_today', case when f.active then public.distribution_vehicle_block_reason(f.vehicle_id, current_date) end,
        'open_items', coalesce((
          select jsonb_agg(i order by i ->> 'starts_on') from (
            select jsonb_build_object('kind', 'DEFECT', 'item_id', d.defect_id, 'title', d.defect_category, 'detail', d.description,
              'severity', d.severity, 'vehicle_condition', d.vehicle_condition, 'status', d.defect_status,
              'starts_on', d.reported_on::date, 'expected_return_on', d.expected_return_on, 'closure_notes', d.closure_notes,
              'row_version', d.row_version, 'blocks', d.vehicle_condition = 'OFF_ROAD') as i
            from public.fleet_vehicle_defects d where d.vehicle_id = f.vehicle_id and d.defect_status in ('OPEN','IN_REPAIR')
            union all
            select jsonb_build_object('kind', 'MAINTENANCE', 'item_id', m.maintenance_id, 'title', m.maintenance_type,
              'detail', coalesce(m.supplier_name, m.notes), 'status', m.maintenance_status, 'starts_on', m.starts_on,
              'expected_return_on', m.expected_return_on, 'supplier_name', m.supplier_name, 'cost_amount', m.cost_amount,
              'notes', m.notes, 'row_version', m.row_version, 'blocks', true)
            from public.fleet_vehicle_maintenance m where m.vehicle_id = f.vehicle_id and m.maintenance_status in ('PLANNED','IN_PROGRESS')
          ) items
        ), '[]'::jsonb),
        'metrics', public.fleet_vehicle_metrics(f.vehicle_id)
      ) order by f.active desc, f.registration_number)
    from public.fleet_vehicles f
    where f.deleted_at is null
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.get_fleet_vehicle_master() from public, anon;
grant execute on function public.get_fleet_vehicle_master() to authenticated;

-- Full defect and maintenance history of one vehicle, with its metrics.
create or replace function public.get_fleet_vehicle_history(p_vehicle_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_distribution_read_access();
  if not exists (select 1 from public.fleet_vehicles where vehicle_id = p_vehicle_id and deleted_at is null) then
    raise exception using errcode = 'P0002', message = 'Vehicle was not found.';
  end if;
  return jsonb_build_object(
    'vehicle_id', p_vehicle_id,
    'metrics', public.fleet_vehicle_metrics(p_vehicle_id),
    'items', coalesce((
      select jsonb_agg(i order by i ->> 'starts_on' desc) from (
        select jsonb_build_object('kind', 'DEFECT', 'item_id', d.defect_id, 'title', d.defect_category, 'detail', d.description,
          'severity', d.severity, 'vehicle_condition', d.vehicle_condition, 'status', d.defect_status,
          'starts_on', d.reported_on::date, 'expected_return_on', d.expected_return_on,
          'returned_on', coalesce(d.returned_on, d.repair_date), 'notes', d.closure_notes) as i
        from public.fleet_vehicle_defects d where d.vehicle_id = p_vehicle_id
        union all
        select jsonb_build_object('kind', 'MAINTENANCE', 'item_id', m.maintenance_id, 'title', m.maintenance_type,
          'detail', coalesce(m.supplier_name, m.defect_description), 'status', m.maintenance_status, 'starts_on', m.starts_on,
          'expected_return_on', m.expected_return_on, 'returned_on', m.returned_on, 'notes', m.notes,
          'cost_amount', m.cost_amount)
        from public.fleet_vehicle_maintenance m where m.vehicle_id = p_vehicle_id
      ) items
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_fleet_vehicle_history(uuid) from public, anon;
grant execute on function public.get_fleet_vehicle_history(uuid) to authenticated;

create or replace function public.save_fleet_vehicle_defect(p_defect jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid := nullif(p_defect ->> 'defect_id','')::uuid;
  v_existing public.fleet_vehicle_defects%rowtype;
  v_vehicle uuid;
  v_status text := upper(coalesce(nullif(p_defect ->> 'defect_status',''),'OPEN'));
  v_condition text := upper(coalesce(nullif(p_defect ->> 'vehicle_condition',''),'ROADWORTHY'));
  v_reported date := coalesce(nullif(p_defect ->> 'reported_on','')::date, current_date);
  v_expected date := nullif(p_defect ->> 'expected_return_on','')::date;
  v_returned date := nullif(p_defect ->> 'returned_on','')::date;
  v_result public.fleet_vehicle_defects%rowtype;
begin
  perform public.require_distribution_master_access();
  if v_id is not null then
    select * into v_existing from public.fleet_vehicle_defects where defect_id = v_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'Defect was not found.'; end if;
    if nullif(p_defect ->> 'row_version','') is not null and (p_defect ->> 'row_version')::integer <> v_existing.row_version then
      raise exception using errcode = '40001', message = 'This defect was changed by someone else. Reload and try again.';
    end if;
  end if;
  v_vehicle := coalesce(v_existing.vehicle_id, nullif(p_defect ->> 'vehicle_id','')::uuid);
  if v_vehicle is null or not exists (select 1 from public.fleet_vehicles where vehicle_id = v_vehicle and deleted_at is null) then
    raise exception using errcode = '22023', message = 'Choose the vehicle.';
  end if;
  if coalesce(trim(p_defect ->> 'defect_category'),'') = '' or coalesce(trim(p_defect ->> 'description'),'') = '' then
    raise exception using errcode = '22023', message = 'Category and description are required.';
  end if;
  if v_condition not in ('ROADWORTHY','RESTRICTED','OFF_ROAD') then
    raise exception using errcode = '22023', message = 'Choose whether the vehicle can still be used.';
  end if;
  if v_status in ('OPEN','IN_REPAIR') and v_expected is null then
    raise exception using errcode = '22023', message = 'Enter the expected return date.';
  end if;
  if v_expected is not null and v_expected < v_reported then
    raise exception using errcode = '22023', message = 'The expected return date cannot be before the report date.';
  end if;
  if v_status = 'CLOSED' then
    v_returned := coalesce(v_returned, current_date);
    if v_returned < v_reported then raise exception using errcode = '22023', message = 'The return date cannot be before the report date.'; end if;
  elsif v_status in ('OPEN','IN_REPAIR') then
    v_returned := null;
  end if;

  insert into public.fleet_vehicle_defects(defect_id,vehicle_id,reported_on,severity,defect_category,description,defect_status,vehicle_condition,expected_return_on,returned_on,closure_notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),v_vehicle,
    case when v_existing.defect_id is not null and v_existing.reported_on::date = v_reported then v_existing.reported_on
         when v_reported = current_date then now() else v_reported::timestamptz end,
    upper(coalesce(nullif(p_defect ->> 'severity',''),'MEDIUM')),trim(p_defect ->> 'defect_category'),trim(p_defect ->> 'description'),
    v_status,v_condition,v_expected,v_returned,nullif(trim(p_defect ->> 'closure_notes'),''),auth.uid(),auth.uid())
  on conflict (defect_id) do update set
    reported_on=excluded.reported_on,severity=excluded.severity,defect_category=excluded.defect_category,description=excluded.description,
    defect_status=excluded.defect_status,vehicle_condition=excluded.vehicle_condition,expected_return_on=excluded.expected_return_on,
    returned_on=excluded.returned_on,closure_notes=excluded.closure_notes,
    closed_at=case when excluded.defect_status='CLOSED' then coalesce(public.fleet_vehicle_defects.closed_at, now()) when excluded.defect_status in ('OPEN','IN_REPAIR') then null else public.fleet_vehicle_defects.closed_at end,
    closed_by=case when excluded.defect_status='CLOSED' then coalesce(public.fleet_vehicle_defects.closed_by, auth.uid()) when excluded.defect_status in ('OPEN','IN_REPAIR') then null else public.fleet_vehicle_defects.closed_by end,
    updated_by=auth.uid(),row_version=public.fleet_vehicle_defects.row_version+1
  returning * into v_result;

  return to_jsonb(v_result) || jsonb_build_object('roster_conflicts', public.fleet_vehicle_roster_conflicts(v_result.vehicle_id));
end;
$$;

revoke all on function public.save_fleet_vehicle_defect(jsonb) from public, anon;
grant execute on function public.save_fleet_vehicle_defect(jsonb) to authenticated;

create or replace function public.save_fleet_vehicle_maintenance(p_maintenance jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid := nullif(p_maintenance ->> 'maintenance_id','')::uuid;
  v_existing public.fleet_vehicle_maintenance%rowtype;
  v_vehicle uuid;
  v_status text := upper(coalesce(nullif(p_maintenance ->> 'maintenance_status',''),'PLANNED'));
  v_starts date := nullif(p_maintenance ->> 'starts_on','')::date;
  v_expected date := nullif(p_maintenance ->> 'expected_return_on','')::date;
  v_returned date := nullif(p_maintenance ->> 'returned_on','')::date;
  v_result public.fleet_vehicle_maintenance%rowtype;
begin
  perform public.require_distribution_master_access();
  if v_id is not null then
    select * into v_existing from public.fleet_vehicle_maintenance where maintenance_id = v_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'Maintenance was not found.'; end if;
    if nullif(p_maintenance ->> 'row_version','') is not null and (p_maintenance ->> 'row_version')::integer <> v_existing.row_version then
      raise exception using errcode = '40001', message = 'This maintenance was changed by someone else. Reload and try again.';
    end if;
  end if;
  v_vehicle := coalesce(v_existing.vehicle_id, nullif(p_maintenance ->> 'vehicle_id','')::uuid);
  if v_vehicle is null or not exists (select 1 from public.fleet_vehicles where vehicle_id = v_vehicle and deleted_at is null) then
    raise exception using errcode = '22023', message = 'Choose the vehicle.';
  end if;
  if coalesce(trim(p_maintenance ->> 'maintenance_type'),'') = '' then
    raise exception using errcode = '22023', message = 'Enter the maintenance type.';
  end if;
  if v_starts is null then raise exception using errcode = '22023', message = 'Enter the start date.'; end if;
  if v_status not in ('PLANNED','IN_PROGRESS','COMPLETED','CANCELLED') then
    raise exception using errcode = '22023', message = 'Unknown maintenance status.';
  end if;
  if v_status in ('PLANNED','IN_PROGRESS') and v_expected is null then
    raise exception using errcode = '22023', message = 'Enter the expected return date.';
  end if;
  if v_expected is not null and v_expected <= v_starts then
    raise exception using errcode = '22023', message = 'The expected return date must be after the start date (the vehicle is off road from the start date until the day before it returns).';
  end if;
  if v_status = 'COMPLETED' then
    v_returned := coalesce(v_returned, current_date);
    if v_returned < v_starts then raise exception using errcode = '22023', message = 'The return date cannot be before the start date.'; end if;
  elsif v_status in ('PLANNED','IN_PROGRESS') then
    v_returned := null;
  end if;

  insert into public.fleet_vehicle_maintenance(maintenance_id,vehicle_id,maintenance_type,maintenance_status,starts_on,ends_on,expected_return_on,returned_on,supplier_name,cost_amount,notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),v_vehicle,trim(p_maintenance ->> 'maintenance_type'),v_status,v_starts,
    greatest(v_starts, coalesce(v_returned, v_expected, v_starts + 1) - 1),v_expected,v_returned,
    nullif(trim(p_maintenance ->> 'supplier_name'),''),nullif(p_maintenance ->> 'cost_amount','')::numeric,nullif(trim(p_maintenance ->> 'notes'),''),auth.uid(),auth.uid())
  on conflict (maintenance_id) do update set
    maintenance_type=excluded.maintenance_type,maintenance_status=excluded.maintenance_status,starts_on=excluded.starts_on,ends_on=excluded.ends_on,
    expected_return_on=excluded.expected_return_on,returned_on=excluded.returned_on,supplier_name=excluded.supplier_name,
    cost_amount=excluded.cost_amount,notes=excluded.notes,
    completed_at=case when excluded.maintenance_status='COMPLETED' then coalesce(public.fleet_vehicle_maintenance.completed_at, now()) when excluded.maintenance_status in ('PLANNED','IN_PROGRESS') then null else public.fleet_vehicle_maintenance.completed_at end,
    completed_by=case when excluded.maintenance_status='COMPLETED' then coalesce(public.fleet_vehicle_maintenance.completed_by, auth.uid()) when excluded.maintenance_status in ('PLANNED','IN_PROGRESS') then null else public.fleet_vehicle_maintenance.completed_by end,
    updated_by=auth.uid(),row_version=public.fleet_vehicle_maintenance.row_version+1
  returning * into v_result;

  return to_jsonb(v_result) || jsonb_build_object('roster_conflicts', public.fleet_vehicle_roster_conflicts(v_result.vehicle_id));
end;
$$;

revoke all on function public.save_fleet_vehicle_maintenance(jsonb) from public, anon;
grant execute on function public.save_fleet_vehicle_maintenance(jsonb) to authenticated;

-- The one place a vehicle comes back: closes its open off-road defects and
-- completes its started maintenance on the return date.
create or replace function public.return_fleet_vehicle_to_service(p_vehicle_id uuid, p_returned_on date default current_date, p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_returned date := coalesce(p_returned_on, current_date);
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_vehicle public.fleet_vehicles%rowtype;
  v_defects integer;
  v_maintenance integer;
begin
  perform public.require_distribution_master_access();
  select * into v_vehicle from public.fleet_vehicles where vehicle_id = p_vehicle_id and deleted_at is null for update;
  if not found then raise exception using errcode = 'P0002', message = 'Vehicle was not found.'; end if;
  if not v_vehicle.active then raise exception using errcode = '22023', message = 'This vehicle is inactive. Reactivate it in Edit first.'; end if;
  if v_returned > current_date then raise exception using errcode = '22023', message = 'The return date cannot be in the future.'; end if;

  update public.fleet_vehicle_defects
  set defect_status = 'CLOSED', returned_on = greatest(v_returned, reported_on::date), closed_at = now(), closed_by = auth.uid(),
      closure_notes = coalesce(closure_notes || E'\n', '') || coalesce(v_notes, 'Returned to service'),
      updated_by = auth.uid(), row_version = row_version + 1
  where vehicle_id = p_vehicle_id and defect_status in ('OPEN','IN_REPAIR') and vehicle_condition = 'OFF_ROAD' and reported_on::date <= v_returned;
  get diagnostics v_defects = row_count;

  update public.fleet_vehicle_maintenance
  set maintenance_status = 'COMPLETED', returned_on = greatest(v_returned, starts_on), ends_on = greatest(starts_on, v_returned - 1),
      completed_at = now(), completed_by = auth.uid(),
      notes = case when v_notes is null then notes else coalesce(notes || E'\n', '') || v_notes end,
      updated_by = auth.uid(), row_version = row_version + 1
  where vehicle_id = p_vehicle_id and maintenance_status in ('PLANNED','IN_PROGRESS') and starts_on <= v_returned;
  get diagnostics v_maintenance = row_count;

  if v_vehicle.operational_status <> 'AVAILABLE' then
    update public.fleet_vehicles set operational_status = 'AVAILABLE', updated_by = auth.uid(), row_version = row_version + 1
    where vehicle_id = p_vehicle_id;
  end if;

  return jsonb_build_object(
    'vehicle_id', p_vehicle_id, 'registration_number', v_vehicle.registration_number,
    'closed_defects', v_defects, 'completed_maintenance', v_maintenance,
    'unavailable_today', public.distribution_vehicle_block_reason(p_vehicle_id, current_date)
  );
end;
$$;

revoke all on function public.return_fleet_vehicle_to_service(uuid, date, text) from public, anon;
grant execute on function public.return_fleet_vehicle_to_service(uuid, date, text) to authenticated;

-- Roster validation: vehicle checks use the dated rule and apply from today
-- onwards (past days are history). Driver checks are unchanged.
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
  order by e.work_date limit 1;
  if found then raise exception using errcode = '22023', message = format('Vehicle %s cannot be used on %s: %s.', v_conflict.registration_number, to_char(v_conflict.work_date, 'Dy DD Mon'), v_conflict.reason); end if;
end;
$$;

revoke all on function public.validate_distribution_roster_version(uuid) from public, anon, authenticated;

-- Roster week: adds the blocked vehicle days so the picker can show them.
create or replace function public.get_distribution_roster_week(p_week_start date, p_roster_version_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.distribution_roster_week_start(p_week_start);
  v_roster public.distribution_roster_versions%rowtype;
begin
  perform public.require_distribution_read_access();
  if p_week_start is null or p_week_start <> v_week_start then
    raise exception using errcode = '22023', message = 'The Distribution roster must start on a Monday.';
  end if;
  if p_roster_version_id is not null then
    select * into v_roster from public.distribution_roster_versions where distribution_roster_version_id = p_roster_version_id and week_start = v_week_start;
  else
    select * into v_roster from public.distribution_roster_versions where week_start = v_week_start and roster_status in ('DRAFT', 'PUBLISHED') order by case roster_status when 'DRAFT' then 0 else 1 end, version_number desc limit 1;
  end if;
  return jsonb_build_object(
    'week_start', v_week_start, 'week_end', v_week_start + 6,
    'can_manage', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'is_past', v_week_start + 6 < current_date,
    'document', case when v_roster.distribution_roster_version_id is null then null else to_jsonb(v_roster) end,
    'required_routes', coalesce(v_roster.required_routes, '{}'::jsonb),
    'routes', coalesce((select jsonb_agg(to_jsonb(r) order by r.sort_order, r.route_code) from public.distribution_routes r where r.active and r.deleted_at is null), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(to_jsonb(d) order by d.display_name) from public.distribution_drivers d where d.deleted_at is null and d.employment_status = 'ACTIVE'), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v) order by v.registration_number) from public.fleet_vehicles v where v.deleted_at is null and v.active), '[]'::jsonb),
    'vehicle_blocks', coalesce((
      select jsonb_agg(jsonb_build_object('vehicle_id', b.vehicle_id, 'work_date', b.work_date, 'reason', b.reason) order by b.work_date)
      from (
        select v.vehicle_id, days.work_date, public.distribution_vehicle_block_reason(v.vehicle_id, days.work_date) as reason
        from public.fleet_vehicles v
        cross join (select generate_series(v_week_start, v_week_start + 6, interval '1 day')::date as work_date) days
        where v.deleted_at is null and v.active and days.work_date >= current_date
      ) b where b.reason is not null
    ), '[]'::jsonb),
    'absences', coalesce((select jsonb_agg(to_jsonb(a) order by a.starts_on, a.driver_id) from public.distribution_driver_absences a where a.absence_status = 'APPROVED' and a.starts_on <= v_week_start + 6 and a.ends_on >= v_week_start), '[]'::jsonb),
    'entries', coalesce((select jsonb_agg(to_jsonb(e) order by e.work_date, e.route_code_snapshot) from public.distribution_roster_entries e where e.distribution_roster_version_id = v_roster.distribution_roster_version_id), '[]'::jsonb),
    'daily_metrics', coalesce((
      with days as (select generate_series(v_week_start, v_week_start + 6, interval '1 day')::date as work_date),
      demand as (
        select days.work_date, count(distinct d.default_route_id)::integer as scheduled_routes, count(d.schedule_day_id)::integer as scheduled_stops
        from days left join public.customer_schedule_versions sv on sv.status='PUBLISHED' and sv.effective_from <= days.work_date and (sv.effective_until is null or sv.effective_until >= days.work_date)
        left join public.customer_schedule_days d on d.schedule_version_id=sv.schedule_version_id and d.active and d.delivery_weekday=extract(isodow from days.work_date)::smallint and d.default_route_id is not null
        group by days.work_date
      )
      select jsonb_agg(jsonb_build_object('work_date',work_date,'scheduled_routes',scheduled_routes,'scheduled_stops',scheduled_stops) order by work_date) from demand
    ), '[]'::jsonb),
    'route_day_metrics', coalesce((
      with days as (select generate_series(v_week_start, v_week_start + 6, interval '1 day')::date as work_date)
      select jsonb_agg(jsonb_build_object('route_id',r.route_id,'work_date',days.work_date,'stops',coalesce(s.stop_count,0),'km',r.default_km,'hours',r.default_hours) order by days.work_date,r.sort_order,r.route_code)
      from public.distribution_routes r cross join days
      left join lateral (
        select count(d.schedule_day_id)::integer as stop_count
        from public.customer_schedule_versions sv join public.customer_schedule_days d on d.schedule_version_id=sv.schedule_version_id and d.active
        where sv.status='PUBLISHED' and sv.effective_from <= days.work_date and (sv.effective_until is null or sv.effective_until >= days.work_date)
          and d.default_route_id=r.route_id and d.delivery_weekday=extract(isodow from days.work_date)::smallint
      ) s on true
      where r.active and r.deleted_at is null
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_distribution_roster_week(date, uuid) from public, anon;
grant execute on function public.get_distribution_roster_week(date, uuid) to authenticated;

-- Daily route plan: the same dated vehicle rule as the roster.
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
  if v_vehicle is not null then
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
