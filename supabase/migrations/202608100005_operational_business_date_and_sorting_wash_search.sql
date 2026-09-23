-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608100005_operational_business_date_and_sorting_wash_search
--
-- Central operational rule:
-- * Evening work after midnight and before the configured rollover belongs to
--   the previous Business Date.
-- * Default rollover = 03:00 Europe/Dublin, covering exceptional work through
--   02:59 while keeping the whole Evening operation on one Business Date.
-- * Morning uses the calendar Business Date normally.
--
-- Sorting UX:
-- * Rare missed-wash entry is moved out of the primary Save workflow.
-- * Wash history is searchable by customer, Wash ID, washer, staff or type.
-- =====================================================================

begin;


insert into public.app_config (
  config_key,
  value_json,
  description
)
values (
  'evening_shift_rollover_time',
  to_jsonb('03:00'::text),
  'Local time at which an overnight Evening shift stops belonging to the previous Business Date. Default 03:00 covers exceptional work through 02:59.'
)
on conflict (config_key) do nothing;

create or replace function public.operational_shift_clock_context(
  p_shift_code text,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_local timestamp;
  v_business_date date;
  v_overnight boolean := false;
begin
  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

  select coalesce(nullif(value_json #>> '{}',''),'Europe/Dublin')
  into v_timezone
  from public.app_config
  where config_key='business_timezone';

  v_timezone := coalesce(v_timezone,'Europe/Dublin');

  select coalesce(nullif(value_json #>> '{}','')::time,time '03:00')
  into v_rollover
  from public.app_config
  where config_key='evening_shift_rollover_time';

  v_rollover := coalesce(v_rollover,time '03:00');
  v_local := p_at at time zone v_timezone;
  v_business_date := v_local::date;

  if v_shift_code='EVENING' and v_local::time < v_rollover then
    v_business_date := v_business_date - 1;
    v_overnight := true;
  end if;

  return jsonb_build_object(
    'shift_code',v_shift_code,
    'business_date',v_business_date,
    'calendar_date',v_local::date,
    'local_time',v_local::time,
    'timezone',v_timezone,
    'evening_rollover_time',v_rollover,
    'overnight_continuation',v_overnight
  );
end;
$$;

create or replace function public.operational_business_date_for_shift(
  p_shift_code text,
  p_at timestamptz default now()
)
returns date
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select (public.operational_shift_clock_context(p_shift_code,p_at)->>'business_date')::date;
$$;

create or replace function public.operational_timestamp_for_shift(
  p_business_date date,
  p_shift_code text,
  p_local_time time
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_calendar_date date := p_business_date;
begin
  if p_business_date is null or p_local_time is null then
    return null;
  end if;

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

  select coalesce(nullif(value_json #>> '{}',''),'Europe/Dublin')
  into v_timezone
  from public.app_config
  where config_key='business_timezone';

  v_timezone := coalesce(v_timezone,'Europe/Dublin');

  select coalesce(nullif(value_json #>> '{}','')::time,time '03:00')
  into v_rollover
  from public.app_config
  where config_key='evening_shift_rollover_time';

  v_rollover := coalesce(v_rollover,time '03:00');

  if v_shift_code='EVENING' and p_local_time < v_rollover then
    v_calendar_date := p_business_date + 1;
  end if;

  return (
    (v_calendar_date::text || ' ' || p_local_time::text)::timestamp
    at time zone v_timezone
  );
end;
$$;

revoke all on function public.operational_shift_clock_context(text,timestamptz)
  from public, anon, authenticated;
revoke all on function public.operational_business_date_for_shift(text,timestamptz)
  from public, anon, authenticated;
revoke all on function public.operational_timestamp_for_shift(date,text,time)
  from public, anon, authenticated;


create or replace function public.get_sorting_manual_staff_candidates(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_shift public.shifts%rowtype;
  v_sorting_area_id uuid;
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

  select a.area_id
  into v_sorting_area_id
  from public.areas a
  where a.area_code = 'SORTING'
    and a.deleted_at is null
  limit 1;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'staff_id', q.staff_id,
      'display_name', q.display_name,
      'employee_code', q.employee_code,
      'planned_shift_code', q.planned_shift_code,
      'planned_day_status', q.planned_day_status,
      'planned_area_code', q.planned_area_code,
      'planned_station_code', q.planned_station_code,
      'planned_display_section_code', q.planned_display_section_code,
      'planned_position_label', q.planned_position_label,
      'candidate_status', q.candidate_status,
      'already_actual_sorting', q.already_actual_sorting
    )
    order by
      case q.candidate_status
        when 'SAME_SHIFT_OTHER_POSITION' then 1
        when 'SAME_SHIFT_NON_WORKING' then 2
        when 'OTHER_SHIFT' then 3
        else 4
      end,
      lower(q.display_name),
      q.staff_id
  ), '[]'::jsonb)
  into v_rows
  from (
    select
      sm.staff_id,
      sm.display_name,
      sm.employee_code,
      current_plan.shift_code as planned_shift_code,
      current_plan.day_status as planned_day_status,
      current_plan.area_code as planned_area_code,
      current_plan.station_code as planned_station_code,
      current_plan.display_section_code as planned_display_section_code,
      case
        when current_plan.roster_entry_id is null then 'Not planned today'
        when current_plan.display_section_code is not null then
          replace(current_plan.display_section_code, '_', ' ')
        when current_plan.station_code is not null then
          replace(current_plan.station_code, '_', ' ')
        when current_plan.area_code is not null then
          replace(current_plan.area_code, '_', ' ')
        else 'Published Roster'
      end as planned_position_label,
      case
        when selected_shift_plan.roster_entry_id is not null
             and selected_shift_plan.day_status = 'WORKING'
          then 'SAME_SHIFT_OTHER_POSITION'
        when selected_shift_plan.roster_entry_id is not null
          then 'SAME_SHIFT_NON_WORKING'
        when current_plan.roster_entry_id is not null
          then 'OTHER_SHIFT'
        else 'NOT_PLANNED'
      end as candidate_status,
      exists (
        select 1
        from public.work_sessions ws
        where ws.work_date = v_business_date
          and ws.staff_id = sm.staff_id
          and ws.shift_id = v_shift.shift_id
          and ws.area_id = v_sorting_area_id
          and ws.status <> 'CANCELLED'
      ) as already_actual_sorting
    from public.staff_members sm
    left join lateral (
      select
        pre.roster_entry_id,
        sh.shift_code,
        pre.day_status,
        coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) as area_code,
        coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) as station_code,
        pre.display_section_code
      from public.production_roster_versions prv
      join public.roster_periods rp
        on rp.roster_period_id = prv.roster_period_id
       and rp.week_start = public.production_roster_week_start(v_business_date)
      join public.shifts sh
        on sh.shift_id = prv.shift_id
      join public.production_roster_entries pre
        on pre.roster_version_id = prv.roster_version_id
       and pre.work_date = v_business_date
       and pre.staff_id = sm.staff_id
      left join public.areas a
        on a.area_id = pre.area_id
      left join public.stations st
        on st.station_id = pre.station_id
      where prv.status = 'PUBLISHED'
      order by
        case when sh.shift_code = v_shift_code then 0 else 1 end,
        prv.published_at desc nulls last,
        prv.version_number desc
      limit 1
    ) current_plan on true
    left join lateral (
      select pre.roster_entry_id, pre.day_status
      from public.production_roster_versions prv
      join public.roster_periods rp
        on rp.roster_period_id = prv.roster_period_id
       and rp.week_start = public.production_roster_week_start(v_business_date)
      join public.production_roster_entries pre
        on pre.roster_version_id = prv.roster_version_id
       and pre.work_date = v_business_date
       and pre.staff_id = sm.staff_id
      where prv.status = 'PUBLISHED'
        and prv.shift_id = v_shift.shift_id
      order by prv.published_at desc nulls last, prv.version_number desc
      limit 1
    ) selected_shift_plan on true
    where sm.production_staff = true
      and sm.active = true
      and sm.roster_eligible = true
      and sm.deleted_at is null
      and not exists (
        select 1
        from public.production_roster_versions prv2
        join public.roster_periods rp2
          on rp2.roster_period_id = prv2.roster_period_id
         and rp2.week_start = public.production_roster_week_start(v_business_date)
        join public.production_roster_entries pre2
          on pre2.roster_version_id = prv2.roster_version_id
         and pre2.work_date = v_business_date
         and pre2.staff_id = sm.staff_id
        left join public.operational_roles opr2
          on opr2.operational_role_id = pre2.operational_role_id
        left join public.areas a2
          on a2.area_id = pre2.area_id
        left join public.stations st2
          on st2.station_id = pre2.station_id
        where prv2.status = 'PUBLISHED'
          and prv2.shift_id = v_shift.shift_id
          and pre2.day_status = 'WORKING'
          and (
            coalesce(nullif(pre2.area_code_snapshot, ''), a2.area_code) = 'SORTING'
            or coalesce(nullif(pre2.station_code_snapshot, ''), st2.station_code) = 'SORTING_MAIN'
            or pre2.display_section_code = 'SORTING_AREA'
            or coalesce(nullif(pre2.operational_role_code_snapshot, ''), opr2.role_code) = 'SORTING_AREA'
          )
      )
  ) q;

  return jsonb_build_object(
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'candidates', v_rows
  );
end;
$$;


create or replace function public.add_sorting_actual_staff(
  p_shift_code text,
  p_staff_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_shift public.shifts%rowtype;
  v_staff public.staff_members%rowtype;
  v_sorting_area_id uuid;
  v_sorting_station_id uuid;
  v_entry public.production_roster_entries%rowtype;
  v_roster_version_id uuid;
  v_profile jsonb;
  v_break_minutes integer := 0;
  v_default_start time;
  v_default_end time;
  v_actual_start timestamptz;
  v_actual_end timestamptz;
  v_session_id uuid;
  v_planned_position text := 'Not planned today';
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
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

  select *
  into v_staff
  from public.staff_members sm
  where sm.staff_id = p_staff_id
    and sm.production_staff = true
    and sm.active = true
    and sm.roster_eligible = true
    and sm.deleted_at is null;

  if not found then
    raise exception using errcode = 'P0002', message = 'Selected staff member is not active production staff.';
  end if;

  select a.area_id
  into v_sorting_area_id
  from public.areas a
  where a.area_code = 'SORTING'
    and a.deleted_at is null
  limit 1;

  select st.station_id
  into v_sorting_station_id
  from public.stations st
  join public.areas a on a.area_id = st.area_id
  where st.station_code = 'SORTING_MAIN'
    and a.area_code = 'SORTING'
    and st.deleted_at is null
  limit 1;

  if v_sorting_area_id is null then
    raise exception using errcode = 'P0002', message = 'Sorting Area master data is not available.';
  end if;

  if exists (
    select 1
    from public.work_sessions ws
    where ws.work_date = v_business_date
      and ws.staff_id = p_staff_id
      and ws.shift_id = v_shift.shift_id
      and ws.area_id = v_sorting_area_id
      and ws.status <> 'CANCELLED'
  ) then
    raise exception using errcode = '23505', message = format('%s is already active in Sorting for this shift.', v_staff.display_name);
  end if;

  -- Link only to the selected-shift published entry. If there is no selected-
  -- shift entry (not planned / other shift), keep the Actual session independent
  -- and derive the mismatch from the published Roster when displaying it.
  select pre.*
  into v_entry
  from public.production_roster_versions prv
  join public.roster_periods rp
    on rp.roster_period_id = prv.roster_period_id
   and rp.week_start = public.production_roster_week_start(v_business_date)
  join public.production_roster_entries pre
    on pre.roster_version_id = prv.roster_version_id
   and pre.work_date = v_business_date
   and pre.staff_id = p_staff_id
  where prv.status = 'PUBLISHED'
    and prv.shift_id = v_shift.shift_id
  order by prv.published_at desc nulls last, prv.version_number desc
  limit 1;

  if found then
    v_roster_version_id := v_entry.roster_version_id;

    select case
      when pre.display_section_code is not null then replace(pre.display_section_code, '_', ' ')
      when nullif(pre.station_code_snapshot, '') is not null then replace(pre.station_code_snapshot, '_', ' ')
      when nullif(pre.area_code_snapshot, '') is not null then replace(pre.area_code_snapshot, '_', ' ')
      else 'Published Roster'
    end
    into v_planned_position
    from public.production_roster_entries pre
    where pre.roster_entry_id = v_entry.roster_entry_id;
  end if;

  v_profile := public.production_roster_work_profile_context(v_business_date, v_shift_code);
  v_break_minutes := coalesce((v_profile ->> 'break_minutes')::integer, 0);
  v_default_start := nullif(v_profile ->> 'default_start_time', '')::time;
  v_default_end := nullif(v_profile ->> 'default_end_time', '')::time;

  if v_default_start is not null then
    v_actual_start := (
      (v_business_date::text || ' ' || v_default_start::text)::timestamp
      at time zone 'Europe/Dublin'
    );
  end if;

  if v_default_end is not null then
    v_actual_end := (
      (v_business_date::text || ' ' || v_default_end::text)::timestamp
      at time zone 'Europe/Dublin'
    );
  end if;

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
    case when v_entry.roster_entry_id is null then null else v_entry.roster_entry_id end,
    v_roster_version_id,
    v_business_date,
    v_staff.staff_id,
    v_sorting_area_id,
    v_sorting_station_id,
    v_shift.shift_id,
    v_actual_start,
    v_actual_end,
    v_break_minutes,
    0,
    'NONE',
    case when v_actual_start is null or v_actual_end is null then 'OPEN' else 'CONFIRMED' end,
    'SORTING_MANUAL_POSITION',
    public.current_staff_id(),
    nullif(trim(p_notes), ''),
    auth.uid(),
    1,
    now()
  )
  returning work_session_id into v_session_id;

  return jsonb_build_object(
    'status', 'success',
    'work_session_id', v_session_id,
    'staff_id', v_staff.staff_id,
    'staff_name', v_staff.display_name,
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'planned_position', v_planned_position,
    'actual_position', 'Sorting Area',
    'message', format('%s added to Sorting Actual staffing.', v_staff.display_name)
  );
end;
$$;


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
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
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
  v_manual_rows jsonb := '[]'::jsonb;
  v_sorting_area_id uuid;
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

  select a.area_id
  into v_sorting_area_id
  from public.areas a
  where a.area_code = 'SORTING'
    and a.deleted_at is null
  limit 1;

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
  join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
  where rp.week_start = v_week_start
    and prv.shift_id = v_shift.shift_id
    and prv.status = 'PUBLISHED'
  order by prv.published_at desc nulls last, prv.version_number desc
  limit 1;

  if v_roster.roster_version_id is not null then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'roster_entry_id', q.roster_entry_id,
        'roster_version_id', q.roster_version_id,
        'staff_id', q.staff_id,
        'display_name', q.display_name,
        'assignment_type', q.assignment_type,
        'role_code', q.role_code,
        'station_code', q.station_code,
        'planned_position_label', 'Sorting Area',
        'actual_position_label', 'Sorting Area',
        'manual_position', false,
        'planned_schedule_label', q.planned_schedule_label,
        'planned_time_source', q.planned_time_source,
        'planned_start_time', q.effective_planned_start,
        'planned_end_time', q.effective_planned_end,
        'planned_net_minutes', q.planned_net_minutes,
        'standard_break_minutes', q.effective_break_minutes,
        'work_session_id', q.work_session_id,
        'actual_start_time', case when q.work_session_id is not null then q.actual_start_time else q.effective_planned_start end,
        'actual_end_time', case when q.work_session_id is not null then q.actual_end_time else q.effective_planned_end end,
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
          when q.actual_start_time_ts is null or q.actual_end_time_ts is null then q.planned_net_minutes
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
          when q.actual_start_time_ts is null or q.actual_end_time_ts is null then 0
          else greatest(
            0,
            round(extract(epoch from (q.actual_end_time_ts - q.actual_start_time_ts)) / 60)::integer
            - q.effective_break_minutes
            - coalesce(q.extra_non_work_minutes, 0)
          ) - q.planned_net_minutes
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
            to_char(pre.planned_start_time, 'HH24:MI') || '-' || to_char(pre.planned_end_time, 'HH24:MI')
          else v_profile_schedule_label
        end as planned_schedule_label,
        case
          when pre.planned_start_time is not null and pre.planned_end_time is not null then 'ROSTER_ENTRY'
          when not v_profile_ambiguous and v_profile_start is not null and v_profile_end is not null then 'WORK_PROFILE'
          else 'WORK_PROFILE_OPTIONS'
        end as planned_time_source,
        case
          when pre.planned_start_time is not null and pre.planned_end_time is not null then
            greatest(0, round(extract(epoch from (pre.planned_end_time - pre.planned_start_time)) / 60)::integer - v_profile_break)
          else v_profile_net
        end as planned_net_minutes,
        ws.work_session_id,
        case when ws.actual_start_at is null then null else (ws.actual_start_at at time zone 'Europe/Dublin')::time end as actual_start_time,
        case when ws.actual_end_at is null then null else (ws.actual_end_at at time zone 'Europe/Dublin')::time end as actual_end_time,
        ws.actual_start_at as actual_start_time_ts,
        ws.actual_end_at as actual_end_time_ts,
        coalesce(ws.break_minutes, v_profile_break) as effective_break_minutes,
        ws.extra_non_work_minutes,
        ws.adjustment_reason,
        ws.notes as work_notes
      from public.production_roster_entries pre
      left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
      left join public.areas a on a.area_id = pre.area_id
      left join public.stations st on st.station_id = pre.station_id
      left join public.work_sessions ws
        on ws.production_roster_entry_id = pre.roster_entry_id
       and ws.status <> 'CANCELLED'
       and ws.area_id = v_sorting_area_id
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
  end if;

  -- Manual Actual Sorting positions whose PUBLISHED planned position is elsewhere
  -- or absent are appended to the operational list.
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'roster_entry_id', plan.roster_entry_id,
      'roster_version_id', plan.roster_version_id,
      'staff_id', sm.staff_id,
      'display_name', sm.display_name,
      'assignment_type', coalesce(plan.assignment_type, 'MANUAL'),
      'role_code', coalesce(plan.role_code, 'MANUAL_ACTUAL'),
      'station_code', 'SORTING_MAIN',
      'planned_position_label', coalesce(plan.planned_position_label, 'Not planned in selected shift'),
      'actual_position_label', 'Sorting Area',
      'manual_position', true,
      'planned_schedule_label', v_profile_schedule_label,
      'planned_time_source', 'WORK_PROFILE',
      'planned_start_time', v_profile_start,
      'planned_end_time', v_profile_end,
      'planned_net_minutes', v_profile_net,
      'standard_break_minutes', coalesce(ws.break_minutes, v_profile_break),
      'work_session_id', ws.work_session_id,
      'actual_start_time', case when ws.actual_start_at is null then v_profile_start else (ws.actual_start_at at time zone 'Europe/Dublin')::time end,
      'actual_end_time', case when ws.actual_end_at is null then v_profile_end else (ws.actual_end_at at time zone 'Europe/Dublin')::time end,
      'extra_non_work_minutes', coalesce(ws.extra_non_work_minutes, 0),
      'adjustment_reason', coalesce(ws.adjustment_reason, 'NONE'),
      'notes', ws.notes,
      'adjusted', true,
      'requires_time_choice', ws.actual_start_at is null and ws.actual_end_at is null and v_profile_ambiguous,
      'net_work_minutes', case
        when ws.actual_start_at is null or ws.actual_end_at is null then v_profile_net
        else greatest(
          0,
          round(extract(epoch from (ws.actual_end_at - ws.actual_start_at)) / 60)::integer
          - coalesce(ws.break_minutes, v_profile_break)
          - coalesce(ws.extra_non_work_minutes, 0)
        )
      end,
      'variance_minutes', case
        when v_profile_net is null then null
        when ws.actual_start_at is null or ws.actual_end_at is null then 0
        else greatest(
          0,
          round(extract(epoch from (ws.actual_end_at - ws.actual_start_at)) / 60)::integer
          - coalesce(ws.break_minutes, v_profile_break)
          - coalesce(ws.extra_non_work_minutes, 0)
        ) - v_profile_net
      end
    )
    order by lower(sm.display_name), sm.staff_id
  ), '[]'::jsonb)
  into v_manual_rows
  from public.work_sessions ws
  join public.staff_members sm on sm.staff_id = ws.staff_id
  left join lateral (
    select
      pre.roster_entry_id,
      pre.roster_version_id,
      pre.assignment_type,
      coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) as role_code,
      case
        when pre.display_section_code is not null then replace(pre.display_section_code, '_', ' ')
        when nullif(pre.station_code_snapshot, '') is not null then replace(pre.station_code_snapshot, '_', ' ')
        when nullif(pre.area_code_snapshot, '') is not null then replace(pre.area_code_snapshot, '_', ' ')
        else 'Published Roster'
      end as planned_position_label
    from public.production_roster_versions prv
    join public.roster_periods rp
      on rp.roster_period_id = prv.roster_period_id
     and rp.week_start = v_week_start
    join public.production_roster_entries pre
      on pre.roster_version_id = prv.roster_version_id
     and pre.work_date = v_business_date
     and pre.staff_id = ws.staff_id
    left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
    where prv.status = 'PUBLISHED'
      and prv.shift_id = v_shift.shift_id
    order by prv.published_at desc nulls last, prv.version_number desc
    limit 1
  ) plan on true
  where ws.work_date = v_business_date
    and ws.shift_id = v_shift.shift_id
    and ws.area_id = v_sorting_area_id
    and ws.source = 'SORTING_MANUAL_POSITION'
    and ws.status <> 'CANCELLED'
    and not exists (
      select 1
      from public.production_roster_entries planned_sorting
      left join public.operational_roles opr2 on opr2.operational_role_id = planned_sorting.operational_role_id
      left join public.areas a2 on a2.area_id = planned_sorting.area_id
      left join public.stations st2 on st2.station_id = planned_sorting.station_id
      where v_roster.roster_version_id is not null
        and planned_sorting.roster_version_id = v_roster.roster_version_id
        and planned_sorting.work_date = v_business_date
        and planned_sorting.staff_id = ws.staff_id
        and planned_sorting.day_status = 'WORKING'
        and (
          coalesce(nullif(planned_sorting.area_code_snapshot, ''), a2.area_code) = 'SORTING'
          or coalesce(nullif(planned_sorting.station_code_snapshot, ''), st2.station_code) = 'SORTING_MAIN'
          or planned_sorting.display_section_code = 'SORTING_AREA'
          or coalesce(nullif(planned_sorting.operational_role_code_snapshot, ''), opr2.role_code) = 'SORTING_AREA'
        )
    );

  return jsonb_build_object(
    'business_date', v_business_date,
    'shift_code', v_shift.shift_code,
    'shift_name', v_shift.shift_name,
    'roster', case
      when v_roster.roster_version_id is null then null
      else jsonb_build_object(
        'roster_version_id', v_roster.roster_version_id,
        'version_number', v_roster.version_number,
        'published_at', v_roster.published_at
      )
    end,
    'work_profile', v_profile,
    'staff', coalesce(v_rows, '[]'::jsonb) || coalesce(v_manual_rows, '[]'::jsonb),
    'source', 'PUBLISHED_ROSTER_PLUS_MANUAL_ACTUAL_POSITIONS'
  );
end;
$$;


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
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_reason text := upper(trim(coalesce(p_adjustment_reason, 'NONE')));
  v_shift public.shifts%rowtype;
  v_session public.work_sessions%rowtype;
  v_entry public.production_roster_entries%rowtype;
  v_roster public.production_roster_versions%rowtype;
  v_sorting_area_id uuid;
  v_sorting_station_id uuid;
  v_break_minutes integer;
  v_actual_start timestamptz;
  v_actual_end timestamptz;
  v_net_minutes integer;
  v_session_id uuid;
  v_staff_name text;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;

  if p_actual_start_time is null or p_actual_end_time is null then
    raise exception using errcode = '22023', message = 'Actual start and end time are required.';
  end if;

  if v_reason not in ('NONE','LATE_ARRIVAL','TRAINING','EARLY_LEAVE','PERSONAL','OTHER','MIXED') then
    raise exception using errcode = '22023', message = 'Invalid work-time adjustment reason.';
  end if;

  if coalesce(p_extra_non_work_minutes, 0) < 0 or coalesce(p_extra_non_work_minutes, 0) > 720 then
    raise exception using errcode = '22023', message = 'Extra time away must be between 0 and 720 minutes.';
  end if;

  if coalesce(p_extra_non_work_minutes, 0) > 0 and v_reason = 'NONE' then
    raise exception using errcode = '22023', message = 'Choose a reason when extra time away is recorded.';
  end if;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  select a.area_id
  into v_sorting_area_id
  from public.areas a
  where a.area_code = 'SORTING'
    and a.deleted_at is null
  limit 1;

  select st.station_id
  into v_sorting_station_id
  from public.stations st
  join public.areas a on a.area_id = st.area_id
  where st.station_code = 'SORTING_MAIN'
    and a.area_code = 'SORTING'
    and st.deleted_at is null
  limit 1;

  select ws.*
  into v_session
  from public.work_sessions ws
  where ws.work_date = v_business_date
    and ws.staff_id = p_staff_id
    and ws.shift_id = v_shift.shift_id
    and ws.area_id = v_sorting_area_id
    and ws.status <> 'CANCELLED'
  order by case when ws.source = 'SORTING_MANUAL_POSITION' then 0 else 1 end, ws.updated_at desc
  limit 1
  for update;

  if found then
    v_session_id := v_session.work_session_id;

    if v_session.production_roster_entry_id is not null then
      select *
      into v_entry
      from public.production_roster_entries pre
      where pre.roster_entry_id = v_session.production_roster_entry_id;
    end if;
  else
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

    select pre.*
    into v_entry
    from public.production_roster_entries pre
    left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
    left join public.areas a on a.area_id = pre.area_id
    left join public.stations st on st.station_id = pre.station_id
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
        message = 'This staff member is not active in Sorting. Add the person manually first.';
    end if;
  end if;

  select sm.display_name
  into v_staff_name
  from public.staff_members sm
  where sm.staff_id = p_staff_id;

  v_break_minutes := public.production_roster_break_minutes_for(v_business_date, v_shift_code);

  v_actual_start := public.operational_timestamp_for_shift(
    v_business_date,
    v_shift_code,
    p_actual_start_time
  );
  v_actual_end := public.operational_timestamp_for_shift(
    v_business_date,
    v_shift_code,
    p_actual_end_time
  );

  if v_shift_code = 'EVENING'
     and v_actual_end <= v_actual_start then
    v_actual_end := v_actual_end + interval '1 day';
  end if;

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

  if v_session_id is not null then
    update public.work_sessions
    set actual_start_at = v_actual_start,
        actual_end_at = v_actual_end,
        break_minutes = v_break_minutes,
        extra_non_work_minutes = coalesce(p_extra_non_work_minutes, 0),
        adjustment_reason = v_reason,
        status = 'CORRECTED',
        notes = nullif(trim(p_notes), ''),
        confirmed_by = public.current_staff_id(),
        recorded_by_auth_user_id = auth.uid(),
        row_version = row_version + 1,
        updated_at = now()
    where work_session_id = v_session_id;
  else
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
      p_staff_id,
      coalesce(v_entry.area_id, v_sorting_area_id),
      coalesce(v_entry.station_id, v_sorting_station_id),
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
    returning work_session_id into v_session_id;
  end if;

  return jsonb_build_object(
    'status', 'success',
    'work_session_id', v_session_id,
    'staff_id', p_staff_id,
    'staff_name', v_staff_name,
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'actual_start_time', p_actual_start_time,
    'actual_end_time', p_actual_end_time,
    'standard_break_minutes', v_break_minutes,
    'extra_non_work_minutes', coalesce(p_extra_non_work_minutes, 0),
    'adjustment_reason', v_reason,
    'net_work_minutes', v_net_minutes,
    'message', format('Worked-time adjustment saved for %s.', coalesce(v_staff_name, 'staff member'))
  );
end;
$$;


create or replace function public.set_sorting_mop_staff(
  p_shift_code text,
  p_staff_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_shift public.shifts%rowtype;
  v_context jsonb;
  v_staff_name text;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
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

  v_context := public.get_sorting_staff_work_context(v_shift_code);

  select staff_row.value ->> 'display_name'
  into v_staff_name
  from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb)) staff_row
  where nullif(staff_row.value ->> 'staff_id', '')::uuid = p_staff_id
  limit 1;

  if v_staff_name is null then
    raise exception using
      errcode = '22023',
      message = 'The selected staff member is not active in Sorting for this shift.';
  end if;

  perform pg_advisory_xact_lock(
    hashtext(v_business_date::text || ':' || v_shift.shift_id::text || ':SORTING_MOP')
  );

  update public.sorting_daily_staff_modes
  set work_mode = 'CLOTHES',
      updated_at = now(),
      updated_by_auth_user_id = auth.uid()
  where business_date = v_business_date
    and shift_id = v_shift.shift_id
    and work_mode = 'MOP'
    and staff_id <> p_staff_id;

  insert into public.sorting_daily_staff_modes (
    business_date,
    shift_id,
    staff_id,
    work_mode,
    source,
    created_by_auth_user_id,
    updated_by_auth_user_id
  )
  values (
    v_business_date,
    v_shift.shift_id,
    p_staff_id,
    'MOP',
    'SORTING_WORKSTATION',
    auth.uid(),
    auth.uid()
  )
  on conflict (business_date, shift_id, staff_id)
  do update
  set work_mode = 'MOP',
      source = 'SORTING_WORKSTATION',
      updated_at = now(),
      updated_by_auth_user_id = auth.uid();

  return jsonb_build_object(
    'status', 'success',
    'business_date', v_business_date,
    'shift_code', v_shift.shift_code,
    'mop_staff_id', p_staff_id,
    'mop_staff_name', v_staff_name,
    'message', format('%s is assigned to MOP for this Sorting shift.', v_staff_name)
  );
end;
$$;


create or replace function public.get_sorting_washing_context(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_sorting_context jsonb;
  v_washers jsonb;
  v_today_customers jsonb;
  v_all_customers jsonb;
  v_recent_washes jsonb;
begin
  perform public.require_sorting_operational_access();

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

  v_sorting_context := public.get_sorting_daily_context(v_business_date, v_shift_code);

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'washer_id', w.washer_id,
      'washer_code', w.washer_code,
      'washer_name', w.washer_name,
      'capacity_kg', w.capacity_kg,
      'category', w.category
    ) order by w.sort_order, w.washer_code
  ), '[]'::jsonb)
  into v_washers
  from public.sorting_washers w
  where w.active and w.deleted_at is null;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', q.customer_id,
      'customer_code', q.customer_code,
      'customer_name', q.customer_name,
      'product_code', q.product_code,
      'production_order', q.production_order,
      'expected_kg', q.expected_kg,
      'production_instructions', q.production_instructions,
      'schedule_version_id', q.schedule_version_id,
      'schedule_day_id', q.schedule_day_id,
      'schedule_product_id', q.schedule_product_id,
      'wash_count', q.wash_count,
      'last_wash_code', q.last_wash_code,
      'last_wash_started_at', q.last_wash_started_at,
      'status', case when q.wash_count > 0 then 'WASHED' else 'PENDING' end
    )
    order by
      case q.product_code when 'CLOTHES' then 1 when 'MOP' then 2 else 9 end,
      q.production_order nulls last,
      lower(q.customer_name),
      q.customer_code
  ), '[]'::jsonb)
  into v_today_customers
  from (
    select
      c.customer_id,
      c.customer_code,
      c.customer_name,
      pt.product_code,
      sp.production_order,
      sp.expected_kg,
      sp.production_instructions,
      csv.schedule_version_id,
      sd.schedule_day_id,
      sp.schedule_product_id,
      (
        select count(*)::integer
        from public.sorting_wash_run_customers wrc
        join public.sorting_wash_runs wr on wr.wash_run_id = wrc.wash_run_id
        where wrc.customer_id = c.customer_id
          and wr.business_date = v_business_date
          and wr.wash_type = pt.product_code
          and wr.status = 'RECORDED'
      ) wash_count,
      (
        select wr2.wash_code
        from public.sorting_wash_run_customers wrc2
        join public.sorting_wash_runs wr2 on wr2.wash_run_id = wrc2.wash_run_id
        where wrc2.customer_id = c.customer_id
          and wr2.business_date = v_business_date
          and wr2.wash_type = pt.product_code
          and wr2.status = 'RECORDED'
        order by wr2.started_at desc, wr2.created_at desc
        limit 1
      ) last_wash_code,
      (
        select wr3.started_at
        from public.sorting_wash_run_customers wrc3
        join public.sorting_wash_runs wr3 on wr3.wash_run_id = wrc3.wash_run_id
        where wrc3.customer_id = c.customer_id
          and wr3.business_date = v_business_date
          and wr3.wash_type = pt.product_code
          and wr3.status = 'RECORDED'
        order by wr3.started_at desc, wr3.created_at desc
        limit 1
      ) last_wash_started_at
    from public.customer_schedule_versions csv
    join public.customers c
      on c.customer_id = csv.customer_id
     and c.active
     and c.deleted_at is null
    join public.customer_schedule_days sd
      on sd.schedule_version_id = csv.schedule_version_id
     and sd.active
     and sd.production_weekday = extract(isodow from v_business_date)::smallint
    join public.customer_schedule_products sp
      on sp.schedule_day_id = sd.schedule_day_id
     and sp.active
    join public.product_types pt
      on pt.product_type_id = sp.product_type_id
     and pt.active
     and pt.deleted_at is null
     and pt.product_code in ('CLOTHES','MOP')
    where csv.status = 'PUBLISHED'
      and csv.effective_from <= v_business_date
      and (csv.effective_until is null or csv.effective_until >= v_business_date)
  ) q;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', c.customer_id,
      'customer_code', c.customer_code,
      'customer_name', c.customer_name
    ) order by lower(c.customer_name), c.customer_code
  ), '[]'::jsonb)
  into v_all_customers
  from public.customers c
  where c.active and c.deleted_at is null;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'wash_run_id', q.wash_run_id,
      'wash_code', q.wash_code,
      'business_date', q.business_date,
      'shift_code', q.shift_code_snapshot,
      'washer_code', q.washer_code_snapshot,
      'washer_name', q.washer_name_snapshot,
      'operator_staff_id', q.operator_staff_id,
      'operator_name', q.operator_name_snapshot,
      'wash_type', q.wash_type,
      'started_at', q.started_at,
      'registered_at', q.registered_at,
      'total_weight_kg', q.total_weight_kg,
      'customers', q.customers
    ) order by q.registered_at desc
  ), '[]'::jsonb)
  into v_recent_washes
  from (
    select
      wr.*,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'wash_run_customer_id', wrc.wash_run_customer_id,
            'trace_code', wrc.trace_code,
            'customer_id', wrc.customer_id,
            'customer_code', wrc.customer_code_snapshot,
            'customer_name', wrc.customer_name_snapshot,
            'schedule_relation', wrc.schedule_relation
          ) order by lower(wrc.customer_name_snapshot), wrc.customer_code_snapshot
        )
        from public.sorting_wash_run_customers wrc
        where wrc.wash_run_id = wr.wash_run_id
      ), '[]'::jsonb) customers
    from public.sorting_wash_runs wr
    where wr.business_date = v_business_date
      and wr.status = 'RECORDED'
    order by wr.registered_at desc
    limit 40
  ) q;

  return jsonb_build_object(
    'business_date', v_business_date,
    'shift', v_sorting_context -> 'shift',
    'roster', v_sorting_context -> 'roster',
    'planned_staff', v_sorting_context -> 'planned_staff',
    'planned_staff_count', v_sorting_context -> 'planned_staff_count',
    'operator', v_sorting_context -> 'operator',
    'washers', v_washers,
    'today_customers', v_today_customers,
    'all_customers', v_all_customers,
    'recent_washes', v_recent_washes,
    'source', 'PUBLISHED_ROSTER_AND_PUBLISHED_CUSTOMER_SCHEDULE'
  );
end;
$$;


create or replace function public.get_sorting_washing_context_v2(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_base jsonb;
  v_recent_washes jsonb := '[]'::jsonb;
begin
  v_base := public.get_sorting_washing_context(p_shift_code);

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'wash_run_id', q.wash_run_id,
      'wash_code', q.wash_code,
      'business_date', q.business_date,
      'shift_code', q.shift_code_snapshot,
      'washer_code', q.washer_code_snapshot,
      'washer_name', q.washer_name_snapshot,
      'operator_staff_id', q.operator_staff_id,
      'operator_name', q.operator_name_snapshot,
      'wash_type', q.wash_type,
      'started_at', q.started_at,
      'registered_at', q.registered_at,
      'total_weight_kg', q.total_weight_kg,
      'customers', q.customers
    )
    order by q.business_date desc, q.started_at desc, q.registered_at desc
  ), '[]'::jsonb)
  into v_recent_washes
  from (
    select
      wr.*,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'wash_run_customer_id', wrc.wash_run_customer_id,
            'trace_code', wrc.trace_code,
            'customer_id', wrc.customer_id,
            'customer_code', wrc.customer_code_snapshot,
            'customer_name', wrc.customer_name_snapshot,
            'schedule_relation', wrc.schedule_relation,
            'scheduled_for_date', wrc.scheduled_for_date,
            'scheduled_weekday',
              coalesce(
                wrc.scheduled_weekday_name_snapshot,
                case
                  when wrc.scheduled_for_date is null then null
                  else trim(to_char(wrc.scheduled_for_date, 'Day'))
                end
              ),
            'route_code',
              coalesce(nullif(wrc.route_code_snapshot, ''), r.route_code),
            'route_display_name',
              coalesce(nullif(wrc.route_display_name_snapshot, ''), r.display_name),
            'route_color',
              coalesce(nullif(wrc.route_color_snapshot, ''), r.route_color)
          )
          order by lower(wrc.customer_name_snapshot), wrc.trace_code
        )
        from public.sorting_wash_run_customers wrc
        left join public.customer_schedule_products sp
          on sp.schedule_product_id = wrc.source_schedule_product_id
        left join public.customer_schedule_days sd
          on sd.schedule_day_id = sp.schedule_day_id
        left join public.distribution_routes r
          on r.route_id = sd.default_route_id
        where wrc.wash_run_id = wr.wash_run_id
      ), '[]'::jsonb) as customers
    from public.sorting_wash_runs wr
    where wr.business_date between (v_business_date - 2) and v_business_date
      and wr.status = 'RECORDED'
    order by wr.business_date desc, wr.started_at desc, wr.registered_at desc
    limit 80
  ) q;

  return v_base || jsonb_build_object(
    'recent_washes', v_recent_washes,
    'recent_wash_window_days', 3
  );
end;
$$;


create or replace function public.save_sorting_wash_run(
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_ids uuid[],
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_code text := upper(trim(coalesce(p_shift_code,'')));
  v_wash_type text := upper(trim(coalesce(p_wash_type,'')));
  v_shift public.shifts%rowtype;
  v_washer public.sorting_washers%rowtype;
  v_operator public.staff_members%rowtype;
  v_context jsonb;
  v_sorting_area_id uuid;
  v_started_at timestamptz;
  v_customer_ids uuid[];
  v_customer_count integer;
  v_active_customer_count integer;
  v_wash_run_id uuid;
  v_wash_code text;
  v_item record;
  v_schedule_version_id uuid;
  v_schedule_day_id uuid;
  v_schedule_product_id uuid;
  v_production_order integer;
  v_expected_kg numeric(12,2);
  v_production_instructions text;
  v_schedule_relation text;
  v_trace_code text;
  v_trace_rows jsonb := '[]'::jsonb;
  v_unscheduled_count integer := 0;
begin
  perform public.require_sorting_operational_access();

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;
  if v_wash_type not in ('CLOTHES','MOP','OTHERS') then
    raise exception using errcode='22023', message='Wash type must be CLOTHES, MOP or OTHERS.';
  end if;
  if p_washer_id is null then
    raise exception using errcode='22023', message='Washer is required.';
  end if;
  if p_operator_staff_id is null then
    raise exception using errcode='22023', message='Operator is required.';
  end if;
  if p_start_time is null then
    raise exception using errcode='22023', message='Start time is required.';
  end if;
  if p_weight_kg is null or p_weight_kg <= 0 then
    raise exception using errcode='22023', message='Weight must be greater than zero.';
  end if;
  if length(coalesce(p_notes,'')) > 1000 then
    raise exception using errcode='22023', message='Notes must be 1000 characters or fewer.';
  end if;

  select array_agg(x.customer_id order by x.first_position)
  into v_customer_ids
  from (
    select customer_id, min(position) first_position
    from unnest(coalesce(p_customer_ids,array[]::uuid[]))
      with ordinality as u(customer_id,position)
    where customer_id is not null
    group by customer_id
  ) x;

  v_customer_count := coalesce(array_length(v_customer_ids,1),0);
  if v_customer_count = 0 then
    raise exception using errcode='22023', message='At least one customer is required.';
  end if;
  if v_customer_count > 20 then
    raise exception using errcode='22023', message='A washing load cannot contain more than 20 customers.';
  end if;

  select * into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  select * into v_washer
  from public.sorting_washers w
  where w.washer_id = p_washer_id
    and w.active
    and w.deleted_at is null;

  if not found then
    raise exception using errcode='P0002', message='Selected washer is not available.';
  end if;

  if p_weight_kg > v_washer.capacity_kg then
    raise exception using
      errcode='22023',
      message=format('Weight (%s KG) exceeds %s capacity (%s KG).',
        p_weight_kg, v_washer.washer_code, v_washer.capacity_kg);
  end if;

  select * into v_operator
  from public.staff_members sm
  where sm.staff_id = p_operator_staff_id
    and sm.production_staff = true
    and sm.active = true
    and sm.roster_eligible = true
    and sm.deleted_at is null;

  if not found then
    raise exception using errcode='P0002', message='Selected operator is not active production staff.';
  end if;

  v_context := public.get_sorting_daily_context(v_business_date, v_shift_code);

  select a.area_id
  into v_sorting_area_id
  from public.areas a
  where a.area_code = 'SORTING'
    and a.deleted_at is null
  limit 1;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_context -> 'planned_staff','[]'::jsonb)) staff_row
    where nullif(staff_row ->> 'staff_id','')::uuid = p_operator_staff_id
  )
  and not exists (
    select 1
    from public.work_sessions ws
    where ws.work_date = v_business_date
      and ws.staff_id = p_operator_staff_id
      and ws.shift_id = v_shift.shift_id
      and ws.area_id = v_sorting_area_id
      and ws.status <> 'CANCELLED'
  ) then
    raise exception using
      errcode='22023',
      message=format(
        '%s is not active in Sorting for %s %s. Add the person to Actual Sorting staffing first.',
        v_operator.display_name, v_business_date, v_shift.shift_name
      );
  end if;

  select count(*)
  into v_active_customer_count
  from public.customers c
  where c.customer_id = any(v_customer_ids)
    and c.active
    and c.deleted_at is null;

  if v_active_customer_count <> v_customer_count then
    raise exception using errcode='22023', message='One or more selected customers are inactive or unavailable.';
  end if;

  v_started_at := public.operational_timestamp_for_shift(
    v_business_date,
    v_shift_code,
    p_start_time
  );

  if v_started_at > now() + interval '2 minutes' then
    raise exception using errcode='22023', message='Start time cannot be in the future.';
  end if;

  -- Per-washer lock supports two concurrent Sorting PCs safely.
  perform pg_advisory_xact_lock(hashtext(v_washer.washer_id::text));

  if exists (
    select 1
    from public.sorting_wash_runs wr
    where wr.washer_id = v_washer.washer_id
      and wr.business_date = v_business_date
      and wr.status = 'RECORDED'
      and abs(extract(epoch from (wr.started_at - v_started_at))) < 600
  ) then
    raise exception using
      errcode='23505',
      message=format('%s already has a washing load recorded within 10 minutes of this start time.',
        v_washer.washer_code);
  end if;

  loop
    v_wash_code := 'W' || to_char(v_business_date,'YYYYMMDD') || '-' ||
      upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    exit when not exists (
      select 1 from public.sorting_wash_runs wr where wr.wash_code = v_wash_code
    );
  end loop;

  insert into public.sorting_wash_runs (
    wash_code, business_date, shift_id, shift_code_snapshot,
    washer_id, washer_code_snapshot, washer_name_snapshot, washer_capacity_kg_snapshot,
    operator_staff_id, operator_name_snapshot,
    wash_type, started_at, total_weight_kg, notes,
    source_application, recorded_by_auth_user_id, metadata
  )
  values (
    v_wash_code, v_business_date, v_shift.shift_id, v_shift.shift_code,
    v_washer.washer_id, v_washer.washer_code, v_washer.washer_name, v_washer.capacity_kg,
    v_operator.staff_id, v_operator.display_name,
    v_wash_type, v_started_at, p_weight_kg, nullif(trim(p_notes),''),
    'SORTING_V2', auth.uid(),
    jsonb_build_object(
      'roster_version_id', v_context -> 'roster' ->> 'roster_version_id',
      'roster_version_number', v_context -> 'roster' ->> 'version_number'
    )
  )
  returning wash_run_id into v_wash_run_id;

  for v_item in
    select
      u.position,
      c.customer_id,
      c.customer_code,
      c.customer_name
    from unnest(v_customer_ids) with ordinality as u(customer_id,position)
    join public.customers c on c.customer_id = u.customer_id
    order by u.position
  loop
    v_schedule_version_id := null;
    v_schedule_day_id := null;
    v_schedule_product_id := null;
    v_production_order := null;
    v_expected_kg := null;
    v_production_instructions := null;

    if v_wash_type in ('CLOTHES','MOP') then
      select
        csv.schedule_version_id,
        sd.schedule_day_id,
        sp.schedule_product_id,
        sp.production_order,
        sp.expected_kg,
        sp.production_instructions
      into
        v_schedule_version_id,
        v_schedule_day_id,
        v_schedule_product_id,
        v_production_order,
        v_expected_kg,
        v_production_instructions
      from public.customer_schedule_versions csv
      join public.customer_schedule_days sd
        on sd.schedule_version_id = csv.schedule_version_id
       and sd.active
       and sd.production_weekday = extract(isodow from v_business_date)::smallint
      join public.customer_schedule_products sp
        on sp.schedule_day_id = sd.schedule_day_id
       and sp.active
      join public.product_types pt
        on pt.product_type_id = sp.product_type_id
       and pt.active
       and pt.deleted_at is null
       and pt.product_code = v_wash_type
      where csv.customer_id = v_item.customer_id
        and csv.status = 'PUBLISHED'
        and csv.effective_from <= v_business_date
        and (csv.effective_until is null or csv.effective_until >= v_business_date)
      order by csv.effective_from desc, csv.version_number desc
      limit 1;

      if v_schedule_product_id is null then
        v_schedule_relation := 'UNSCHEDULED';
        v_unscheduled_count := v_unscheduled_count + 1;
      else
        v_schedule_relation := 'TODAY';
      end if;
    else
      v_schedule_relation := 'NOT_APPLICABLE';
    end if;

    v_trace_code := v_wash_code || '-' || lpad(v_item.position::text,2,'0');

    insert into public.sorting_wash_run_customers (
      trace_code, wash_run_id, customer_id,
      customer_code_snapshot, customer_name_snapshot, wash_type_snapshot,
      source_schedule_version_id, source_schedule_day_id, source_schedule_product_id,
      production_order_snapshot, expected_kg_snapshot, production_instructions_snapshot,
      schedule_relation, metadata
    )
    values (
      v_trace_code, v_wash_run_id, v_item.customer_id,
      v_item.customer_code, v_item.customer_name, v_wash_type,
      v_schedule_version_id, v_schedule_day_id, v_schedule_product_id,
      v_production_order, v_expected_kg, v_production_instructions,
      v_schedule_relation,
      jsonb_build_object('trace_role','SORTING_WASH_CUSTOMER','future_processing_link',true)
    );

    v_trace_rows := v_trace_rows || jsonb_build_array(
      jsonb_build_object(
        'trace_code', v_trace_code,
        'customer_id', v_item.customer_id,
        'customer_code', v_item.customer_code,
        'customer_name', v_item.customer_name,
        'schedule_relation', v_schedule_relation,
        'source_schedule_product_id', v_schedule_product_id
      )
    );
  end loop;

  return jsonb_build_object(
    'status','success',
    'wash_run_id',v_wash_run_id,
    'wash_code',v_wash_code,
    'business_date',v_business_date,
    'shift_code',v_shift.shift_code,
    'washer_code',v_washer.washer_code,
    'operator_staff_id',v_operator.staff_id,
    'operator_name',v_operator.display_name,
    'wash_type',v_wash_type,
    'started_at',v_started_at,
    'weight_kg',p_weight_kg,
    'customer_count',v_customer_count,
    'unscheduled_customer_count',v_unscheduled_count,
    'trace_rows',v_trace_rows,
    'message',case
      when v_unscheduled_count > 0 then
        format('Washing %s saved. %s customer(s) are outside today''s published %s schedule and remain traceable as UNSCHEDULED.',
          v_wash_code,v_unscheduled_count,v_wash_type)
      else format('Washing %s saved successfully.',v_wash_code)
    end
  );
end;
$$;


create or replace function public.save_sorting_wash_run_v2(
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_selections jsonb,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_wash_type text := upper(trim(coalesce(p_wash_type, '')));
  v_customer_ids uuid[];
  v_selection_count integer;
  v_unique_customer_count integer;
  v_result jsonb;
  v_wash_run_id uuid;
  v_selection record;
  v_customer_id uuid;
  v_schedule_product_id uuid;
  v_scheduled_for_date date;
  v_schedule_version_id uuid;
  v_schedule_day_id uuid;
  v_production_order integer;
  v_expected_kg numeric(12,2);
  v_production_instructions text;
  v_weekday smallint;
  v_weekday_name text;
  v_route_id uuid;
  v_route_code text;
  v_route_display_name text;
  v_route_color text;
  v_relation text;
  v_trace_rows jsonb := '[]'::jsonb;
  v_unscheduled_count integer := 0;
  v_early_count integer := 0;
begin
  perform public.require_sorting_operational_access();

  if p_customer_selections is null
     or jsonb_typeof(p_customer_selections) <> 'array'
     or jsonb_array_length(p_customer_selections) = 0 then
    raise exception using errcode = '22023', message = 'At least one customer selection is required.';
  end if;

  select
    array_agg(nullif(item.value ->> 'customer_id', '')::uuid order by item.ordinality),
    count(*)::integer,
    count(distinct nullif(item.value ->> 'customer_id', '')::uuid)::integer
  into v_customer_ids, v_selection_count, v_unique_customer_count
  from jsonb_array_elements(p_customer_selections) with ordinality item(value, ordinality);

  if v_customer_ids is null
     or array_position(v_customer_ids, null) is not null then
    raise exception using errcode = '22023', message = 'Every customer selection requires a valid customer_id.';
  end if;

  if v_selection_count <> v_unique_customer_count then
    raise exception using
      errcode = '22023',
      message = 'The same customer cannot be linked to two scheduled days in one washer load.';
  end if;

  v_result := public.save_sorting_wash_run(
    p_shift_code => p_shift_code,
    p_washer_id => p_washer_id,
    p_operator_staff_id => p_operator_staff_id,
    p_start_time => p_start_time,
    p_weight_kg => p_weight_kg,
    p_wash_type => v_wash_type,
    p_customer_ids => v_customer_ids,
    p_notes => p_notes
  );

  v_wash_run_id := nullif(v_result ->> 'wash_run_id', '')::uuid;

  for v_selection in
    select item.value as selection, item.ordinality
    from jsonb_array_elements(p_customer_selections) with ordinality item(value, ordinality)
    order by item.ordinality
  loop
    v_customer_id := nullif(v_selection.selection ->> 'customer_id', '')::uuid;
    v_schedule_product_id := nullif(v_selection.selection ->> 'schedule_product_id', '')::uuid;
    v_scheduled_for_date := nullif(v_selection.selection ->> 'scheduled_for_date', '')::date;

    v_schedule_version_id := null;
    v_schedule_day_id := null;
    v_production_order := null;
    v_expected_kg := null;
    v_production_instructions := null;
    v_weekday := null;
    v_weekday_name := null;
    v_route_id := null;
    v_route_code := null;
    v_route_display_name := null;
    v_route_color := null;

    if v_wash_type in ('CLOTHES', 'MOP') and v_schedule_product_id is not null then
      if v_scheduled_for_date is null then
        raise exception using
          errcode = '22023',
          message = 'Scheduled date is required for a scheduled customer selection.';
      end if;

      if v_scheduled_for_date < v_business_date - 2
         or v_scheduled_for_date > v_business_date + 2 then
        raise exception using
          errcode = '22023',
          message = 'Scheduled customer date must be within two days of the washing Business Date.';
      end if;

      select
        csv.schedule_version_id,
        sd.schedule_day_id,
        sp.production_order,
        sp.expected_kg,
        sp.production_instructions,
        sd.production_weekday,
        trim(to_char(v_scheduled_for_date, 'Day')),
        r.route_id,
        r.route_code,
        r.display_name,
        r.route_color
      into
        v_schedule_version_id,
        v_schedule_day_id,
        v_production_order,
        v_expected_kg,
        v_production_instructions,
        v_weekday,
        v_weekday_name,
        v_route_id,
        v_route_code,
        v_route_display_name,
        v_route_color
      from public.customer_schedule_products sp
      join public.customer_schedule_days sd
        on sd.schedule_day_id = sp.schedule_day_id
       and sd.active = true
      join public.customer_schedule_versions csv
        on csv.schedule_version_id = sd.schedule_version_id
       and csv.status = 'PUBLISHED'
       and csv.customer_id = v_customer_id
       and csv.effective_from <= v_scheduled_for_date
       and (csv.effective_until is null or csv.effective_until >= v_scheduled_for_date)
      join public.product_types pt
        on pt.product_type_id = sp.product_type_id
       and pt.active = true
       and pt.deleted_at is null
       and pt.product_code = v_wash_type
      left join public.distribution_routes r
        on r.route_id = sd.default_route_id
       and r.deleted_at is null
      where sp.schedule_product_id = v_schedule_product_id
        and sp.active = true
        and sd.production_weekday = extract(isodow from v_scheduled_for_date)::smallint
      limit 1;

      if v_schedule_day_id is null then
        raise exception using
          errcode = '22023',
          message = 'The selected customer schedule does not match the selected product/date.';
      end if;

      v_relation := case
        when v_scheduled_for_date = v_business_date then 'TODAY'
        when v_scheduled_for_date > v_business_date then 'EARLY'
        else 'LATE'
      end;

      if v_relation = 'EARLY' then
        v_early_count := v_early_count + 1;
      end if;

      update public.sorting_wash_run_customers wrc
      set source_schedule_version_id = v_schedule_version_id,
          source_schedule_day_id = v_schedule_day_id,
          source_schedule_product_id = v_schedule_product_id,
          production_order_snapshot = v_production_order,
          expected_kg_snapshot = v_expected_kg,
          production_instructions_snapshot = v_production_instructions,
          schedule_relation = v_relation,
          scheduled_for_date = v_scheduled_for_date,
          scheduled_weekday_snapshot = v_weekday,
          scheduled_weekday_name_snapshot = v_weekday_name,
          route_id_snapshot = v_route_id,
          route_code_snapshot = v_route_code,
          route_display_name_snapshot = v_route_display_name,
          route_color_snapshot = v_route_color
      where wrc.wash_run_id = v_wash_run_id
        and wrc.customer_id = v_customer_id;

    elsif v_wash_type in ('CLOTHES', 'MOP') then
      v_unscheduled_count := v_unscheduled_count + 1;

      update public.sorting_wash_run_customers wrc
      set source_schedule_version_id = null,
          source_schedule_day_id = null,
          source_schedule_product_id = null,
          production_order_snapshot = null,
          expected_kg_snapshot = null,
          production_instructions_snapshot = null,
          schedule_relation = 'UNSCHEDULED',
          scheduled_for_date = null,
          scheduled_weekday_snapshot = null,
          scheduled_weekday_name_snapshot = null,
          route_id_snapshot = null,
          route_code_snapshot = null,
          route_display_name_snapshot = null,
          route_color_snapshot = null
      where wrc.wash_run_id = v_wash_run_id
        and wrc.customer_id = v_customer_id;

    else
      update public.sorting_wash_run_customers wrc
      set schedule_relation = 'NOT_APPLICABLE',
          scheduled_for_date = null,
          scheduled_weekday_snapshot = null,
          scheduled_weekday_name_snapshot = null,
          route_id_snapshot = null,
          route_code_snapshot = null,
          route_display_name_snapshot = null,
          route_color_snapshot = null
      where wrc.wash_run_id = v_wash_run_id
        and wrc.customer_id = v_customer_id;
    end if;
  end loop;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'trace_code', wrc.trace_code,
      'customer_id', wrc.customer_id,
      'customer_code', wrc.customer_code_snapshot,
      'customer_name', wrc.customer_name_snapshot,
      'schedule_relation', wrc.schedule_relation,
      'scheduled_for_date', wrc.scheduled_for_date,
      'scheduled_weekday', wrc.scheduled_weekday_name_snapshot,
      'source_schedule_product_id', wrc.source_schedule_product_id,
      'route_code', wrc.route_code_snapshot,
      'route_display_name', wrc.route_display_name_snapshot,
      'route_color', wrc.route_color_snapshot
    )
    order by wrc.trace_code
  ), '[]'::jsonb)
  into v_trace_rows
  from public.sorting_wash_run_customers wrc
  where wrc.wash_run_id = v_wash_run_id;

  return v_result || jsonb_build_object(
    'unscheduled_customer_count', v_unscheduled_count,
    'early_customer_count', v_early_count,
    'trace_rows', v_trace_rows,
    'message', case
      when v_early_count > 0 and v_unscheduled_count > 0 then
        format(
          'Washing %s saved. %s customer(s) are work-ahead and %s customer(s) are off schedule.',
          v_result ->> 'wash_code',
          v_early_count,
          v_unscheduled_count
        )
      when v_early_count > 0 then
        format(
          'Washing %s saved. %s customer(s) belong to a future scheduled production day.',
          v_result ->> 'wash_code',
          v_early_count
        )
      when v_unscheduled_count > 0 then
        format(
          'Washing %s saved. %s customer(s) are outside the selected published schedule.',
          v_result ->> 'wash_code',
          v_unscheduled_count
        )
      else
        format('Washing %s saved successfully.', v_result ->> 'wash_code')
    end
  );
end;
$$;


create or replace function public.get_sorting_customer_board_v3(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_rows jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  with board_days as (
    select
      v_business_date as scheduled_for_date,
      'TODAY'::text as day_relation,
      0::integer as day_offset
    union all
    select
      v_business_date + 1,
      'TOMORROW'::text,
      1
  ),
  board_rows as (
    select
      bd.scheduled_for_date,
      bd.day_relation,
      bd.day_offset,
      extract(isodow from bd.scheduled_for_date)::smallint as scheduled_weekday,
      trim(to_char(bd.scheduled_for_date, 'Day')) as scheduled_weekday_name,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      pt.product_code,
      sp.production_order,
      sp.expected_kg,
      sp.production_instructions,
      csv.schedule_version_id,
      sd.schedule_day_id,
      sp.schedule_product_id,
      r.route_id,
      r.route_code,
      r.display_name as route_display_name,
      r.route_color,
      coalesce((
        select sum(req.quantity)::integer
        from public.customer_schedule_trolley_requirements req
        where req.schedule_day_id = sd.schedule_day_id
          and req.owner_schedule_product_id = sp.schedule_product_id
          and req.active = true
      ), 0) as planned_trolley_quantity,
      (
        select count(*)::integer
        from public.sorting_wash_run_customers wrc
        join public.sorting_wash_runs wr
          on wr.wash_run_id = wrc.wash_run_id
        where wr.status = 'RECORDED'
          and wrc.customer_id = c.customer_id
          and wrc.wash_type_snapshot = pt.product_code
          and wrc.source_schedule_product_id = sp.schedule_product_id
          and coalesce(wrc.scheduled_for_date, wr.business_date) = bd.scheduled_for_date
      ) as wash_count,
      (
        select wr2.wash_code
        from public.sorting_wash_run_customers wrc2
        join public.sorting_wash_runs wr2
          on wr2.wash_run_id = wrc2.wash_run_id
        where wr2.status = 'RECORDED'
          and wrc2.customer_id = c.customer_id
          and wrc2.wash_type_snapshot = pt.product_code
          and wrc2.source_schedule_product_id = sp.schedule_product_id
          and coalesce(wrc2.scheduled_for_date, wr2.business_date) = bd.scheduled_for_date
        order by wr2.started_at desc, wr2.created_at desc
        limit 1
      ) as last_wash_code,
      (
        select wr3.business_date
        from public.sorting_wash_run_customers wrc3
        join public.sorting_wash_runs wr3
          on wr3.wash_run_id = wrc3.wash_run_id
        where wr3.status = 'RECORDED'
          and wrc3.customer_id = c.customer_id
          and wrc3.wash_type_snapshot = pt.product_code
          and wrc3.source_schedule_product_id = sp.schedule_product_id
          and coalesce(wrc3.scheduled_for_date, wr3.business_date) = bd.scheduled_for_date
        order by wr3.started_at desc, wr3.created_at desc
        limit 1
      ) as last_washed_on
    from board_days bd
    join public.customer_schedule_versions csv
      on csv.status = 'PUBLISHED'
     and csv.effective_from <= bd.scheduled_for_date
     and (csv.effective_until is null or csv.effective_until >= bd.scheduled_for_date)
    join public.customers c
      on c.customer_id = csv.customer_id
     and c.active = true
     and c.deleted_at is null
    join public.customer_schedule_days sd
      on sd.schedule_version_id = csv.schedule_version_id
     and sd.active = true
     and sd.production_weekday = extract(isodow from bd.scheduled_for_date)::smallint
    join public.customer_schedule_products sp
      on sp.schedule_day_id = sd.schedule_day_id
     and sp.active = true
    join public.product_types pt
      on pt.product_type_id = sp.product_type_id
     and pt.active = true
     and pt.deleted_at is null
     and pt.product_code in ('CLOTHES', 'MOP')
    left join public.distribution_routes r
      on r.route_id = sd.default_route_id
     and r.deleted_at is null
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', br.customer_id,
      'customer_code', br.customer_code,
      'customer_name', br.customer_name,
      'product_code', br.product_code,
      'production_order', br.production_order,
      'expected_kg', br.expected_kg,
      'production_instructions', br.production_instructions,
      'schedule_version_id', br.schedule_version_id,
      'schedule_day_id', br.schedule_day_id,
      'schedule_product_id', br.schedule_product_id,
      'scheduled_for_date', br.scheduled_for_date,
      'scheduled_weekday', br.scheduled_weekday,
      'scheduled_weekday_name', br.scheduled_weekday_name,
      'day_relation', br.day_relation,
      'day_offset', br.day_offset,
      'route_id', br.route_id,
      'route_code', br.route_code,
      'route_display_name', br.route_display_name,
      'route_color', br.route_color,
      'planned_trolley_quantity', br.planned_trolley_quantity,
      'wash_count', br.wash_count,
      'last_wash_code', br.last_wash_code,
      'last_washed_on', br.last_washed_on,
      'status', case when br.wash_count > 0 then 'WASHED' else 'PENDING' end
    )
    order by
      br.day_offset,
      case br.product_code when 'CLOTHES' then 1 when 'MOP' then 2 else 9 end,
      br.production_order nulls last,
      lower(br.customer_name),
      br.customer_code
  ), '[]'::jsonb)
  into v_rows
  from board_rows br;

  return jsonb_build_object(
    'business_date', v_business_date,
    'customers', v_rows,
    'source', 'PUBLISHED_CUSTOMER_SCHEDULE_TODAY_AND_TOMORROW'
  );
end;
$$;


create or replace function public.get_sorting_washing_context_v3(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_base jsonb;
  v_recent_washes jsonb := '[]'::jsonb;
begin
  v_base := public.get_sorting_washing_context_v2(p_shift_code);

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'wash_run_id', q.wash_run_id,
      'wash_code', q.wash_code,
      'business_date', q.business_date,
      'shift_code', q.shift_code_snapshot,
      'washer_id', q.washer_id,
      'washer_code', q.washer_code_snapshot,
      'washer_name', q.washer_name_snapshot,
      'operator_staff_id', q.operator_staff_id,
      'operator_name', q.operator_name_snapshot,
      'wash_type', q.wash_type,
      'started_at', q.started_at,
      'registered_at', q.registered_at,
      'total_weight_kg', q.total_weight_kg,
      'status', q.status,
      'entry_mode', q.entry_mode,
      'row_version', q.row_version,
      'notes', q.notes,
      'correction_reason', q.correction_reason,
      'cancellation_reason', q.cancellation_reason,
      'cancelled_at', q.cancelled_at,
      'replaces_wash_run_id', q.replaces_wash_run_id,
      'replaces_wash_code', replaced.wash_code,
      'replacement_wash_code', replacement.wash_code,
      'customers', q.customers
    )
    order by q.business_date desc, q.started_at desc, q.registered_at desc
  ), '[]'::jsonb)
  into v_recent_washes
  from (
    select
      wr.*,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'wash_run_customer_id', wrc.wash_run_customer_id,
            'trace_code', wrc.trace_code,
            'customer_id', wrc.customer_id,
            'customer_code', wrc.customer_code_snapshot,
            'customer_name', wrc.customer_name_snapshot,
            'schedule_product_id', wrc.source_schedule_product_id,
            'schedule_relation', wrc.schedule_relation,
            'scheduled_for_date', wrc.scheduled_for_date,
            'scheduled_weekday',
              coalesce(
                wrc.scheduled_weekday_name_snapshot,
                case
                  when wrc.scheduled_for_date is null then null
                  else trim(to_char(wrc.scheduled_for_date, 'Day'))
                end
              ),
            'route_code',
              coalesce(nullif(wrc.route_code_snapshot, ''), r.route_code),
            'route_display_name',
              coalesce(nullif(wrc.route_display_name_snapshot, ''), r.display_name),
            'route_color',
              coalesce(nullif(wrc.route_color_snapshot, ''), r.route_color)
          )
          order by lower(wrc.customer_name_snapshot), wrc.trace_code
        )
        from public.sorting_wash_run_customers wrc
        left join public.customer_schedule_products sp
          on sp.schedule_product_id = wrc.source_schedule_product_id
        left join public.customer_schedule_days sd
          on sd.schedule_day_id = sp.schedule_day_id
        left join public.distribution_routes r
          on r.route_id = sd.default_route_id
        where wrc.wash_run_id = wr.wash_run_id
      ), '[]'::jsonb) as customers
    from public.sorting_wash_runs wr
    where wr.business_date between (v_business_date - 2) and v_business_date
    order by wr.business_date desc, wr.started_at desc, wr.registered_at desc
    limit 100
  ) q
  left join public.sorting_wash_runs replaced
    on replaced.wash_run_id = q.replaces_wash_run_id
  left join lateral (
    select child.wash_code
    from public.sorting_wash_runs child
    where child.replaces_wash_run_id = q.wash_run_id
    order by child.created_at desc
    limit 1
  ) replacement on true;

  return v_base || jsonb_build_object(
    'recent_washes', v_recent_washes,
    'recent_wash_window_days', 3,
    'corrections_supported', true,
    'late_entry_supported', true,
    'operational_clock', public.operational_shift_clock_context(p_shift_code)
  );
end;
$$;


create or replace function public.cancel_sorting_wash_run(
  p_wash_run_id uuid,
  p_expected_row_version integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date;
  v_old public.sorting_wash_runs%rowtype;
  v_new public.sorting_wash_runs%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  perform public.require_sorting_operational_access();

  if p_wash_run_id is null then
    raise exception using errcode='22023', message='Wash record is required.';
  end if;
  if v_reason is null then
    raise exception using errcode='22023', message='Reason is required to cancel a washing record.';
  end if;
  if length(v_reason) > 500 then
    raise exception using errcode='22023', message='Cancellation reason must be 500 characters or fewer.';
  end if;

  select *
  into v_old
  from public.sorting_wash_runs wr
  where wr.wash_run_id = p_wash_run_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Washing record was not found.';
  end if;

  v_business_date := public.operational_business_date_for_shift(v_old.shift_code_snapshot);

  if v_old.status <> 'RECORDED' then
    raise exception using errcode='22023', message='Only an active RECORDED washing can be cancelled.';
  end if;

  if v_old.business_date <> v_business_date then
    raise exception using
      errcode='22023',
      message='Sorting operators can cancel only today''s washing records. Older records require management review.';
  end if;

  if p_expected_row_version is null or p_expected_row_version <> v_old.row_version then
    raise exception using
      errcode='40001',
      message='This washing record changed after it was loaded. Reload before cancelling.';
  end if;

  update public.sorting_wash_runs
  set status = 'CANCELLED',
      cancelled_at = now(),
      cancelled_by_auth_user_id = auth.uid(),
      cancellation_reason = v_reason,
      updated_at = now(),
      row_version = row_version + 1,
      metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'cancelled_from', 'SORTING_V2',
        'cancelled_at', now()
      )
  where wash_run_id = p_wash_run_id
  returning * into v_new;

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'SORTING_WASH_CANCELLED',
    'sorting_wash_runs',
    v_old.wash_run_id::text,
    to_jsonb(v_old),
    to_jsonb(v_new),
    v_reason,
    'SORTING_V2'
  );

  return jsonb_build_object(
    'status','success',
    'wash_run_id',v_new.wash_run_id,
    'wash_code',v_new.wash_code,
    'row_version',v_new.row_version,
    'message',format('%s cancelled. It no longer counts as a completed wash.',v_new.wash_code)
  );
end;
$$;


create or replace function public.correct_sorting_wash_run_v2(
  p_wash_run_id uuid,
  p_expected_row_version integer,
  p_shift_code text,
  p_washer_id uuid,
  p_operator_staff_id uuid,
  p_start_time time,
  p_weight_kg numeric,
  p_wash_type text,
  p_customer_selections jsonb,
  p_notes text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_old public.sorting_wash_runs%rowtype;
  v_cancelled public.sorting_wash_runs%rowtype;
  v_new public.sorting_wash_runs%rowtype;
  v_result jsonb;
  v_new_id uuid;
  v_reason text := nullif(trim(coalesce(p_reason,'')), '');
begin
  perform public.require_sorting_operational_access();

  if v_reason is null then
    raise exception using errcode='22023', message='Correction reason is required.';
  end if;
  if length(v_reason) > 500 then
    raise exception using errcode='22023', message='Correction reason must be 500 characters or fewer.';
  end if;

  select *
  into v_old
  from public.sorting_wash_runs wr
  where wr.wash_run_id = p_wash_run_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Washing record was not found.';
  end if;

  if v_old.status <> 'RECORDED' then
    raise exception using errcode='22023', message='Only an active RECORDED washing can be corrected.';
  end if;

  if v_old.business_date <> v_business_date then
    raise exception using
      errcode='22023',
      message='Sorting operators can correct only today''s washing records. Older records require management review.';
  end if;

  if p_expected_row_version is null or p_expected_row_version <> v_old.row_version then
    raise exception using
      errcode='40001',
      message='This washing record changed after it was loaded. Reload before correcting.';
  end if;

  -- Cancel inside the same transaction. If replacement creation fails, this
  -- cancellation also rolls back automatically.
  update public.sorting_wash_runs
  set status = 'CANCELLED',
      cancelled_at = now(),
      cancelled_by_auth_user_id = auth.uid(),
      cancellation_reason = 'Corrected: ' || v_reason,
      updated_at = now(),
      row_version = row_version + 1,
      metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'cancelled_for_correction', true,
        'correction_reason', v_reason
      )
  where wash_run_id = v_old.wash_run_id
  returning * into v_cancelled;

  v_result := public.save_sorting_wash_run_v2(
    p_shift_code => p_shift_code,
    p_washer_id => p_washer_id,
    p_operator_staff_id => p_operator_staff_id,
    p_start_time => p_start_time,
    p_weight_kg => p_weight_kg,
    p_wash_type => p_wash_type,
    p_customer_selections => p_customer_selections,
    p_notes => p_notes
  );

  v_new_id := nullif(v_result ->> 'wash_run_id','')::uuid;

  update public.sorting_wash_runs
  set entry_mode = 'CORRECTION',
      replaces_wash_run_id = v_old.wash_run_id,
      correction_reason = v_reason,
      metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'corrects_wash_code', v_old.wash_code,
        'correction_reason', v_reason
      ),
      updated_at = now(),
      row_version = row_version + 1
  where wash_run_id = v_new_id
  returning * into v_new;

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application, correlation_id
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'SORTING_WASH_CORRECTED',
    'sorting_wash_runs',
    v_new.wash_run_id::text,
    to_jsonb(v_old),
    to_jsonb(v_new),
    v_reason,
    'SORTING_V2',
    v_old.wash_run_id
  );

  return v_result || jsonb_build_object(
    'status','success',
    'wash_run_id',v_new.wash_run_id,
    'wash_code',v_new.wash_code,
    'row_version',v_new.row_version,
    'entry_mode','CORRECTION',
    'replaces_wash_run_id',v_old.wash_run_id,
    'replaces_wash_code',v_old.wash_code,
    'message',format('%s corrected. Replacement Wash ID: %s.',v_old.wash_code,v_new.wash_code)
  );
end;
$$;



create or replace function public.search_sorting_wash_history(
  p_shift_code text,
  p_query text default null,
  p_date_from date default null,
  p_date_to date default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_query text := lower(trim(coalesce(p_query,'')));
  v_date_to date := coalesce(p_date_to,v_business_date);
  v_date_from date := coalesce(p_date_from,v_date_to-90);
  v_limit integer := greatest(1,least(coalesce(p_limit,100),200));
  v_rows jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  if v_date_from > v_date_to then
    raise exception using errcode='22023', message='Search From date cannot be after To date.';
  end if;

  if v_date_to-v_date_from > 366 then
    raise exception using errcode='22023', message='Wash history search is limited to 366 days at a time.';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'wash_run_id',q.wash_run_id,
      'wash_code',q.wash_code,
      'business_date',q.business_date,
      'shift_code',q.shift_code_snapshot,
      'washer_id',q.washer_id,
      'washer_code',q.washer_code_snapshot,
      'washer_name',q.washer_name_snapshot,
      'operator_staff_id',q.operator_staff_id,
      'operator_name',q.operator_name_snapshot,
      'wash_type',q.wash_type,
      'started_at',q.started_at,
      'registered_at',q.registered_at,
      'total_weight_kg',q.total_weight_kg,
      'status',q.status,
      'entry_mode',q.entry_mode,
      'row_version',q.row_version,
      'notes',q.notes,
      'correction_reason',q.correction_reason,
      'cancellation_reason',q.cancellation_reason,
      'cancelled_at',q.cancelled_at,
      'replaces_wash_run_id',q.replaces_wash_run_id,
      'replaces_wash_code',replaced.wash_code,
      'replacement_wash_code',replacement.wash_code,
      'customers',q.customers
    )
    order by q.business_date desc,q.started_at desc,q.registered_at desc
  ),'[]'::jsonb)
  into v_rows
  from (
    select
      wr.*,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'wash_run_customer_id',wrc.wash_run_customer_id,
            'trace_code',wrc.trace_code,
            'customer_id',wrc.customer_id,
            'customer_code',wrc.customer_code_snapshot,
            'customer_name',wrc.customer_name_snapshot,
            'schedule_product_id',wrc.source_schedule_product_id,
            'schedule_relation',wrc.schedule_relation,
            'scheduled_for_date',wrc.scheduled_for_date,
            'scheduled_weekday',coalesce(
              wrc.scheduled_weekday_name_snapshot,
              case when wrc.scheduled_for_date is null then null
                   else trim(to_char(wrc.scheduled_for_date,'Day')) end
            ),
            'route_code',coalesce(nullif(wrc.route_code_snapshot,''),r.route_code),
            'route_display_name',coalesce(nullif(wrc.route_display_name_snapshot,''),r.display_name),
            'route_color',coalesce(nullif(wrc.route_color_snapshot,''),r.route_color)
          )
          order by lower(wrc.customer_name_snapshot),wrc.trace_code
        )
        from public.sorting_wash_run_customers wrc
        left join public.customer_schedule_products sp
          on sp.schedule_product_id=wrc.source_schedule_product_id
        left join public.customer_schedule_days sd
          on sd.schedule_day_id=sp.schedule_day_id
        left join public.distribution_routes r
          on r.route_id=sd.default_route_id
        where wrc.wash_run_id=wr.wash_run_id
      ),'[]'::jsonb) as customers
    from public.sorting_wash_runs wr
    where wr.business_date between v_date_from and v_date_to
      and (
        v_query=''
        or lower(wr.wash_code) like '%'||v_query||'%'
        or lower(coalesce(wr.washer_code_snapshot,'')) like '%'||v_query||'%'
        or lower(coalesce(wr.washer_name_snapshot,'')) like '%'||v_query||'%'
        or lower(coalesce(wr.operator_name_snapshot,'')) like '%'||v_query||'%'
        or lower(coalesce(wr.wash_type,'')) like '%'||v_query||'%'
        or lower(to_char(wr.business_date,'YYYY-MM-DD')) like '%'||v_query||'%'
        or exists (
          select 1
          from public.sorting_wash_run_customers wrc_search
          where wrc_search.wash_run_id=wr.wash_run_id
            and (
              lower(coalesce(wrc_search.customer_name_snapshot,'')) like '%'||v_query||'%'
              or lower(coalesce(wrc_search.customer_code_snapshot,'')) like '%'||v_query||'%'
              or lower(coalesce(wrc_search.trace_code,'')) like '%'||v_query||'%'
            )
        )
      )
    order by wr.business_date desc,wr.started_at desc,wr.registered_at desc
    limit v_limit
  ) q
  left join public.sorting_wash_runs replaced
    on replaced.wash_run_id=q.replaces_wash_run_id
  left join lateral (
    select child.wash_code
    from public.sorting_wash_runs child
    where child.replaces_wash_run_id=q.wash_run_id
    order by child.created_at desc
    limit 1
  ) replacement on true;

  return jsonb_build_object(
    'status','success',
    'business_date',v_business_date,
    'query',nullif(v_query,''),
    'date_from',v_date_from,
    'date_to',v_date_to,
    'result_count',jsonb_array_length(v_rows),
    'washes',v_rows
  );
end;
$$;

revoke all on function public.search_sorting_wash_history(text,text,date,date,integer)
  from public, anon, authenticated;
grant execute on function public.search_sorting_wash_history(text,text,date,date,integer)
  to authenticated;


revoke all on function public.get_sorting_customer_board_v3(text)
  from public, anon, authenticated;
grant execute on function public.get_sorting_customer_board_v3(text)
  to authenticated;

comment on function public.operational_business_date_for_shift(text,timestamptz) is
  'Shared operational Business Date resolver. Evening activity before the configured rollover belongs to the previous Business Date; intended for Sorting and future Finish/MOP/Distribution operational writes.';

comment on function public.search_sorting_wash_history(text,text,date,date,integer) is
  'Controlled Sorting wash history search by Customer, Wash ID, Washer, Staff, Type, trace code or Business Date. Default window is the last 90 Business Dates.';

commit;
