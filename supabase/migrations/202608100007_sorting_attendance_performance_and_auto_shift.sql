-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608100007_sorting_attendance_performance_and_auto_shift
--
-- Operational rules:
--   * Production Roster remains Planned.
--   * Sorting attendance is an Actual overlay. Planned staff can be marked
--     ABSENT without mutating the published Roster.
--   * A staff member explicitly marked ABSENT cannot be used as wash operator
--     or assigned as Actual MOP until attendance is corrected.
--   * Washing performance is attributed by sorting_wash_runs.operator_staff_id.
--   * CLOTHES target = 160 KG/staff-hour.
--   * MOP reference target = 100 KG/staff-hour and is explicitly provisional.
--   * Targets are production_targets master data and therefore appear in
--     Production Roster -> Settings -> Targets.
--   * Auto Shift is derived from the standard weekly schedule. Manual Shift
--     override remains a workstation/session decision and does not edit Roster.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Targets: authoritative Production Roster Settings master data
-- ---------------------------------------------------------------------

insert into public.production_targets (
  target_code,
  target_name,
  area_code,
  metric_code,
  unit_code,
  target_value,
  description,
  active,
  sort_order
)
values
  (
    'SORTING_CLOTHES_KG_PER_STAFF_HOUR',
    'Sorting Clothes productivity',
    'SORTING',
    'PRODUCTIVITY_PER_STAFF_HOUR',
    'KG_PER_STAFF_HOUR',
    160,
    'Target kilograms per effective Sorting staff hour for CLOTHES washing.',
    true,
    20
  ),
  (
    'SORTING_MOP_KG_PER_STAFF_HOUR',
    'Sorting MOP productivity (provisional)',
    'SORTING',
    'PRODUCTIVITY_PER_STAFF_HOUR',
    'KG_PER_STAFF_HOUR',
    100,
    'Provisional reference only. MOP wetness and model variation mean recorded KG is not a precise measure of actual dry MOP mass.',
    true,
    30
  )
on conflict (target_code) do update
set
  target_name = excluded.target_name,
  area_code = excluded.area_code,
  metric_code = excluded.metric_code,
  unit_code = excluded.unit_code,
  description = excluded.description,
  active = true,
  sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- 2. Actual attendance overlay
-- ---------------------------------------------------------------------

create table if not exists public.sorting_daily_staff_attendance (
  sorting_daily_staff_attendance_id uuid primary key default gen_random_uuid(),
  business_date date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  attendance_status text not null,
  absence_reason text,
  notes text,
  source text not null default 'SORTING_WORKSTATION',
  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by_auth_user_id uuid references auth.users(id) on delete set null,
  constraint sorting_daily_staff_attendance_unique
    unique (business_date, shift_id, staff_id),
  constraint sorting_daily_staff_attendance_status_check
    check (attendance_status in ('PRESENT','ABSENT')),
  constraint sorting_daily_staff_attendance_absence_reason_check
    check (absence_reason is null or absence_reason in ('SICK','NO_SHOW','OTHER')),
  constraint sorting_daily_staff_attendance_reason_required_check
    check (
      (attendance_status = 'PRESENT' and absence_reason is null)
      or
      (attendance_status = 'ABSENT' and absence_reason is not null)
    )
);

alter table public.sorting_daily_staff_attendance enable row level security;
revoke all on table public.sorting_daily_staff_attendance from public, anon, authenticated;

create index if not exists sorting_daily_staff_attendance_date_shift_idx
  on public.sorting_daily_staff_attendance (
    business_date,
    shift_id,
    attendance_status,
    staff_id
  );

-- ---------------------------------------------------------------------
-- 3. Misuse guards: ABSENT cannot be used as a shortcut
-- ---------------------------------------------------------------------

create or replace function public.sorting_guard_absent_mop_mode()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.work_mode = 'MOP'
     and exists (
       select 1
       from public.sorting_daily_staff_attendance a
       where a.business_date = new.business_date
         and a.shift_id = new.shift_id
         and a.staff_id = new.staff_id
         and a.attendance_status = 'ABSENT'
     ) then
    raise exception using
      errcode = '22023',
      message = 'This staff member is marked absent and cannot be assigned as Actual MOP. Mark the staff member present first.';
  end if;

  return new;
end;
$$;

drop trigger if exists sorting_daily_staff_modes_absent_mop_guard
  on public.sorting_daily_staff_modes;

create trigger sorting_daily_staff_modes_absent_mop_guard
before insert or update of work_mode
on public.sorting_daily_staff_modes
for each row
execute function public.sorting_guard_absent_mop_mode();

create or replace function public.sorting_guard_absent_wash_operator()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.status = 'RECORDED'
     and exists (
       select 1
       from public.sorting_daily_staff_attendance a
       where a.business_date = new.business_date
         and a.shift_id = new.shift_id
         and a.staff_id = new.operator_staff_id
         and a.attendance_status = 'ABSENT'
     ) then
    raise exception using
      errcode = '22023',
      message = 'The selected washing operator is marked absent for this Business Date and Shift. Correct attendance before recording a wash.';
  end if;

  return new;
end;
$$;

drop trigger if exists sorting_wash_runs_absent_operator_guard
  on public.sorting_wash_runs;

create trigger sorting_wash_runs_absent_operator_guard
before insert or update of operator_staff_id, business_date, shift_id, status
on public.sorting_wash_runs
for each row
execute function public.sorting_guard_absent_wash_operator();

-- ---------------------------------------------------------------------
-- 4. Attendance write RPC
-- ---------------------------------------------------------------------

create or replace function public.set_sorting_staff_attendance(
  p_shift_code text,
  p_staff_id uuid,
  p_attendance_status text,
  p_absence_reason text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_status text := upper(trim(coalesce(p_attendance_status, '')));
  v_reason text := nullif(upper(trim(coalesce(p_absence_reason, ''))), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift public.shifts%rowtype;
  v_context jsonb;
  v_target jsonb;
  v_staff_name text;
  v_actor_staff_id uuid;
  v_old_data jsonb;
  v_new public.sorting_daily_staff_attendance%rowtype;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;

  if v_status not in ('PRESENT','ABSENT') then
    raise exception using errcode = '22023', message = 'Attendance must be PRESENT or ABSENT.';
  end if;

  if v_status = 'ABSENT' and v_reason not in ('SICK','NO_SHOW','OTHER') then
    raise exception using
      errcode = '22023',
      message = 'Choose Sick, No show or Other when marking a staff member absent.';
  end if;

  if v_status = 'PRESENT' then
    v_reason := null;
  end if;

  if v_notes is not null and length(v_notes) > 1000 then
    raise exception using errcode = '22023', message = 'Attendance notes must be 1000 characters or fewer.';
  end if;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  v_context := public.get_sorting_staff_work_context_v2(v_shift_code);

  select value
  into v_target
  from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
  where value ->> 'staff_id' = p_staff_id::text
  limit 1;

  if v_target is null then
    raise exception using
      errcode = '22023',
      message = 'The selected staff member is not active in Sorting for this shift.';
  end if;

  v_staff_name := v_target ->> 'display_name';
  v_actor_staff_id := public.current_staff_id();

  -- Do not let the easiest click create contradictory data.
  if v_status = 'ABSENT'
     and exists (
       select 1
       from public.sorting_wash_runs wr
       where wr.business_date = v_business_date
         and wr.shift_id = v_shift.shift_id
         and wr.operator_staff_id = p_staff_id
         and wr.status = 'RECORDED'
     ) then
    raise exception using
      errcode = '22023',
      message = format(
        '%s already has recorded washing activity for this Business Date and Shift. Correct those wash records before marking the staff member absent.',
        v_staff_name
      );
  end if;

  select to_jsonb(a)
  into v_old_data
  from public.sorting_daily_staff_attendance a
  where a.business_date = v_business_date
    and a.shift_id = v_shift.shift_id
    and a.staff_id = p_staff_id;

  insert into public.sorting_daily_staff_attendance (
    business_date,
    shift_id,
    staff_id,
    attendance_status,
    absence_reason,
    notes,
    source,
    created_by_auth_user_id,
    updated_by_auth_user_id
  )
  values (
    v_business_date,
    v_shift.shift_id,
    p_staff_id,
    v_status,
    v_reason,
    v_notes,
    'SORTING_WORKSTATION',
    auth.uid(),
    auth.uid()
  )
  on conflict (business_date, shift_id, staff_id)
  do update
  set attendance_status = excluded.attendance_status,
      absence_reason = excluded.absence_reason,
      notes = excluded.notes,
      source = 'SORTING_WORKSTATION',
      updated_at = now(),
      updated_by_auth_user_id = auth.uid()
  returning * into v_new;

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
    v_actor_staff_id,
    'SORTING_ATTENDANCE_CHANGED',
    'sorting_daily_staff_attendance',
    v_new.sorting_daily_staff_attendance_id::text,
    v_old_data,
    to_jsonb(v_new),
    case
      when v_status = 'ABSENT'
        then concat(
          replace(initcap(lower(v_reason)), '_', ' '),
          case when v_notes is null then '' else ': ' || v_notes end
        )
      else coalesce(v_notes, 'Attendance corrected to Present')
    end,
    'SORTING_V2'
  );

  return jsonb_build_object(
    'status', 'success',
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'staff_id', p_staff_id,
    'staff_name', v_staff_name,
    'attendance_status', v_status,
    'absence_reason', v_reason,
    'audit_recorded', true,
    'message', case
      when v_status = 'ABSENT'
        then format(
          '%s marked absent (%s).',
          v_staff_name,
          replace(initcap(lower(v_reason)), '_', ' ')
        )
      else format('%s marked present.', v_staff_name)
    end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Staff dashboard: attendance + Clothes/MOP performance
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_staff_dashboard_context(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_base jsonb;
  v_business_date date;
  v_shift_id uuid;
  v_clothes_target numeric := 160;
  v_mop_target numeric := 100;
  v_staff jsonb := '[]'::jsonb;
  v_present_count integer := 0;
  v_absent_count integer := 0;
  v_effective_mop_count integer := 0;
  v_effective_mop_staff_id uuid;
  v_effective_mop_staff_name text;
  v_operational_mop_coverage text := 'UNRESOLVED';
begin
  v_base := public.get_sorting_staff_work_context_v2(p_shift_code);
  v_business_date := (v_base ->> 'business_date')::date;

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code = upper(trim(coalesce(p_shift_code, '')))
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  select coalesce(pt.target_value, 160)
  into v_clothes_target
  from public.production_targets pt
  where pt.target_code = 'SORTING_CLOTHES_KG_PER_STAFF_HOUR'
    and pt.active = true;

  v_clothes_target := coalesce(v_clothes_target, 160);

  select coalesce(pt.target_value, 100)
  into v_mop_target
  from public.production_targets pt
  where pt.target_code = 'SORTING_MOP_KG_PER_STAFF_HOUR'
    and pt.active = true;

  v_mop_target := coalesce(v_mop_target, 100);

  select coalesce(jsonb_agg(
    staff_row.value ||
    jsonb_build_object(
      'attendance_status',
        case
          when att.attendance_status = 'ABSENT' then 'ABSENT'
          when att.attendance_status = 'PRESENT' then 'PRESENT'
          when coalesce(perf.total_loads, 0) > 0 then 'PRESENT_EVIDENCE'
          else 'PLANNED'
        end,
      'absence_reason', att.absence_reason,
      'attendance_notes', att.notes,
      'attendance_changed_at', att.updated_at,
      'performance',
        jsonb_build_object(
          'basis', 'EFFECTIVE_SHIFT_MINUTES',
          'worked_minutes',
            case
              when att.attendance_status = 'ABSENT' then 0
              else coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::integer, 0)
            end,
          'worked_hours',
            case
              when att.attendance_status = 'ABSENT' then 0
              else round(
                coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) / 60.0,
                2
              )
            end,
          'clothes_kg', coalesce(perf.clothes_kg, 0),
          'clothes_loads', coalesce(perf.clothes_loads, 0),
          'clothes_kg_hr',
            case
              when att.attendance_status = 'ABSENT'
                or coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) <= 0
                then null
              else round(
                coalesce(perf.clothes_kg, 0) * 60.0 /
                nullif(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0),
                1
              )
            end,
          'clothes_target_kg_hr', v_clothes_target,
          'clothes_target_pct',
            case
              when att.attendance_status = 'ABSENT'
                or coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) <= 0
                then null
              else round(
                (
                  coalesce(perf.clothes_kg, 0) * 60.0 /
                  nullif(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0)
                ) / nullif(v_clothes_target, 0) * 100.0,
                1
              )
            end,
          'mop_kg', coalesce(perf.mop_kg, 0),
          'mop_loads', coalesce(perf.mop_loads, 0),
          'mop_kg_hr',
            case
              when att.attendance_status = 'ABSENT'
                or coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) <= 0
                then null
              else round(
                coalesce(perf.mop_kg, 0) * 60.0 /
                nullif(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0),
                1
              )
            end,
          'mop_target_kg_hr', v_mop_target,
          'mop_target_pct',
            case
              when att.attendance_status = 'ABSENT'
                or coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) <= 0
                then null
              else round(
                (
                  coalesce(perf.mop_kg, 0) * 60.0 /
                  nullif(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0)
                ) / nullif(v_mop_target, 0) * 100.0,
                1
              )
            end,
          'mop_target_provisional', true,
          'total_loads', coalesce(perf.total_loads, 0)
        )
    )
    order by lower(staff_row.value ->> 'display_name')
  ), '[]'::jsonb)
  into v_staff
  from jsonb_array_elements(coalesce(v_base -> 'staff', '[]'::jsonb)) staff_row
  left join public.sorting_daily_staff_attendance att
    on att.business_date = v_business_date
   and att.shift_id = v_shift_id
   and att.staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
  left join lateral (
    select
      coalesce(sum(wr.total_weight_kg) filter (where wr.wash_type = 'CLOTHES'), 0) as clothes_kg,
      count(*) filter (where wr.wash_type = 'CLOTHES')::integer as clothes_loads,
      coalesce(sum(wr.total_weight_kg) filter (where wr.wash_type = 'MOP'), 0) as mop_kg,
      count(*) filter (where wr.wash_type = 'MOP')::integer as mop_loads,
      count(*)::integer as total_loads
    from public.sorting_wash_runs wr
    where wr.business_date = v_business_date
      and wr.shift_id = v_shift_id
      and wr.operator_staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
      and wr.status = 'RECORDED'
  ) perf on true;

  select
    count(*) filter (where staff_row.value ->> 'attendance_status' <> 'ABSENT')::integer,
    count(*) filter (where staff_row.value ->> 'attendance_status' = 'ABSENT')::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' <> 'ABSENT'
        and staff_row.value ->> 'work_mode' = 'MOP'
    )::integer
  into v_present_count, v_absent_count, v_effective_mop_count
  from jsonb_array_elements(v_staff) staff_row;

  select
    nullif(staff_row.value ->> 'staff_id', '')::uuid,
    staff_row.value ->> 'display_name'
  into v_effective_mop_staff_id, v_effective_mop_staff_name
  from jsonb_array_elements(v_staff) staff_row
  where staff_row.value ->> 'attendance_status' <> 'ABSENT'
    and staff_row.value ->> 'work_mode' = 'MOP'
  limit 1;

  v_operational_mop_coverage := case
    when v_present_count = 0 then 'NO_PRESENT_SORTING_STAFF'
    when v_effective_mop_count = 1 then 'DEDICATED'
    when v_effective_mop_count = 0
         and coalesce(v_base ->> 'actual_mop_coverage', '') = 'NO_DEDICATED_MOP'
      then 'NO_DEDICATED_MOP'
    when v_effective_mop_count = 0
         and coalesce(v_base ->> 'actual_mop_coverage', '') = 'DEDICATED'
      then 'UNRESOLVED_ABSENT_MOP'
    else 'UNRESOLVED'
  end;

  return v_base || jsonb_build_object(
    'staff', v_staff,
    'attendance_summary', jsonb_build_object(
      'shown_staff', jsonb_array_length(v_staff),
      'not_absent', v_present_count,
      'absent', v_absent_count
    ),
    'performance_targets', jsonb_build_object(
      'clothes_kg_hr', v_clothes_target,
      'mop_kg_hr', v_mop_target,
      'mop_provisional', true,
      'source', 'PRODUCTION_TARGETS'
    ),
    'operational_mop_coverage', v_operational_mop_coverage,
    'operational_mop_staff_id', v_effective_mop_staff_id,
    'operational_mop_staff_name', v_effective_mop_staff_name
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Auto Shift from the standard weekly schedule
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_auto_shift_context(
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_local timestamp;
  v_local_date date;
  v_local_time time;
  v_evening_profile jsonb;
  v_evening_start time := time '14:00';
  v_shift_code text;
  v_business_date date;
  v_reason text;
  v_next_change timestamp;
begin
  perform public.require_sorting_operational_access();

  select coalesce(nullif(value_json #>> '{}', ''), 'Europe/Dublin')
  into v_timezone
  from public.app_config
  where config_key = 'business_timezone';

  v_timezone := coalesce(v_timezone, 'Europe/Dublin');

  select coalesce(nullif(value_json #>> '{}', '')::time, time '03:00')
  into v_rollover
  from public.app_config
  where config_key = 'evening_shift_rollover_time';

  v_rollover := coalesce(v_rollover, time '03:00');

  v_local := p_at at time zone v_timezone;
  v_local_date := v_local::date;
  v_local_time := v_local::time;

  if v_local_time < v_rollover then
    v_shift_code := 'EVENING';
    v_business_date := v_local_date - 1;
    v_reason := 'EVENING_OVERNIGHT_CONTINUATION';
    v_next_change := (v_local_date::text || ' ' || v_rollover::text)::timestamp;
  else
    v_evening_profile := public.production_roster_work_profile_context(
      v_local_date,
      'EVENING'
    );

    if nullif(v_evening_profile ->> 'default_start_time', '') is not null then
      v_evening_start := (v_evening_profile ->> 'default_start_time')::time;
    end if;

    if v_local_time >= v_evening_start then
      v_shift_code := 'EVENING';
      v_business_date := v_local_date;
      v_reason := case
        when v_evening_profile is null then 'EVENING_FALLBACK_START'
        else 'EVENING_STANDARD_START'
      end;
      v_next_change := (
        (v_local_date + 1)::text || ' ' || v_rollover::text
      )::timestamp;
    else
      v_shift_code := 'MORNING';
      v_business_date := v_local_date;
      v_reason := case
        when v_evening_profile is null then 'BEFORE_EVENING_FALLBACK_START'
        else 'BEFORE_EVENING_STANDARD_START'
      end;
      v_next_change := (
        v_local_date::text || ' ' || v_evening_start::text
      )::timestamp;
    end if;
  end if;

  return jsonb_build_object(
    'recommended_shift_code', v_shift_code,
    'business_date', v_business_date,
    'local_date', v_local_date,
    'local_time', v_local_time,
    'timezone', v_timezone,
    'evening_rollover_time', v_rollover,
    'evening_standard_start', v_evening_start,
    'reason', v_reason,
    'next_auto_change_local', v_next_change
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Privileges
-- ---------------------------------------------------------------------

revoke all on function public.set_sorting_staff_attendance(text,uuid,text,text,text)
  from public, anon, authenticated;
revoke all on function public.get_sorting_staff_dashboard_context(text)
  from public, anon, authenticated;
revoke all on function public.get_sorting_auto_shift_context(timestamptz)
  from public, anon, authenticated;
revoke all on function public.sorting_guard_absent_mop_mode()
  from public, anon, authenticated;
revoke all on function public.sorting_guard_absent_wash_operator()
  from public, anon, authenticated;

grant execute on function public.set_sorting_staff_attendance(text,uuid,text,text,text)
  to authenticated;
grant execute on function public.get_sorting_staff_dashboard_context(text)
  to authenticated;
grant execute on function public.get_sorting_auto_shift_context(timestamptz)
  to authenticated;

comment on table public.sorting_daily_staff_attendance is
  'Actual Sorting attendance overlay. Published Production Roster remains Planned and immutable.';

comment on function public.get_sorting_staff_dashboard_context(text) is
  'Sorting Staff card context including Actual attendance and per-operator CLOTHES/MOP washing performance. Performance denominator is the staff effective shift minutes; MOP KG/hr target is provisional.';

comment on function public.get_sorting_auto_shift_context(timestamptz) is
  'Recommended Sorting workstation shift based on standard weekly Evening start and overnight rollover. Frontend may hold a manual session override for early staff arrival.';

commit;
