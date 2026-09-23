-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608080010_operational_work_sessions_and_sorting_staff_adjustments.sql
--
-- Reuses the foundation `work_sessions` table as the Actual Worked Time layer.
-- Production Roster remains immutable Planned data.
--
-- Planned = production_roster_entries (PUBLISHED version)
-- Actual adjustment = work_sessions
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Bridge foundation work_sessions to Production Roster V2
-- ---------------------------------------------------------------------

alter table public.work_sessions
  add column if not exists production_roster_entry_id uuid
    references public.production_roster_entries(roster_entry_id) on delete restrict,
  add column if not exists production_roster_version_id uuid
    references public.production_roster_versions(roster_version_id) on delete restrict,
  add column if not exists extra_non_work_minutes integer not null default 0,
  add column if not exists adjustment_reason text not null default 'NONE',
  add column if not exists recorded_by_auth_user_id uuid
    references auth.users(id) on delete set null,
  add column if not exists row_version integer not null default 1;

alter table public.work_sessions
  drop constraint if exists work_sessions_extra_non_work_minutes_check;
alter table public.work_sessions
  add constraint work_sessions_extra_non_work_minutes_check
    check (extra_non_work_minutes between 0 and 720);

alter table public.work_sessions
  drop constraint if exists work_sessions_adjustment_reason_check;
alter table public.work_sessions
  add constraint work_sessions_adjustment_reason_check
    check (
      adjustment_reason in (
        'NONE',
        'LATE_ARRIVAL',
        'TRAINING',
        'EARLY_LEAVE',
        'PERSONAL',
        'OTHER',
        'MIXED'
      )
    );

create unique index if not exists work_sessions_production_roster_entry_active_uidx
  on public.work_sessions (production_roster_entry_id)
  where production_roster_entry_id is not null
    and status <> 'CANCELLED';

-- The foundation originally exposed work_sessions directly to authenticated.
-- Actual worked time is now sensitive operational data and must use controlled RPCs.
drop policy if exists "authenticated_read_work_sessions" on public.work_sessions;
revoke all on table public.work_sessions from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Break profile helper
-- ---------------------------------------------------------------------

create or replace function public.production_roster_break_minutes_for(
  p_work_date date,
  p_shift_code text
)
returns integer
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_date date := coalesce(p_work_date, (now() at time zone 'Europe/Dublin')::date);
  v_shift text := upper(trim(coalesce(p_shift_code, '')));
  v_is_bank_holiday boolean;
  v_break integer;
begin
  select exists (
    select 1
    from public.production_roster_calendar_exceptions e
    where e.work_date = v_date
      and e.active = true
      and e.exception_type = 'BANK_HOLIDAY'
      and e.use_saturday_profile = true
  )
  into v_is_bank_holiday;

  select p.break_minutes
  into v_break
  from public.production_roster_work_profiles p
  where p.active = true
    and p.shift_code = v_shift
    and (
      (v_is_bank_holiday and p.applies_to_bank_holiday = true)
      or
      (
        not v_is_bank_holiday
        and extract(isodow from v_date)::smallint = any(p.iso_days)
      )
    )
  order by
    case when v_is_bank_holiday and p.applies_to_bank_holiday then 0 else 1 end,
    p.sort_order
  limit 1;

  return coalesce(v_break, 0);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Sorting Staff Actual/Adjustment context
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_staff_work_context(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_shift public.shifts%rowtype;
  v_week_start date;
  v_roster public.production_roster_versions%rowtype;
  v_break_minutes integer;
  v_rows jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  if v_shift_code not in ('MORNING', 'EVENING') then
    raise exception using errcode = '22023', message = 'Shift must be MORNING or EVENING.';
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

  v_week_start := public.production_roster_week_start(v_business_date);
  v_break_minutes := public.production_roster_break_minutes_for(v_business_date, v_shift_code);

  select prv.*
  into v_roster
  from public.production_roster_versions prv
  join public.roster_periods rp
    on rp.roster_period_id = prv.roster_period_id
  where rp.week_start = v_week_start
    and prv.shift_id = v_shift.shift_id
    and prv.status = 'PUBLISHED'
  order by prv.published_at desc nulls last, prv.version_number desc
  limit 1;

  if v_roster.roster_version_id is null then
    return jsonb_build_object(
      'business_date', v_business_date,
      'shift_code', v_shift_code,
      'roster', null,
      'staff', '[]'::jsonb
    );
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'roster_entry_id', q.roster_entry_id,
      'roster_version_id', q.roster_version_id,
      'staff_id', q.staff_id,
      'display_name', q.display_name,
      'assignment_type', q.assignment_type,
      'role_code', q.role_code,
      'station_code', q.station_code,
      'planned_start_time', q.planned_start_time,
      'planned_end_time', q.planned_end_time,
      'standard_break_minutes', v_break_minutes,
      'work_session_id', q.work_session_id,
      'actual_start_time', coalesce(q.actual_start_time, q.planned_start_time),
      'actual_end_time', coalesce(q.actual_end_time, q.planned_end_time),
      'extra_non_work_minutes', coalesce(q.extra_non_work_minutes, 0),
      'adjustment_reason', coalesce(q.adjustment_reason, 'NONE'),
      'notes', q.work_notes,
      'adjusted', q.work_session_id is not null,
      'net_work_minutes',
        greatest(
          0,
          coalesce(q.effective_minutes, q.planned_minutes, 0)
          - v_break_minutes
          - coalesce(q.extra_non_work_minutes, 0)
        ),
      'planned_net_minutes',
        greatest(0, coalesce(q.planned_minutes, 0) - v_break_minutes),
      'variance_minutes',
        (
          greatest(
            0,
            coalesce(q.effective_minutes, q.planned_minutes, 0)
            - v_break_minutes
            - coalesce(q.extra_non_work_minutes, 0)
          )
          -
          greatest(0, coalesce(q.planned_minutes, 0) - v_break_minutes)
        )
    )
    order by lower(q.display_name), q.staff_id
  ), '[]'::jsonb)
  into v_rows
  from (
    select
      pre.roster_entry_id,
      pre.roster_version_id,
      pre.staff_id,
      pre.staff_display_name_snapshot as display_name,
      pre.assignment_type,
      coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) as role_code,
      coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) as station_code,
      pre.planned_start_time,
      pre.planned_end_time,
      ws.work_session_id,
      case
        when ws.actual_start_at is null then null
        else (ws.actual_start_at at time zone 'Europe/Dublin')::time
      end as actual_start_time,
      case
        when ws.actual_end_at is null then null
        else (ws.actual_end_at at time zone 'Europe/Dublin')::time
      end as actual_end_time,
      ws.extra_non_work_minutes,
      ws.adjustment_reason,
      ws.notes as work_notes,
      case
        when pre.planned_start_time is null or pre.planned_end_time is null then null
        else round(extract(epoch from (pre.planned_end_time - pre.planned_start_time)) / 60)::integer
      end as planned_minutes,
      case
        when ws.actual_start_at is null or ws.actual_end_at is null then null
        else round(extract(epoch from (ws.actual_end_at - ws.actual_start_at)) / 60)::integer
      end as effective_minutes
    from public.production_roster_entries pre
    left join public.operational_roles opr
      on opr.operational_role_id = pre.operational_role_id
    left join public.areas a
      on a.area_id = pre.area_id
    left join public.stations st
      on st.station_id = pre.station_id
    left join public.work_sessions ws
      on ws.production_roster_entry_id = pre.roster_entry_id
     and ws.status <> 'CANCELLED'
    where pre.roster_version_id = v_roster.roster_version_id
      and pre.work_date = v_business_date
      and pre.day_status = 'WORKING'
      and (
        coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) = 'SORTING'
        or coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) = 'SORTING_MAIN'
        or pre.display_section_code = 'SORTING_AREA'
        or coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) = 'SORTING_AREA'
      )
  ) q;

  return jsonb_build_object(
    'business_date', v_business_date,
    'shift_code', v_shift.shift_code,
    'shift_name', v_shift.shift_name,
    'roster', jsonb_build_object(
      'roster_version_id', v_roster.roster_version_id,
      'version_number', v_roster.version_number,
      'published_at', v_roster.published_at
    ),
    'staff', v_rows,
    'source', 'PUBLISHED_ROSTER_PLUS_WORK_SESSION_ADJUSTMENTS'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Save one Sorting worked-time adjustment
-- ---------------------------------------------------------------------

create or replace function public.save_sorting_staff_work_adjustment(
  p_shift_code text,
  p_staff_id uuid,
  p_actual_start_time time,
  p_actual_end_time time,
  p_extra_non_work_minutes integer default 0,
  p_adjustment_reason text default 'NONE',
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_reason text := upper(trim(coalesce(p_adjustment_reason, 'NONE')));
  v_shift public.shifts%rowtype;
  v_roster public.production_roster_versions%rowtype;
  v_entry public.production_roster_entries%rowtype;
  v_break_minutes integer;
  v_actual_start timestamptz;
  v_actual_end timestamptz;
  v_net_minutes integer;
  v_session_id uuid;
  v_area_id uuid;
  v_station_id uuid;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;

  if p_actual_start_time is null or p_actual_end_time is null then
    raise exception using errcode = '22023', message = 'Actual start and end time are required.';
  end if;

  if v_reason not in (
    'NONE', 'LATE_ARRIVAL', 'TRAINING', 'EARLY_LEAVE',
    'PERSONAL', 'OTHER', 'MIXED'
  ) then
    raise exception using errcode = '22023', message = 'Invalid work-time adjustment reason.';
  end if;

  if coalesce(p_extra_non_work_minutes, 0) < 0
     or coalesce(p_extra_non_work_minutes, 0) > 720 then
    raise exception using errcode = '22023', message = 'Extra time away must be between 0 and 720 minutes.';
  end if;

  if coalesce(p_extra_non_work_minutes, 0) > 0 and v_reason = 'NONE' then
    raise exception using errcode = '22023', message = 'Choose a reason when extra time away is recorded.';
  end if;

  if length(coalesce(p_notes, '')) > 1000 then
    raise exception using errcode = '22023', message = 'Notes must be 1000 characters or fewer.';
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

  select prv.*
  into v_roster
  from public.production_roster_versions prv
  join public.roster_periods rp
    on rp.roster_period_id = prv.roster_period_id
   and rp.week_start = public.production_roster_week_start(v_business_date)
  where prv.shift_id = v_shift.shift_id
    and prv.status = 'PUBLISHED'
  order by prv.published_at desc nulls last, prv.version_number desc
  limit 1;

  if v_roster.roster_version_id is null then
    raise exception using errcode = 'P0002', message = 'No published Roster exists for this shift today.';
  end if;

  select pre.*
  into v_entry
  from public.production_roster_entries pre
  left join public.operational_roles opr
    on opr.operational_role_id = pre.operational_role_id
  left join public.areas a
    on a.area_id = pre.area_id
  left join public.stations st
    on st.station_id = pre.station_id
  where pre.roster_version_id = v_roster.roster_version_id
    and pre.work_date = v_business_date
    and pre.staff_id = p_staff_id
    and pre.day_status = 'WORKING'
    and (
      coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) = 'SORTING'
      or coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) = 'SORTING_MAIN'
      or pre.display_section_code = 'SORTING_AREA'
      or coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) = 'SORTING_AREA'
    )
  limit 1;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'This staff member is not in today''s published Sorting Roster for the selected shift.';
  end if;

  v_area_id := v_entry.area_id;
  v_station_id := v_entry.station_id;

  if v_area_id is null then
    select a.area_id
    into v_area_id
    from public.areas a
    where a.area_code = 'SORTING'
      and a.deleted_at is null
    limit 1;
  end if;

  v_break_minutes := public.production_roster_break_minutes_for(v_business_date, v_shift_code);

  v_actual_start := (
    (v_business_date::text || ' ' || p_actual_start_time::text)::timestamp
    at time zone 'Europe/Dublin'
  );

  v_actual_end := (
    (v_business_date::text || ' ' || p_actual_end_time::text)::timestamp
    at time zone 'Europe/Dublin'
  );

  if v_actual_end <= v_actual_start then
    raise exception using errcode = '22023', message = 'Actual end time must be later than actual start time.';
  end if;

  if v_actual_start > now() + interval '5 minutes' then
    raise exception using errcode = '22023', message = 'Actual start time cannot be in the future.';
  end if;

  v_net_minutes :=
    round(extract(epoch from (v_actual_end - v_actual_start)) / 60)::integer
    - v_break_minutes
    - coalesce(p_extra_non_work_minutes, 0);

  if v_net_minutes < 0 then
    raise exception using errcode = '22023', message = 'Recorded break/time away exceeds the available work period.';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_entry.roster_entry_id::text));

  insert into public.work_sessions (
    production_roster_entry_id,
    production_roster_version_id,
    work_date,
    staff_id,
    area_id,
    station_id,
    shift_id,
    actual_start_at,
    actual_end_at,
    break_minutes,
    extra_non_work_minutes,
    adjustment_reason,
    status,
    source,
    confirmed_by,
    notes,
    recorded_by_auth_user_id,
    row_version,
    updated_at
  )
  values (
    v_entry.roster_entry_id,
    v_entry.roster_version_id,
    v_business_date,
    v_entry.staff_id,
    v_area_id,
    v_station_id,
    v_shift.shift_id,
    v_actual_start,
    v_actual_end,
    v_break_minutes,
    coalesce(p_extra_non_work_minutes, 0),
    v_reason,
    'CORRECTED',
    'SORTING_WORKSTATION',
    public.current_staff_id(),
    nullif(trim(p_notes), ''),
    auth.uid(),
    1,
    now()
  )
  on conflict (production_roster_entry_id)
    where production_roster_entry_id is not null and status <> 'CANCELLED'
  do update
  set actual_start_at = excluded.actual_start_at,
      actual_end_at = excluded.actual_end_at,
      break_minutes = excluded.break_minutes,
      extra_non_work_minutes = excluded.extra_non_work_minutes,
      adjustment_reason = excluded.adjustment_reason,
      status = 'CORRECTED',
      source = 'SORTING_WORKSTATION',
      confirmed_by = excluded.confirmed_by,
      notes = excluded.notes,
      recorded_by_auth_user_id = excluded.recorded_by_auth_user_id,
      row_version = public.work_sessions.row_version + 1,
      updated_at = now()
  returning work_session_id into v_session_id;

  return jsonb_build_object(
    'status', 'success',
    'work_session_id', v_session_id,
    'staff_id', v_entry.staff_id,
    'staff_name', v_entry.staff_display_name_snapshot,
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'planned_start_time', v_entry.planned_start_time,
    'planned_end_time', v_entry.planned_end_time,
    'actual_start_time', p_actual_start_time,
    'actual_end_time', p_actual_end_time,
    'standard_break_minutes', v_break_minutes,
    'extra_non_work_minutes', coalesce(p_extra_non_work_minutes, 0),
    'adjustment_reason', v_reason,
    'net_work_minutes', v_net_minutes,
    'message', format('Worked-time adjustment saved for %s.', v_entry.staff_display_name_snapshot)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Privileges
-- ---------------------------------------------------------------------

revoke all on function public.production_roster_break_minutes_for(date, text)
  from public, anon, authenticated;
revoke all on function public.get_sorting_staff_work_context(text)
  from public, anon, authenticated;
revoke all on function public.save_sorting_staff_work_adjustment(text, uuid, time, time, integer, text, text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_staff_work_context(text)
  to authenticated;
grant execute on function public.save_sorting_staff_work_adjustment(text, uuid, time, time, integer, text, text)
  to authenticated;

comment on table public.work_sessions is
  'Actual/adjusted operational worked-time layer. Production Roster remains the immutable Planned source.';

comment on function public.get_sorting_staff_work_context(text) is
  'Returns today published Sorting staff with effective work times. No work_session means no adjustment and the published plan remains the effective baseline.';

comment on function public.save_sorting_staff_work_adjustment(text, uuid, time, time, integer, text, text) is
  'Stores a traceable Sorting worked-time adjustment without modifying the published Production Roster.';

commit;
