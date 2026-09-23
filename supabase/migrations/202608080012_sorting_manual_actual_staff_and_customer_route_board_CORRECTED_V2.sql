-- =====================================================================
-- CORRECTED V2 — USE THIS FILE FOR MIGRATION 202608080012
--
-- The add_sorting_actual_staff() function loads the published roster entry
-- into a single %ROWTYPE variable and assigns the roster version afterward.
-- This file supersedes all previously downloaded copies of Migration 012.
-- =====================================================================

-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608080012_sorting_manual_actual_staff_and_customer_route_board.sql
--
-- Adds:
--   1. manual Actual staff positioning in Sorting without modifying PUBLISHED Roster;
--   2. controlled cancel of a manual position (history preserved);
--   3. candidate list for manual staff addition;
--   4. Today's Customers operational board with official Route color and
--      product-owned planned trolley quantity.
--
-- Roster = Planned
-- work_sessions = Actual
-- =====================================================================

begin;

-- One active manual Sorting position per staff/date/shift.
create unique index if not exists work_sessions_sorting_manual_position_uidx
  on public.work_sessions (work_date, staff_id, shift_id, area_id)
  where source = 'SORTING_MANUAL_POSITION'
    and status <> 'CANCELLED';

-- ---------------------------------------------------------------------
-- 1. Candidate list for manual Actual position
-- ---------------------------------------------------------------------

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
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
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

-- ---------------------------------------------------------------------
-- 2. Add manual Actual Sorting position
-- ---------------------------------------------------------------------

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
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
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

-- ---------------------------------------------------------------------
-- 3. Cancel only a manual Sorting position, preserving history
-- ---------------------------------------------------------------------

create or replace function public.cancel_sorting_actual_staff(
  p_work_session_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_session public.work_sessions%rowtype;
  v_staff_name text;
begin
  perform public.require_sorting_operational_access();

  if p_work_session_id is null then
    raise exception using errcode = '22023', message = 'Work session is required.';
  end if;

  select *
  into v_session
  from public.work_sessions ws
  where ws.work_session_id = p_work_session_id
    and ws.source = 'SORTING_MANUAL_POSITION'
    and ws.status <> 'CANCELLED'
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Active manual Sorting position was not found.';
  end if;

  select sm.display_name
  into v_staff_name
  from public.staff_members sm
  where sm.staff_id = v_session.staff_id;

  update public.work_sessions
  set status = 'CANCELLED',
      notes = concat_ws(
        E'\n',
        nullif(notes, ''),
        case
          when nullif(trim(p_reason), '') is null then 'Manual Sorting position cancelled.'
          else 'Manual Sorting position cancelled: ' || trim(p_reason)
        end
      ),
      row_version = row_version + 1,
      updated_at = now(),
      recorded_by_auth_user_id = auth.uid()
  where work_session_id = p_work_session_id;

  return jsonb_build_object(
    'status', 'success',
    'work_session_id', p_work_session_id,
    'staff_name', v_staff_name,
    'message', format('Manual Sorting position cancelled for %s.', coalesce(v_staff_name, 'staff member'))
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Today's Customers board: Route color + trolley quantity
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_today_customer_board()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := (now() at time zone 'Europe/Dublin')::date;
  v_rows jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

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
      'route_id', q.route_id,
      'route_code', q.route_code,
      'route_display_name', q.route_display_name,
      'route_color', q.route_color,
      'planned_trolley_quantity', q.planned_trolley_quantity,
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
  into v_rows
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
        where wrc.customer_id = c.customer_id
          and wr.business_date = v_business_date
          and wr.wash_type = pt.product_code
          and wr.status = 'RECORDED'
      ) as wash_count,
      (
        select wr2.wash_code
        from public.sorting_wash_run_customers wrc2
        join public.sorting_wash_runs wr2
          on wr2.wash_run_id = wrc2.wash_run_id
        where wrc2.customer_id = c.customer_id
          and wr2.business_date = v_business_date
          and wr2.wash_type = pt.product_code
          and wr2.status = 'RECORDED'
        order by wr2.started_at desc, wr2.created_at desc
        limit 1
      ) as last_wash_code,
      (
        select wr3.started_at
        from public.sorting_wash_run_customers wrc3
        join public.sorting_wash_runs wr3
          on wr3.wash_run_id = wrc3.wash_run_id
        where wrc3.customer_id = c.customer_id
          and wr3.business_date = v_business_date
          and wr3.wash_type = pt.product_code
          and wr3.status = 'RECORDED'
        order by wr3.started_at desc, wr3.created_at desc
        limit 1
      ) as last_wash_started_at
    from public.customer_schedule_versions csv
    join public.customers c
      on c.customer_id = csv.customer_id
     and c.active = true
     and c.deleted_at is null
    join public.customer_schedule_days sd
      on sd.schedule_version_id = csv.schedule_version_id
     and sd.active = true
     and sd.production_weekday = extract(isodow from v_business_date)::smallint
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
    where csv.status = 'PUBLISHED'
      and csv.effective_from <= v_business_date
      and (csv.effective_until is null or csv.effective_until >= v_business_date)
  ) q;

  return jsonb_build_object(
    'business_date', v_business_date,
    'customers', v_rows,
    'source', 'PUBLISHED_CUSTOMER_SCHEDULE_ROUTE_MASTER_AND_TROLLEY_REQUIREMENTS'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Extend Sorting Staff context with manual Actual staff
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

-- ---------------------------------------------------------------------
-- 6. Extend worked-time adjustment so manual Actual staff can be edited
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

-- ---------------------------------------------------------------------
-- 7. Privileges
-- ---------------------------------------------------------------------

revoke all on function public.get_sorting_manual_staff_candidates(text)
  from public, anon, authenticated;
revoke all on function public.add_sorting_actual_staff(text, uuid, text)
  from public, anon, authenticated;
revoke all on function public.cancel_sorting_actual_staff(uuid, text)
  from public, anon, authenticated;
revoke all on function public.get_sorting_today_customer_board()
  from public, anon, authenticated;
revoke all on function public.get_sorting_staff_work_context(text)
  from public, anon, authenticated;
revoke all on function public.save_sorting_staff_work_adjustment(text, uuid, time, time, integer, text, text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_manual_staff_candidates(text) to authenticated;
grant execute on function public.add_sorting_actual_staff(text, uuid, text) to authenticated;
grant execute on function public.cancel_sorting_actual_staff(uuid, text) to authenticated;
grant execute on function public.get_sorting_today_customer_board() to authenticated;
grant execute on function public.get_sorting_staff_work_context(text) to authenticated;
grant execute on function public.save_sorting_staff_work_adjustment(text, uuid, time, time, integer, text, text) to authenticated;

comment on function public.add_sorting_actual_staff(text, uuid, text) is
  'Adds an active production staff member to today Sorting Actual staffing. PUBLISHED Roster remains unchanged; planned-vs-actual position is preserved.';
comment on function public.cancel_sorting_actual_staff(uuid, text) is
  'Cancels only a manual Sorting Actual position by status change. History is preserved.';
comment on function public.get_sorting_today_customer_board() is
  'Returns today CLOTHES/MOP production board with official route master color and product-owned planned trolley quantity. Shared trolley requirements are not duplicated because ownership remains authoritative.';

commit;
