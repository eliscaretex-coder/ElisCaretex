-- =====================================================================
-- ElisCaretex V2
-- Distribution driver roster matrix and planning metrics
-- Requires: 202608130005 and 202608130006
-- =====================================================================

begin;

alter table public.distribution_routes
  add column if not exists default_km numeric(12,1) not null default 0,
  add column if not exists default_hours numeric(8,2) not null default 0;

alter table public.distribution_roster_versions
  add column if not exists required_routes jsonb not null default '{}'::jsonb;

alter table public.distribution_roster_entries
  alter column route_id drop not null,
  alter column route_code_snapshot drop not null,
  alter column route_name_snapshot drop not null,
  drop constraint if exists distribution_roster_entries_status_check,
  drop constraint if exists distribution_roster_entries_route_day_unique,
  drop constraint if exists distribution_roster_entries_route_or_status_check,
  add constraint distribution_roster_entries_status_check check (assignment_status in ('PLANNED','OFF','HOLIDAY','TRAINING','ABSENT','SICK')),
  add constraint distribution_roster_entries_route_or_status_check check ((assignment_status = 'PLANNED' and route_id is not null) or (assignment_status <> 'PLANNED' and primary_driver_id is not null));

create unique index if not exists distribution_roster_entries_route_day_unique
  on public.distribution_roster_entries(distribution_roster_version_id, work_date, route_id)
  where route_id is not null;

create unique index if not exists distribution_roster_entries_primary_driver_day_unique
  on public.distribution_roster_entries(distribution_roster_version_id, work_date, primary_driver_id)
  where primary_driver_id is not null;

create table if not exists public.distribution_master_events (
  event_id uuid primary key default gen_random_uuid(),
  entity_table text not null,
  entity_id text not null,
  event_type text not null,
  event_payload jsonb not null default '{}'::jsonb,
  event_at timestamptz not null default now(),
  recorded_by uuid references auth.users(id) on delete set null
);

alter table public.distribution_master_events enable row level security;
revoke all on table public.distribution_master_events from public, anon, authenticated;

create or replace function public.record_distribution_master_event()
returns trigger language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare
  v_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_id text := coalesce(
    v_row ->> 'driver_id',
    v_row ->> 'vehicle_id',
    v_row ->> 'route_id',
    v_row ->> 'maintenance_id',
    v_row ->> 'defect_id',
    v_row ->> 'absence_id',
    v_row ->> 'registration_number',
    v_row ->> 'driver_code',
    v_row ->> 'route_code',
    ''
  );
begin
  insert into public.distribution_master_events(entity_table, entity_id, event_type, event_payload, recorded_by)
  values (tg_table_name, v_id, tg_op, jsonb_build_object('old', case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end, 'new', case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end), auth.uid());
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists distribution_drivers_master_event on public.distribution_drivers;
create trigger distribution_drivers_master_event after insert or update or delete on public.distribution_drivers for each row execute function public.record_distribution_master_event();

drop trigger if exists fleet_vehicles_master_event on public.fleet_vehicles;
create trigger fleet_vehicles_master_event after insert or update or delete on public.fleet_vehicles for each row execute function public.record_distribution_master_event();

drop trigger if exists distribution_routes_master_event on public.distribution_routes;
create trigger distribution_routes_master_event after insert or update or delete on public.distribution_routes for each row execute function public.record_distribution_master_event();

drop trigger if exists fleet_vehicle_maintenance_master_event on public.fleet_vehicle_maintenance;
create trigger fleet_vehicle_maintenance_master_event after insert or update or delete on public.fleet_vehicle_maintenance for each row execute function public.record_distribution_master_event();

drop trigger if exists fleet_vehicle_defects_master_event on public.fleet_vehicle_defects;
create trigger fleet_vehicle_defects_master_event after insert or update or delete on public.fleet_vehicle_defects for each row execute function public.record_distribution_master_event();

drop trigger if exists distribution_driver_absences_master_event on public.distribution_driver_absences;
create trigger distribution_driver_absences_master_event after insert or update or delete on public.distribution_driver_absences for each row execute function public.record_distribution_master_event();

alter table public.distribution_routes
  drop constraint if exists distribution_routes_default_km_check,
  add constraint distribution_routes_default_km_check check (default_km >= 0),
  drop constraint if exists distribution_routes_default_hours_check,
  add constraint distribution_routes_default_hours_check check (default_hours >= 0);

create or replace function public.save_distribution_route(p_route jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_id uuid := nullif(p_route ->> 'route_id','')::uuid; v_result public.distribution_routes%rowtype;
begin
  perform public.require_distribution_master_access();
  insert into public.distribution_routes(route_id,route_code,display_name,route_color,route_kind,allow_as_default,active,sort_order,default_km,default_hours,notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),upper(trim(p_route ->> 'route_code')),trim(p_route ->> 'display_name'),nullif(p_route ->> 'route_color',''),upper(coalesce(nullif(p_route ->> 'route_kind',''),'STANDARD')),coalesce((p_route ->> 'allow_as_default')::boolean,true),coalesce((p_route ->> 'active')::boolean,true),coalesce(nullif(p_route ->> 'sort_order','')::integer,0),coalesce(nullif(p_route ->> 'default_km','')::numeric,0),coalesce(nullif(p_route ->> 'default_hours','')::numeric,0),nullif(p_route ->> 'notes',''),auth.uid(),auth.uid())
  on conflict (route_id) do update set route_code=excluded.route_code,display_name=excluded.display_name,route_color=excluded.route_color,route_kind=excluded.route_kind,allow_as_default=excluded.allow_as_default,active=excluded.active,sort_order=excluded.sort_order,default_km=excluded.default_km,default_hours=excluded.default_hours,notes=excluded.notes,updated_by=auth.uid(),row_version=public.distribution_routes.row_version+1
  returning * into v_result;
  return to_jsonb(v_result);
end;
$$;

create or replace function public.get_distribution_roster_week(p_week_start date, p_roster_version_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
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

create or replace function public.validate_distribution_roster_version(p_roster_version_id uuid)
returns void language plpgsql security definer set search_path = public, auth, pg_temp as $$
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

  select e.work_date, v.registration_number into v_conflict from public.distribution_roster_entries e join public.fleet_vehicles v on v.vehicle_id = e.vehicle_id
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED'
    and (v.deleted_at is not null or not v.active or v.operational_status <> 'AVAILABLE') limit 1;
  if found then raise exception using errcode = '22023', message = format('Vehicle %s is not available for the roster.', v_conflict.registration_number); end if;

  select e.work_date, v.registration_number into v_conflict from public.distribution_roster_entries e
  join public.fleet_vehicle_maintenance m on m.vehicle_id = e.vehicle_id and m.maintenance_status in ('PLANNED', 'IN_PROGRESS') and e.work_date between m.starts_on and coalesce(m.ends_on, m.starts_on)
  join public.fleet_vehicles v on v.vehicle_id = e.vehicle_id
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED' limit 1;
  if found then raise exception using errcode = '22023', message = format('Vehicle %s has maintenance planned on %s.', v_conflict.registration_number, v_conflict.work_date); end if;
end;
$$;

create or replace function public.save_distribution_roster_week(p_roster jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare
  v_week_start date := nullif(p_roster ->> 'week_start', '')::date;
  v_roster_id uuid := nullif(p_roster ->> 'distribution_roster_version_id', '')::uuid;
  v_expected_version integer := nullif(p_roster ->> 'row_version', '')::integer;
  v_required_routes jsonb := coalesce(p_roster -> 'required_routes', '{}'::jsonb);
  v_roster public.distribution_roster_versions%rowtype;
  v_entry jsonb; v_work_date date; v_route public.distribution_routes%rowtype;
  v_primary_name text; v_support_name text; v_vehicle public.fleet_vehicles%rowtype; v_status text;
begin
  perform public.require_distribution_plan_access();
  if v_week_start is null or v_week_start <> public.distribution_roster_week_start(v_week_start) then raise exception using errcode = '22023', message = 'Select a Monday as the roster week start.'; end if;
  if jsonb_typeof(coalesce(p_roster -> 'entries', '[]'::jsonb)) <> 'array' then raise exception using errcode = '22023', message = 'Roster entries must be an array.'; end if;
  if jsonb_typeof(v_required_routes) <> 'object' then raise exception using errcode = '22023', message = 'Required routes must be a daily object.'; end if;
  if exists (select 1 from jsonb_each_text(v_required_routes) r where r.key::date < v_week_start or r.key::date > v_week_start + 6 or coalesce(nullif(r.value,'')::integer,0) < 0) then raise exception using errcode = '22023', message = 'Required routes must be non-negative values in the selected week.'; end if;
  if v_roster_id is not null then
    select * into v_roster from public.distribution_roster_versions where distribution_roster_version_id = v_roster_id for update;
    if not found or v_roster.week_start <> v_week_start or v_roster.roster_status <> 'DRAFT' then raise exception using errcode = '22023', message = 'Distribution roster draft was not found or is already published.'; end if;
    if v_expected_version is not null and v_roster.row_version <> v_expected_version then raise exception using errcode = '40001', message = 'This roster was changed by another user. Reload it before saving.'; end if;
    update public.distribution_roster_versions set roster_note=nullif(p_roster ->> 'roster_note',''),required_routes=v_required_routes,updated_by=auth.uid(),row_version=row_version+1 where distribution_roster_version_id=v_roster_id returning * into v_roster;
  else
    select * into v_roster from public.distribution_roster_versions where week_start=v_week_start and roster_status='DRAFT' for update;
    if found then
      v_roster_id:=v_roster.distribution_roster_version_id;
      if v_expected_version is not null and v_roster.row_version <> v_expected_version then raise exception using errcode = '40001', message = 'This roster was changed by another user. Reload it before saving.'; end if;
      update public.distribution_roster_versions set roster_note=nullif(p_roster ->> 'roster_note',''),required_routes=v_required_routes,updated_by=auth.uid(),row_version=row_version+1 where distribution_roster_version_id=v_roster_id returning * into v_roster;
    else
      insert into public.distribution_roster_versions(week_start,version_number,roster_note,required_routes,created_by,updated_by) values(v_week_start,coalesce((select max(version_number)+1 from public.distribution_roster_versions where week_start=v_week_start),1),nullif(p_roster ->> 'roster_note',''),v_required_routes,auth.uid(),auth.uid()) returning * into v_roster;
      v_roster_id:=v_roster.distribution_roster_version_id;
      insert into public.distribution_roster_events(distribution_roster_version_id,event_type,recorded_by) values(v_roster_id,'DRAFT_CREATED',auth.uid());
    end if;
  end if;
  delete from public.distribution_roster_entries where distribution_roster_version_id=v_roster_id;
  for v_entry in select value from jsonb_array_elements(coalesce(p_roster -> 'entries','[]'::jsonb)) loop
    v_work_date:=nullif(v_entry ->> 'work_date','')::date;
    if v_work_date is null or v_work_date < v_week_start or v_work_date > v_week_start+5 then raise exception using errcode='22023',message='Roster entries must be from Monday through Saturday of the selected week.'; end if;
    v_status:=upper(coalesce(nullif(v_entry ->> 'assignment_status',''),'PLANNED'));
    if v_status not in ('PLANNED','OFF','HOLIDAY','TRAINING','ABSENT','SICK') then raise exception using errcode='22023',message='Unknown Distribution roster status.'; end if;
    if v_status = 'PLANNED' then
      select * into v_route from public.distribution_routes where route_id=nullif(v_entry ->> 'route_id','')::uuid and active and deleted_at is null;
      if not found then raise exception using errcode='22023',message='Roster route is inactive or invalid.'; end if;
      if nullif(v_entry ->> 'primary_driver_id','') is null or nullif(v_entry ->> 'vehicle_id','') is null then raise exception using errcode='22023',message='Working roster entries require Driver, Route and Vehicle.'; end if;
    else
      v_route:=null;
    end if;
    select display_name into v_primary_name from public.distribution_drivers where driver_id=nullif(v_entry ->> 'primary_driver_id','')::uuid;
    select display_name into v_support_name from public.distribution_drivers where driver_id=nullif(v_entry ->> 'support_driver_id','')::uuid;
    select * into v_vehicle from public.fleet_vehicles where vehicle_id=nullif(v_entry ->> 'vehicle_id','')::uuid;
    insert into public.distribution_roster_entries(distribution_roster_version_id,work_date,route_id,assignment_status,primary_driver_id,support_driver_id,vehicle_id,route_code_snapshot,route_name_snapshot,route_color_snapshot,primary_driver_name_snapshot,support_driver_name_snapshot,vehicle_registration_snapshot,vehicle_name_snapshot,entry_note,created_by,updated_by)
    values(v_roster_id,v_work_date,case when v_status='PLANNED' then v_route.route_id else null end,v_status,nullif(v_entry ->> 'primary_driver_id','')::uuid,case when v_status='PLANNED' then nullif(v_entry ->> 'support_driver_id','')::uuid else null end,case when v_status='PLANNED' then nullif(v_entry ->> 'vehicle_id','')::uuid else null end,v_route.route_code,v_route.display_name,v_route.route_color,v_primary_name,case when v_status='PLANNED' then v_support_name else null end,case when v_status='PLANNED' then v_vehicle.registration_number else null end,case when v_status='PLANNED' then v_vehicle.display_name else null end,nullif(v_entry ->> 'entry_note',''),auth.uid(),auth.uid());
  end loop;
  perform public.validate_distribution_roster_version(v_roster_id);
  insert into public.distribution_roster_events(distribution_roster_version_id,event_type,event_payload,recorded_by) values(v_roster_id,'DRAFT_SAVED',jsonb_build_object('entry_count',jsonb_array_length(coalesce(p_roster -> 'entries','[]'::jsonb))),auth.uid());
  return public.get_distribution_roster_week(v_week_start,v_roster_id);
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

revoke all on function public.get_distribution_roster_week(date,uuid), public.save_distribution_roster_week(jsonb), public.save_distribution_route(jsonb) from public, anon;
grant execute on function public.get_distribution_roster_week(date,uuid), public.save_distribution_roster_week(jsonb), public.save_distribution_route(jsonb) to authenticated;
revoke all on function public.get_distribution_activity_history(date,date,integer) from public, anon;
grant execute on function public.get_distribution_activity_history(date,date,integer) to authenticated;
revoke all on function public.record_distribution_master_event() from public, anon, authenticated;

comment on column public.distribution_routes.default_km is 'Planned kilometres used by the weekly driver roster.';
comment on column public.distribution_routes.default_hours is 'Planned driving and route hours used by the weekly driver roster.';
comment on column public.distribution_roster_versions.required_routes is 'Editable daily target number of planned route runs for the roster week.';

commit;
