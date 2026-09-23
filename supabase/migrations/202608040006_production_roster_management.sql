-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608040006_production_roster_management.sql
-- Purpose:
--   Add a versioned Production Roster with immutable published history,
--   Morning/Evening publication independence, governed COVER assignments,
--   production-staff-only candidate scope, and a revocable mobile view.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Safety checks
-- ---------------------------------------------------------------------

do $$
begin
  if to_regclass('public.staff_members') is null
     or to_regclass('public.operational_roles') is null
     or to_regclass('public.staff_cover_capabilities') is null
     or to_regclass('public.roster_periods') is null
     or to_regclass('public.areas') is null
     or to_regclass('public.stations') is null
     or to_regclass('public.shifts') is null
     or to_regclass('public.audit_log') is null then
    raise exception 'Required ElisCaretex Staff Master and foundation tables are missing.';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'staff_members'
      and column_name = 'production_staff'
  ) then
    raise exception 'Staff production scope migration must be applied first.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Versioned Production Roster
-- ---------------------------------------------------------------------

create table if not exists public.production_roster_versions (
  roster_version_id uuid primary key default gen_random_uuid(),
  roster_period_id uuid not null references public.roster_periods(roster_period_id) on delete restrict,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  version_number integer not null,
  status text not null default 'DRAFT',
  include_sunday boolean not null default false,
  week_note text,
  based_on_version_id uuid references public.production_roster_versions(roster_version_id) on delete set null,
  row_version integer not null default 1,
  saved_at timestamptz,
  saved_by uuid references auth.users(id) on delete set null,
  published_at timestamptz,
  published_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint production_roster_version_number_positive check (version_number > 0),
  constraint production_roster_row_version_positive check (row_version > 0),
  constraint production_roster_version_status_check
    check (status in ('DRAFT', 'PUBLISHED', 'SUPERSEDED', 'CANCELLED')),
  constraint production_roster_publication_fields_check
    check (
      (status in ('PUBLISHED', 'SUPERSEDED') and published_at is not null)
      or status in ('DRAFT', 'CANCELLED')
    ),
  unique (roster_period_id, shift_id, version_number)
);

create unique index if not exists production_roster_one_draft_idx
  on public.production_roster_versions (roster_period_id, shift_id)
  where status = 'DRAFT';

create unique index if not exists production_roster_one_published_idx
  on public.production_roster_versions (roster_period_id, shift_id)
  where status = 'PUBLISHED';

create index if not exists production_roster_versions_lookup_idx
  on public.production_roster_versions (roster_period_id, shift_id, status, version_number desc);

create table if not exists public.production_roster_entries (
  roster_entry_id uuid primary key default gen_random_uuid(),
  roster_version_id uuid not null references public.production_roster_versions(roster_version_id) on delete restrict,
  work_date date not null,
  staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  day_status text not null default 'WORKING',
  assignment_type text not null default 'BASE',
  operational_role_id uuid references public.operational_roles(operational_role_id) on delete restrict,
  area_id uuid references public.areas(area_id) on delete restrict,
  station_id uuid references public.stations(station_id) on delete restrict,
  planned_start_time time,
  planned_end_time time,
  notes text,

  -- Snapshot fields preserve exactly what was published at the time.
  staff_display_name_snapshot text not null,
  employee_code_snapshot text,
  shift_code_snapshot text not null,
  shift_name_snapshot text not null,
  operational_role_code_snapshot text,
  operational_role_name_snapshot text,
  area_code_snapshot text,
  area_name_snapshot text,
  station_code_snapshot text,
  station_name_snapshot text,
  staff_primary_role_code_snapshot text,
  staff_primary_role_name_snapshot text,
  staff_default_area_code_snapshot text,
  staff_default_area_name_snapshot text,
  staff_default_station_code_snapshot text,
  staff_default_station_name_snapshot text,
  fire_training_snapshot boolean not null default false,
  first_aid_training_snapshot boolean not null default false,
  eod_capable_snapshot boolean not null default false,

  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,

  constraint production_roster_entry_unique unique (roster_version_id, staff_id, work_date),
  constraint production_roster_day_status_check
    check (day_status in ('WORKING', 'OFF', 'SICK', 'HOLIDAY', 'TRAINING', 'QUALITY_ANALYSIS')),
  constraint production_roster_assignment_type_check
    check (assignment_type in ('BASE', 'COVER')),
  constraint production_roster_cover_status_check
    check (assignment_type <> 'COVER' or day_status = 'WORKING'),
  constraint production_roster_work_assignment_check
    check (
      day_status not in ('WORKING', 'QUALITY_ANALYSIS')
      or (operational_role_id is not null and area_id is not null)
    ),
  constraint production_roster_time_check
    check (
      planned_end_time is null
      or planned_start_time is null
      or planned_end_time > planned_start_time
    )
);

create index if not exists production_roster_entries_day_lookup_idx
  on public.production_roster_entries (work_date, staff_id, day_status);

create index if not exists production_roster_entries_station_lookup_idx
  on public.production_roster_entries (work_date, area_id, station_id, day_status);

create table if not exists public.production_roster_events (
  roster_event_id uuid primary key default gen_random_uuid(),
  roster_version_id uuid not null references public.production_roster_versions(roster_version_id) on delete restrict,
  event_type text not null,
  actor_auth_user_id uuid references auth.users(id) on delete set null,
  actor_staff_id uuid references public.staff_members(staff_id) on delete set null,
  reason text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  constraint production_roster_event_type_check
    check (event_type in ('DRAFT_CREATED', 'DRAFT_SAVED', 'PUBLISHED', 'SUPERSEDED', 'DRAFT_CANCELLED'))
);

create index if not exists production_roster_events_history_idx
  on public.production_roster_events (roster_version_id, occurred_at desc);

create table if not exists public.production_roster_view_links (
  roster_view_link_id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  token_hash text not null unique,
  token_hint text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id) on delete set null,
  last_used_at timestamptz
);

create unique index if not exists production_roster_one_active_view_link_idx
  on public.production_roster_view_links (shift_id)
  where active = true;

-- ---------------------------------------------------------------------
-- Updated-at and immutability triggers
-- ---------------------------------------------------------------------

drop trigger if exists production_roster_versions_set_updated_at on public.production_roster_versions;
create trigger production_roster_versions_set_updated_at
before update on public.production_roster_versions
for each row execute function public.set_updated_at();

drop trigger if exists production_roster_entries_set_updated_at on public.production_roster_entries;
create trigger production_roster_entries_set_updated_at
before update on public.production_roster_entries
for each row execute function public.set_updated_at();

create or replace function public.protect_published_production_roster_entries()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_version_id uuid := coalesce(new.roster_version_id, old.roster_version_id);
  v_status text;
begin
  select prv.status into v_status
  from public.production_roster_versions prv
  where prv.roster_version_id = v_version_id;

  if v_status in ('PUBLISHED', 'SUPERSEDED') then
    raise exception using
      errcode = '55000',
      message = 'Published Production Roster entries are immutable.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists production_roster_entries_immutable on public.production_roster_entries;
create trigger production_roster_entries_immutable
before insert or update or delete on public.production_roster_entries
for each row execute function public.protect_published_production_roster_entries();

-- ---------------------------------------------------------------------
-- Shared helpers and permissions
-- ---------------------------------------------------------------------

create or replace function public.production_roster_week_start(p_date date)
returns date
language sql
immutable
as $$
  select date_trunc('week', p_date::timestamp)::date;
$$;

create or replace function public.require_production_roster_read_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'ROSTER_MANAGER', 'SUPERVISOR', 'AUDITOR']) then
    raise exception using errcode = '42501', message = 'You do not have permission to view the Production Roster.';
  end if;
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
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'ROSTER_MANAGER']) then
    raise exception using errcode = '42501', message = 'You do not have permission to manage the Production Roster.';
  end if;
end;
$$;

create or replace function public.get_production_roster_reference_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_production_roster_read_role();

  return jsonb_build_object(
    'can_manage', public.has_any_role(array['ADMIN', 'MANAGER', 'ROSTER_MANAGER']),
    'shifts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'shift_id', s.shift_id,
        'shift_code', s.shift_code,
        'shift_name', s.shift_name,
        'start_time', s.start_time,
        'end_time', s.end_time,
        'sort_order', s.sort_order
      ) order by s.sort_order, s.shift_name)
      from public.shifts s
      where s.active = true and s.deleted_at is null and s.shift_code in ('MORNING', 'EVENING')
    ), '[]'::jsonb),
    'operational_roles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'role_code', r.role_code,
        'role_name', r.role_name,
        'allow_as_cover', r.allow_as_cover,
        'sort_order', r.sort_order
      ) order by r.sort_order, r.role_name)
      from public.operational_roles r
      where r.active = true and r.deleted_at is null
    ), '[]'::jsonb),
    'areas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'area_id', a.area_id,
        'area_code', a.area_code,
        'area_name', a.area_name,
        'sort_order', a.sort_order
      ) order by a.sort_order, a.area_name)
      from public.areas a
      where a.active = true and a.deleted_at is null
        and a.area_code in ('SORTING', 'FINISH', 'MOP', 'WASHING')
    ), '[]'::jsonb),
    'stations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'station_id', st.station_id,
        'area_id', st.area_id,
        'station_code', st.station_code,
        'station_name', st.station_name,
        'station_type', st.station_type,
        'sort_order', st.sort_order
      ) order by st.sort_order, st.station_name)
      from public.stations st
      where st.active = true and st.deleted_at is null
    ), '[]'::jsonb),
    'day_statuses', jsonb_build_array(
      jsonb_build_object('code', 'WORKING', 'name', 'Working', 'abbreviation', 'W'),
      jsonb_build_object('code', 'COVER', 'name', 'Cover', 'abbreviation', 'C'),
      jsonb_build_object('code', 'OFF', 'name', 'Off', 'abbreviation', 'O'),
      jsonb_build_object('code', 'SICK', 'name', 'Sick', 'abbreviation', 'S'),
      jsonb_build_object('code', 'HOLIDAY', 'name', 'Holiday', 'abbreviation', 'H'),
      jsonb_build_object('code', 'TRAINING', 'name', 'Training', 'abbreviation', 'T'),
      jsonb_build_object('code', 'QUALITY_ANALYSIS', 'name', 'Quality Analysis', 'abbreviation', 'QA')
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Controlled roster read model
-- ---------------------------------------------------------------------

create or replace function public.get_production_roster_week(
  p_week_start date,
  p_shift_code text,
  p_roster_version_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift public.shifts%rowtype;
  v_version public.production_roster_versions%rowtype;
  v_period_id uuid;
  v_can_manage boolean;
  v_is_past boolean := v_week_start < public.production_roster_week_start(current_date);
begin
  perform public.require_production_roster_read_role();
  v_can_manage := public.has_any_role(array['ADMIN', 'MANAGER', 'ROSTER_MANAGER']);

  select * into v_shift
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code))
    and s.active = true
    and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid or inactive shift.';
  end if;

  select rp.roster_period_id into v_period_id
  from public.roster_periods rp
  where rp.week_start = v_week_start;

  if p_roster_version_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where prv.roster_version_id = p_roster_version_id
      and rp.week_start = v_week_start
      and prv.shift_id = v_shift.shift_id;
  elsif v_period_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id
      and prv.shift_id = v_shift.shift_id
      and prv.status in ('DRAFT', 'PUBLISHED')
    order by case prv.status when 'DRAFT' then 1 else 2 end, prv.version_number desc
    limit 1;
  end if;

  return jsonb_build_object(
    'week_start', v_week_start,
    'week_end', v_week_start + 6,
    'is_past', v_is_past,
    'can_manage', v_can_manage,
    'shift', jsonb_build_object(
      'shift_id', v_shift.shift_id,
      'shift_code', v_shift.shift_code,
      'shift_name', v_shift.shift_name,
      'start_time', v_shift.start_time,
      'end_time', v_shift.end_time
    ),
    'document', case when v_version.roster_version_id is null then null else jsonb_build_object(
      'roster_version_id', v_version.roster_version_id,
      'version_number', v_version.version_number,
      'status', v_version.status,
      'include_sunday', v_version.include_sunday,
      'week_note', v_version.week_note,
      'row_version', v_version.row_version,
      'based_on_version_id', v_version.based_on_version_id,
      'saved_at', v_version.saved_at,
      'published_at', v_version.published_at,
      'is_historical', p_roster_version_id is not null
    ) end,
    'published_document', (
      select jsonb_build_object(
        'roster_version_id', p.roster_version_id,
        'version_number', p.version_number,
        'published_at', p.published_at
      )
      from public.production_roster_versions p
      where p.roster_period_id = v_period_id
        and p.shift_id = v_shift.shift_id
        and p.status = 'PUBLISHED'
      limit 1
    ),
    'staff', case
      when v_version.roster_version_id is not null then coalesce((
        select jsonb_agg(staff_row order by
          (staff_row ->> 'group_sort')::integer,
          (staff_row ->> 'station_sort')::integer,
          lower(staff_row ->> 'display_name')
        )
        from (
          select distinct on (pre.staff_id)
            jsonb_build_object(
              'staff_id', pre.staff_id,
              'display_name', pre.staff_display_name_snapshot,
              'employee_code', pre.employee_code_snapshot,
              'default_shift_code', pre.shift_code_snapshot,
              'primary_role_code', coalesce(pre.staff_primary_role_code_snapshot, sm_role.role_code),
              'primary_role_name', coalesce(pre.staff_primary_role_name_snapshot, sm_role.role_name),
              'default_area_code', coalesce(pre.staff_default_area_code_snapshot, sm_area.area_code),
              'default_area_name', coalesce(pre.staff_default_area_name_snapshot, sm_area.area_name),
              'default_station_code', coalesce(pre.staff_default_station_code_snapshot, sm_station.station_code),
              'default_station_name', coalesce(pre.staff_default_station_name_snapshot, sm_station.station_name),
              'fire_training', pre.fire_training_snapshot,
              'first_aid_training', pre.first_aid_training_snapshot,
              'eod_capable', pre.eod_capable_snapshot,
              'cover_role_codes', coalesce((
                select jsonb_agg(cr.role_code order by cr.sort_order)
                from public.staff_cover_capabilities scc
                join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
                where scc.staff_id = pre.staff_id
                  and scc.active = true
                  and scc.deleted_at is null
                  and scc.effective_from <= current_date
                  and (scc.effective_until is null or scc.effective_until >= current_date)
              ), '[]'::jsonb),
              'group_sort', coalesce(sm_role.sort_order, 999),
              'station_sort', coalesce(sm_station.sort_order, 999)
            ) as staff_row
          from public.production_roster_entries pre
          left join public.staff_members sm on sm.staff_id = pre.staff_id
          left join public.operational_roles sm_role on sm_role.operational_role_id = sm.primary_operational_role_id
          left join public.areas sm_area on sm_area.area_id = sm.default_area_id
          left join public.stations sm_station on sm_station.station_id = sm.default_station_id
          where pre.roster_version_id = v_version.roster_version_id
          order by pre.staff_id, pre.work_date
        ) rows
      ), '[]'::jsonb)
      else coalesce((
        select jsonb_agg(jsonb_build_object(
          'staff_id', sm.staff_id,
          'display_name', sm.display_name,
          'employee_code', sm.employee_code,
          'default_shift_code', s.shift_code,
          'primary_role_code', opr.role_code,
          'primary_role_name', opr.role_name,
          'default_area_code', a.area_code,
          'default_area_name', a.area_name,
          'default_station_code', st.station_code,
          'default_station_name', st.station_name,
          'fire_training', sm.fire_training,
          'first_aid_training', sm.first_aid_training,
          'eod_capable', sm.eod_capable,
          'cover_role_codes', coalesce((
            select jsonb_agg(cr.role_code order by cr.sort_order)
            from public.staff_cover_capabilities scc
            join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
            where scc.staff_id = sm.staff_id
              and scc.active = true
              and scc.deleted_at is null
              and scc.effective_from <= v_week_start + 6
              and (scc.effective_until is null or scc.effective_until >= v_week_start)
          ), '[]'::jsonb),
          'group_sort', coalesce(opr.sort_order, 999),
          'station_sort', coalesce(st.sort_order, 999)
        ) order by coalesce(opr.sort_order, 999), coalesce(st.sort_order, 999), lower(sm.display_name))
        from public.staff_members sm
        join public.shifts s on s.shift_id = sm.default_shift_id
        left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
        left join public.areas a on a.area_id = sm.default_area_id
        left join public.stations st on st.station_id = sm.default_station_id
        where sm.production_staff = true
          and sm.active = true
          and sm.roster_eligible = true
          and sm.deleted_at is null
          and s.shift_id = v_shift.shift_id
      ), '[]'::jsonb)
    end,
    'entries', case when v_version.roster_version_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'roster_entry_id', pre.roster_entry_id,
        'staff_id', pre.staff_id,
        'work_date', pre.work_date,
        'day_status', pre.day_status,
        'assignment_type', pre.assignment_type,
        'operational_role_code', opr.role_code,
        'operational_role_name', pre.operational_role_name_snapshot,
        'area_code', a.area_code,
        'area_name', pre.area_name_snapshot,
        'station_code', st.station_code,
        'station_name', pre.station_name_snapshot,
        'planned_start_time', pre.planned_start_time,
        'planned_end_time', pre.planned_end_time,
        'notes', pre.notes
      ) order by pre.work_date, lower(pre.staff_display_name_snapshot))
      from public.production_roster_entries pre
      left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
      left join public.areas a on a.area_id = pre.area_id
      left join public.stations st on st.station_id = pre.station_id
      where pre.roster_version_id = v_version.roster_version_id
    ), '[]'::jsonb) end
  );
end;
$$;

create or replace function public.get_production_roster_history(
  p_week_start date,
  p_shift_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift_id uuid;
begin
  perform public.require_production_roster_read_role();

  select s.shift_id into v_shift_id
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code)) and s.active = true and s.deleted_at is null;

  if v_shift_id is null then
    raise exception using errcode = '22023', message = 'Invalid shift.';
  end if;

  return jsonb_build_object(
    'week_start', v_week_start,
    'shift_code', upper(trim(p_shift_code)),
    'versions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'roster_version_id', prv.roster_version_id,
        'version_number', prv.version_number,
        'status', prv.status,
        'include_sunday', prv.include_sunday,
        'week_note', prv.week_note,
        'saved_at', prv.saved_at,
        'published_at', prv.published_at,
        'created_at', prv.created_at,
        'entry_count', (select count(*) from public.production_roster_entries pre where pre.roster_version_id = prv.roster_version_id),
        'staff_count', (select count(distinct pre.staff_id) from public.production_roster_entries pre where pre.roster_version_id = prv.roster_version_id)
      ) order by prv.version_number desc)
      from public.production_roster_versions prv
      join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
      where rp.week_start = v_week_start
        and prv.shift_id = v_shift_id
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Save, publish and cancel
-- ---------------------------------------------------------------------

create or replace function public.save_production_roster_week(
  p_week_start date,
  p_shift_code text,
  p_include_sunday boolean,
  p_week_note text,
  p_entries jsonb,
  p_base_row_version integer default null,
  p_change_reason text default null,
  p_source_application text default 'PRODUCTION_ROSTER'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift public.shifts%rowtype;
  v_period_id uuid;
  v_draft public.production_roster_versions%rowtype;
  v_published public.production_roster_versions%rowtype;
  v_item jsonb;
  v_staff public.staff_members%rowtype;
  v_role public.operational_roles%rowtype;
  v_area public.areas%rowtype;
  v_station public.stations%rowtype;
  v_work_date date;
  v_day_status text;
  v_assignment_type text;
  v_role_code text;
  v_area_code text;
  v_station_code text;
  v_expected_days integer := case when p_include_sunday then 7 else 6 end;
  v_entry_count integer;
  v_staff_count integer;
  v_actor_staff uuid := public.current_staff_id();
  v_next_version integer;
begin
  perform public.require_production_roster_manage_role();

  if v_week_start < public.production_roster_week_start(current_date) then
    raise exception using errcode = '55000', message = 'Past Production Roster weeks are read-only.';
  end if;

  if p_entries is null or jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) = 0 then
    raise exception using errcode = '22023', message = 'The Production Roster must contain staff entries.';
  end if;

  select * into v_shift
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code)) and s.active = true and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid or inactive shift.';
  end if;

  insert into public.roster_periods (week_start, status, created_by)
  values (v_week_start, 'DRAFT', auth.uid())
  on conflict (week_start) do nothing;

  select rp.roster_period_id into v_period_id
  from public.roster_periods rp
  where rp.week_start = v_week_start
  for update;

  select * into v_draft
  from public.production_roster_versions prv
  where prv.roster_period_id = v_period_id
    and prv.shift_id = v_shift.shift_id
    and prv.status = 'DRAFT'
  for update;

  if v_draft.roster_version_id is not null then
    if p_base_row_version is null or p_base_row_version <> v_draft.row_version then
      raise exception using errcode = '40001', message = 'The Production Roster was changed by another user. Reload before saving.';
    end if;
  else
    select * into v_published
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id
      and prv.shift_id = v_shift.shift_id
      and prv.status = 'PUBLISHED'
    limit 1;

    select coalesce(max(prv.version_number), 0) + 1 into v_next_version
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id and prv.shift_id = v_shift.shift_id;

    insert into public.production_roster_versions (
      roster_period_id, shift_id, version_number, status, include_sunday,
      week_note, based_on_version_id, saved_at, saved_by, created_by, updated_by
    ) values (
      v_period_id, v_shift.shift_id, v_next_version, 'DRAFT', p_include_sunday,
      nullif(trim(p_week_note), ''), v_published.roster_version_id,
      now(), auth.uid(), auth.uid(), auth.uid()
    ) returning * into v_draft;

    insert into public.production_roster_events (
      roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason, metadata
    ) values (
      v_draft.roster_version_id, 'DRAFT_CREATED', auth.uid(), v_actor_staff,
      nullif(trim(p_change_reason), ''),
      jsonb_build_object('week_start', v_week_start, 'shift_code', v_shift.shift_code)
    );
  end if;

  delete from public.production_roster_entries pre
  where pre.roster_version_id = v_draft.roster_version_id;

  for v_item in select value from jsonb_array_elements(p_entries)
  loop
    v_work_date := (v_item ->> 'work_date')::date;
    v_day_status := upper(coalesce(nullif(trim(v_item ->> 'day_status'), ''), 'WORKING'));
    v_assignment_type := upper(coalesce(nullif(trim(v_item ->> 'assignment_type'), ''), 'BASE'));
    v_role_code := upper(nullif(trim(v_item ->> 'operational_role_code'), ''));
    v_area_code := upper(nullif(trim(v_item ->> 'area_code'), ''));
    v_station_code := upper(nullif(trim(v_item ->> 'station_code'), ''));

    if v_work_date < v_week_start
       or v_work_date > v_week_start + (v_expected_days - 1) then
      raise exception using errcode = '22023', message = 'A roster entry is outside the selected week.';
    end if;

    if v_day_status not in ('WORKING', 'OFF', 'SICK', 'HOLIDAY', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using errcode = '22023', message = 'Invalid Production Roster day status.';
    end if;

    if v_assignment_type not in ('BASE', 'COVER') then
      raise exception using errcode = '22023', message = 'Invalid Production Roster assignment type.';
    end if;

    if v_assignment_type = 'COVER' and v_day_status <> 'WORKING' then
      raise exception using errcode = '22023', message = 'COVER can only be used with Working status.';
    end if;

    select * into v_staff
    from public.staff_members sm
    where sm.staff_id = (v_item ->> 'staff_id')::uuid
      and sm.production_staff = true
      and sm.active = true
      and sm.roster_eligible = true
      and sm.deleted_at is null;

    if not found then
      raise exception using errcode = '22023', message = 'The roster contains inactive, ineligible or non-production staff.';
    end if;

    v_role.operational_role_id := null;
    v_role.role_code := null;
    v_role.role_name := null;
    v_role.allow_as_cover := false;
    v_area.area_id := null;
    v_area.area_code := null;
    v_area.area_name := null;
    v_station.station_id := null;
    v_station.station_code := null;
    v_station.station_name := null;

    if v_day_status in ('WORKING', 'QUALITY_ANALYSIS') then
      if v_role_code is null or v_area_code is null then
        raise exception using errcode = '22023', message = 'Working assignments require an operational role and area.';
      end if;

      select * into v_role from public.operational_roles opr
      where opr.role_code = v_role_code and opr.active = true and opr.deleted_at is null;
      if not found then
        raise exception using errcode = '22023', message = 'Invalid operational role in roster entry.';
      end if;

      select * into v_area from public.areas a
      where a.area_code = v_area_code and a.active = true and a.deleted_at is null;
      if not found then
        raise exception using errcode = '22023', message = 'Invalid area in roster entry.';
      end if;

      if v_station_code is not null then
        select * into v_station from public.stations st
        where st.station_code = v_station_code
          and st.area_id = v_area.area_id
          and st.active = true
          and st.deleted_at is null;
        if not found then
          raise exception using errcode = '22023', message = 'The selected station does not belong to the selected area.';
        end if;
      end if;

      if v_assignment_type = 'COVER' then
        if v_role.allow_as_cover is not true or not exists (
          select 1
          from public.staff_cover_capabilities scc
          where scc.staff_id = v_staff.staff_id
            and scc.operational_role_id = v_role.operational_role_id
            and scc.active = true
            and scc.deleted_at is null
            and scc.effective_from <= v_work_date
            and (scc.effective_until is null or scc.effective_until >= v_work_date)
        ) then
          raise exception using errcode = '22023', message = 'The staff member is not authorised for the selected COVER role.';
        end if;
      end if;
    else
      v_assignment_type := 'BASE';
      v_role_code := null;
      v_area_code := null;
      v_station_code := null;
    end if;

    insert into public.production_roster_entries (
      roster_version_id, work_date, staff_id, day_status, assignment_type,
      operational_role_id, area_id, station_id,
      planned_start_time, planned_end_time, notes,
      staff_display_name_snapshot, employee_code_snapshot,
      shift_code_snapshot, shift_name_snapshot,
      operational_role_code_snapshot, operational_role_name_snapshot,
      area_code_snapshot, area_name_snapshot,
      station_code_snapshot, station_name_snapshot,
      staff_primary_role_code_snapshot, staff_primary_role_name_snapshot,
      staff_default_area_code_snapshot, staff_default_area_name_snapshot,
      staff_default_station_code_snapshot, staff_default_station_name_snapshot,
      fire_training_snapshot, first_aid_training_snapshot, eod_capable_snapshot,
      created_by, updated_by
    ) values (
      v_draft.roster_version_id,
      v_work_date,
      v_staff.staff_id,
      v_day_status,
      v_assignment_type,
      v_role.operational_role_id,
      v_area.area_id,
      v_station.station_id,
      nullif(v_item ->> 'planned_start_time', '')::time,
      nullif(v_item ->> 'planned_end_time', '')::time,
      nullif(trim(v_item ->> 'notes'), ''),
      v_staff.display_name,
      v_staff.employee_code,
      v_shift.shift_code,
      v_shift.shift_name,
      v_role.role_code,
      v_role.role_name,
      v_area.area_code,
      v_area.area_name,
      v_station.station_code,
      v_station.station_name,
      (select opr.role_code from public.operational_roles opr where opr.operational_role_id = v_staff.primary_operational_role_id),
      (select opr.role_name from public.operational_roles opr where opr.operational_role_id = v_staff.primary_operational_role_id),
      (select a.area_code from public.areas a where a.area_id = v_staff.default_area_id),
      (select a.area_name from public.areas a where a.area_id = v_staff.default_area_id),
      (select st.station_code from public.stations st where st.station_id = v_staff.default_station_id),
      (select st.station_name from public.stations st where st.station_id = v_staff.default_station_id),
      v_staff.fire_training,
      v_staff.first_aid_training,
      v_staff.eod_capable,
      auth.uid(),
      auth.uid()
    );
  end loop;

  select count(*), count(distinct staff_id)
  into v_entry_count, v_staff_count
  from public.production_roster_entries pre
  where pre.roster_version_id = v_draft.roster_version_id;

  if v_staff_count = 0 or v_entry_count <> v_staff_count * v_expected_days then
    raise exception using errcode = '22023', message = 'Every included staff member must have exactly one entry for each visible day.';
  end if;

  update public.production_roster_versions
  set include_sunday = p_include_sunday,
      week_note = nullif(trim(p_week_note), ''),
      saved_at = now(),
      saved_by = auth.uid(),
      updated_by = auth.uid(),
      row_version = row_version + 1
  where roster_version_id = v_draft.roster_version_id
  returning * into v_draft;

  insert into public.production_roster_events (
    roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason,
    metadata
  ) values (
    v_draft.roster_version_id, 'DRAFT_SAVED', auth.uid(), v_actor_staff,
    nullif(trim(p_change_reason), ''),
    jsonb_build_object('entry_count', v_entry_count, 'staff_count', v_staff_count, 'source_application', p_source_application)
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_DRAFT_SAVED',
    'production_roster_versions', v_draft.roster_version_id::text,
    jsonb_build_object('week_start', v_week_start, 'shift_code', v_shift.shift_code, 'version_number', v_draft.version_number),
    nullif(trim(p_change_reason), ''), p_source_application
  );

  return jsonb_build_object(
    'roster_version_id', v_draft.roster_version_id,
    'version_number', v_draft.version_number,
    'status', v_draft.status,
    'row_version', v_draft.row_version,
    'entry_count', v_entry_count,
    'staff_count', v_staff_count,
    'saved_at', v_draft.saved_at
  );
end;
$$;

create or replace function public.publish_production_roster_week(
  p_roster_version_id uuid,
  p_base_row_version integer,
  p_reason text default null,
  p_source_application text default 'PRODUCTION_ROSTER'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_draft public.production_roster_versions%rowtype;
  v_period public.roster_periods%rowtype;
  v_previous_id uuid;
  v_actor_staff uuid := public.current_staff_id();
  v_entries integer;
begin
  perform public.require_production_roster_manage_role();

  select prv.* into v_draft
  from public.production_roster_versions prv
  where prv.roster_version_id = p_roster_version_id
    and prv.status = 'DRAFT'
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Production Roster draft not found.';
  end if;

  if v_draft.row_version <> p_base_row_version then
    raise exception using errcode = '40001', message = 'The Production Roster was changed by another user. Reload before publishing.';
  end if;

  select * into v_period from public.roster_periods rp
  where rp.roster_period_id = v_draft.roster_period_id;

  if v_period.week_start < public.production_roster_week_start(current_date) then
    raise exception using errcode = '55000', message = 'Past Production Roster weeks cannot be published.';
  end if;

  select count(*) into v_entries
  from public.production_roster_entries pre
  where pre.roster_version_id = v_draft.roster_version_id;

  if v_entries = 0 then
    raise exception using errcode = '22023', message = 'An empty Production Roster cannot be published.';
  end if;

  select prv.roster_version_id into v_previous_id
  from public.production_roster_versions prv
  where prv.roster_period_id = v_draft.roster_period_id
    and prv.shift_id = v_draft.shift_id
    and prv.status = 'PUBLISHED'
  limit 1
  for update;

  if v_previous_id is not null then
    update public.production_roster_versions
    set status = 'SUPERSEDED', updated_by = auth.uid(), row_version = row_version + 1
    where roster_version_id = v_previous_id;

    insert into public.production_roster_events (
      roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason,
      metadata
    ) values (
      v_previous_id, 'SUPERSEDED', auth.uid(), v_actor_staff,
      nullif(trim(p_reason), ''), jsonb_build_object('superseded_by', v_draft.roster_version_id)
    );
  end if;

  update public.production_roster_versions
  set status = 'PUBLISHED',
      published_at = now(),
      published_by = auth.uid(),
      updated_by = auth.uid(),
      row_version = row_version + 1
  where roster_version_id = v_draft.roster_version_id
  returning * into v_draft;

  update public.roster_periods
  set status = 'PUBLISHED', published_at = now(), published_by = auth.uid(), updated_at = now()
  where roster_period_id = v_draft.roster_period_id;

  insert into public.production_roster_events (
    roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason,
    metadata
  ) values (
    v_draft.roster_version_id, 'PUBLISHED', auth.uid(), v_actor_staff,
    nullif(trim(p_reason), ''), jsonb_build_object('source_application', p_source_application)
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_PUBLISHED',
    'production_roster_versions', v_draft.roster_version_id::text,
    jsonb_build_object('version_number', v_draft.version_number, 'published_at', v_draft.published_at),
    nullif(trim(p_reason), ''), p_source_application
  );

  return jsonb_build_object(
    'roster_version_id', v_draft.roster_version_id,
    'version_number', v_draft.version_number,
    'status', v_draft.status,
    'row_version', v_draft.row_version,
    'published_at', v_draft.published_at,
    'superseded_version_id', v_previous_id
  );
end;
$$;

create or replace function public.cancel_production_roster_draft(
  p_roster_version_id uuid,
  p_base_row_version integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_draft public.production_roster_versions%rowtype;
  v_actor_staff uuid := public.current_staff_id();
begin
  perform public.require_production_roster_manage_role();

  if nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason is required to discard roster changes.';
  end if;

  select * into v_draft
  from public.production_roster_versions
  where roster_version_id = p_roster_version_id and status = 'DRAFT'
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Production Roster draft not found.';
  end if;

  if v_draft.row_version <> p_base_row_version then
    raise exception using errcode = '40001', message = 'The Production Roster was changed by another user.';
  end if;

  delete from public.production_roster_entries
  where roster_version_id = v_draft.roster_version_id;

  update public.production_roster_versions
  set status = 'CANCELLED', updated_by = auth.uid(), row_version = row_version + 1
  where roster_version_id = v_draft.roster_version_id
  returning * into v_draft;

  insert into public.production_roster_events (
    roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason
  ) values (
    v_draft.roster_version_id, 'DRAFT_CANCELLED', auth.uid(), v_actor_staff, trim(p_reason)
  );

  return jsonb_build_object('status', 'CANCELLED', 'roster_version_id', v_draft.roster_version_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Revocable mobile RosterView link and anonymous published read
-- ---------------------------------------------------------------------

create or replace function public.production_roster_view_token_hash(p_token text)
returns text
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select md5('ELISCARETEXT-ROSTER-VIEW-A:' || p_token)
      || md5('ELISCARETEXT-ROSTER-VIEW-B:' || p_token);
$$;

create or replace function public.rotate_production_roster_view_link(p_shift_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift public.shifts%rowtype;
  v_token text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_hint text;
begin
  perform public.require_production_roster_manage_role();

  select * into v_shift from public.shifts s
  where s.shift_code = upper(trim(p_shift_code)) and s.active = true and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid shift.';
  end if;

  v_hint := left(v_token, 4) || '…' || right(v_token, 4);

  update public.production_roster_view_links
  set active = false, revoked_at = now(), revoked_by = auth.uid()
  where shift_id = v_shift.shift_id and active = true;

  insert into public.production_roster_view_links (
    shift_id, token_hash, token_hint, active, created_by
  ) values (
    v_shift.shift_id, public.production_roster_view_token_hash(v_token), v_hint, true, auth.uid()
  );

  return jsonb_build_object(
    'token', v_token,
    'token_hint', v_hint,
    'shift_code', v_shift.shift_code,
    'shift_name', v_shift.shift_name,
    'created_at', now()
  );
end;
$$;

create or replace function public.get_published_production_roster(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_link public.production_roster_view_links%rowtype;
  v_shift public.shifts%rowtype;
  v_current_week date := public.production_roster_week_start(current_date);
begin
  if nullif(trim(p_token), '') is null then
    raise exception using errcode = '42501', message = 'A valid RosterView link is required.';
  end if;

  select * into v_link
  from public.production_roster_view_links prvl
  where prvl.token_hash = public.production_roster_view_token_hash(trim(p_token))
    and prvl.active = true;

  if not found then
    raise exception using errcode = '42501', message = 'This RosterView link is invalid or has been replaced.';
  end if;

  select * into v_shift from public.shifts where shift_id = v_link.shift_id;

  update public.production_roster_view_links
  set last_used_at = now()
  where roster_view_link_id = v_link.roster_view_link_id;

  return jsonb_build_object(
    'shift', jsonb_build_object('shift_code', v_shift.shift_code, 'shift_name', v_shift.shift_name),
    'generated_at', now(),
    'weeks', coalesce((
      select jsonb_agg(week_json order by (week_json ->> 'week_start')::date)
      from (
        select jsonb_build_object(
          'week_start', rp.week_start,
          'week_end', rp.week_start + 6,
          'version_number', prv.version_number,
          'published_at', prv.published_at,
          'week_note', prv.week_note,
          'include_sunday', prv.include_sunday,
          'entries', coalesce((
            select jsonb_agg(jsonb_build_object(
              'staff_id', pre.staff_id,
              'display_name', pre.staff_display_name_snapshot,
              'employee_code', pre.employee_code_snapshot,
              'work_date', pre.work_date,
              'day_status', pre.day_status,
              'assignment_type', pre.assignment_type,
              'operational_role_code', pre.operational_role_code_snapshot,
              'operational_role_name', pre.operational_role_name_snapshot,
              'area_code', pre.area_code_snapshot,
              'area_name', pre.area_name_snapshot,
              'station_code', pre.station_code_snapshot,
              'station_name', pre.station_name_snapshot
            ) order by lower(pre.staff_display_name_snapshot), pre.work_date)
            from public.production_roster_entries pre
            where pre.roster_version_id = prv.roster_version_id
          ), '[]'::jsonb)
        ) as week_json
        from public.production_roster_versions prv
        join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
        where prv.shift_id = v_shift.shift_id
          and prv.status = 'PUBLISHED'
          and rp.week_start in (v_current_week, v_current_week + 7)
      ) published_weeks
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Security
-- ---------------------------------------------------------------------

alter table public.production_roster_versions enable row level security;
alter table public.production_roster_entries enable row level security;
alter table public.production_roster_events enable row level security;
alter table public.production_roster_view_links enable row level security;

revoke all on table public.production_roster_versions from public, anon, authenticated;
revoke all on table public.production_roster_entries from public, anon, authenticated;
revoke all on table public.production_roster_events from public, anon, authenticated;
revoke all on table public.production_roster_view_links from public, anon, authenticated;

revoke all on function public.production_roster_week_start(date) from public, anon, authenticated;
revoke all on function public.require_production_roster_read_role() from public, anon, authenticated;
revoke all on function public.require_production_roster_manage_role() from public, anon, authenticated;
revoke all on function public.get_production_roster_reference_data() from public, anon, authenticated;
revoke all on function public.get_production_roster_week(date, text, uuid) from public, anon, authenticated;
revoke all on function public.get_production_roster_history(date, text) from public, anon, authenticated;
revoke all on function public.save_production_roster_week(date, text, boolean, text, jsonb, integer, text, text) from public, anon, authenticated;
revoke all on function public.publish_production_roster_week(uuid, integer, text, text) from public, anon, authenticated;
revoke all on function public.cancel_production_roster_draft(uuid, integer, text) from public, anon, authenticated;
revoke all on function public.rotate_production_roster_view_link(text) from public, anon, authenticated;
revoke all on function public.get_published_production_roster(text) from public, anon, authenticated;

-- Internal helper remains unavailable to browsers.
grant execute on function public.production_roster_week_start(date) to authenticated;
grant execute on function public.get_production_roster_reference_data() to authenticated;
grant execute on function public.get_production_roster_week(date, text, uuid) to authenticated;
grant execute on function public.get_production_roster_history(date, text) to authenticated;
grant execute on function public.save_production_roster_week(date, text, boolean, text, jsonb, integer, text, text) to authenticated;
grant execute on function public.publish_production_roster_week(uuid, integer, text, text) to authenticated;
grant execute on function public.cancel_production_roster_draft(uuid, integer, text) to authenticated;
grant execute on function public.rotate_production_roster_view_link(text) to authenticated;
grant execute on function public.get_published_production_roster(text) to anon, authenticated;

comment on table public.production_roster_versions is
  'Versioned Morning/Evening Production Roster. Published versions are immutable and retained for historical consultation.';
comment on table public.production_roster_entries is
  'Daily planned staff status and assignment snapshots for a Production Roster version.';
comment on table public.production_roster_view_links is
  'Revocable read-only links used by staff to view current and next published roster on mobile devices.';

commit;
