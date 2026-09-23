-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608040004_staff_master_management.sql
-- Purpose:
--   Add a governed Staff Master for operational staff. The model keeps
--   system permissions separate from operational roles, preserves staff
--   history through activation/deactivation, and records COVER
--   capabilities without replacing the staff member's primary function.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Safety checks
-- ---------------------------------------------------------------------

do $$
begin
  if to_regclass('public.staff_members') is null
     or to_regclass('public.roles') is null
     or to_regclass('public.staff_roles') is null
     or to_regclass('public.areas') is null
     or to_regclass('public.stations') is null
     or to_regclass('public.shifts') is null
     or to_regclass('public.audit_log') is null then
    raise exception 'Required ElisCaretex foundation tables are missing.';
  end if;

  if to_regprocedure('public.has_any_role(text[])') is null
     or to_regprocedure('public.current_staff_id()') is null then
    raise exception 'Required authentication helpers are missing.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Operational roles are work functions, not application permissions.
-- Examples: GENERAL_OPERATIVE, TEAM_LEADER and SORTING_AREA.
-- ---------------------------------------------------------------------

create table if not exists public.operational_roles (
  operational_role_id uuid primary key default gen_random_uuid(),
  role_code text not null unique,
  role_name text not null,
  description text,
  allow_as_primary boolean not null default true,
  allow_as_cover boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

insert into public.operational_roles (
  role_code,
  role_name,
  description,
  allow_as_primary,
  allow_as_cover,
  sort_order
)
values
  ('SUPERVISOR', 'Supervisor', 'Operational production supervisor.', true, true, 10),
  ('SORTING_AREA', 'Sorting Area', 'Sorting and washing-preparation work.', true, true, 20),
  ('LABEL', 'Label', 'Label preparation and control.', true, false, 30),
  ('TEAM_LEADER', 'Team Leader', 'Team leadership for an operational table or area.', true, true, 40),
  ('GENERAL_OPERATIVE', 'General Operative', 'General production operative.', true, false, 50),
  ('CLEANER', 'Cleaner', 'Cleaning and facility support.', true, false, 60),
  ('SUPPORT_ROLE', 'Support Role', 'Flexible operational support.', true, false, 70)
on conflict (role_code) do update
set
  role_name = excluded.role_name,
  description = excluded.description,
  allow_as_primary = excluded.allow_as_primary,
  allow_as_cover = excluded.allow_as_cover,
  active = true,
  sort_order = excluded.sort_order,
  updated_at = now(),
  deleted_at = null;

-- ---------------------------------------------------------------------
-- Reference records required by the Staff Master and future Roster.
-- Start/end times remain null until the business confirms them.
-- ---------------------------------------------------------------------

insert into public.shifts (
  shift_code,
  shift_name,
  start_time,
  end_time,
  crosses_midnight,
  active,
  sort_order
)
values
  ('MORNING', 'Morning Shift', null, null, false, true, 10),
  ('EVENING', 'Evening Shift', null, null, false, true, 20)
on conflict (shift_code) do update
set
  shift_name = excluded.shift_name,
  active = true,
  sort_order = excluded.sort_order,
  updated_at = now(),
  deleted_at = null;

insert into public.stations (
  area_id,
  station_code,
  station_name,
  station_type,
  active,
  sort_order
)
select a.area_id, values_row.station_code, values_row.station_name,
       values_row.station_type, true, values_row.sort_order
from public.areas a
join (
  values
    ('FINISH', 'FINISH_TABLE_1', 'Table 1', 'TABLE', 10),
    ('FINISH', 'FINISH_TABLE_2', 'Table 2', 'TABLE', 20),
    ('FINISH', 'FINISH_TABLE_3', 'Table 3', 'TABLE', 30),
    ('FINISH', 'FINISH_LABEL', 'Label', 'WORKSTATION', 40),
    ('SORTING', 'SORTING_MAIN', 'Sorting Area', 'AREA_STATION', 10)
) as values_row(area_code, station_code, station_name, station_type, sort_order)
  on values_row.area_code = a.area_code
on conflict (station_code) do update
set
  area_id = excluded.area_id,
  station_name = excluded.station_name,
  station_type = excluded.station_type,
  active = true,
  sort_order = excluded.sort_order,
  updated_at = now(),
  deleted_at = null;

-- ---------------------------------------------------------------------
-- Staff Master extensions
-- Empty legacy training values are imported as false by the seed.
-- Missing joined/deactivated dates remain null and are not review errors.
-- ---------------------------------------------------------------------

alter table public.staff_members
  add column if not exists legacy_user_id integer,
  add column if not exists roster_eligible boolean not null default true,
  add column if not exists default_shift_id uuid references public.shifts(shift_id) on delete restrict,
  add column if not exists primary_operational_role_id uuid references public.operational_roles(operational_role_id) on delete restrict,
  add column if not exists default_area_id uuid references public.areas(area_id) on delete restrict,
  add column if not exists default_station_id uuid references public.stations(station_id) on delete restrict,
  add column if not exists fire_training boolean not null default false,
  add column if not exists first_aid_training boolean not null default false,
  add column if not exists eod_capable boolean not null default false,
  add column if not exists notes text,
  add column if not exists deactivation_reason text,
  add column if not exists import_review_required boolean not null default false,
  add column if not exists import_review_notes text,
  add column if not exists row_version integer not null default 1;

create unique index if not exists staff_members_legacy_user_id_unique
  on public.staff_members (legacy_user_id)
  where legacy_user_id is not null;

create index if not exists staff_members_directory_idx
  on public.staff_members (
    active,
    roster_eligible,
    default_shift_id,
    lower(display_name)
  )
  where deleted_at is null;

-- COVER is a temporary daily assignment. These rows record which
-- alternative roles the person is allowed to cover; they do not replace
-- the primary operational role stored on staff_members.
create table if not exists public.staff_cover_capabilities (
  staff_cover_capability_id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  operational_role_id uuid not null references public.operational_roles(operational_role_id) on delete restrict,
  effective_from date not null default current_date,
  effective_until date,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  constraint staff_cover_capability_dates_check
    check (effective_until is null or effective_until >= effective_from)
);

create unique index if not exists staff_cover_capabilities_active_unique
  on public.staff_cover_capabilities (staff_id, operational_role_id)
  where active = true and effective_until is null and deleted_at is null;

create index if not exists staff_cover_capabilities_staff_idx
  on public.staff_cover_capabilities (staff_id, active, effective_from, effective_until);

-- Updated-at triggers.
drop trigger if exists operational_roles_set_updated_at on public.operational_roles;
create trigger operational_roles_set_updated_at
before update on public.operational_roles
for each row execute function public.set_updated_at();

drop trigger if exists staff_cover_capabilities_set_updated_at on public.staff_cover_capabilities;
create trigger staff_cover_capabilities_set_updated_at
before update on public.staff_cover_capabilities
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Permission helpers
-- ---------------------------------------------------------------------

create or replace function public.require_staff_master_read_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.has_any_role(
    array['ADMIN', 'MANAGER', 'ROSTER_MANAGER', 'SUPERVISOR', 'AUDITOR']
  ) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to view Staff Master.';
  end if;
end;
$$;

create or replace function public.require_staff_master_manage_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER']) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to maintain Staff Master.';
  end if;
end;
$$;

revoke all on function public.require_staff_master_read_role() from public, anon, authenticated;
revoke all on function public.require_staff_master_manage_role() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------

create or replace function public.generate_staff_employee_code()
returns text
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_code text;
  v_attempt integer := 0;
begin
  loop
    v_attempt := v_attempt + 1;
    v_code := 'STF-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 7));

    exit when not exists (
      select 1
      from public.staff_members sm
      where sm.employee_code = v_code
    );

    if v_attempt >= 20 then
      raise exception 'Unable to generate a unique employee code.';
    end if;
  end loop;

  return v_code;
end;
$$;

revoke all on function public.generate_staff_employee_code() from public, anon, authenticated;

create or replace function public.validate_staff_work_defaults(
  p_primary_role_code text,
  p_default_area_code text,
  p_default_station_code text
)
returns table (
  operational_role_id uuid,
  area_id uuid,
  station_id uuid
)
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_role public.operational_roles%rowtype;
  v_area public.areas%rowtype;
  v_station public.stations%rowtype;
begin
  if nullif(trim(p_primary_role_code), '') is null then
    raise exception 'A primary operational role is required.';
  end if;

  select * into v_role
  from public.operational_roles opr
  where opr.role_code = upper(trim(p_primary_role_code))
    and opr.allow_as_primary = true
    and opr.active = true
    and opr.deleted_at is null;

  if not found then
    raise exception 'Primary operational role is invalid or inactive.';
  end if;

  if nullif(trim(p_default_area_code), '') is not null then
    select * into v_area
    from public.areas a
    where a.area_code = upper(trim(p_default_area_code))
      and a.active = true
      and a.deleted_at is null;

    if not found then
      raise exception 'Default work area is invalid or inactive.';
    end if;
  end if;

  if nullif(trim(p_default_station_code), '') is not null then
    select * into v_station
    from public.stations s
    where s.station_code = upper(trim(p_default_station_code))
      and s.active = true
      and s.deleted_at is null;

    if not found then
      raise exception 'Default station is invalid or inactive.';
    end if;

    if v_area.area_id is null or v_station.area_id <> v_area.area_id then
      raise exception 'Default station does not belong to the selected work area.';
    end if;
  end if;

  operational_role_id := v_role.operational_role_id;
  area_id := v_area.area_id;
  station_id := v_station.station_id;
  return next;
end;
$$;

revoke all on function public.validate_staff_work_defaults(text, text, text)
  from public, anon, authenticated;

create or replace function public.sync_staff_cover_capabilities(
  p_staff_id uuid,
  p_cover_role_codes text[]
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_codes text[] := array(
    select distinct upper(trim(value))
    from unnest(coalesce(p_cover_role_codes, array[]::text[])) value
    where nullif(trim(value), '') is not null
  );
  v_invalid_codes text[];
  v_role record;
begin
  select array_agg(code order by code)
  into v_invalid_codes
  from unnest(v_codes) code
  where not exists (
    select 1
    from public.operational_roles opr
    where opr.role_code = code
      and opr.allow_as_cover = true
      and opr.active = true
      and opr.deleted_at is null
  );

  if coalesce(array_length(v_invalid_codes, 1), 0) > 0 then
    raise exception 'Invalid COVER roles: %', array_to_string(v_invalid_codes, ', ');
  end if;

  update public.staff_cover_capabilities scc
  set
    active = false,
    effective_until = current_date,
    updated_by = auth.uid()
  where scc.staff_id = p_staff_id
    and scc.active = true
    and scc.effective_until is null
    and scc.deleted_at is null
    and not exists (
      select 1
      from public.operational_roles opr
      where opr.operational_role_id = scc.operational_role_id
        and opr.role_code = any(v_codes)
    );

  for v_role in
    select opr.operational_role_id
    from public.operational_roles opr
    where opr.role_code = any(v_codes)
      and opr.allow_as_cover = true
      and opr.active = true
      and opr.deleted_at is null
  loop
    if not exists (
      select 1
      from public.staff_cover_capabilities scc
      where scc.staff_id = p_staff_id
        and scc.operational_role_id = v_role.operational_role_id
        and scc.active = true
        and scc.effective_until is null
        and scc.deleted_at is null
    ) then
      insert into public.staff_cover_capabilities (
        staff_id,
        operational_role_id,
        effective_from,
        active,
        created_by,
        updated_by
      )
      values (
        p_staff_id,
        v_role.operational_role_id,
        current_date,
        true,
        auth.uid(),
        auth.uid()
      );
    end if;
  end loop;
end;
$$;

revoke all on function public.sync_staff_cover_capabilities(uuid, text[])
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Read APIs
-- ---------------------------------------------------------------------

create or replace function public.get_staff_master_reference_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_staff_master_read_role();

  return jsonb_build_object(
    'business_date', current_date,
    'can_edit_staff', public.has_any_role(array['ADMIN', 'MANAGER']),
    'can_deactivate_staff', public.has_any_role(array['ADMIN', 'MANAGER']),
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
      where s.active = true and s.deleted_at is null
    ), '[]'::jsonb),
    'operational_roles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'operational_role_id', opr.operational_role_id,
        'role_code', opr.role_code,
        'role_name', opr.role_name,
        'allow_as_primary', opr.allow_as_primary,
        'allow_as_cover', opr.allow_as_cover,
        'sort_order', opr.sort_order
      ) order by opr.sort_order, opr.role_name)
      from public.operational_roles opr
      where opr.active = true and opr.deleted_at is null
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
    ), '[]'::jsonb),
    'stations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'station_id', s.station_id,
        'station_code', s.station_code,
        'station_name', s.station_name,
        'station_type', s.station_type,
        'area_id', s.area_id,
        'sort_order', s.sort_order
      ) order by a.sort_order, s.sort_order, s.station_name)
      from public.stations s
      join public.areas a on a.area_id = s.area_id
      where s.active = true and s.deleted_at is null
        and a.active = true and a.deleted_at is null
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_staff_directory(
  p_status text default 'ACTIVE',
  p_shift_code text default null,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_status text := upper(coalesce(nullif(trim(p_status), ''), 'ACTIVE'));
  v_shift_code text := upper(nullif(trim(p_shift_code), ''));
  v_search text := lower(nullif(trim(p_search), ''));
begin
  perform public.require_staff_master_read_role();

  if v_status not in ('ALL', 'ACTIVE', 'INACTIVE', 'REVIEW') then
    raise exception 'Invalid Staff Master status filter.';
  end if;

  return jsonb_build_object(
    'summary', jsonb_build_object(
      'total', (select count(*) from public.staff_members sm where sm.deleted_at is null),
      'active', (select count(*) from public.staff_members sm where sm.active = true and sm.deleted_at is null),
      'inactive', (select count(*) from public.staff_members sm where sm.active = false and sm.deleted_at is null),
      'roster_eligible', (select count(*) from public.staff_members sm where sm.active = true and sm.roster_eligible = true and sm.deleted_at is null),
      'review_required', (select count(*) from public.staff_members sm where sm.import_review_required = true and sm.deleted_at is null)
    ),
    'staff', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'staff_id', sm.staff_id,
          'legacy_user_id', sm.legacy_user_id,
          'employee_code', sm.employee_code,
          'display_name', sm.display_name,
          'active', sm.active,
          'roster_eligible', sm.roster_eligible,
          'default_shift_code', sh.shift_code,
          'default_shift_name', sh.shift_name,
          'primary_role_code', opr.role_code,
          'primary_role_name', opr.role_name,
          'default_area_code', a.area_code,
          'default_area_name', a.area_name,
          'default_station_code', st.station_code,
          'default_station_name', st.station_name,
          'fire_training', sm.fire_training,
          'first_aid_training', sm.first_aid_training,
          'eod_capable', sm.eod_capable,
          'joined_on', sm.joined_on,
          'deactivated_on', sm.deactivated_on,
          'deactivation_reason', sm.deactivation_reason,
          'import_review_required', sm.import_review_required,
          'import_review_notes', sm.import_review_notes,
          'cover_roles', coalesce((
            select jsonb_agg(jsonb_build_object(
              'role_code', cover_role.role_code,
              'role_name', cover_role.role_name
            ) order by cover_role.sort_order, cover_role.role_name)
            from public.staff_cover_capabilities scc
            join public.operational_roles cover_role
              on cover_role.operational_role_id = scc.operational_role_id
            where scc.staff_id = sm.staff_id
              and scc.active = true
              and scc.effective_from <= current_date
              and (scc.effective_until is null or scc.effective_until >= current_date)
              and scc.deleted_at is null
              and cover_role.active = true
              and cover_role.deleted_at is null
          ), '[]'::jsonb),
          'row_version', sm.row_version,
          'updated_at', sm.updated_at
        )
        order by
          case when sm.active then 0 else 1 end,
          coalesce(sh.sort_order, 999),
          coalesce(opr.sort_order, 999),
          lower(sm.display_name)
      )
      from public.staff_members sm
      left join public.shifts sh on sh.shift_id = sm.default_shift_id
      left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
      left join public.areas a on a.area_id = sm.default_area_id
      left join public.stations st on st.station_id = sm.default_station_id
      where sm.deleted_at is null
        and (
          v_status = 'ALL'
          or (v_status = 'ACTIVE' and sm.active = true)
          or (v_status = 'INACTIVE' and sm.active = false)
          or (v_status = 'REVIEW' and sm.import_review_required = true)
        )
        and (v_shift_code is null or sh.shift_code = v_shift_code)
        and (
          v_search is null
          or lower(sm.display_name) like '%' || v_search || '%'
          or lower(coalesce(sm.employee_code, '')) like '%' || v_search || '%'
          or lower(coalesce(opr.role_name, '')) like '%' || v_search || '%'
          or lower(coalesce(st.station_name, '')) like '%' || v_search || '%'
        )
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_staff_master_record(
  p_staff_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_result jsonb;
begin
  perform public.require_staff_master_read_role();

  if p_staff_id is null then
    raise exception 'Staff ID is required.';
  end if;

  select jsonb_build_object(
    'staff_id', sm.staff_id,
    'legacy_user_id', sm.legacy_user_id,
    'employee_code', sm.employee_code,
    'display_name', sm.display_name,
    'active', sm.active,
    'roster_eligible', sm.roster_eligible,
    'default_shift_code', sh.shift_code,
    'primary_role_code', opr.role_code,
    'default_area_code', a.area_code,
    'default_station_code', st.station_code,
    'fire_training', sm.fire_training,
    'first_aid_training', sm.first_aid_training,
    'eod_capable', sm.eod_capable,
    'joined_on', sm.joined_on,
    'deactivated_on', sm.deactivated_on,
    'deactivation_reason', sm.deactivation_reason,
    'notes', sm.notes,
    'import_review_required', sm.import_review_required,
    'import_review_notes', sm.import_review_notes,
    'cover_role_codes', coalesce((
      select array_agg(cover_role.role_code order by cover_role.sort_order, cover_role.role_code)
      from public.staff_cover_capabilities scc
      join public.operational_roles cover_role
        on cover_role.operational_role_id = scc.operational_role_id
      where scc.staff_id = sm.staff_id
        and scc.active = true
        and scc.effective_from <= current_date
        and (scc.effective_until is null or scc.effective_until >= current_date)
        and scc.deleted_at is null
    ), array[]::text[]),
    'row_version', sm.row_version,
    'created_at', sm.created_at,
    'updated_at', sm.updated_at
  )
  into v_result
  from public.staff_members sm
  left join public.shifts sh on sh.shift_id = sm.default_shift_id
  left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
  left join public.areas a on a.area_id = sm.default_area_id
  left join public.stations st on st.station_id = sm.default_station_id
  where sm.staff_id = p_staff_id
    and sm.deleted_at is null;

  if v_result is null then
    raise exception using errcode = 'P0002', message = 'Staff member not found.';
  end if;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Write APIs
-- ---------------------------------------------------------------------

create or replace function public.create_staff_master(
  p_display_name text,
  p_employee_code text default null,
  p_default_shift_code text default null,
  p_primary_role_code text default null,
  p_default_area_code text default null,
  p_default_station_code text default null,
  p_roster_eligible boolean default true,
  p_cover_role_codes text[] default array[]::text[],
  p_fire_training boolean default false,
  p_first_aid_training boolean default false,
  p_eod_capable boolean default false,
  p_joined_on date default null,
  p_notes text default null,
  p_change_reason text default null,
  p_source_application text default 'STAFF_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_defaults record;
  v_shift_id uuid;
  v_staff public.staff_members%rowtype;
  v_employee_code text;
begin
  perform public.require_staff_master_manage_role();

  if nullif(trim(p_display_name), '') is null then
    raise exception 'Staff name is required.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception 'A creation reason is required.';
  end if;

  select * into v_defaults
  from public.validate_staff_work_defaults(
    p_primary_role_code,
    p_default_area_code,
    p_default_station_code
  );

  if nullif(trim(p_default_shift_code), '') is not null then
    select s.shift_id into v_shift_id
    from public.shifts s
    where s.shift_code = upper(trim(p_default_shift_code))
      and s.active = true
      and s.deleted_at is null;

    if v_shift_id is null then
      raise exception 'Default shift is invalid or inactive.';
    end if;
  end if;

  v_employee_code := upper(nullif(trim(p_employee_code), ''));
  if v_employee_code is null then
    v_employee_code := public.generate_staff_employee_code();
  end if;

  if exists (
    select 1 from public.staff_members sm where sm.employee_code = v_employee_code
  ) then
    raise exception 'Employee code already exists.';
  end if;

  insert into public.staff_members (
    employee_code,
    display_name,
    active,
    roster_eligible,
    default_shift_id,
    primary_operational_role_id,
    default_area_id,
    default_station_id,
    fire_training,
    first_aid_training,
    eod_capable,
    joined_on,
    notes,
    row_version,
    created_by,
    updated_by
  )
  values (
    v_employee_code,
    trim(p_display_name),
    true,
    coalesce(p_roster_eligible, true),
    v_shift_id,
    v_defaults.operational_role_id,
    v_defaults.area_id,
    v_defaults.station_id,
    coalesce(p_fire_training, false),
    coalesce(p_first_aid_training, false),
    coalesce(p_eod_capable, false),
    p_joined_on,
    nullif(trim(p_notes), ''),
    1,
    auth.uid(),
    auth.uid()
  )
  returning * into v_staff;

  perform public.sync_staff_cover_capabilities(v_staff.staff_id, p_cover_role_codes);

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'CREATE_STAFF_MEMBER',
    'staff_members',
    v_staff.staff_id::text,
    public.get_staff_master_record(v_staff.staff_id),
    trim(p_change_reason),
    coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI')
  );

  return public.get_staff_master_record(v_staff.staff_id);
end;
$$;

create or replace function public.update_staff_master(
  p_staff_id uuid,
  p_expected_row_version integer,
  p_display_name text,
  p_employee_code text,
  p_default_shift_code text,
  p_primary_role_code text,
  p_default_area_code text,
  p_default_station_code text,
  p_roster_eligible boolean,
  p_cover_role_codes text[],
  p_fire_training boolean,
  p_first_aid_training boolean,
  p_eod_capable boolean,
  p_joined_on date,
  p_notes text,
  p_import_review_required boolean default false,
  p_import_review_notes text default null,
  p_change_reason text default null,
  p_source_application text default 'STAFF_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before jsonb;
  v_defaults record;
  v_shift_id uuid;
  v_staff public.staff_members%rowtype;
  v_employee_code text := upper(nullif(trim(p_employee_code), ''));
begin
  perform public.require_staff_master_manage_role();

  if p_staff_id is null then
    raise exception 'Staff ID is required.';
  end if;

  if p_expected_row_version is null or p_expected_row_version < 1 then
    raise exception 'A valid row version is required.';
  end if;

  if nullif(trim(p_display_name), '') is null then
    raise exception 'Staff name is required.';
  end if;

  if v_employee_code is null then
    raise exception 'Employee code is required.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception 'A change reason is required.';
  end if;

  v_before := public.get_staff_master_record(p_staff_id);

  select * into v_defaults
  from public.validate_staff_work_defaults(
    p_primary_role_code,
    p_default_area_code,
    p_default_station_code
  );

  if nullif(trim(p_default_shift_code), '') is not null then
    select s.shift_id into v_shift_id
    from public.shifts s
    where s.shift_code = upper(trim(p_default_shift_code))
      and s.active = true
      and s.deleted_at is null;

    if v_shift_id is null then
      raise exception 'Default shift is invalid or inactive.';
    end if;
  end if;

  if exists (
    select 1
    from public.staff_members sm
    where sm.employee_code = v_employee_code
      and sm.staff_id <> p_staff_id
  ) then
    raise exception 'Employee code already exists.';
  end if;

  update public.staff_members sm
  set
    employee_code = v_employee_code,
    display_name = trim(p_display_name),
    roster_eligible = coalesce(p_roster_eligible, false),
    default_shift_id = v_shift_id,
    primary_operational_role_id = v_defaults.operational_role_id,
    default_area_id = v_defaults.area_id,
    default_station_id = v_defaults.station_id,
    fire_training = coalesce(p_fire_training, false),
    first_aid_training = coalesce(p_first_aid_training, false),
    eod_capable = coalesce(p_eod_capable, false),
    joined_on = p_joined_on,
    notes = nullif(trim(p_notes), ''),
    import_review_required = coalesce(p_import_review_required, false),
    import_review_notes = case
      when coalesce(p_import_review_required, false) then nullif(trim(p_import_review_notes), '')
      else null
    end,
    row_version = sm.row_version + 1,
    updated_by = auth.uid()
  where sm.staff_id = p_staff_id
    and sm.row_version = p_expected_row_version
    and sm.deleted_at is null
  returning * into v_staff;

  if not found then
    if not exists (
      select 1 from public.staff_members sm
      where sm.staff_id = p_staff_id and sm.deleted_at is null
    ) then
      raise exception using errcode = 'P0002', message = 'Staff member not found.';
    end if;

    raise exception using
      errcode = '40001',
      message = 'Staff record changed in another session. Reload before saving.';
  end if;

  perform public.sync_staff_cover_capabilities(v_staff.staff_id, p_cover_role_codes);

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'UPDATE_STAFF_MEMBER',
    'staff_members',
    v_staff.staff_id::text,
    v_before,
    public.get_staff_master_record(v_staff.staff_id),
    trim(p_change_reason),
    coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI')
  );

  return public.get_staff_master_record(v_staff.staff_id);
end;
$$;

create or replace function public.deactivate_staff_member(
  p_staff_id uuid,
  p_expected_row_version integer,
  p_deactivated_on date default current_date,
  p_reason text default null,
  p_source_application text default 'STAFF_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before jsonb;
  v_staff public.staff_members%rowtype;
begin
  perform public.require_staff_master_manage_role();

  if p_staff_id is null then
    raise exception 'Staff ID is required.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A deactivation reason is required.';
  end if;

  if exists (
    select 1
    from public.staff_members sm
    where sm.staff_id = p_staff_id
      and sm.auth_user_id = auth.uid()
  ) then
    raise exception 'You cannot deactivate your own signed-in staff profile.';
  end if;

  v_before := public.get_staff_master_record(p_staff_id);

  update public.staff_members sm
  set
    active = false,
    roster_eligible = false,
    deactivated_on = coalesce(p_deactivated_on, current_date),
    deactivation_reason = trim(p_reason),
    row_version = sm.row_version + 1,
    updated_by = auth.uid()
  where sm.staff_id = p_staff_id
    and sm.row_version = p_expected_row_version
    and sm.active = true
    and sm.deleted_at is null
  returning * into v_staff;

  if not found then
    raise exception 'Staff member is inactive, missing or has changed. Reload before continuing.';
  end if;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'DEACTIVATE_STAFF_MEMBER',
    'staff_members',
    v_staff.staff_id::text,
    v_before,
    public.get_staff_master_record(v_staff.staff_id),
    trim(p_reason),
    coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI')
  );

  return public.get_staff_master_record(v_staff.staff_id);
end;
$$;

create or replace function public.reactivate_staff_member(
  p_staff_id uuid,
  p_expected_row_version integer,
  p_roster_eligible boolean default true,
  p_reason text default null,
  p_source_application text default 'STAFF_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before jsonb;
  v_staff public.staff_members%rowtype;
begin
  perform public.require_staff_master_manage_role();

  if p_staff_id is null then
    raise exception 'Staff ID is required.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A reactivation reason is required.';
  end if;

  v_before := public.get_staff_master_record(p_staff_id);

  update public.staff_members sm
  set
    active = true,
    roster_eligible = coalesce(p_roster_eligible, true),
    deactivated_on = null,
    deactivation_reason = null,
    row_version = sm.row_version + 1,
    updated_by = auth.uid()
  where sm.staff_id = p_staff_id
    and sm.row_version = p_expected_row_version
    and sm.active = false
    and sm.deleted_at is null
  returning * into v_staff;

  if not found then
    raise exception 'Staff member is active, missing or has changed. Reload before continuing.';
  end if;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'REACTIVATE_STAFF_MEMBER',
    'staff_members',
    v_staff.staff_id::text,
    v_before,
    public.get_staff_master_record(v_staff.staff_id),
    trim(p_reason),
    coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI')
  );

  return public.get_staff_master_record(v_staff.staff_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Permissions and RLS
-- ---------------------------------------------------------------------

alter table public.operational_roles enable row level security;
alter table public.staff_cover_capabilities enable row level security;

revoke all on table public.operational_roles from public, anon, authenticated;
revoke all on table public.staff_cover_capabilities from public, anon, authenticated;
revoke insert, update, delete, truncate on table public.staff_members from authenticated;

revoke all on function public.get_staff_master_reference_data() from public, anon;
revoke all on function public.get_staff_directory(text, text, text) from public, anon;
revoke all on function public.get_staff_master_record(uuid) from public, anon;
revoke all on function public.create_staff_master(
  text, text, text, text, text, text, boolean, text[], boolean, boolean,
  boolean, date, text, text, text
) from public, anon;
revoke all on function public.update_staff_master(
  uuid, integer, text, text, text, text, text, text, boolean, text[],
  boolean, boolean, boolean, date, text, boolean, text, text, text
) from public, anon;
revoke all on function public.deactivate_staff_member(uuid, integer, date, text, text)
  from public, anon;
revoke all on function public.reactivate_staff_member(uuid, integer, boolean, text, text)
  from public, anon;

grant execute on function public.get_staff_master_reference_data() to authenticated;
grant execute on function public.get_staff_directory(text, text, text) to authenticated;
grant execute on function public.get_staff_master_record(uuid) to authenticated;
grant execute on function public.create_staff_master(
  text, text, text, text, text, text, boolean, text[], boolean, boolean,
  boolean, date, text, text, text
) to authenticated;
grant execute on function public.update_staff_master(
  uuid, integer, text, text, text, text, text, text, boolean, text[],
  boolean, boolean, boolean, date, text, boolean, text, text, text
) to authenticated;
grant execute on function public.deactivate_staff_member(uuid, integer, date, text, text)
  to authenticated;
grant execute on function public.reactivate_staff_member(uuid, integer, boolean, text, text)
  to authenticated;

commit;
