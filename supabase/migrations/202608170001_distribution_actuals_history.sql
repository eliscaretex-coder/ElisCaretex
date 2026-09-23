-- =====================================================================
-- ElisCaretex V2
-- Distribution weekly actual hours and vehicle mileage history
-- =====================================================================

begin;

create table if not exists public.distribution_driver_weekly_actuals (
  actual_id uuid primary key default gen_random_uuid(),
  week_start date not null,
  driver_id uuid not null references public.distribution_drivers(driver_id) on delete restrict,
  planned_hours numeric(8,2) not null default 0,
  actual_hours numeric(8,2) not null,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint distribution_driver_weekly_actuals_week_check check (week_start = public.distribution_roster_week_start(week_start)),
  constraint distribution_driver_weekly_actuals_hours_check check (planned_hours >= 0 and actual_hours >= 0),
  constraint distribution_driver_weekly_actuals_unique unique (week_start, driver_id)
);

create table if not exists public.distribution_vehicle_weekly_mileage (
  mileage_id uuid primary key default gen_random_uuid(),
  week_start date not null,
  vehicle_id uuid not null references public.fleet_vehicles(vehicle_id) on delete restrict,
  planned_km numeric(12,1) not null default 0,
  actual_km numeric(12,1) not null,
  odometer_km numeric(12,1),
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint distribution_vehicle_weekly_mileage_week_check check (week_start = public.distribution_roster_week_start(week_start)),
  constraint distribution_vehicle_weekly_mileage_km_check check (planned_km >= 0 and actual_km >= 0 and (odometer_km is null or odometer_km >= 0)),
  constraint distribution_vehicle_weekly_mileage_unique unique (week_start, vehicle_id)
);

alter table public.distribution_driver_weekly_actuals enable row level security;
alter table public.distribution_vehicle_weekly_mileage enable row level security;
revoke all on table public.distribution_driver_weekly_actuals, public.distribution_vehicle_weekly_mileage from public, anon, authenticated;

drop trigger if exists distribution_driver_weekly_actuals_set_updated_at on public.distribution_driver_weekly_actuals;
create trigger distribution_driver_weekly_actuals_set_updated_at before update on public.distribution_driver_weekly_actuals for each row execute function public.set_updated_at();

drop trigger if exists distribution_vehicle_weekly_mileage_set_updated_at on public.distribution_vehicle_weekly_mileage;
create trigger distribution_vehicle_weekly_mileage_set_updated_at before update on public.distribution_vehicle_weekly_mileage for each row execute function public.set_updated_at();

create index if not exists distribution_driver_weekly_actuals_week_idx on public.distribution_driver_weekly_actuals(week_start desc, driver_id);
create index if not exists distribution_vehicle_weekly_mileage_week_idx on public.distribution_vehicle_weekly_mileage(week_start desc, vehicle_id);

create or replace function public.get_distribution_actuals_week(p_week_start date)
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
declare
  v_week_start date := public.distribution_roster_week_start(p_week_start);
  v_roster_id uuid;
begin
  perform public.require_distribution_read_access();
  if p_week_start is null or p_week_start <> v_week_start then
    raise exception using errcode = '22023', message = 'Select a Monday as the Distribution actuals week start.';
  end if;

  select distribution_roster_version_id into v_roster_id
  from public.distribution_roster_versions
  where week_start = v_week_start and roster_status in ('DRAFT', 'PUBLISHED')
  order by case roster_status when 'PUBLISHED' then 0 else 1 end, version_number desc
  limit 1;

  return jsonb_build_object(
    'week_start', v_week_start,
    'week_end', v_week_start + 6,
    'can_manage', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'drivers', coalesce((
      with planned as (
        select e.primary_driver_id as driver_id,
          sum(case when e.assignment_status = 'TRAINING' then 8 else coalesce(r.default_hours, 0) end)::numeric(8,2) as planned_hours
        from public.distribution_roster_entries e
        left join public.distribution_routes r on r.route_id = e.route_id
        where e.distribution_roster_version_id = v_roster_id and e.primary_driver_id is not null
        group by e.primary_driver_id
      )
      select jsonb_agg(jsonb_build_object(
        'driver_id', d.driver_id,
        'driver_code', d.driver_code,
        'display_name', d.display_name,
        'planned_hours', coalesce(p.planned_hours, 0),
        'actual_hours', a.actual_hours,
        'notes', a.notes,
        'updated_at', a.updated_at
      ) order by d.display_name)
      from public.distribution_drivers d
      left join planned p on p.driver_id = d.driver_id
      left join public.distribution_driver_weekly_actuals a on a.week_start = v_week_start and a.driver_id = d.driver_id
      where d.deleted_at is null and d.employment_status = 'ACTIVE'
    ), '[]'::jsonb),
    'vehicles', coalesce((
      with planned as (
        select e.vehicle_id,
          sum(coalesce(r.default_km, 0))::numeric(12,1) as planned_km
        from public.distribution_roster_entries e
        left join public.distribution_routes r on r.route_id = e.route_id
        where e.distribution_roster_version_id = v_roster_id and e.assignment_status = 'PLANNED' and e.vehicle_id is not null
        group by e.vehicle_id
      )
      select jsonb_agg(jsonb_build_object(
        'vehicle_id', v.vehicle_id,
        'registration_number', v.registration_number,
        'display_name', v.display_name,
        'vehicle_type', v.vehicle_type,
        'planned_km', coalesce(p.planned_km, 0),
        'actual_km', m.actual_km,
        'odometer_km', coalesce(m.odometer_km, v.odometer_km),
        'current_odometer_km', v.odometer_km,
        'notes', m.notes,
        'updated_at', m.updated_at
      ) order by v.registration_number)
      from public.fleet_vehicles v
      left join planned p on p.vehicle_id = v.vehicle_id
      left join public.distribution_vehicle_weekly_mileage m on m.week_start = v_week_start and m.vehicle_id = v.vehicle_id
      where v.deleted_at is null and v.active
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.save_distribution_actuals_week(p_week_start date, p_driver_actuals jsonb default '[]'::jsonb, p_vehicle_mileage jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare
  v_week_start date := public.distribution_roster_week_start(p_week_start);
  v_item jsonb;
  v_driver_count integer := 0;
  v_vehicle_count integer := 0;
  v_vehicle_id uuid;
  v_odometer numeric(12,1);
begin
  perform public.require_distribution_plan_access();
  if p_week_start is null or p_week_start <> v_week_start then
    raise exception using errcode = '22023', message = 'Select a Monday as the Distribution actuals week start.';
  end if;
  if jsonb_typeof(coalesce(p_driver_actuals, '[]'::jsonb)) <> 'array' or jsonb_typeof(coalesce(p_vehicle_mileage, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = '22023', message = 'Distribution actuals must be arrays.';
  end if;

  for v_item in select value from jsonb_array_elements(coalesce(p_driver_actuals, '[]'::jsonb)) loop
    if nullif(v_item ->> 'actual_hours', '') is null then continue; end if;
    if nullif(v_item ->> 'driver_id', '') is null then raise exception using errcode = '22023', message = 'Driver actual hours require a driver.'; end if;
    if (v_item ->> 'actual_hours')::numeric < 0 then raise exception using errcode = '22023', message = 'Actual hours cannot be negative.'; end if;
    insert into public.distribution_driver_weekly_actuals(week_start, driver_id, planned_hours, actual_hours, notes, created_by, updated_by)
    values (v_week_start, (v_item ->> 'driver_id')::uuid, coalesce(nullif(v_item ->> 'planned_hours','')::numeric, 0), (v_item ->> 'actual_hours')::numeric, nullif(v_item ->> 'notes',''), auth.uid(), auth.uid())
    on conflict (week_start, driver_id) do update set
      planned_hours = excluded.planned_hours,
      actual_hours = excluded.actual_hours,
      notes = excluded.notes,
      updated_by = auth.uid(),
      row_version = public.distribution_driver_weekly_actuals.row_version + 1;
    v_driver_count := v_driver_count + 1;
  end loop;

  for v_item in select value from jsonb_array_elements(coalesce(p_vehicle_mileage, '[]'::jsonb)) loop
    if nullif(v_item ->> 'actual_km', '') is null and nullif(v_item ->> 'odometer_km', '') is null then continue; end if;
    if nullif(v_item ->> 'vehicle_id', '') is null then raise exception using errcode = '22023', message = 'Vehicle mileage requires a vehicle.'; end if;
    if coalesce(nullif(v_item ->> 'actual_km','')::numeric, 0) < 0 then raise exception using errcode = '22023', message = 'Actual KM cannot be negative.'; end if;
    v_vehicle_id := (v_item ->> 'vehicle_id')::uuid;
    v_odometer := nullif(v_item ->> 'odometer_km','')::numeric;
    insert into public.distribution_vehicle_weekly_mileage(week_start, vehicle_id, planned_km, actual_km, odometer_km, notes, created_by, updated_by)
    values (v_week_start, v_vehicle_id, coalesce(nullif(v_item ->> 'planned_km','')::numeric, 0), coalesce(nullif(v_item ->> 'actual_km','')::numeric, 0), v_odometer, nullif(v_item ->> 'notes',''), auth.uid(), auth.uid())
    on conflict (week_start, vehicle_id) do update set
      planned_km = excluded.planned_km,
      actual_km = excluded.actual_km,
      odometer_km = excluded.odometer_km,
      notes = excluded.notes,
      updated_by = auth.uid(),
      row_version = public.distribution_vehicle_weekly_mileage.row_version + 1;
    if v_odometer is not null then
      update public.fleet_vehicles set odometer_km = v_odometer, updated_by = auth.uid(), row_version = row_version + 1 where vehicle_id = v_vehicle_id;
    end if;
    v_vehicle_count := v_vehicle_count + 1;
  end loop;

  insert into public.distribution_master_events(entity_table, entity_id, event_type, event_payload, recorded_by)
  values ('distribution_actuals', v_week_start::text, 'ACTUALS_SAVED', jsonb_build_object('driver_rows', v_driver_count, 'vehicle_rows', v_vehicle_count), auth.uid());

  return public.get_distribution_actuals_week(v_week_start);
end;
$$;

create or replace function public.get_distribution_activity_history(p_from date default null, p_to date default null, p_limit integer default 250)
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
declare
  v_from date := coalesce(p_from, current_date - 90);
  v_to date := coalesce(p_to, current_date + 30);
  v_limit integer := least(greatest(coalesce(p_limit, 250), 1), 500);
begin
  perform public.require_distribution_read_access();
  return jsonb_build_object(
    'range_from', v_from,
    'range_to', v_to,
    'events', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.event_at desc)
      from (
        select
          'Roster'::text as source,
          e.event_type,
          e.event_at,
          e.recorded_by,
          rv.week_start,
          rv.version_number,
          rv.roster_status,
          case
            when e.event_type = 'DRAFT_CREATED' then format('Week %s draft created', rv.week_start)
            when e.event_type = 'DRAFT_SAVED' then format('Week %s draft saved with %s entries', rv.week_start, coalesce(e.event_payload ->> 'entry_count', '0'))
            when e.event_type = 'PUBLISHED' then format('Week %s published as version %s', rv.week_start, rv.version_number)
            else format('Roster week %s: %s', rv.week_start, e.event_type)
          end as summary
        from public.distribution_roster_events e
        join public.distribution_roster_versions rv on rv.distribution_roster_version_id = e.distribution_roster_version_id
        where e.event_at::date between v_from and v_to
        union all
        select
          'Daily route'::text as source,
          e.event_type,
          e.event_at,
          e.recorded_by,
          r.business_date as week_start,
          null::integer as version_number,
          r.run_status as roster_status,
          format('%s on %s: %s', coalesce(dr.display_name, dr.route_code, 'Route'), r.business_date, e.event_type) as summary
        from public.distribution_run_events e
        join public.distribution_route_runs r on r.run_id = e.run_id
        left join public.distribution_routes dr on dr.route_id = r.route_id
        where e.event_at::date between v_from and v_to
        union all
        select
          'Actual hours'::text as source,
          'HOURS_SAVED'::text as event_type,
          a.updated_at as event_at,
          a.updated_by as recorded_by,
          a.week_start,
          null::integer as version_number,
          'ACTUALS'::text as roster_status,
          format('%s: %s actual hours, planned %s', d.display_name, a.actual_hours, a.planned_hours) as summary
        from public.distribution_driver_weekly_actuals a
        join public.distribution_drivers d on d.driver_id = a.driver_id
        where a.updated_at::date between v_from and v_to
        union all
        select
          'Vehicle mileage'::text as source,
          'MILEAGE_SAVED'::text as event_type,
          m.updated_at as event_at,
          m.updated_by as recorded_by,
          m.week_start,
          null::integer as version_number,
          'MILEAGE'::text as roster_status,
          format('%s: %s actual KM, odometer %s', v.registration_number, m.actual_km, coalesce(m.odometer_km::text, 'not recorded')) as summary
        from public.distribution_vehicle_weekly_mileage m
        join public.fleet_vehicles v on v.vehicle_id = m.vehicle_id
        where m.updated_at::date between v_from and v_to
        union all
        select
          'Master data'::text as source,
          e.event_type,
          e.event_at,
          e.recorded_by,
          null::date as week_start,
          null::integer as version_number,
          e.entity_table as roster_status,
          format('%s %s: %s', e.entity_table, e.event_type, e.entity_id) as summary
        from public.distribution_master_events e
        where e.event_at::date between v_from and v_to
        order by event_at desc
        limit v_limit
      ) x
    ), '[]'::jsonb),
    'roster_versions', coalesce((
      select jsonb_agg(to_jsonb(rv) order by rv.week_start desc, rv.version_number desc)
      from public.distribution_roster_versions rv
      where rv.created_at::date between v_from and v_to or coalesce(rv.published_at, rv.created_at)::date between v_from and v_to
      limit v_limit
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_distribution_actuals_week(date), public.save_distribution_actuals_week(date,jsonb,jsonb) from public, anon;
grant execute on function public.get_distribution_actuals_week(date), public.save_distribution_actuals_week(date,jsonb,jsonb) to authenticated;

comment on table public.distribution_driver_weekly_actuals is 'Weekly actual driver hours for Distribution, kept separate from planned roster hours.';
comment on table public.distribution_vehicle_weekly_mileage is 'Weekly actual vehicle mileage and odometer readings for Distribution fleet history.';

commit;
