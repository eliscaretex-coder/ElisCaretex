-- Sorting Results, and Finish Results staff hours that follow every staff movement.
--
-- 1. get_sorting_results_dashboard_v1(date): what Sorting did on a Business Date and the
--    efficiency per staff, per shift and for the day. Staff hours follow the same
--    Planned -> Actual contract as the Sorting Staff tab, for any date:
--      - a Sorting work session (late start, early leave, manual position, imported
--        history, the Sorting part of a partial move) counts its own times;
--      - a published Sorting roster entry without a session counts its planned time,
--        unless the person is absent (confirmed, or inferred after the shift with no
--        wash activity) or moved out of Sorting for the whole shift;
--      - cancelled sessions never count (Back to Sorting cancels the Finish session).
--    Efficiency = earned hours / worked hours, where earned hours = Clothes kg /
--    Clothes target + MOP kg / MOP target. OTHERS loads use the Clothes target.
--
-- 2. get_finish_results_dashboard_normal_v1(date) is replaced. It used the latest work
--    session per person, so a person with two Finish sessions in a shift (overtime,
--    table change, a partial move from Sorting) counted only one of them, chosen by an
--    updated_at tie. It also ignored Finish absences, table segments and staff who are
--    no longer active. Staff hours now come from every non-cancelled Finish session,
--    split across tables by finish_staff_table_segments, plus planned Finish roster
--    entries with no Actual anywhere and no absence. The output shape is unchanged,
--    with a new "staff" list.
--
-- Read-only functions: no data is changed.

create or replace function public.get_sorting_results_dashboard_v1(
  p_business_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_date date;
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_clothes_target numeric := 160;
  v_mop_target numeric := 100;
  v_sorting_area_id uuid;
  v_staff jsonb := '[]'::jsonb;
  v_shifts jsonb := '[]'::jsonb;
  v_total jsonb := '{}'::jsonb;
  v_runs jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  select coalesce(nullif(value_json #>> '{}', ''), 'Europe/Dublin') into v_timezone
  from public.app_config where config_key = 'business_timezone';
  v_timezone := coalesce(v_timezone, 'Europe/Dublin');
  select coalesce(nullif(value_json #>> '{}', '')::time, time '03:00') into v_rollover
  from public.app_config where config_key = 'evening_shift_rollover_time';
  v_rollover := coalesce(v_rollover, time '03:00');

  v_date := p_business_date;
  if v_date is null then
    v_date := (now() at time zone v_timezone)::date;
    if (now() at time zone v_timezone)::time < v_rollover then
      v_date := v_date - 1;
    end if;
  end if;

  select coalesce((select target_value from public.production_targets
    where target_code = 'SORTING_CLOTHES_KG_PER_STAFF_HOUR' and active = true limit 1), 160)
  into v_clothes_target;
  select coalesce((select target_value from public.production_targets
    where target_code = 'SORTING_MOP_KG_PER_STAFF_HOUR' and active = true limit 1), 100)
  into v_mop_target;
  v_clothes_target := greatest(v_clothes_target, 0.001);
  v_mop_target := greatest(v_mop_target, 0.001);

  select a.area_id into v_sorting_area_id
  from public.areas a where a.area_code = 'SORTING' and a.deleted_at is null limit 1;

  with shift_ctx as (
    select
      sh.shift_id,
      sh.shift_code,
      coalesce(nullif(pc.profile ->> 'break_minutes', '')::integer, 0) as profile_break,
      coalesce(nullif(pc.profile ->> 'net_minutes', '')::integer, 0) as profile_net,
      nullif(pc.profile ->> 'default_start_time', '')::time as profile_start,
      nullif(pc.profile ->> 'default_end_time', '')::time as profile_end,
      coalesce((public.sorting_shift_auto_absence_context(v_date, sh.shift_code, now()) ->> 'cutoff_reached')::boolean, false) as cutoff_reached,
      (
        select prv.roster_version_id
        from public.production_roster_versions prv
        join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
        where rp.week_start = public.production_roster_week_start(v_date)
          and prv.shift_id = sh.shift_id
          and prv.status = 'PUBLISHED'
        order by prv.published_at desc nulls last, prv.version_number desc
        limit 1
      ) as roster_version_id
    from public.shifts sh
    cross join lateral (select public.production_roster_work_profile_context(v_date, sh.shift_code) as profile) pc
    where sh.shift_code in ('MORNING', 'EVENING') and sh.active = true and sh.deleted_at is null
  ), planned as (
    -- Same Sorting criteria as get_sorting_staff_work_context.
    select distinct on (sc.shift_id, pre.staff_id)
      sc.shift_id,
      pre.staff_id,
      pre.roster_entry_id,
      pre.staff_display_name_snapshot as display_name,
      pre.planned_start_time,
      pre.planned_end_time,
      pre.sorting_work_mode
    from shift_ctx sc
    join public.production_roster_entries pre on pre.roster_version_id = sc.roster_version_id
    left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
    left join public.areas a on a.area_id = pre.area_id
    left join public.stations st on st.station_id = pre.station_id
    where pre.work_date = v_date
      and pre.day_status = 'WORKING'
      and (
        coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) = 'SORTING'
        or coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) = 'SORTING_MAIN'
        or pre.display_section_code = 'SORTING_AREA'
        or coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) = 'SORTING_AREA'
      )
    order by sc.shift_id, pre.staff_id, pre.roster_entry_id
  ), sessions as (
    select ws.*, a.area_code, a.area_name, st.station_name
    from public.work_sessions ws
    join shift_ctx sc on sc.shift_id = ws.shift_id
    join public.areas a on a.area_id = ws.area_id
    left join public.stations st on st.station_id = ws.station_id
    where ws.work_date = v_date
      and ws.status <> 'CANCELLED'
  ), sorting_session_times as (
    select
      s.shift_id,
      s.staff_id,
      s.source,
      s.notes,
      s.actual_start_at,
      s.actual_end_at,
      coalesce(s.break_minutes, sc.profile_break) as break_minutes,
      coalesce(s.extra_non_work_minutes, 0) as extra_minutes,
      sc.profile_net,
      t.start_at,
      case when t.end_at is not null and t.start_at is not null and t.end_at <= t.start_at
        then t.end_at + interval '1 day' else t.end_at end as end_at
    from sessions s
    join shift_ctx sc on sc.shift_id = s.shift_id
    left join public.production_roster_entries pre on pre.roster_entry_id = s.production_roster_entry_id
    left join planned p on p.shift_id = s.shift_id and p.staff_id = s.staff_id
    cross join lateral (
      select
        coalesce(s.actual_start_at, public.operational_timestamp_for_shift(v_date, sc.shift_code,
          coalesce(pre.planned_start_time, p.planned_start_time, sc.profile_start))) as start_at,
        coalesce(s.actual_end_at, public.operational_timestamp_for_shift(v_date, sc.shift_code,
          coalesce(pre.planned_end_time, p.planned_end_time, sc.profile_end))) as end_at
    ) t
    where s.area_id = v_sorting_area_id
  ), sorting_actual as (
    select
      shift_id,
      staff_id,
      sum(case
        when start_at is null or end_at is null then profile_net
        else greatest(0, round(extract(epoch from (end_at - start_at)) / 60)::integer - break_minutes - extra_minutes)
      end)::integer as worked_minutes,
      min(start_at) as first_start_at,
      max(end_at) as last_end_at,
      sum(break_minutes)::integer as break_minutes,
      sum(extra_minutes)::integer as extra_minutes,
      bool_or(source = 'APPS_SCRIPT_IMPORT') as imported,
      bool_or(actual_start_at is null or actual_end_at is null) as uses_planned_time,
      bool_or(coalesce(notes, '') ilike '%Posição: MOP%' or coalesce(notes, '') ilike '%Position: MOP%') as imported_mop
    from sorting_session_times
    group by shift_id, staff_id
  ), moved_out as (
    -- Actual work outside Sorting in the same shift (whole or partial move).
    select distinct on (s.shift_id, s.staff_id)
      s.shift_id, s.staff_id, s.area_code, s.area_name, s.station_name, s.actual_start_at, s.source
    from sessions s
    where s.area_id is distinct from v_sorting_area_id
    order by s.shift_id, s.staff_id, s.actual_start_at nulls first, s.created_at
  ), run_totals as (
    select
      wr.shift_id,
      wr.operator_staff_id as staff_id,
      max(wr.operator_name_snapshot) as operator_name,
      coalesce(sum(wr.total_weight_kg) filter (where wr.wash_type = 'CLOTHES'), 0) as clothes_kg,
      count(*) filter (where wr.wash_type = 'CLOTHES')::integer as clothes_loads,
      coalesce(sum(wr.total_weight_kg) filter (where wr.wash_type = 'MOP'), 0) as mop_kg,
      count(*) filter (where wr.wash_type = 'MOP')::integer as mop_loads,
      coalesce(sum(wr.total_weight_kg) filter (where wr.wash_type not in ('CLOTHES', 'MOP')), 0) as others_kg,
      count(*) filter (where wr.wash_type not in ('CLOTHES', 'MOP'))::integer as others_loads,
      count(*)::integer as total_loads
    from public.sorting_wash_runs wr
    join shift_ctx sc on sc.shift_id = wr.shift_id
    where wr.business_date = v_date
      and wr.status = 'RECORDED'
    group by wr.shift_id, wr.operator_staff_id
  ), people as (
    select shift_id, staff_id from planned
    union
    select shift_id, staff_id from sorting_actual
    union
    select shift_id, staff_id from run_totals
  ), resolved as (
    select
      pe.shift_id,
      sc.shift_code,
      pe.staff_id,
      coalesce(sm.display_name, p.display_name, rt.operator_name, 'Not recorded') as display_name,
      p.roster_entry_id is not null as planned_in_sorting,
      case when p.planned_start_time is not null and p.planned_end_time is not null
        then to_char(p.planned_start_time, 'HH24:MI') || '-' || to_char(p.planned_end_time, 'HH24:MI')
        when sc.profile_start is not null and sc.profile_end is not null
        then to_char(sc.profile_start, 'HH24:MI') || '-' || to_char(sc.profile_end, 'HH24:MI')
      end as planned_label,
      case
        when p.planned_start_time is not null and p.planned_end_time is not null then greatest(0,
          round(extract(epoch from (
            (v_date + p.planned_end_time + case when p.planned_end_time <= p.planned_start_time then interval '1 day' else interval '0 day' end)
            - (v_date + p.planned_start_time))) / 60)::integer - sc.profile_break)
        else sc.profile_net
      end as planned_minutes,
      sa.worked_minutes as actual_minutes,
      sa.first_start_at,
      sa.last_end_at,
      sa.break_minutes,
      sa.extra_minutes,
      coalesce(sa.imported, false) as imported,
      coalesce(sa.uses_planned_time, false) as uses_planned_time,
      mo.area_code as moved_area_code,
      coalesce(mo.station_name, mo.area_name) as moved_to,
      mo.actual_start_at as moved_at,
      att.attendance_status,
      att.absence_reason,
      coalesce(rt.clothes_kg, 0) as clothes_kg,
      coalesce(rt.clothes_loads, 0) as clothes_loads,
      coalesce(rt.mop_kg, 0) as mop_kg,
      coalesce(rt.mop_loads, 0) as mop_loads,
      coalesce(rt.others_kg, 0) as others_kg,
      coalesce(rt.others_loads, 0) as others_loads,
      coalesce(rt.total_loads, 0) as total_loads,
      coalesce(
        md.work_mode,
        p.sorting_work_mode,
        case when coalesce(sa.imported_mop, false) then 'MOP' end,
        case when coalesce(rt.mop_kg, 0) > coalesce(rt.clothes_kg, 0) + coalesce(rt.others_kg, 0) then 'MOP' end,
        'CLOTHES'
      ) as work_mode,
      case
        when att.attendance_status = 'ABSENT' then 'ABSENT'
        when sa.staff_id is not null and mo.staff_id is not null then 'PARTIAL_MOVE'
        when sa.staff_id is not null then 'ACTUAL'
        when mo.staff_id is not null then 'MOVED'
        when p.staff_id is null then 'NO_HOURS'
        when public.sorting_resolve_attendance_status(att.attendance_status, coalesce(rt.total_loads, 0), false, false, sc.cutoff_reached) = 'AUTO_ABSENT' then 'AUTO_ABSENT'
        else 'AS_PLANNED'
      end as status
    from people pe
    join shift_ctx sc on sc.shift_id = pe.shift_id
    left join public.staff_members sm on sm.staff_id = pe.staff_id
    left join planned p on p.shift_id = pe.shift_id and p.staff_id = pe.staff_id
    left join sorting_actual sa on sa.shift_id = pe.shift_id and sa.staff_id = pe.staff_id
    left join moved_out mo on mo.shift_id = pe.shift_id and mo.staff_id = pe.staff_id
    left join run_totals rt on rt.shift_id = pe.shift_id and rt.staff_id is not distinct from pe.staff_id
    left join public.sorting_daily_staff_attendance att
      on att.business_date = v_date and att.shift_id = pe.shift_id and att.staff_id = pe.staff_id
    left join public.sorting_daily_staff_modes md
      on md.business_date = v_date and md.shift_id = pe.shift_id and md.staff_id = pe.staff_id
  ), measured as (
    select
      r.*,
      case
        when r.status in ('ACTUAL', 'PARTIAL_MOVE') then coalesce(r.actual_minutes, 0)
        when r.status = 'AS_PLANNED' then coalesce(r.planned_minutes, 0)
        else 0
      end as worked_minutes,
      (r.clothes_kg + r.others_kg) / v_clothes_target + r.mop_kg / v_mop_target as earned_hours
    from resolved r
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'shift_code', m.shift_code,
    'staff_id', m.staff_id,
    'display_name', m.display_name,
    'work_mode', m.work_mode,
    'status', m.status,
    'planned_in_sorting', m.planned_in_sorting,
    'planned_label', m.planned_label,
    'planned_minutes', m.planned_minutes,
    'actual_start', case when m.status in ('ACTUAL', 'PARTIAL_MOVE') then to_char(m.first_start_at at time zone v_timezone, 'HH24:MI') end,
    'actual_end', case when m.status in ('ACTUAL', 'PARTIAL_MOVE') then to_char(m.last_end_at at time zone v_timezone, 'HH24:MI') end,
    'break_minutes', m.break_minutes,
    'extra_non_work_minutes', m.extra_minutes,
    'uses_planned_time', m.uses_planned_time,
    'imported', m.imported,
    'moved_to', m.moved_to,
    'moved_area_code', m.moved_area_code,
    'moved_at', case when m.moved_at is null then null else to_char(m.moved_at at time zone v_timezone, 'HH24:MI') end,
    'attendance_status', m.attendance_status,
    'absence_reason', m.absence_reason,
    'worked_minutes', m.worked_minutes,
    'worked_hours', round(m.worked_minutes / 60.0, 2),
    'clothes_kg', round(m.clothes_kg, 1),
    'clothes_loads', m.clothes_loads,
    'mop_kg', round(m.mop_kg, 1),
    'mop_loads', m.mop_loads,
    'others_kg', round(m.others_kg, 1),
    'others_loads', m.others_loads,
    'produced_kg', round(m.clothes_kg + m.mop_kg + m.others_kg, 1),
    'total_loads', m.total_loads,
    'kg_per_staff_hour', case when m.worked_minutes > 0 then round((m.clothes_kg + m.mop_kg + m.others_kg) * 60.0 / m.worked_minutes, 1) end,
    'earned_hours', round(m.earned_hours, 2),
    'efficiency_percent', case when m.worked_minutes > 0 then round(m.earned_hours * 60.0 / m.worked_minutes * 100, 1) end
  ) order by
    case m.shift_code when 'MORNING' then 1 else 2 end,
    case when m.worked_minutes > 0 then 0 when m.status in ('MOVED', 'NO_HOURS') then 1 else 2 end,
    lower(m.display_name)
  ), '[]'::jsonb)
  into v_staff
  from measured m;

  with rows as (
    select value as item from jsonb_array_elements(v_staff)
  ), grouped as (
    select
      s.shift_code,
      coalesce(sum((r.item ->> 'worked_minutes')::numeric), 0) as worked_minutes,
      coalesce(sum((r.item ->> 'clothes_kg')::numeric), 0) as clothes_kg,
      coalesce(sum((r.item ->> 'clothes_loads')::integer), 0) as clothes_loads,
      coalesce(sum((r.item ->> 'mop_kg')::numeric), 0) as mop_kg,
      coalesce(sum((r.item ->> 'mop_loads')::integer), 0) as mop_loads,
      coalesce(sum((r.item ->> 'others_kg')::numeric), 0) as others_kg,
      coalesce(sum((r.item ->> 'others_loads')::integer), 0) as others_loads,
      coalesce(sum((r.item ->> 'earned_hours')::numeric), 0) as earned_hours,
      count(*) filter (where (r.item ->> 'worked_minutes')::numeric > 0)::integer as staff_count,
      count(*) filter (where r.item ->> 'status' in ('ABSENT', 'AUTO_ABSENT'))::integer as absent_count,
      count(*) filter (where r.item ->> 'status' = 'MOVED')::integer as moved_count,
      count(*) filter (where r.item ->> 'status' = 'PARTIAL_MOVE')::integer as partial_move_count
    from (values ('MORNING'), ('EVENING')) s(shift_code)
    left join rows r on r.item ->> 'shift_code' = s.shift_code
    group by s.shift_code
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'shift_code', g.shift_code,
    'staff_hours', round(g.worked_minutes / 60.0, 2),
    'clothes_kg', round(g.clothes_kg, 1),
    'clothes_loads', g.clothes_loads,
    'mop_kg', round(g.mop_kg, 1),
    'mop_loads', g.mop_loads,
    'others_kg', round(g.others_kg, 1),
    'others_loads', g.others_loads,
    'produced_kg', round(g.clothes_kg + g.mop_kg + g.others_kg, 1),
    'total_loads', g.clothes_loads + g.mop_loads + g.others_loads,
    'earned_hours', round(g.earned_hours, 2),
    'kg_per_staff_hour', case when g.worked_minutes > 0 then round((g.clothes_kg + g.mop_kg + g.others_kg) * 60.0 / g.worked_minutes, 1) end,
    'efficiency_percent', case when g.worked_minutes > 0 then round(g.earned_hours * 60.0 / g.worked_minutes * 100, 1) end,
    'staff_count', g.staff_count,
    'absent_count', g.absent_count,
    'moved_count', g.moved_count,
    'partial_move_count', g.partial_move_count
  ) order by case g.shift_code when 'MORNING' then 1 else 2 end), '[]'::jsonb)
  into v_shifts
  from grouped g;

  with rows as (
    select value as item from jsonb_array_elements(v_staff)
  ), t as (
    select
      coalesce(sum((item ->> 'worked_minutes')::numeric), 0) as worked_minutes,
      coalesce(sum((item ->> 'clothes_kg')::numeric), 0) as clothes_kg,
      coalesce(sum((item ->> 'clothes_loads')::integer), 0) as clothes_loads,
      coalesce(sum((item ->> 'mop_kg')::numeric), 0) as mop_kg,
      coalesce(sum((item ->> 'mop_loads')::integer), 0) as mop_loads,
      coalesce(sum((item ->> 'others_kg')::numeric), 0) as others_kg,
      coalesce(sum((item ->> 'others_loads')::integer), 0) as others_loads,
      coalesce(sum((item ->> 'earned_hours')::numeric), 0) as earned_hours,
      count(distinct item ->> 'staff_id') filter (where (item ->> 'worked_minutes')::numeric > 0)::integer as staff_count,
      count(*) filter (where item ->> 'status' in ('ABSENT', 'AUTO_ABSENT'))::integer as absent_count,
      count(*) filter (where item ->> 'status' = 'MOVED')::integer as moved_count,
      count(*) filter (where item ->> 'status' = 'PARTIAL_MOVE')::integer as partial_move_count
    from rows
  )
  select jsonb_build_object(
    'staff_hours', round(worked_minutes / 60.0, 2),
    'clothes_kg', round(clothes_kg, 1),
    'clothes_loads', clothes_loads,
    'mop_kg', round(mop_kg, 1),
    'mop_loads', mop_loads,
    'others_kg', round(others_kg, 1),
    'others_loads', others_loads,
    'produced_kg', round(clothes_kg + mop_kg + others_kg, 1),
    'total_loads', clothes_loads + mop_loads + others_loads,
    'earned_hours', round(earned_hours, 2),
    'kg_per_staff_hour', case when worked_minutes > 0 then round((clothes_kg + mop_kg + others_kg) * 60.0 / worked_minutes, 1) end,
    'efficiency_percent', case when worked_minutes > 0 then round(earned_hours * 60.0 / worked_minutes * 100, 1) end,
    'staff_count', staff_count,
    'absent_count', absent_count,
    'moved_count', moved_count,
    'partial_move_count', partial_move_count
  )
  into v_total
  from t;

  select coalesce(jsonb_agg(jsonb_build_object(
    'wash_run_id', wr.wash_run_id,
    'wash_code', wr.wash_code,
    'shift_code', coalesce(sh.shift_code, wr.shift_code_snapshot),
    'washer_name', coalesce(wr.washer_name_snapshot, wr.washer_code_snapshot),
    'wash_type', wr.wash_type,
    'total_weight_kg', wr.total_weight_kg,
    'operator_staff_id', wr.operator_staff_id,
    'operator_name', coalesce(wr.operator_name_snapshot, 'Not recorded'),
    'registered_at', coalesce(wr.registered_at, wr.started_at),
    'customer_count', coalesce(c.customer_count, 0),
    'customers', coalesce(c.customers, '[]'::jsonb)
  ) order by coalesce(wr.registered_at, wr.started_at), wr.wash_code), '[]'::jsonb)
  into v_runs
  from public.sorting_wash_runs wr
  left join public.shifts sh on sh.shift_id = wr.shift_id
  left join lateral (
    select
      count(distinct coalesce(wc.customer_id::text, wc.customer_name_snapshot))::integer as customer_count,
      jsonb_agg(distinct jsonb_build_object(
        'customer_name', wc.customer_name_snapshot,
        'route_code', wc.route_code_snapshot,
        'route_color', wc.route_color_snapshot
      )) as customers
    from public.sorting_wash_run_customers wc
    where wc.wash_run_id = wr.wash_run_id
  ) c on true
  where wr.business_date = v_date
    and wr.status = 'RECORDED';

  return jsonb_build_object(
    'schema_version', 'SORTING_RESULTS_V1',
    'source_contract', 'SORTING_WORK_SESSIONS_PLUS_PUBLISHED_ROSTER_PLUS_RECORDED_WASH_RUNS',
    'generated_at', now(),
    'business_date', v_date,
    'targets', jsonb_build_object(
      'clothes_kg_per_staff_hour', v_clothes_target,
      'mop_kg_per_staff_hour', v_mop_target,
      'others_use_clothes_target', true
    ),
    'total', v_total,
    'shifts', v_shifts,
    'staff', v_staff,
    'runs', v_runs,
    'notes', 'Staff hours follow Actual work sessions (cancelled ones excluded), then the published Roster for people without an Actual, minus absences and whole-shift moves.'
  );
end;
$$;

revoke all on function public.get_sorting_results_dashboard_v1(date) from public, anon;
grant execute on function public.get_sorting_results_dashboard_v1(date) to authenticated;


create or replace function public.get_finish_results_dashboard_normal_v1(
  p_business_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_date date;
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_target numeric := 23.5;
  v_finish_area_id uuid;
  v_staff jsonb := '[]'::jsonb;
  v_tables jsonb := '[]'::jsonb;
  v_shifts jsonb := '[]'::jsonb;
  v_total jsonb := '{}'::jsonb;
  v_entries jsonb := '[]'::jsonb;
begin
  perform public.require_finish_production_access();

  select coalesce(nullif(value_json #>> '{}', ''), 'Europe/Dublin') into v_timezone
  from public.app_config where config_key = 'business_timezone';
  v_timezone := coalesce(v_timezone, 'Europe/Dublin');
  select coalesce(nullif(value_json #>> '{}', '')::time, time '03:00') into v_rollover
  from public.app_config where config_key = 'evening_shift_rollover_time';
  v_rollover := coalesce(v_rollover, time '03:00');

  if p_business_date is not null then
    v_date := p_business_date;
  else
    v_date := (now() at time zone v_timezone)::date;
    if (now() at time zone v_timezone)::time < v_rollover then
      v_date := v_date - 1;
    end if;
  end if;

  select coalesce((select target_value from public.production_targets
    where target_code = 'FINISH_TABLE_KG_PER_STAFF_HOUR' and active = true limit 1), 23.5)
  into v_target;

  select a.area_id into v_finish_area_id
  from public.areas a where a.area_code = 'FINISH' and a.deleted_at is null limit 1;

  -- Staff hours: every non-cancelled Finish session (split by table segments), plus
  -- planned Finish roster entries for people with no Actual anywhere in the shift.
  with shift_ctx as (
    select
      sh.shift_id,
      sh.shift_code,
      coalesce(nullif(pc.profile ->> 'break_minutes', '')::integer, 0) as profile_break,
      coalesce(nullif(pc.profile ->> 'net_minutes', '')::integer, 0) as profile_net,
      nullif(pc.profile ->> 'default_start_time', '')::time as profile_start,
      nullif(pc.profile ->> 'default_end_time', '')::time as profile_end
    from public.shifts sh
    cross join lateral (select public.production_roster_work_profile_context(v_date, sh.shift_code) as profile) pc
    where sh.shift_code in ('MORNING', 'EVENING') and sh.active = true and sh.deleted_at is null
  ), planned as (
    select distinct on (sc.shift_id, pre.staff_id)
      sc.shift_id,
      pre.staff_id,
      pre.staff_display_name_snapshot as display_name,
      pre.station_code_snapshot as table_code,
      pre.planned_start_time,
      pre.planned_end_time
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id = pre.roster_version_id
    join shift_ctx sc on sc.shift_id = prv.shift_id
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where prv.status = 'PUBLISHED'
      and pre.work_date = v_date
      and rp.week_start = public.production_roster_week_start(v_date)
      and pre.area_code_snapshot = 'FINISH'
      and pre.day_status in ('WORKING', 'QUALITY_ANALYSIS')
    order by sc.shift_id, pre.staff_id, prv.version_number desc, prv.published_at desc nulls last
  ), absent as (
    select fa.shift_id, fa.staff_id
    from public.finish_daily_staff_attendance fa
    where fa.business_date = v_date and fa.attendance_status = 'ABSENT'
  ), sessions as (
    select ws.*
    from public.work_sessions ws
    join shift_ctx sc on sc.shift_id = ws.shift_id
    where ws.work_date = v_date and ws.status <> 'CANCELLED'
  ), finish_sessions as (
    select
      s.work_session_id,
      s.shift_id,
      s.staff_id,
      s.source,
      st.station_code as table_code,
      s.actual_start_at is null or s.actual_end_at is null as uses_planned_time,
      coalesce(s.break_minutes, sc.profile_break) + coalesce(s.extra_non_work_minutes, 0) as non_work_minutes,
      sc.profile_net,
      t.start_at,
      case when t.end_at is not null and t.start_at is not null and t.end_at <= t.start_at
        then t.end_at + interval '1 day' else t.end_at end as end_at
    from sessions s
    join shift_ctx sc on sc.shift_id = s.shift_id
    left join public.stations st on st.station_id = s.station_id
    left join public.production_roster_entries pre on pre.roster_entry_id = s.production_roster_entry_id
    left join planned p on p.shift_id = s.shift_id and p.staff_id = s.staff_id
    cross join lateral (
      select
        coalesce(s.actual_start_at, public.operational_timestamp_for_shift(v_date, sc.shift_code,
          coalesce(pre.planned_start_time, p.planned_start_time, sc.profile_start))) as start_at,
        coalesce(s.actual_end_at, public.operational_timestamp_for_shift(v_date, sc.shift_code,
          coalesce(pre.planned_end_time, p.planned_end_time, sc.profile_end))) as end_at
    ) t
    where s.area_id = v_finish_area_id
      and not exists (select 1 from absent ab where ab.shift_id = s.shift_id and ab.staff_id = s.staff_id)
  ), pieces as (
    select
      fs.*,
      coalesce(seg.table_code, fs.table_code) as piece_table_code,
      coalesce(seg.started_at, fs.start_at) as piece_start_at,
      coalesce(seg.ended_at, fs.end_at) as piece_end_at
    from finish_sessions fs
    left join lateral (
      select st.station_code as table_code, g.started_at, coalesce(g.ended_at, fs.end_at) as ended_at
      from public.finish_staff_table_segments g
      join public.stations st on st.station_id = g.station_id
      where g.work_session_id = fs.work_session_id
    ) seg on true
  ), piece_minutes as (
    select
      p.*,
      greatest(0, extract(epoch from (p.piece_end_at - p.piece_start_at)) / 60.0) as piece_gross,
      sum(greatest(0, extract(epoch from (p.piece_end_at - p.piece_start_at)) / 60.0)) over (partition by p.work_session_id) as session_gross,
      count(*) over (partition by p.work_session_id) as piece_count
    from pieces p
  ), actual_rows as (
    select
      pm.shift_id,
      pm.staff_id,
      pm.piece_table_code as table_code,
      'ACTUAL'::text as hours_source,
      pm.source as session_source,
      pm.uses_planned_time,
      pm.piece_start_at as start_at,
      pm.piece_end_at as end_at,
      case
        when pm.start_at is null or pm.end_at is null then pm.profile_net::numeric / pm.piece_count
        when coalesce(pm.session_gross, 0) <= 0 then 0::numeric
        else greatest(0, pm.session_gross - pm.non_work_minutes) * pm.piece_gross / pm.session_gross
      end as net_minutes
    from piece_minutes pm
  ), planned_rows as (
    select
      p.shift_id,
      p.staff_id,
      p.table_code,
      'PLANNED'::text as hours_source,
      null::text as session_source,
      true as uses_planned_time,
      public.operational_timestamp_for_shift(v_date, sc.shift_code, coalesce(p.planned_start_time, sc.profile_start)) as start_at,
      public.operational_timestamp_for_shift(v_date, sc.shift_code, coalesce(p.planned_end_time, sc.profile_end)) as end_at,
      case
        when p.planned_start_time is not null and p.planned_end_time is not null then greatest(0,
          extract(epoch from (
            (v_date + p.planned_end_time + case when p.planned_end_time <= p.planned_start_time then interval '1 day' else interval '0 day' end)
            - (v_date + p.planned_start_time))) / 60.0 - sc.profile_break)
        else sc.profile_net::numeric
      end as net_minutes
    from planned p
    join shift_ctx sc on sc.shift_id = p.shift_id
    where not exists (select 1 from sessions s where s.shift_id = p.shift_id and s.staff_id = p.staff_id)
      and not exists (select 1 from absent ab where ab.shift_id = p.shift_id and ab.staff_id = p.staff_id)
  ), all_rows as (
    select * from actual_rows
    union all
    select * from planned_rows
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'shift_code', sc.shift_code,
    'staff_id', r.staff_id,
    'display_name', coalesce(sm.display_name, p.display_name, 'Staff'),
    'table_code', r.table_code,
    'table_name', case r.table_code when 'FINISH_TABLE_1' then 'Table 1' when 'FINISH_TABLE_2' then 'Table 2' when 'FINISH_TABLE_3' then 'Table 3' end,
    'hours_source', r.hours_source,
    'session_source', r.session_source,
    'uses_planned_time', r.uses_planned_time,
    'start_time', to_char(r.start_at at time zone v_timezone, 'HH24:MI'),
    'end_time', to_char(r.end_at at time zone v_timezone, 'HH24:MI'),
    'net_minutes', round(r.net_minutes)::integer,
    'staff_hours', round(r.net_minutes / 60.0, 2)
  ) order by case sc.shift_code when 'MORNING' then 1 else 2 end, r.table_code, lower(coalesce(sm.display_name, p.display_name, '')), r.start_at), '[]'::jsonb)
  into v_staff
  from all_rows r
  join shift_ctx sc on sc.shift_id = r.shift_id
  left join public.staff_members sm on sm.staff_id = r.staff_id
  left join planned p on p.shift_id = r.shift_id and p.staff_id = r.staff_id
  where r.table_code in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3');

  with staff_rows as (
    select value as item from jsonb_array_elements(v_staff)
  ), staff_by_cell as (
    select
      item ->> 'table_code' as table_code,
      item ->> 'shift_code' as shift_code,
      coalesce(sum((item ->> 'net_minutes')::numeric), 0) / 60.0 as staff_hours,
      count(distinct item ->> 'staff_id') filter (where (item ->> 'net_minutes')::numeric > 0)::integer as staff_count
    from staff_rows
    group by 1, 2
  ), production_by_cell as (
    select
      e.table_code_snapshot as table_code,
      e.shift_code_snapshot as shift_code,
      coalesce(sum(l.quantity) filter (where l.unit_code = 'KG'), 0)::numeric as produced_kg,
      coalesce(sum(l.quantity) filter (where l.unit_code = 'UNIT'), 0)::numeric as produced_units,
      count(distinct e.entry_group_id)::integer as contribution_count
    from public.finish_production_entries e
    join public.finish_production_lines l on l.finish_production_entry_id = e.finish_production_entry_id
    where e.status = 'ACTIVE'
      and e.production_business_date = v_date
      and e.table_code_snapshot in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3')
      and e.shift_code_snapshot in ('MORNING', 'EVENING')
    group by e.table_code_snapshot, e.shift_code_snapshot
  ), cells as (
    select
      t.table_code,
      case t.table_code when 'FINISH_TABLE_1' then 'Table 1' when 'FINISH_TABLE_2' then 'Table 2' when 'FINISH_TABLE_3' then 'Table 3' end as table_name,
      s.shift_code,
      coalesce(p.produced_kg, 0)::numeric as produced_kg,
      coalesce(p.produced_units, 0)::numeric as produced_units,
      coalesce(p.contribution_count, 0)::integer as contribution_count,
      coalesce(st.staff_hours, 0)::numeric as staff_hours,
      coalesce(st.staff_count, 0)::integer as staff_count
    from (values ('FINISH_TABLE_1'), ('FINISH_TABLE_2'), ('FINISH_TABLE_3')) t(table_code)
    cross join (values ('MORNING'), ('EVENING')) s(shift_code)
    left join production_by_cell p on p.table_code = t.table_code and p.shift_code = s.shift_code
    left join staff_by_cell st on st.table_code = t.table_code and st.shift_code = s.shift_code
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'table_code', c.table_code,
    'table_name', c.table_name,
    'shift_code', c.shift_code,
    'produced_kg', round(c.produced_kg, 2),
    'produced_units', round(c.produced_units, 0),
    'planned_kg', round(c.staff_hours * v_target, 2),
    'efficiency_percent', case when c.staff_hours * v_target > 0 then round(c.produced_kg / (c.staff_hours * v_target) * 100, 2) else 0 end,
    'staff_hours', round(c.staff_hours, 2),
    'staff_count', c.staff_count,
    'kg_per_staff_hour', case when c.staff_hours > 0 then round(c.produced_kg / c.staff_hours, 2) else 0 end,
    'contribution_count', c.contribution_count
  ) order by case c.shift_code when 'MORNING' then 1 else 2 end, c.table_code), '[]'::jsonb)
  into v_tables
  from cells c;

  with cell_rows as (
    select value as item from jsonb_array_elements(v_tables)
  ), shifts as (
    select
      item ->> 'shift_code' as shift_code,
      sum((item ->> 'produced_kg')::numeric) as produced_kg,
      sum((item ->> 'produced_units')::numeric) as produced_units,
      sum((item ->> 'planned_kg')::numeric) as planned_kg,
      sum((item ->> 'staff_hours')::numeric) as staff_hours,
      sum((item ->> 'contribution_count')::integer) as contribution_count
    from cell_rows
    group by 1
  ), shift_staff as (
    select item ->> 'shift_code' as shift_code,
      count(distinct item ->> 'staff_id') filter (where (item ->> 'net_minutes')::numeric > 0)::integer as staff_count
    from jsonb_array_elements(v_staff) x(item)
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'shift_code', s.shift_code,
    'produced_kg', round(s.produced_kg, 2),
    'produced_units', round(s.produced_units, 0),
    'planned_kg', round(s.planned_kg, 2),
    'missing_kg', round(greatest(s.planned_kg - s.produced_kg, 0), 2),
    'efficiency_percent', case when s.planned_kg > 0 then round(s.produced_kg / s.planned_kg * 100, 2) else 0 end,
    'staff_hours', round(s.staff_hours, 2),
    'staff_count', coalesce(ss.staff_count, 0),
    'contribution_count', s.contribution_count
  ) order by case s.shift_code when 'MORNING' then 1 else 2 end), '[]'::jsonb)
  into v_shifts
  from shifts s
  left join shift_staff ss on ss.shift_code = s.shift_code;

  with totals as (
    select
      coalesce(sum((x.value ->> 'produced_kg')::numeric), 0) as produced_kg,
      coalesce(sum((x.value ->> 'produced_units')::numeric), 0) as produced_units,
      coalesce(sum((x.value ->> 'planned_kg')::numeric), 0) as planned_kg,
      coalesce(sum((x.value ->> 'staff_hours')::numeric), 0) as staff_hours,
      coalesce(sum((x.value ->> 'contribution_count')::integer), 0) as contribution_count
    from jsonb_array_elements(v_tables) x
  ), all_staff as (
    select count(distinct x.value ->> 'staff_id') filter (where (x.value ->> 'net_minutes')::numeric > 0)::integer as staff_count
    from jsonb_array_elements(v_staff) x
  )
  select jsonb_build_object(
    'produced_kg', round(t.produced_kg, 2),
    'produced_units', round(t.produced_units, 0),
    'planned_kg', round(t.planned_kg, 2),
    'missing_kg', round(greatest(t.planned_kg - t.produced_kg, 0), 2),
    'efficiency_percent', case when t.planned_kg > 0 then round(t.produced_kg / t.planned_kg * 100, 2) else 0 end,
    'staff_hours', round(t.staff_hours, 2),
    'staff_count', coalesce(a.staff_count, 0),
    'contribution_count', t.contribution_count
  )
  into v_total
  from totals t cross join all_staff a;

  -- Production detail: unchanged from 202608130004.
  with active_entries as (
    select
      e.finish_production_entry_id,
      e.entry_group_id,
      e.revision_no,
      e.production_flow_item_id,
      e.customer_id,
      e.production_business_date,
      e.shift_code_snapshot,
      e.table_code_snapshot,
      e.table_name_snapshot,
      e.recorded_at,
      e.processed_by_staff_id,
      coalesce(nullif(e.processed_by_name_snapshot, ''), ps.display_name, 'Not recorded') as processed_by,
      e.recorded_by_staff_id,
      coalesce(rs.display_name, '—') as recorded_by,
      e.trolley_scan_status,
      pfi.customer_name_snapshot as customer_name,
      pfi.customer_code_snapshot as customer_code,
      pfi.route_code_snapshot as route_code,
      pfi.route_display_name_snapshot as route_name,
      pfi.route_color_snapshot as route_color,
      pfi.production_order_snapshot as production_order
    from public.finish_production_entries e
    join public.production_flow_items pfi on pfi.production_flow_item_id = e.production_flow_item_id
    left join public.staff_members ps on ps.staff_id = e.processed_by_staff_id
    left join public.staff_members rs on rs.staff_id = e.recorded_by_staff_id
    where e.status = 'ACTIVE'
      and e.production_business_date = v_date
  ), detail as (
    select
      a.*,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'line_no', l.line_no,
          'batch_reference', l.batch_reference,
          'unit_code', l.unit_code,
          'quantity', l.quantity
        ) order by l.line_no)
        from public.finish_production_lines l
        where l.finish_production_entry_id = a.finish_production_entry_id
      ), '[]'::jsonb) as lines,
      coalesce((
        select jsonb_agg(t.trolley_code_snapshot order by t.trolley_code_snapshot)
        from public.finish_production_trolleys t
        where t.finish_production_entry_id = a.finish_production_entry_id
      ), '[]'::jsonb) as trolley_codes
    from active_entries a
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'finish_production_entry_id', d.finish_production_entry_id,
    'entry_group_id', d.entry_group_id,
    'revision_no', d.revision_no,
    'production_flow_item_id', d.production_flow_item_id,
    'customer_id', d.customer_id,
    'customer_name', d.customer_name,
    'customer_code', d.customer_code,
    'route_code', d.route_code,
    'route_name', d.route_name,
    'route_color', d.route_color,
    'production_order', d.production_order,
    'business_date', d.production_business_date,
    'shift_code', d.shift_code_snapshot,
    'table_code', d.table_code_snapshot,
    'table_name', d.table_name_snapshot,
    'recorded_at', d.recorded_at,
    'processed_by_staff_id', d.processed_by_staff_id,
    'processed_by', d.processed_by,
    'recorded_by_staff_id', d.recorded_by_staff_id,
    'recorded_by', d.recorded_by,
    'trolley_scan_status', d.trolley_scan_status,
    'trolley_codes', d.trolley_codes,
    'lines', d.lines,
    'processed_kg', coalesce((select sum((x.value ->> 'quantity')::numeric) from jsonb_array_elements(d.lines) x where x.value ->> 'unit_code' = 'KG'), 0),
    'processed_units', coalesce((select sum((x.value ->> 'quantity')::numeric) from jsonb_array_elements(d.lines) x where x.value ->> 'unit_code' = 'UNIT'), 0)
  ) order by coalesce(d.production_order, 2147483647), d.route_code, d.recorded_at), '[]'::jsonb)
  into v_entries
  from detail d;

  return jsonb_build_object(
    'schema_version', 'FINISH_RESULTS_V1',
    'source_contract', 'FINISH_ACTIVE_REVISIONS_PLUS_ALL_FINISH_WORK_SESSIONS',
    'generated_at', now(),
    'business_date', v_date,
    'target_kg_per_staff_hour', v_target,
    'total', v_total,
    'shifts', v_shifts,
    'tables', v_tables,
    'staff', v_staff,
    'entries', v_entries,
    'rewash_separate_metric_supported', false,
    'notes', 'Staff hours count every non-cancelled Finish work session, split by table segments, plus planned Finish staff with no Actual and no absence.'
  );
end;
$$;

revoke all on function public.get_finish_results_dashboard_normal_v1(date) from public, anon;
grant execute on function public.get_finish_results_dashboard_normal_v1(date) to authenticated;
