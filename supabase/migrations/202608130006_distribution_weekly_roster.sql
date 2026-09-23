-- =====================================================================
-- ElisCaretex V2
-- Distribution weekly roster (incremental migration)
-- Requires: 202608130005_distribution_operations_foundation.sql
-- =====================================================================

begin;

create table public.distribution_roster_versions (
  distribution_roster_version_id uuid primary key default gen_random_uuid(),
  week_start date not null,
  version_number integer not null,
  roster_status text not null default 'DRAFT',
  roster_note text,
  published_at timestamptz,
  published_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint distribution_roster_versions_week_start_check check (extract(isodow from week_start) = 1),
  constraint distribution_roster_versions_status_check check (roster_status in ('DRAFT', 'PUBLISHED', 'SUPERSEDED', 'CANCELLED')),
  constraint distribution_roster_versions_number_check check (version_number > 0),
  constraint distribution_roster_versions_row_version_check check (row_version > 0),
  constraint distribution_roster_versions_week_number_unique unique (week_start, version_number)
);

create unique index distribution_roster_one_draft_per_week on public.distribution_roster_versions(week_start) where roster_status = 'DRAFT';
create unique index distribution_roster_one_published_per_week on public.distribution_roster_versions(week_start) where roster_status = 'PUBLISHED';

create table public.distribution_roster_entries (
  distribution_roster_entry_id uuid primary key default gen_random_uuid(),
  distribution_roster_version_id uuid not null references public.distribution_roster_versions(distribution_roster_version_id) on delete cascade,
  work_date date not null,
  route_id uuid references public.distribution_routes(route_id) on delete restrict,
  assignment_status text not null default 'PLANNED',
  primary_driver_id uuid references public.distribution_drivers(driver_id) on delete restrict,
  support_driver_id uuid references public.distribution_drivers(driver_id) on delete restrict,
  vehicle_id uuid references public.fleet_vehicles(vehicle_id) on delete restrict,
  route_code_snapshot text,
  route_name_snapshot text,
  route_color_snapshot text,
  primary_driver_name_snapshot text,
  support_driver_name_snapshot text,
  vehicle_registration_snapshot text,
  vehicle_name_snapshot text,
  entry_note text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint distribution_roster_entries_workday_check check (extract(isodow from work_date) between 1 and 6),
  constraint distribution_roster_entries_status_check check (assignment_status in ('PLANNED', 'OFF', 'HOLIDAY', 'TRAINING', 'ABSENT', 'SICK')),
  constraint distribution_roster_entries_driver_check check (primary_driver_id is null or support_driver_id is null or primary_driver_id <> support_driver_id),
  constraint distribution_roster_entries_row_version_check check (row_version > 0),
  constraint distribution_roster_entries_route_or_status_check check ((assignment_status = 'PLANNED' and route_id is not null) or (assignment_status <> 'PLANNED' and primary_driver_id is not null))
);

create table public.distribution_roster_events (
  roster_event_id uuid primary key default gen_random_uuid(),
  distribution_roster_version_id uuid not null references public.distribution_roster_versions(distribution_roster_version_id) on delete cascade,
  event_type text not null,
  event_payload jsonb not null default '{}'::jsonb,
  event_at timestamptz not null default now(),
  recorded_by uuid references auth.users(id) on delete set null
);

create index distribution_roster_entries_version_date_idx on public.distribution_roster_entries(distribution_roster_version_id, work_date);
create index distribution_roster_entries_driver_date_idx on public.distribution_roster_entries(primary_driver_id, work_date) where primary_driver_id is not null;
create index distribution_roster_entries_vehicle_date_idx on public.distribution_roster_entries(vehicle_id, work_date) where vehicle_id is not null;
create unique index distribution_roster_entries_route_day_unique on public.distribution_roster_entries(distribution_roster_version_id, work_date, route_id) where route_id is not null;
create unique index distribution_roster_entries_primary_driver_day_unique on public.distribution_roster_entries(distribution_roster_version_id, work_date, primary_driver_id) where primary_driver_id is not null;

create trigger distribution_roster_versions_set_updated_at before update on public.distribution_roster_versions for each row execute function public.set_updated_at();
create trigger distribution_roster_entries_set_updated_at before update on public.distribution_roster_entries for each row execute function public.set_updated_at();

alter table public.distribution_roster_versions enable row level security;
alter table public.distribution_roster_entries enable row level security;
alter table public.distribution_roster_events enable row level security;
revoke all on table public.distribution_roster_versions, public.distribution_roster_entries, public.distribution_roster_events from public, anon, authenticated;

create or replace function public.distribution_roster_week_start(p_date date)
returns date language sql immutable set search_path = public, pg_temp as $$
  select p_date - (extract(isodow from p_date)::integer - 1);
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
    select * into v_roster from public.distribution_roster_versions
    where week_start = v_week_start and roster_status in ('DRAFT', 'PUBLISHED')
    order by case roster_status when 'DRAFT' then 0 else 1 end, version_number desc limit 1;
  end if;
  return jsonb_build_object(
    'week_start', v_week_start, 'week_end', v_week_start + 5,
    'can_manage', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'is_past', v_week_start + 5 < current_date,
    'document', case when v_roster.distribution_roster_version_id is null then null else to_jsonb(v_roster) end,
    'routes', coalesce((select jsonb_agg(to_jsonb(r) order by r.sort_order, r.route_code) from public.distribution_routes r where r.active and r.deleted_at is null and r.route_kind = 'STANDARD'), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(to_jsonb(d) order by d.display_name) from public.distribution_drivers d where d.deleted_at is null and d.employment_status = 'ACTIVE'), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v) order by v.registration_number) from public.fleet_vehicles v where v.deleted_at is null and v.active), '[]'::jsonb),
    'absences', coalesce((select jsonb_agg(to_jsonb(a) order by a.starts_on, a.driver_id) from public.distribution_driver_absences a where a.absence_status = 'APPROVED' and a.starts_on <= v_week_start + 5 and a.ends_on >= v_week_start), '[]'::jsonb),
    'entries', coalesce((select jsonb_agg(to_jsonb(e) order by e.work_date, e.route_code_snapshot) from public.distribution_roster_entries e where e.distribution_roster_version_id = v_roster.distribution_roster_version_id), '[]'::jsonb)
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
  v_roster public.distribution_roster_versions%rowtype;
  v_entry jsonb; v_work_date date; v_route public.distribution_routes%rowtype;
  v_primary_name text; v_support_name text; v_vehicle public.fleet_vehicles%rowtype; v_status text;
begin
  perform public.require_distribution_plan_access();
  if v_week_start is null or v_week_start <> public.distribution_roster_week_start(v_week_start) then raise exception using errcode = '22023', message = 'Select a Monday as the roster week start.'; end if;
  if jsonb_typeof(coalesce(p_roster -> 'entries', '[]'::jsonb)) <> 'array' then raise exception using errcode = '22023', message = 'Roster entries must be an array.'; end if;
  if v_roster_id is not null then
    select * into v_roster from public.distribution_roster_versions where distribution_roster_version_id = v_roster_id for update;
    if not found or v_roster.week_start <> v_week_start or v_roster.roster_status <> 'DRAFT' then raise exception using errcode = '22023', message = 'Distribution roster draft was not found or is already published.'; end if;
    if v_expected_version is not null and v_roster.row_version <> v_expected_version then raise exception using errcode = '40001', message = 'This roster was changed by another user. Reload it before saving.'; end if;
    update public.distribution_roster_versions set roster_note = nullif(p_roster ->> 'roster_note', ''), updated_by = auth.uid(), row_version = row_version + 1 where distribution_roster_version_id = v_roster_id returning * into v_roster;
  else
    select * into v_roster from public.distribution_roster_versions where week_start = v_week_start and roster_status = 'DRAFT' for update;
    if found then
      v_roster_id := v_roster.distribution_roster_version_id;
      if v_expected_version is not null and v_roster.row_version <> v_expected_version then raise exception using errcode = '40001', message = 'This roster was changed by another user. Reload it before saving.'; end if;
      update public.distribution_roster_versions set roster_note = nullif(p_roster ->> 'roster_note', ''), updated_by = auth.uid(), row_version = row_version + 1 where distribution_roster_version_id = v_roster_id returning * into v_roster;
    else
      insert into public.distribution_roster_versions(week_start, version_number, roster_note, created_by, updated_by)
      values (v_week_start, coalesce((select max(version_number) + 1 from public.distribution_roster_versions where week_start = v_week_start), 1), nullif(p_roster ->> 'roster_note', ''), auth.uid(), auth.uid()) returning * into v_roster;
      v_roster_id := v_roster.distribution_roster_version_id;
      insert into public.distribution_roster_events(distribution_roster_version_id, event_type, recorded_by) values (v_roster_id, 'DRAFT_CREATED', auth.uid());
    end if;
  end if;
  delete from public.distribution_roster_entries where distribution_roster_version_id = v_roster_id;
  for v_entry in select value from jsonb_array_elements(coalesce(p_roster -> 'entries', '[]'::jsonb)) loop
    v_work_date := nullif(v_entry ->> 'work_date', '')::date;
    if v_work_date is null or v_work_date < v_week_start or v_work_date > v_week_start + 5 then raise exception using errcode = '22023', message = 'Roster entries must be from Monday through Saturday of the selected week.'; end if;
    v_status := upper(coalesce(nullif(v_entry ->> 'assignment_status', ''), 'PLANNED'));
    if v_status not in ('PLANNED', 'OFF', 'HOLIDAY', 'TRAINING', 'ABSENT', 'SICK') then raise exception using errcode = '22023', message = 'Unknown Distribution roster status.'; end if;
    if v_status = 'PLANNED' then
      select * into v_route from public.distribution_routes where route_id = nullif(v_entry ->> 'route_id', '')::uuid and active and deleted_at is null;
      if not found then raise exception using errcode = '22023', message = 'Roster route is inactive or invalid.'; end if;
      if nullif(v_entry ->> 'primary_driver_id', '') is null or nullif(v_entry ->> 'vehicle_id', '') is null then raise exception using errcode = '22023', message = 'Working roster entries require Driver, Route and Vehicle.'; end if;
    else
      v_route := null;
    end if;
    select display_name into v_primary_name from public.distribution_drivers where driver_id = nullif(v_entry ->> 'primary_driver_id', '')::uuid;
    select display_name into v_support_name from public.distribution_drivers where driver_id = nullif(v_entry ->> 'support_driver_id', '')::uuid;
    select * into v_vehicle from public.fleet_vehicles where vehicle_id = nullif(v_entry ->> 'vehicle_id', '')::uuid;
    insert into public.distribution_roster_entries(distribution_roster_version_id, work_date, route_id, assignment_status, primary_driver_id, support_driver_id, vehicle_id, route_code_snapshot, route_name_snapshot, route_color_snapshot, primary_driver_name_snapshot, support_driver_name_snapshot, vehicle_registration_snapshot, vehicle_name_snapshot, entry_note, created_by, updated_by)
    values (v_roster_id, v_work_date, case when v_status = 'PLANNED' then v_route.route_id else null end, v_status, nullif(v_entry ->> 'primary_driver_id', '')::uuid, case when v_status = 'PLANNED' then nullif(v_entry ->> 'support_driver_id', '')::uuid else null end, case when v_status = 'PLANNED' then nullif(v_entry ->> 'vehicle_id', '')::uuid else null end, v_route.route_code, v_route.display_name, v_route.route_color, v_primary_name, case when v_status = 'PLANNED' then v_support_name else null end, case when v_status = 'PLANNED' then v_vehicle.registration_number else null end, case when v_status = 'PLANNED' then v_vehicle.display_name else null end, nullif(v_entry ->> 'entry_note', ''), auth.uid(), auth.uid());
  end loop;
  perform public.validate_distribution_roster_version(v_roster_id);
  insert into public.distribution_roster_events(distribution_roster_version_id, event_type, event_payload, recorded_by) values (v_roster_id, 'DRAFT_SAVED', jsonb_build_object('entry_count', jsonb_array_length(coalesce(p_roster -> 'entries', '[]'::jsonb))), auth.uid());
  return public.get_distribution_roster_week(v_week_start, v_roster_id);
end;
$$;

create or replace function public.publish_distribution_roster_week(p_roster_version_id uuid, p_expected_row_version integer default null)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_roster public.distribution_roster_versions%rowtype; v_conflict record; v_entry public.distribution_roster_entries%rowtype; v_run_id uuid;
begin
  perform public.require_distribution_plan_access();
  select * into v_roster from public.distribution_roster_versions where distribution_roster_version_id = p_roster_version_id for update;
  if not found or v_roster.roster_status <> 'DRAFT' then raise exception using errcode = '22023', message = 'Only an existing Distribution roster draft can be published.'; end if;
  if p_expected_row_version is not null and v_roster.row_version <> p_expected_row_version then raise exception using errcode = '40001', message = 'This roster was changed by another user. Reload it before publishing.'; end if;
  if exists (select 1 from public.distribution_roster_entries e where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED' and (e.primary_driver_id is null or e.vehicle_id is null)) then raise exception using errcode = '22023', message = 'Every planned route needs a primary driver and vehicle before publishing.'; end if;
  perform public.validate_distribution_roster_version(p_roster_version_id);
  select r.business_date, r.run_id into v_conflict from public.distribution_roster_entries e join public.distribution_route_runs r on r.business_date = e.work_date and r.route_id = e.route_id
  where e.distribution_roster_version_id = p_roster_version_id and r.run_status not in ('DRAFT', 'READY') and (e.assignment_status = 'OFF' or r.primary_driver_id is distinct from e.primary_driver_id or r.support_driver_id is distinct from e.support_driver_id or r.vehicle_id is distinct from e.vehicle_id) limit 1;
  if found then raise exception using errcode = '22023', message = format('Roster cannot replace the operational run on %s.', v_conflict.business_date); end if;
  update public.distribution_roster_versions set roster_status = 'SUPERSEDED', updated_by = auth.uid(), row_version = row_version + 1 where week_start = v_roster.week_start and roster_status = 'PUBLISHED';
  update public.distribution_roster_versions set roster_status = 'PUBLISHED', published_at = now(), published_by = auth.uid(), updated_by = auth.uid(), row_version = row_version + 1 where distribution_roster_version_id = p_roster_version_id returning * into v_roster;
  for v_entry in select * from public.distribution_roster_entries where distribution_roster_version_id = p_roster_version_id order by work_date, route_code_snapshot loop
    if v_entry.assignment_status <> 'PLANNED' then
      update public.distribution_route_runs set run_status = 'CANCELLED', updated_by = auth.uid(), row_version = row_version + 1 where business_date = v_entry.work_date and route_id = v_entry.route_id and run_status in ('DRAFT', 'READY');
    else
      insert into public.distribution_route_runs(business_date, route_id, run_status, primary_driver_id, support_driver_id, vehicle_id, dispatch_notes, created_by, updated_by)
      values (v_entry.work_date, v_entry.route_id, 'READY', v_entry.primary_driver_id, v_entry.support_driver_id, v_entry.vehicle_id, v_entry.entry_note, auth.uid(), auth.uid())
      on conflict (business_date, route_id) do update set run_status = 'READY', primary_driver_id = excluded.primary_driver_id, support_driver_id = excluded.support_driver_id, vehicle_id = excluded.vehicle_id, dispatch_notes = excluded.dispatch_notes, updated_by = auth.uid(), row_version = public.distribution_route_runs.row_version + 1 where public.distribution_route_runs.run_status in ('DRAFT', 'READY')
      returning run_id into v_run_id;
      if v_run_id is null then select run_id into v_run_id from public.distribution_route_runs where business_date = v_entry.work_date and route_id = v_entry.route_id; end if;
      perform public.sync_distribution_route_run_stops(v_run_id);
      insert into public.distribution_run_events(run_id, event_type, event_payload, recorded_by) values (v_run_id, 'ROSTER_PUBLISHED', jsonb_build_object('distribution_roster_version_id', p_roster_version_id), auth.uid());
      v_run_id := null;
    end if;
  end loop;
  insert into public.distribution_roster_events(distribution_roster_version_id, event_type, event_payload, recorded_by) values (p_roster_version_id, 'PUBLISHED', jsonb_build_object('published_at', v_roster.published_at), auth.uid());
  return public.get_distribution_roster_week(v_roster.week_start, p_roster_version_id);
end;
$$;

create or replace function public.get_distribution_roster_history(p_week_start date)
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  perform public.require_distribution_read_access();
  return coalesce((select jsonb_agg(jsonb_build_object('distribution_roster_version_id', distribution_roster_version_id, 'version_number', version_number, 'roster_status', roster_status, 'published_at', published_at, 'created_at', created_at) order by version_number desc) from public.distribution_roster_versions where week_start = public.distribution_roster_week_start(p_week_start)), '[]'::jsonb);
end;
$$;

revoke all on function public.distribution_roster_week_start(date), public.validate_distribution_roster_version(uuid) from public, anon, authenticated;
revoke all on function public.get_distribution_roster_week(date,uuid), public.save_distribution_roster_week(jsonb), public.publish_distribution_roster_week(uuid,integer), public.get_distribution_roster_history(date) from public, anon;
grant execute on function public.get_distribution_roster_week(date,uuid), public.save_distribution_roster_week(jsonb), public.publish_distribution_roster_week(uuid,integer), public.get_distribution_roster_history(date) to authenticated;

comment on table public.distribution_roster_versions is 'Immutable published weekly Distribution fleet and driver planning roster.';
comment on table public.distribution_roster_entries is 'Weekly driver roster states. Working entries require Driver, Route and Vehicle; non-working entries keep Driver and status only. Vans may be planned for two turns per day.';

commit;
