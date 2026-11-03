-- ElisCaretex V2 - Finish Results: competitive ranking of Finish teams for closed periods.
--
-- One read-only RPC. No table, column or existing function changes.
--
-- Period: a closed week (Monday to Sunday) or a closed calendar month, by Business Date.
-- The current (still open) week or month is never ranked, so a position cannot change
-- after the period is shown.
--
-- Two rankings in the same answer:
--   teams   Table x Shift (6 teams: Table 1 Morning ... Table 3 Evening). The people of one
--           Table in one Shift work together, so this is the main competition.
--   tables  Table only (Morning + Evening together, 3 rows).
--
-- Metric (fair across teams of different size and different days worked):
--   efficiency %  = produced kg equivalent / (staff hours x FINISH_TABLE_KG_PER_STAFF_HOUR) x 100
--                   exactly the numbers of the daily Finish Results screen
--                   (get_finish_results_dashboard), summed over the period: KG lines + units
--                   converted to kg + real ReWash kg, and the staff hours behind each Table.
--   trolley error % = contributions saved with a wrong trolley quantity/size / contributions
--                   with a trolley check, same rules as get_finish_trolley_errors_v1
--                   (a PENDING/RESOLVED plan report from the team is not an error).
--   score         = efficiency % - 2 x trolley error %
--                   (each 1% of contributions saved with a wrong trolley costs 2 points).
-- Only days on which that Table x Shift has staff hours count: before 12/10/2026 Finish
-- had production but no staff hours, and counting that kg without its hours would inflate
-- efficiency. That kg is returned as unmeasured_kg so the screen can say it was left out.
-- Ties: fewer trolley errors first, then more kg produced.
-- A team needs at least 16 staff hours in a week (64 in a month) to be ranked, so a Table
-- that barely opened does not win or lose on a few hours.
-- Zones: position 1 is the leader; positions 2-3 are the podium when 5 or more are ranked;
-- the last 2 (5 or more ranked) or the last 1 (3-4 ranked) are the relegation zone.

create or replace function public.get_finish_table_ranking_v1(
  p_period text default 'WEEK',
  p_anchor date default null
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
  v_period text := upper(coalesce(nullif(trim(p_period), ''), 'WEEK'));
  v_today date;
  v_latest_from date;
  v_from date;
  v_to date;
  v_prev_from date;
  v_prev_to date;
  v_target numeric := 23.5;
  v_penalty numeric := 2;
  v_min_hours numeric;
  v_result jsonb;
begin
  perform public.require_finish_production_access();

  if v_period not in ('WEEK', 'MONTH') then
    raise exception using errcode = '22023', message = 'Choose WEEK or MONTH.';
  end if;

  select coalesce(nullif(value_json #>> '{}', ''), 'Europe/Dublin') into v_timezone
  from public.app_config where config_key = 'business_timezone';
  v_timezone := coalesce(v_timezone, 'Europe/Dublin');
  select coalesce(nullif(value_json #>> '{}', '')::time, time '03:00') into v_rollover
  from public.app_config where config_key = 'evening_shift_rollover_time';
  v_rollover := coalesce(v_rollover, time '03:00');

  v_today := (now() at time zone v_timezone)::date;
  if (now() at time zone v_timezone)::time < v_rollover then
    v_today := v_today - 1;
  end if;

  select coalesce((select target_value from public.production_targets
    where target_code = 'FINISH_TABLE_KG_PER_STAFF_HOUR' and active = true limit 1), 23.5)
  into v_target;

  if v_period = 'WEEK' then
    v_latest_from := date_trunc('week', v_today)::date - 7;
    v_from := date_trunc('week', coalesce(p_anchor, v_latest_from))::date;
    v_to := v_from + 6;
    v_prev_from := v_from - 7;
    v_prev_to := v_from - 1;
    v_min_hours := 16;
  else
    v_latest_from := (date_trunc('month', v_today) - interval '1 month')::date;
    v_from := date_trunc('month', coalesce(p_anchor, v_latest_from))::date;
    v_to := (v_from + interval '1 month')::date - 1;
    v_prev_from := (v_from - interval '1 month')::date;
    v_prev_to := v_from - 1;
    v_min_hours := 64;
  end if;

  if v_from > v_latest_from then
    raise exception using errcode = '22023', message = 'Only closed periods are ranked. Choose an earlier week or month.';
  end if;

  with day_cells as (
    -- The daily Finish Results numbers, one row per day x Table x Shift.
    select
      case when d.d >= v_from then 'CURRENT' else 'PREVIOUS' end as period_key,
      c.value ->> 'table_code' as table_code,
      c.value ->> 'shift_code' as shift_code,
      coalesce((c.value ->> 'produced_kg')::numeric, 0) as produced_kg,
      coalesce((c.value ->> 'rewash_kg')::numeric, 0) as rewash_kg,
      coalesce((c.value ->> 'planned_kg')::numeric, 0) as planned_kg,
      coalesce((c.value ->> 'staff_hours')::numeric, 0) as staff_hours,
      d.d as business_date
    from generate_series(v_prev_from, v_to, interval '1 day') g
    cross join lateral (select g::date as d) d
    cross join lateral jsonb_array_elements(coalesce(public.get_finish_results_dashboard(d.d) -> 'tables', '[]'::jsonb)) c
  ), grp as (
    select e.entry_group_id,
      bool_or(e.trolley_scan_status = 'MISMATCH') as had_mismatch,
      bool_or(e.trolley_scan_status in ('MATCHED', 'MISMATCH')) as checked
    from public.finish_production_entries e
    where e.production_business_date between v_prev_from and v_to
      and e.status in ('ACTIVE', 'SUPERSEDED')
    group by e.entry_group_id
    having bool_or(e.status = 'ACTIVE')
  ), trolley_rows as (
    select
      case when a.production_business_date >= v_from then 'CURRENT' else 'PREVIOUS' end as period_key,
      a.table_code_snapshot as table_code,
      a.shift_code_snapshot as shift_code,
      g.had_mismatch and not exists (
        select 1 from public.operational_data_reports r
        where r.production_flow_item_id = a.production_flow_item_id
          and r.report_type = 'CUSTOMER_TROLLEY_REQUIREMENT'
          and r.source_area_code = 'FINISH'
          and r.status in ('PENDING', 'RESOLVED')
      ) as is_error
    from public.finish_production_entries a
    join grp g on g.entry_group_id = a.entry_group_id and g.checked
    where a.status = 'ACTIVE'
  ), production as (
    select period_key, table_code, shift_code,
      grouping(shift_code) = 1 as is_table_level,
      coalesce(sum(produced_kg) filter (where staff_hours > 0), 0) as produced_kg,
      coalesce(sum(rewash_kg) filter (where staff_hours > 0), 0) as rewash_kg,
      coalesce(sum(produced_kg) filter (where staff_hours <= 0), 0) as unmeasured_kg,
      sum(planned_kg) as planned_kg,
      sum(staff_hours) as staff_hours,
      count(distinct business_date) filter (where staff_hours > 0) as worked_days
    from day_cells
    where table_code in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3')
      and shift_code in ('MORNING', 'EVENING')
    group by grouping sets ((period_key, table_code, shift_code), (period_key, table_code))
  ), trolleys as (
    select period_key, table_code, shift_code,
      grouping(shift_code) = 1 as is_table_level,
      count(*) as checked_count,
      count(*) filter (where is_error) as error_count
    from trolley_rows
    where table_code in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3')
      and shift_code in ('MORNING', 'EVENING')
    group by grouping sets ((period_key, table_code, shift_code), (period_key, table_code))
  ), measured as (
    select
      p.period_key,
      case when p.is_table_level then 'TABLE' else 'TEAM' end as level,
      p.table_code,
      p.shift_code,
      p.produced_kg, p.rewash_kg, p.unmeasured_kg, p.planned_kg, p.staff_hours, p.worked_days,
      coalesce(t.checked_count, 0) as checked_count,
      coalesce(t.error_count, 0) as error_count,
      case when p.planned_kg > 0 then p.produced_kg / p.planned_kg * 100 else 0 end as efficiency,
      case when coalesce(t.checked_count, 0) > 0 then 100.0 * t.error_count / t.checked_count else 0 end as error_percent,
      p.staff_hours >= v_min_hours and p.planned_kg > 0 as eligible
    from production p
    left join trolleys t
      on t.period_key = p.period_key and t.table_code = p.table_code
      and t.is_table_level = p.is_table_level
      and (p.is_table_level or t.shift_code = p.shift_code)
  ), scored as (
    select m.*,
      round(m.efficiency - v_penalty * m.error_percent, 1) as score
    from measured m
  ), ranked as (
    select s.*,
      case when s.eligible then row_number() over (
        partition by s.period_key, s.level, s.eligible
        order by s.score desc, s.error_count asc, s.produced_kg desc, s.table_code, s.shift_code
      ) end as rank_no,
      count(*) filter (where s.eligible) over (partition by s.period_key, s.level) as ranked_count
    from scored s
  ), zoned as (
    select r.*,
      case when r.ranked_count >= 5 then 2 when r.ranked_count >= 3 then 1 else 0 end as relegation_size
    from ranked r
  ), current_rows as (
    select z.*,
      prev.rank_no as previous_rank,
      case
        when not z.eligible then 'NOT_RANKED'
        when z.rank_no = 1 then 'LEADER'
        when z.rank_no > z.ranked_count - z.relegation_size then 'RELEGATION'
        when z.rank_no <= 3 and z.ranked_count >= 5 then 'PODIUM'
        else 'MIDDLE'
      end as zone,
      (select a.score from zoned a
        where a.period_key = 'CURRENT' and a.level = z.level and a.rank_no = z.rank_no - 1) as next_score,
      (select a.score from zoned a
        where a.period_key = 'CURRENT' and a.level = z.level and a.rank_no = z.ranked_count - z.relegation_size) as safety_score
    from zoned z
    left join zoned prev
      on prev.period_key = 'PREVIOUS' and prev.level = z.level and prev.table_code = z.table_code
      and coalesce(prev.shift_code, '') = coalesce(z.shift_code, '')
    where z.period_key = 'CURRENT'
  ), rows_json as (
    select c.level, jsonb_build_object(
      'code', c.table_code || coalesce('|' || c.shift_code, ''),
      'table_code', c.table_code,
      'table_name', case c.table_code when 'FINISH_TABLE_1' then 'Table 1' when 'FINISH_TABLE_2' then 'Table 2' when 'FINISH_TABLE_3' then 'Table 3' end,
      'shift_code', c.shift_code,
      'produced_kg', round(c.produced_kg, 1),
      'rewash_kg', round(c.rewash_kg, 1),
      'unmeasured_kg', round(c.unmeasured_kg, 1),
      'planned_kg', round(c.planned_kg, 1),
      'staff_hours', round(c.staff_hours, 1),
      'kg_per_staff_hour', case when c.staff_hours > 0 then round(c.produced_kg / c.staff_hours, 1) else 0 end,
      'worked_days', c.worked_days,
      'efficiency_percent', round(c.efficiency, 1),
      'trolley_checked_count', c.checked_count,
      'trolley_error_count', c.error_count,
      'trolley_error_percent', round(c.error_percent, 1),
      'penalty_points', round(v_penalty * c.error_percent, 1),
      'score', c.score,
      'eligible', c.eligible,
      'rank', c.rank_no,
      'ranked_count', c.ranked_count,
      'previous_rank', c.previous_rank,
      'rank_change', case when c.rank_no is not null and c.previous_rank is not null then c.previous_rank - c.rank_no end,
      'zone', c.zone,
      'points_to_next', case when c.next_score is not null then round(c.next_score - c.score, 1) end,
      'points_to_safety', case when c.zone = 'RELEGATION' and c.safety_score is not null then round(c.safety_score - c.score, 1) end
    ) as item,
    coalesce(c.rank_no, 99) as sort_rank,
    c.table_code as sort_table,
    case c.shift_code when 'MORNING' then 1 when 'EVENING' then 2 else 0 end as sort_shift
    from current_rows c
  )
  select jsonb_build_object(
    'teams', coalesce((select jsonb_agg(item order by sort_rank, sort_table, sort_shift) from rows_json where level = 'TEAM'), '[]'::jsonb),
    'tables', coalesce((select jsonb_agg(item order by sort_rank, sort_table) from rows_json where level = 'TABLE'), '[]'::jsonb)
  ) into v_result;

  return jsonb_build_object(
    'schema_version', 'FINISH_TABLE_RANKING_V1',
    'period', v_period,
    'date_from', v_from,
    'date_to', v_to,
    'previous_from', v_prev_from,
    'previous_to', v_prev_to,
    'latest_closed_from', v_latest_from,
    'is_latest_closed', v_from = v_latest_from,
    'target_kg_per_staff_hour', v_target,
    'trolley_error_penalty_per_percent', v_penalty,
    'min_staff_hours', v_min_hours
  ) || v_result;
end;
$$;

revoke all on function public.get_finish_table_ranking_v1(text, date) from public, anon;
grant execute on function public.get_finish_table_ranking_v1(text, date) to authenticated;

comment on function public.get_finish_table_ranking_v1(text, date) is
  'Finish Results: ranking of Table x Shift teams and Tables for a closed week or month. Score = efficiency % (daily Finish Results numbers summed) - 2 x trolley error %. Read-only.';
