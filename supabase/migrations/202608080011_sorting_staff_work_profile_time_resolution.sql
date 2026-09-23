-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608080011_sorting_staff_work_profile_time_resolution.sql
--
-- Corrects Snapshot 56 assumption that every Production Roster entry carries
-- planned_start_time/planned_end_time.
--
-- Current Roster behavior:
-- - entry-level times are optional overrides;
-- - standard working times are held in production_roster_work_profiles;
-- - Morning Mon-Fri has two equivalent-duration schedule windows;
-- - Saturday/Bank Holiday and Evening profiles have one schedule window.
--
-- No published Roster row is modified.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Resolve the applicable work profile for a Business Date + Shift
-- ---------------------------------------------------------------------

create or replace function public.production_roster_work_profile_context(
  p_work_date date,
  p_shift_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_date date := coalesce(p_work_date, (now() at time zone 'Europe/Dublin')::date);
  v_shift text := upper(trim(coalesce(p_shift_code, '')));
  v_is_bank_holiday boolean;
  v_profile public.production_roster_work_profiles%rowtype;
  v_is_ambiguous boolean := false;
  v_default_start time;
  v_default_end time;
begin
  if v_shift not in ('MORNING', 'EVENING') then
    raise exception using errcode = '22023', message = 'Shift must be MORNING or EVENING.';
  end if;

  select exists (
    select 1
    from public.production_roster_calendar_exceptions e
    where e.work_date = v_date
      and e.active = true
      and e.exception_type = 'BANK_HOLIDAY'
      and e.use_saturday_profile = true
  )
  into v_is_bank_holiday;

  select p.*
  into v_profile
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

  if not found then
    return null;
  end if;

  v_is_ambiguous := position(' or ' in lower(v_profile.schedule_label)) > 0;

  if not v_is_ambiguous
     and v_profile.schedule_label ~ '^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$' then
    v_default_start := split_part(v_profile.schedule_label, '-', 1)::time;
    v_default_end := split_part(v_profile.schedule_label, '-', 2)::time;
  end if;

  return jsonb_build_object(
    'profile_code', v_profile.profile_code,
    'profile_name', v_profile.profile_name,
    'shift_code', v_profile.shift_code,
    'schedule_label', v_profile.schedule_label,
    'break_minutes', v_profile.break_minutes,
    'net_minutes', v_profile.net_minutes,
    'is_bank_holiday_profile', v_is_bank_holiday,
    'is_ambiguous_time_window', v_is_ambiguous,
    'default_start_time', v_default_start,
    'default_end_time', v_default_end
  );
end;
$$;

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
  v_profile jsonb;
begin
  v_profile := public.production_roster_work_profile_context(p_work_date, p_shift_code);
  return coalesce((v_profile ->> 'break_minutes')::integer, 0);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Sorting Staff context: entry override first, profile otherwise
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
  v_profile jsonb;
  v_profile_schedule_label text;
  v_profile_break integer := 0;
  v_profile_net integer;
  v_profile_start time;
  v_profile_end time;
  v_profile_ambiguous boolean := false;
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
  v_profile := public.production_roster_work_profile_context(v_business_date, v_shift_code);

  if v_profile is not null then
    v_profile_schedule_label := v_profile ->> 'schedule_label';
    v_profile_break := coalesce((v_profile ->> 'break_minutes')::integer, 0);
    v_profile_net := nullif(v_profile ->> 'net_minutes', '')::integer;
    v_profile_start := nullif(v_profile ->> 'default_start_time', '')::time;
    v_profile_end := nullif(v_profile ->> 'default_end_time', '')::time;
    v_profile_ambiguous := coalesce((v_profile ->> 'is_ambiguous_time_window')::boolean, false);
  end if;

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
      'work_profile', v_profile,
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

      'planned_schedule_label', q.planned_schedule_label,
      'planned_time_source', q.planned_time_source,
      'planned_start_time', q.effective_planned_start,
      'planned_end_time', q.effective_planned_end,
      'planned_net_minutes', q.planned_net_minutes,
      'standard_break_minutes', q.effective_break_minutes,

      'work_session_id', q.work_session_id,
      'actual_start_time', case
        when q.work_session_id is not null then q.actual_start_time
        else q.effective_planned_start
      end,
      'actual_end_time', case
        when q.work_session_id is not null then q.actual_end_time
        else q.effective_planned_end
      end,
      'extra_non_work_minutes', coalesce(q.extra_non_work_minutes, 0),
      'adjustment_reason', coalesce(q.adjustment_reason, 'NONE'),
      'notes', q.work_notes,
      'adjusted', q.work_session_id is not null,
      'requires_time_choice',
        q.work_session_id is null
        and q.entry_planned_start is null
        and q.entry_planned_end is null
        and v_profile_ambiguous,

      'net_work_minutes', case
        when q.work_session_id is null then q.planned_net_minutes
        when q.actual_start_time is null or q.actual_end_time is null then q.planned_net_minutes
        else greatest(
          0,
          round(extract(epoch from (q.actual_end_time_ts - q.actual_start_time_ts)) / 60)::integer
          - q.effective_break_minutes
          - coalesce(q.extra_non_work_minutes, 0)
        )
      end,

      'variance_minutes', case
        when q.planned_net_minutes is null then null
        when q.work_session_id is null then 0
        when q.actual_start_time is null or q.actual_end_time is null then 0
        else
          greatest(
            0,
            round(extract(epoch from (q.actual_end_time_ts - q.actual_start_time_ts)) / 60)::integer
            - q.effective_break_minutes
            - coalesce(q.extra_non_work_minutes, 0)
          )
          - q.planned_net_minutes
      end
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

      pre.planned_start_time as entry_planned_start,
      pre.planned_end_time as entry_planned_end,

      coalesce(pre.planned_start_time, v_profile_start) as effective_planned_start,
      coalesce(pre.planned_end_time, v_profile_end) as effective_planned_end,

      case
        when pre.planned_start_time is not null and pre.planned_end_time is not null then
          to_char(pre.planned_start_time, 'HH24:MI') || '-' ||
          to_char(pre.planned_end_time, 'HH24:MI')
        else v_profile_schedule_label
      end as planned_schedule_label,

      case
        when pre.planned_start_time is not null and pre.planned_end_time is not null
          then 'ROSTER_ENTRY'
        when not v_profile_ambiguous and v_profile_start is not null and v_profile_end is not null
          then 'WORK_PROFILE'
        else 'WORK_PROFILE_OPTIONS'
      end as planned_time_source,

      case
        when pre.planned_start_time is not null and pre.planned_end_time is not null then
          greatest(
            0,
            round(extract(epoch from (pre.planned_end_time - pre.planned_start_time)) / 60)::integer
            - v_profile_break
          )
        else v_profile_net
      end as planned_net_minutes,

      ws.work_session_id,
      case
        when ws.actual_start_at is null then null
        else (ws.actual_start_at at time zone 'Europe/Dublin')::time
      end as actual_start_time,
      case
        when ws.actual_end_at is null then null
        else (ws.actual_end_at at time zone 'Europe/Dublin')::time
      end as actual_end_time,
      ws.actual_start_at as actual_start_time_ts,
      ws.actual_end_at as actual_end_time_ts,
      coalesce(ws.break_minutes, v_profile_break) as effective_break_minutes,
      ws.extra_non_work_minutes,
      ws.adjustment_reason,
      ws.notes as work_notes
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
    'work_profile', v_profile,
    'staff', v_rows,
    'source', 'PUBLISHED_ROSTER_PLUS_WORK_PROFILE_PLUS_WORK_SESSION_ADJUSTMENTS'
  );
end;
$$;

revoke all on function public.production_roster_work_profile_context(date, text)
  from public, anon, authenticated;
revoke all on function public.production_roster_break_minutes_for(date, text)
  from public, anon, authenticated;
revoke all on function public.get_sorting_staff_work_context(text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_staff_work_context(text)
  to authenticated;

comment on function public.production_roster_work_profile_context(date, text) is
  'Resolves the official Production Roster work profile for a date/shift. A single schedule window is returned as default times; ambiguous Morning alternatives are preserved as options and are never guessed.';

comment on function public.get_sorting_staff_work_context(text) is
  'Returns today Sorting staff using entry-level planned times when explicitly set, otherwise the official work profile. Ambiguous Morning schedule alternatives are preserved without inventing an individual start window.';

commit;
