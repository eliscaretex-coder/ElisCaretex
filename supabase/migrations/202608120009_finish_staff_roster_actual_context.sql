-- ElisCaretex V2 - Migration 045 - Finish Staff Roster/Actual context
-- PREPARED: execute only with owner authorization.
--
-- Purpose:
-- - Preserve the current Finish production workflow from Migration 044.
-- - Add a dedicated read contract for the Finish Staff screen.
-- - Roster remains Planned; work_sessions remains Actual.
-- - Include planned Finish staff, incoming Actual Finish staff and Planned -> Actual area differences.
-- - Return the same staff-hours inputs used by the current Finish workflow so the browser can
--   reproduce Target now / Staff Hours / Efficiency without inventing per-person KG ownership.

begin;

create or replace function public.get_finish_staff_context_v2(
  p_shift_code text default 'MORNING',
  p_at timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code,'MORNING')));
  v_now timestamptz := coalesce(p_at,now());
  v_business_date date;
  v_shift public.shifts%rowtype;
  v_profile jsonb;
  v_break_minutes integer := 0;
  v_profile_start time;
  v_profile_end time;
  v_profile_label text;
  v_profile_ambiguous boolean := false;
  v_target numeric := 23.5;
  v_staff jsonb := '[]'::jsonb;
  v_tables jsonb := '[]'::jsonb;
begin
  perform public.require_finish_production_access();

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be Morning or Evening.';
  end if;

  select * into v_shift
  from public.shifts
  where shift_code=v_shift_code and active=true and deleted_at is null
  limit 1;
  if not found then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  v_business_date := public.operational_business_date_for_shift(v_shift_code,v_now);
  v_profile := public.production_roster_work_profile_context(v_business_date,v_shift_code);
  if v_profile is not null then
    v_break_minutes := coalesce(nullif(v_profile->>'break_minutes','')::integer,0);
    v_profile_start := nullif(v_profile->>'default_start_time','')::time;
    v_profile_end := nullif(v_profile->>'default_end_time','')::time;
    v_profile_label := nullif(v_profile->>'schedule_label','');
    v_profile_ambiguous := coalesce(nullif(v_profile->>'is_ambiguous_time_window','')::boolean,false);
  end if;

  select coalesce((select target_value from public.production_targets where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR' and active=true limit 1),23.5)
  into v_target;

  with planned as (
    select distinct on (pre.staff_id)
      pre.staff_id,
      pre.roster_entry_id,
      pre.staff_display_name_snapshot as display_name,
      pre.station_code_snapshot as planned_table_code,
      pre.planned_start_time,
      pre.planned_end_time,
      pre.day_status,
      prv.roster_version_id,
      prv.version_number,
      prv.published_at
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
    join public.shifts sh on sh.shift_id=prv.shift_id
    where prv.status='PUBLISHED'
      and pre.work_date=v_business_date
      and sh.shift_code=v_shift_code
      and pre.area_code_snapshot='FINISH'
      and pre.day_status in ('WORKING','QUALITY_ANALYSIS')
    order by pre.staff_id,prv.version_number desc,prv.published_at desc nulls last
  ), latest_actual as (
    select distinct on (ws.staff_id)
      ws.staff_id,
      ws.work_session_id,
      ws.production_roster_entry_id,
      ws.actual_start_at,
      ws.actual_end_at,
      coalesce(ws.break_minutes,v_break_minutes) as break_minutes,
      coalesce(ws.extra_non_work_minutes,0) as extra_non_work_minutes,
      ws.status,
      ws.source,
      ws.notes,
      ws.updated_at,
      a.area_code as actual_area_code,
      a.area_name as actual_area_name,
      st.station_code as actual_station_code,
      st.station_name as actual_station_name
    from public.work_sessions ws
    join public.shifts sh on sh.shift_id=ws.shift_id
    join public.areas a on a.area_id=ws.area_id
    left join public.stations st on st.station_id=ws.station_id
    where ws.work_date=v_business_date
      and sh.shift_code=v_shift_code
      and ws.status<>'CANCELLED'
    order by ws.staff_id,ws.updated_at desc,ws.work_session_id desc
  ), ids as (
    select staff_id from planned
    union
    select staff_id from latest_actual where actual_area_code='FINISH'
  ), rows as (
    select
      sm.staff_id,
      sm.display_name,
      p.roster_entry_id,
      p.roster_version_id,
      p.version_number as roster_version_number,
      p.published_at as roster_published_at,
      p.day_status as planned_day_status,
      p.planned_table_code,
      p.planned_start_time,
      p.planned_end_time,
      la.work_session_id,
      la.actual_area_code,
      la.actual_area_name,
      la.actual_station_code,
      la.actual_station_name,
      la.actual_start_at,
      la.actual_end_at,
      la.break_minutes,
      la.extra_non_work_minutes,
      la.status as actual_status,
      la.source as actual_source,
      la.notes as actual_notes,
      case
        when la.work_session_id is not null then la.actual_area_code='FINISH'
        else true
      end as actual_in_finish,
      case
        when la.work_session_id is not null and la.actual_area_code='FINISH' then la.actual_station_code
        when la.work_session_id is not null then null
        else p.planned_table_code
      end as effective_table_code,
      case
        when la.work_session_id is not null and la.actual_area_code='FINISH' and la.actual_start_at is not null
          then (la.actual_start_at at time zone 'Europe/Dublin')::time
        else coalesce(p.planned_start_time,v_profile_start)
      end as effective_start_time,
      case
        when la.work_session_id is not null and la.actual_area_code='FINISH' and la.actual_end_at is not null
          then (la.actual_end_at at time zone 'Europe/Dublin')::time
        else coalesce(p.planned_end_time,v_profile_end)
      end as effective_end_time,
      case when la.work_session_id is not null then coalesce(la.break_minutes,v_break_minutes) else v_break_minutes end as effective_break_minutes,
      case
        when la.work_session_id is not null and la.actual_area_code<>'FINISH' then 'ACTUAL_ELSEWHERE'
        when la.work_session_id is not null and p.staff_id is null then 'INCOMING_ACTUAL'
        when la.work_session_id is not null and (
          coalesce(la.actual_station_code,'')<>coalesce(p.planned_table_code,'')
          or la.actual_start_at is not null
          or la.actual_end_at is not null
        ) then 'ADJUSTED'
        else 'AS_PLANNED'
      end as staff_state,
      (coalesce(p.planned_start_time,v_profile_start) is null or coalesce(p.planned_end_time,v_profile_end) is null) as requires_time_choice
    from ids i
    join public.staff_members sm on sm.staff_id=i.staff_id
    left join planned p on p.staff_id=i.staff_id
    left join latest_actual la on la.staff_id=i.staff_id
    where sm.production_staff=true and sm.active=true and sm.roster_eligible=true and sm.deleted_at is null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id',r.staff_id,
    'display_name',r.display_name,
    'roster_entry_id',r.roster_entry_id,
    'roster_version_id',r.roster_version_id,
    'roster_version_number',r.roster_version_number,
    'roster_published_at',r.roster_published_at,
    'planned_day_status',r.planned_day_status,
    'planned_table_code',r.planned_table_code,
    'planned_start_time',r.planned_start_time,
    'planned_end_time',r.planned_end_time,
    'work_session_id',r.work_session_id,
    'actual_area_code',r.actual_area_code,
    'actual_area_name',r.actual_area_name,
    'actual_station_code',r.actual_station_code,
    'actual_station_name',r.actual_station_name,
    'actual_start_at',r.actual_start_at,
    'actual_end_at',r.actual_end_at,
    'actual_status',r.actual_status,
    'actual_source',r.actual_source,
    'actual_notes',r.actual_notes,
    'actual_in_finish',r.actual_in_finish,
    'effective_table_code',r.effective_table_code,
    'effective_start_time',r.effective_start_time,
    'effective_end_time',r.effective_end_time,
    'break_minutes',r.effective_break_minutes,
    'extra_non_work_minutes',r.extra_non_work_minutes,
    'staff_state',r.staff_state,
    'requires_time_choice',r.requires_time_choice
  ) order by coalesce(r.effective_table_code,r.planned_table_code,'ZZZ'),lower(r.display_name)),'[]'::jsonb)
  into v_staff
  from rows r;

  with table_master as (
    select st.station_code,st.station_name
    from public.stations st
    join public.areas a on a.area_id=st.area_id
    where a.area_code='FINISH'
      and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
      and st.active=true and st.deleted_at is null
  ), production as (
    select e.table_code_snapshot as table_code,
      coalesce(sum(l.quantity) filter(where l.unit_code='KG'),0) as produced_kg,
      coalesce(sum(l.quantity) filter(where l.unit_code='UNIT'),0) as produced_units,
      count(distinct e.entry_group_id) as contribution_count
    from public.finish_production_entries e
    join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
    where e.status='ACTIVE'
      and e.production_business_date=v_business_date
      and e.shift_code_snapshot=v_shift_code
    group by e.table_code_snapshot
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'table_code',tm.station_code,
    'table_name',tm.station_name,
    'produced_kg',coalesce(p.produced_kg,0),
    'produced_units',coalesce(p.produced_units,0),
    'contribution_count',coalesce(p.contribution_count,0)
  ) order by tm.station_code),'[]'::jsonb)
  into v_tables
  from table_master tm
  left join production p on p.table_code=tm.station_code;

  return jsonb_build_object(
    'schema_version','FINISH_STAFF_V2',
    'source_contract','PUBLISHED_ROSTER_PLUS_WORK_SESSIONS_ACTUAL',
    'generated_at',v_now,
    'business_date',v_business_date,
    'shift_code',v_shift_code,
    'target_kg_per_staff_hour',v_target,
    'work_profile',v_profile,
    'staff',v_staff,
    'tables',v_tables
  );
end;
$$;

revoke all on function public.get_finish_staff_context_v2(text,timestamptz) from public,anon;
grant execute on function public.get_finish_staff_context_v2(text,timestamptz) to authenticated;

comment on function public.get_finish_staff_context_v2(text,timestamptz) is
'Finish Staff V2 read contract. Published Roster is Planned; latest work_sessions evidence is Actual. Returns current Table production plus legacy-compatible staff-hours inputs for Target now / Efficiency without assigning table KG to an individual scanner.';

commit;
