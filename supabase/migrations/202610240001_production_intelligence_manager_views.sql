-- Production Intelligence for managers, and the in-app Daily Production Report.
--
-- 1. production_intelligence_staff_hours(date,date): internal helper. Finish and Sorting
--    staff hours per day, shift, area, station and person:
--      - a day/area with imported Apps Script attendance uses those sessions only;
--      - otherwise every non-cancelled work session counts, and a published roster entry
--        (WORKING) without a session in that shift counts its work-profile net time,
--        unless the person is marked ABSENT in the Finish/Sorting attendance overlay.
--    Planned time is used only for past days, so the current day never shows hours that
--    have not been worked yet.
--
-- 2. get_production_intelligence_manager_view(from,to,granularity,compare_from,compare_to):
--    one call for the manager page: summary against a comparison period, trend, area
--    results, customers (KG and average trolleys), shift and table performance and staff
--    turnover. Finish entries record one person per entry while tables work as a team, so
--    there is no per-person KG ranking.
--    Efficiency only counts KG on day/shift/table cells that have staff hours, so a day
--    without recorded hours never inflates the result.
--
-- 3. get_production_daily_report(date): replaces the Apps Script daily emails. Scheduled
--    customers against what was washed and produced, the Sorting and Finish results of
--    the day (reusing their Results functions, so the numbers match those pages) and
--    MOP production.
--
-- Official KG stays Finish KG lines plus MOP batches (production_official_actuals).
-- Shift/table efficiency follows the Finish Results basis (KG + units converted + ReWash)
-- and is labelled as such in the page. Read-only functions: no data is changed.

create or replace function public.production_intelligence_staff_hours(
  p_from date,
  p_to date
)
returns table(work_date date, shift_code text, area_code text, station_code text, staff_id uuid, staff_hours numeric)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with sessions as (
    select ws.work_date, sh.shift_code, a.area_code, st.station_code, ws.staff_id, ws.source,
      greatest(0, extract(epoch from (ws.actual_end_at - ws.actual_start_at)) / 3600.0
        - coalesce(ws.break_minutes, 0) / 60.0
        - coalesce(ws.extra_non_work_minutes, 0) / 60.0)::numeric as hours
    from public.work_sessions ws
    join public.areas a on a.area_id = ws.area_id and a.area_code in ('FINISH', 'SORTING')
    left join public.shifts sh on sh.shift_id = ws.shift_id
    left join public.stations st on st.station_id = ws.station_id
    where ws.work_date between p_from and p_to
      and ws.status <> 'CANCELLED'
      and ws.actual_start_at is not null
      and ws.actual_end_at is not null
  ), imported_days as (
    select distinct s.work_date, s.area_code from sessions s where s.source = 'APPS_SCRIPT_IMPORT'
  ), rostered as (
    select distinct on (pre.work_date, pre.shift_code_snapshot, pre.staff_id)
      pre.work_date, pre.shift_code_snapshot as shift_code, pre.area_code_snapshot as area_code,
      pre.station_code_snapshot as station_code, pre.staff_id
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id = pre.roster_version_id and prv.status = 'PUBLISHED'
    where pre.work_date between p_from and least(p_to, current_date - 1)
      and pre.day_status = 'WORKING'
      and pre.area_code_snapshot in ('FINISH', 'SORTING')
      and pre.staff_id is not null
    order by pre.work_date, pre.shift_code_snapshot, pre.staff_id, prv.published_at desc nulls last, prv.version_number desc
  ), planned as (
    select r.work_date, r.shift_code, r.area_code, r.station_code, r.staff_id, (pwp.net_minutes / 60.0)::numeric as hours
    from rostered r
    join public.production_roster_work_profiles pwp
      on pwp.active and pwp.shift_code = r.shift_code and extract(isodow from r.work_date)::integer = any(pwp.iso_days)
    where not exists (select 1 from imported_days i where i.work_date = r.work_date and i.area_code = r.area_code)
      and not exists (select 1 from sessions s where s.work_date = r.work_date and s.shift_code = r.shift_code and s.staff_id = r.staff_id)
      and not exists (
        select 1 from public.finish_daily_staff_attendance fa join public.shifts sh on sh.shift_id = fa.shift_id
        where r.area_code = 'FINISH' and fa.business_date = r.work_date and sh.shift_code = r.shift_code
          and fa.staff_id = r.staff_id and fa.attendance_status = 'ABSENT')
      and not exists (
        select 1 from public.sorting_daily_staff_attendance sa join public.shifts sh on sh.shift_id = sa.shift_id
        where r.area_code = 'SORTING' and sa.business_date = r.work_date and sh.shift_code = r.shift_code
          and sa.staff_id = r.staff_id and sa.attendance_status = 'ABSENT')
  )
  select s.work_date, s.shift_code, s.area_code, s.station_code, s.staff_id, s.hours from sessions s
  union all
  select p.work_date, p.shift_code, p.area_code, p.station_code, p.staff_id, p.hours from planned p;
$$;

revoke all on function public.production_intelligence_staff_hours(date, date) from public, anon, authenticated;

comment on function public.production_intelligence_staff_hours(date, date) is
  'Internal: Finish and Sorting staff hours per day, shift, station and person (sessions, then published roster for past days, minus absences).';


create or replace function public.get_production_intelligence_manager_view(
  p_from_date date default null,
  p_to_date date default null,
  p_granularity text default 'DAY',
  p_compare_from date default null,
  p_compare_to date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_from date := coalesce(p_from_date, date_trunc('month', current_date)::date);
  v_to date := coalesce(p_to_date, current_date);
  v_cmp_from date;
  v_cmp_to date;
  v_granularity text := upper(coalesce(p_granularity, 'DAY'));
  v_finish_target numeric;
  v_clothes_target numeric;
  v_mop_target numeric;
  v_units_per_kg numeric;
  v_summary jsonb;
  v_compare jsonb;
  v_trend jsonb;
  v_areas jsonb;
  v_customers jsonb;
  v_shifts jsonb;
  v_tables jsonb;
  v_turnover jsonb;
begin
  if auth.uid() is null or not public.has_account_permission('PRODUCTION_INSIGHTS', 'VIEW', null) then
    raise exception using errcode = '42501', message = 'This account cannot view Production Intelligence.';
  end if;
  if v_from > v_to or v_to - v_from > 731 then
    raise exception using errcode = '22023', message = 'Choose a valid period of no more than two years.';
  end if;
  if v_granularity not in ('DAY', 'WEEK', 'MONTH') then
    raise exception using errcode = '22023', message = 'Granularity must be DAY, WEEK or MONTH.';
  end if;

  v_cmp_to := coalesce(p_compare_to, v_from - 1);
  v_cmp_from := coalesce(p_compare_from, v_cmp_to - (v_to - v_from));
  if v_cmp_from > v_cmp_to or v_cmp_to - v_cmp_from > 731 then
    raise exception using errcode = '22023', message = 'Choose a valid comparison period.';
  end if;

  select coalesce((select target_value from public.production_targets where target_code = 'FINISH_TABLE_KG_PER_STAFF_HOUR' and active limit 1), 23.5) into v_finish_target;
  select coalesce((select target_value from public.production_targets where target_code = 'SORTING_CLOTHES_KG_PER_STAFF_HOUR' and active limit 1), 160) into v_clothes_target;
  select coalesce((select target_value from public.production_targets where target_code = 'SORTING_MOP_KG_PER_STAFF_HOUR' and active limit 1), 100) into v_mop_target;
  select coalesce((select target_value from public.production_targets where target_code = 'FINISH_UNITS_PER_KG' and active limit 1), 6) into v_units_per_kg;
  v_finish_target := greatest(v_finish_target, 0.001);
  v_clothes_target := greatest(v_clothes_target, 0.001);
  v_mop_target := greatest(v_mop_target, 0.001);
  v_units_per_kg := greatest(v_units_per_kg, 0.001);

  -- Summary of the period and of the comparison period.
  with actuals as (
    select a.*, case when a.actual_date between v_from and v_to then 'CURRENT' else 'COMPARE' end as period_code
    from public.production_official_actuals a
    where a.actual_date between v_from and v_to or a.actual_date between v_cmp_from and v_cmp_to
  ), trolleys as (
    select case when e.production_business_date between v_from and v_to then 'CURRENT' else 'COMPARE' end as period_code,
      count(*)::integer as trolleys
    from public.finish_production_entries e
    join public.finish_production_trolleys t on t.finish_production_entry_id = e.finish_production_entry_id
    where e.status = 'ACTIVE'
      and (e.production_business_date between v_from and v_to or e.production_business_date between v_cmp_from and v_cmp_to)
    group by 1
    union all
    select case when coalesce(b.physical_processed_on, b.business_date) between v_from and v_to then 'CURRENT' else 'COMPARE' end,
      count(distinct (b.mop_production_batch_id, t.trolley_id))::integer
    from public.sorting_mop_production_batches b
    join public.sorting_mop_production_trolleys t on t.mop_production_batch_id = b.mop_production_batch_id
    where b.status = 'RECORDED'
      and (coalesce(b.physical_processed_on, b.business_date) between v_from and v_to
        or coalesce(b.physical_processed_on, b.business_date) between v_cmp_from and v_cmp_to)
    group by 1
  ), periods as (
    select p.period_code from (values ('CURRENT'), ('COMPARE')) p(period_code)
  ), built as (
    select p.period_code, jsonb_build_object(
      'total_kg', coalesce(round(sum(a.actual_kg), 1), 0),
      'finish_kg', coalesce(round(sum(a.actual_kg) filter (where a.production_source = 'FINISH'), 1), 0),
      'mop_kg', coalesce(round(sum(a.actual_kg) filter (where a.production_source = 'MOP'), 1), 0),
      'production_days', count(distinct a.actual_date),
      'customers', count(distinct a.customer_id),
      'kg_per_production_day', case when count(distinct a.actual_date) > 0 then round(sum(a.actual_kg) / count(distinct a.actual_date), 1) else 0 end,
      'trolleys_out', coalesce((select sum(t.trolleys) from trolleys t where t.period_code = p.period_code), 0)
    ) as summary
    from periods p
    left join actuals a on a.period_code = p.period_code
    group by p.period_code
  )
  select (select summary from built where period_code = 'CURRENT'), (select summary from built where period_code = 'COMPARE')
  into v_summary, v_compare;

  -- Trend inside the period.
  select coalesce(jsonb_agg(to_jsonb(t) order by t.bucket_start), '[]'::jsonb) into v_trend
  from (
    select date_trunc(lower(v_granularity), a.actual_date)::date as bucket_start,
      round(coalesce(sum(a.actual_kg) filter (where a.production_source = 'FINISH'), 0), 1) as finish_kg,
      round(coalesce(sum(a.actual_kg) filter (where a.production_source = 'MOP'), 0), 1) as mop_kg,
      round(sum(a.actual_kg), 1) as total_kg,
      count(distinct a.customer_id)::integer as customers,
      count(distinct a.actual_date)::integer as production_days
    from public.production_official_actuals a
    where a.actual_date between v_from and v_to
    group by 1
  ) t;

  -- Shift, table, staff and area performance (current period only).
  with hours as (
    select * from public.production_intelligence_staff_hours(v_from, v_to)
  ), finish_produced as (
    select e.production_business_date as work_date, e.shift_code_snapshot as shift_code, e.table_code_snapshot as table_code,
      sum(case when l.unit_code = 'KG' then l.quantity when l.unit_code = 'UNIT' then l.quantity / v_units_per_kg else 0 end)::numeric as kg
    from public.finish_production_entries e
    join public.finish_production_lines l on l.finish_production_entry_id = e.finish_production_entry_id
    where e.status = 'ACTIVE' and e.production_business_date between v_from and v_to
    group by 1, 2, 3
    union all
    select e.production_business_date, e.shift_code_snapshot, e.table_code_snapshot, sum(l.quantity_kg)::numeric
    from public.finish_rewash_entries e
    join public.finish_rewash_lines l on l.finish_rewash_entry_id = e.finish_rewash_entry_id
    where e.status = 'ACTIVE' and e.production_business_date between v_from and v_to
    group by 1, 2, 3
  ), finish_cells as (
    select coalesce(p.work_date, h.work_date) as work_date, coalesce(p.shift_code, h.shift_code) as shift_code,
      coalesce(p.table_code, h.station_code) as table_code, coalesce(p.kg, 0) as kg, coalesce(h.hours, 0) as hours, coalesce(h.staff, 0) as staff
    from (select work_date, shift_code, table_code, sum(kg) as kg from finish_produced group by 1, 2, 3) p
    full join (
      select work_date, shift_code, station_code, sum(staff_hours) as hours, count(distinct staff_id) as staff
      from hours where area_code = 'FINISH' and station_code like 'FINISH_TABLE_%' group by 1, 2, 3
    ) h on h.work_date = p.work_date and h.shift_code = p.shift_code and h.station_code = p.table_code
  ), sorting_cells as (
    select coalesce(w.work_date, h.work_date) as work_date, coalesce(w.shift_code, h.shift_code) as shift_code,
      coalesce(w.clothes_kg, 0) as clothes_kg, coalesce(w.mop_kg, 0) as mop_kg, coalesce(w.loads, 0) as loads,
      coalesce(h.hours, 0) as hours, coalesce(h.staff, 0) as staff
    from (
      select wr.business_date as work_date, wr.shift_code_snapshot as shift_code,
        sum(wr.total_weight_kg) filter (where wr.wash_type <> 'MOP') as clothes_kg,
        sum(wr.total_weight_kg) filter (where wr.wash_type = 'MOP') as mop_kg,
        count(*) as loads
      from public.sorting_wash_runs wr
      where wr.status = 'RECORDED' and wr.business_date between v_from and v_to
      group by 1, 2
    ) w
    full join (
      select work_date, shift_code, sum(staff_hours) as hours, count(distinct staff_id) as staff
      from hours where area_code = 'SORTING' group by 1, 2
    ) h on h.work_date = w.work_date and h.shift_code = w.shift_code
  ), finish_by_table as (
    select shift_code, table_code, sum(kg) as kg, sum(hours) as hours,
      sum(kg) filter (where hours > 0) as matched_kg, count(distinct work_date) filter (where kg > 0) as days,
      avg(staff) filter (where hours > 0) as avg_staff
    from finish_cells where table_code like 'FINISH_TABLE_%' and shift_code in ('MORNING', 'EVENING')
    group by 1, 2
  ), finish_by_shift as (
    select shift_code, sum(kg) as kg, sum(hours) as hours, sum(kg) filter (where hours > 0) as matched_kg,
      count(distinct work_date) filter (where kg > 0) as days
    from finish_cells where shift_code in ('MORNING', 'EVENING')
    group by 1
  ), sorting_by_shift as (
    select shift_code, sum(clothes_kg) as clothes_kg, sum(mop_kg) as mop_kg, sum(loads) as loads, sum(hours) as hours,
      sum(clothes_kg / v_clothes_target + mop_kg / v_mop_target) filter (where hours > 0) as earned_hours,
      count(distinct work_date) filter (where loads > 0) as days
    from sorting_cells where shift_code in ('MORNING', 'EVENING')
    group by 1
  ), mop_by_shift as (
    select b.shift_code_snapshot as shift_code, sum(b.total_weight_kg) as kg, count(*) as batches,
      sum(coalesce(b.total_units, 0)) as units, count(distinct coalesce(b.physical_processed_on, b.business_date)) as days
    from public.sorting_mop_production_batches b
    where b.status = 'RECORDED' and coalesce(b.physical_processed_on, b.business_date) between v_from and v_to
    group by 1
  )
  select
    coalesce((select jsonb_agg(jsonb_build_object(
      'shift_code', s.shift_code,
      'finish_kg', round(coalesce(f.kg, 0), 1),
      'finish_hours', round(coalesce(f.hours, 0), 1),
      'finish_kg_per_hour', case when coalesce(f.hours, 0) > 0 then round(coalesce(f.matched_kg, 0) / f.hours, 1) end,
      'finish_efficiency_percent', case when coalesce(f.hours, 0) > 0 then round(coalesce(f.matched_kg, 0) / (f.hours * v_finish_target) * 100, 1) end,
      'finish_days', coalesce(f.days, 0),
      'sorting_kg', round(coalesce(so.clothes_kg, 0) + coalesce(so.mop_kg, 0), 1),
      'sorting_loads', coalesce(so.loads, 0),
      'sorting_hours', round(coalesce(so.hours, 0), 1),
      'sorting_efficiency_percent', case when coalesce(so.hours, 0) > 0 then round(coalesce(so.earned_hours, 0) / so.hours * 100, 1) end,
      'mop_kg', round(coalesce(m.kg, 0), 1),
      'mop_batches', coalesce(m.batches, 0),
      'mop_units', coalesce(m.units, 0)
    ) order by case s.shift_code when 'MORNING' then 1 else 2 end)
    from (values ('MORNING'), ('EVENING')) s(shift_code)
    left join finish_by_shift f on f.shift_code = s.shift_code
    left join sorting_by_shift so on so.shift_code = s.shift_code
    left join mop_by_shift m on m.shift_code = s.shift_code), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
      'shift_code', t.shift_code,
      'table_code', t.table_code,
      'table_name', 'Table ' || replace(t.table_code, 'FINISH_TABLE_', ''),
      'kg', round(t.kg, 1),
      'hours', round(t.hours, 1),
      'kg_per_hour', case when t.hours > 0 then round(coalesce(t.matched_kg, 0) / t.hours, 1) end,
      'efficiency_percent', case when t.hours > 0 then round(coalesce(t.matched_kg, 0) / (t.hours * v_finish_target) * 100, 1) end,
      'production_days', t.days,
      'average_staff', round(coalesce(t.avg_staff, 0), 1)
    ) order by case t.shift_code when 'MORNING' then 1 else 2 end, t.table_code) from finish_by_table t), '[]'::jsonb),
    jsonb_build_object(
      'finish', (select jsonb_build_object(
        'produced_kg', round(coalesce(sum(kg), 0), 1),
        'staff_hours', round(coalesce(sum(hours), 0), 1),
        'kg_per_hour', case when sum(hours) > 0 then round(coalesce(sum(kg) filter (where hours > 0), 0) / sum(hours), 1) end,
        'efficiency_percent', case when sum(hours) > 0 then round(coalesce(sum(kg) filter (where hours > 0), 0) / (sum(hours) * v_finish_target) * 100, 1) end,
        'target_kg_per_hour', v_finish_target)
        from finish_cells where table_code like 'FINISH_TABLE_%'),
      'sorting', (select jsonb_build_object(
        'approximate_kg', round(coalesce(sum(clothes_kg + mop_kg), 0), 1),
        'clothes_kg', round(coalesce(sum(clothes_kg), 0), 1),
        'mop_kg', round(coalesce(sum(mop_kg), 0), 1),
        'loads', coalesce(sum(loads), 0),
        'staff_hours', round(coalesce(sum(hours), 0), 1),
        'efficiency_percent', case when sum(hours) > 0 then round(coalesce(sum(clothes_kg / v_clothes_target + mop_kg / v_mop_target) filter (where hours > 0), 0) / sum(hours) * 100, 1) end,
        'clothes_target_kg_per_hour', v_clothes_target,
        'mop_target_kg_per_hour', v_mop_target)
        from sorting_cells),
      'mop', (select jsonb_build_object(
        'kg', round(coalesce(sum(kg), 0), 1),
        'batches', coalesce(sum(batches), 0),
        'units', coalesce(sum(units), 0))
        from mop_by_shift),
      'trolleys_received', (select count(*) from public.trolley_customer_stays tcs where tcs.received_on between v_from and v_to)
    )
  into v_shifts, v_tables, v_areas;

  -- Customers: KG, production days and average trolleys, against the comparison period.
  with actuals as (
    select a.customer_id, a.product_code, a.actual_date, a.actual_kg, max(a.customer_name) over (partition by a.customer_id) as customer_name,
      case when a.actual_date between v_from and v_to then 'CURRENT' else 'COMPARE' end as period_code
    from public.production_official_actuals a
    where a.actual_date between v_from and v_to or a.actual_date between v_cmp_from and v_cmp_to
  ), trolleys as (
    select e.customer_id, 'CLOTHES'::text as product_code, count(*)::integer as trolleys
    from public.finish_production_entries e
    join public.finish_production_trolleys t on t.finish_production_entry_id = e.finish_production_entry_id
    where e.status = 'ACTIVE' and e.production_business_date between v_from and v_to
    group by 1
    union all
    select b.customer_id, 'MOP', count(distinct (b.mop_production_batch_id, t.trolley_id))::integer
    from public.sorting_mop_production_batches b
    join public.sorting_mop_production_trolleys t on t.mop_production_batch_id = b.mop_production_batch_id
    where b.status = 'RECORDED' and coalesce(b.physical_processed_on, b.business_date) between v_from and v_to
    group by 1
  ), received as (
    select tcs.received_from_customer_id as customer_id, count(*)::integer as trolleys_received
    from public.trolley_customer_stays tcs
    where tcs.received_on between v_from and v_to and tcs.received_from_customer_id is not null
    group by 1
  ), grouped as (
    select customer_id, product_code, max(customer_name) as customer_name,
      sum(actual_kg) filter (where period_code = 'CURRENT') as kg,
      count(distinct actual_date) filter (where period_code = 'CURRENT') as days,
      sum(actual_kg) filter (where period_code = 'COMPARE') as compare_kg,
      count(distinct actual_date) filter (where period_code = 'COMPARE') as compare_days
    from actuals group by 1, 2
  ), total as (
    select nullif(sum(kg), 0) as kg from grouped
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'customer_id', g.customer_id,
    'customer_name', g.customer_name,
    'product_code', g.product_code,
    'kg', round(coalesce(g.kg, 0), 1),
    'production_days', coalesce(g.days, 0),
    'average_kg_per_day', case when g.days > 0 then round(g.kg / g.days, 1) end,
    'share_percent', round(coalesce(g.kg, 0) / (select kg from total) * 100, 1),
    'trolleys', coalesce(t.trolleys, 0),
    'average_trolleys_per_day', case when g.days > 0 then round(coalesce(t.trolleys, 0)::numeric / g.days, 1) end,
    'trolleys_received', case when g.product_code = 'CLOTHES' then coalesce(r.trolleys_received, 0) end,
    'compare_kg', round(coalesce(g.compare_kg, 0), 1),
    'compare_days', coalesce(g.compare_days, 0),
    'change_percent', case when coalesce(g.compare_kg, 0) > 0 then round((coalesce(g.kg, 0) - g.compare_kg) / g.compare_kg * 100, 1) end
  ) order by coalesce(g.kg, 0) desc, g.customer_name), '[]'::jsonb)
  into v_customers
  from grouped g
  left join trolleys t on t.customer_id = g.customer_id and t.product_code = g.product_code
  left join received r on r.customer_id = g.customer_id;

  -- Staff turnover (production staff). Start date is joined_on, or the record creation date
  -- for staff created directly in the system (not imported). Imported staff without a start
  -- date are treated as already employed.
  with people as (
    select sm.staff_id, sm.display_name, sm.deactivated_on, sm.deactivation_reason,
      coalesce(sm.joined_on, case when sm.legacy_user_id is null and not coalesce(sm.import_review_required, false) then sm.created_at::date end) as start_on
    from public.staff_members sm
    where sm.production_staff and sm.deleted_at is null
      and (sm.active or sm.deactivated_on is not null)
  ), months as (
    select m::date as month_start, least((m + interval '1 month - 1 day')::date, v_to) as month_end
    from generate_series(date_trunc('month', v_to) - interval '11 months', date_trunc('month', v_to), interval '1 month') m
  ), monthly as (
    select mo.month_start,
      (select count(*) from people p where (p.start_on is null or p.start_on <= mo.month_end) and (p.deactivated_on is null or p.deactivated_on > mo.month_end)) as headcount_end,
      (select count(*) from people p where (p.start_on is null or p.start_on < mo.month_start) and (p.deactivated_on is null or p.deactivated_on >= mo.month_start)) as headcount_start,
      (select count(*) from people p where p.deactivated_on between mo.month_start and mo.month_end) as leavers,
      (select count(*) from people p where p.start_on between mo.month_start and mo.month_end) as joiners
    from months mo
  ), period as (
    select
      (select count(*) from people p where (p.start_on is null or p.start_on < v_from) and (p.deactivated_on is null or p.deactivated_on >= v_from)) as headcount_start,
      (select count(*) from people p where (p.start_on is null or p.start_on <= v_to) and (p.deactivated_on is null or p.deactivated_on > v_to)) as headcount_end,
      (select count(*) from people p where p.deactivated_on between v_from and v_to) as leavers,
      (select count(*) from people p where p.start_on between v_from and v_to) as joiners,
      (select count(*) from people p where p.deactivated_on between v_cmp_from and v_cmp_to) as compare_leavers
  )
  select jsonb_build_object(
    'headcount_start', p.headcount_start,
    'headcount_end', p.headcount_end,
    'leavers', p.leavers,
    'joiners', p.joiners,
    'compare_leavers', p.compare_leavers,
    'turnover_percent', case when p.headcount_start + p.headcount_end > 0 then round(p.leavers / ((p.headcount_start + p.headcount_end) / 2.0) * 100, 1) else 0 end,
    'joiners_note', 'Start dates are missing for most imported staff, so joiners only count people with a start date.',
    'leavers_list', coalesce((select jsonb_agg(jsonb_build_object('display_name', x.display_name, 'deactivated_on', x.deactivated_on, 'reason', x.deactivation_reason, 'start_on', x.start_on) order by x.deactivated_on desc)
      from people x where x.deactivated_on between v_from and v_to), '[]'::jsonb),
    'monthly', coalesce((select jsonb_agg(jsonb_build_object(
      'month_start', m.month_start, 'headcount_end', m.headcount_end, 'leavers', m.leavers, 'joiners', m.joiners,
      'turnover_percent', case when m.headcount_start + m.headcount_end > 0 then round(m.leavers / ((m.headcount_start + m.headcount_end) / 2.0) * 100, 1) else 0 end
    ) order by m.month_start) from monthly m), '[]'::jsonb)
  ) into v_turnover
  from period p;

  return jsonb_build_object(
    'schema_version', 'PRODUCTION_INTELLIGENCE_MANAGER_V1',
    'period', jsonb_build_object('from', v_from, 'to', v_to, 'granularity', v_granularity),
    'compare_period', jsonb_build_object('from', v_cmp_from, 'to', v_cmp_to),
    'targets', jsonb_build_object('finish_kg_per_staff_hour', v_finish_target, 'sorting_clothes_kg_per_staff_hour', v_clothes_target,
      'sorting_mop_kg_per_staff_hour', v_mop_target, 'finish_units_per_kg', v_units_per_kg),
    'summary', v_summary,
    'compare', v_compare,
    'trend', v_trend,
    'areas', v_areas,
    'shifts', v_shifts,
    'tables', v_tables,
    'customers', v_customers,
    'turnover', v_turnover
  );
end;
$$;

revoke all on function public.get_production_intelligence_manager_view(date, date, text, date, date) from public, anon;
grant execute on function public.get_production_intelligence_manager_view(date, date, text, date, date) to authenticated;

comment on function public.get_production_intelligence_manager_view(date, date, text, date, date) is
  'Permission-guarded manager view: period summary against a comparison period, trend, areas, customers with average trolleys, shift/table/staff performance and staff turnover.';


create or replace function public.get_production_daily_report(
  p_business_date date default null
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
  v_date date;
  v_units_per_kg numeric;
  v_customers jsonb;
  v_unscheduled jsonb;
  v_sorting jsonb;
  v_finish jsonb;
  v_mop jsonb;
  v_raw jsonb;
begin
  if auth.uid() is null or not public.has_account_permission('PRODUCTION_INSIGHTS', 'VIEW', null) then
    raise exception using errcode = '42501', message = 'This account cannot view the Daily Production Report.';
  end if;

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

  select coalesce((select target_value from public.production_targets where target_code = 'FINISH_UNITS_PER_KG' and active limit 1), 6) into v_units_per_kg;
  v_units_per_kg := greatest(v_units_per_kg, 0.001);

  -- Scheduled customers for the day against what was washed and produced.
  -- The schedule version in force on the day: re-published schedules supersede older
  -- versions, so a past day uses the version whose effective range covers it.
  with versions as (
    select distinct on (csv.customer_id) csv.schedule_version_id, csv.customer_id
    from public.customer_schedule_versions csv
    join public.customers c on c.customer_id = csv.customer_id and c.deleted_at is null
      and (c.active or c.deactivated_at::date > v_date)
    where csv.status in ('PUBLISHED', 'SUPERSEDED')
      and (csv.effective_until is null or csv.effective_until >= v_date)
    order by csv.customer_id, (coalesce(csv.effective_from, csv.published_at::date) <= v_date) desc,
      coalesce(csv.effective_from, csv.published_at::date) desc, csv.version_number desc
  ), schedule as (
    select distinct on (v.customer_id, pt.product_code)
      v.customer_id, c.customer_code, c.customer_name, pt.product_code, csd.delivery_weekday, csp.production_order,
      csp.expected_kg, r.route_code, r.display_name as route_name, r.route_color
    from versions v
    join public.customers c on c.customer_id = v.customer_id
    join public.customer_schedule_days csd on csd.schedule_version_id = v.schedule_version_id and csd.active
      and csd.production_weekday = extract(isodow from v_date)::integer
    join public.customer_schedule_products csp on csp.schedule_day_id = csd.schedule_day_id and csp.active
    join public.product_types pt on pt.product_type_id = csp.product_type_id and pt.product_code in ('CLOTHES', 'MOP')
    left join public.distribution_routes r on r.route_id = csd.default_route_id
    order by v.customer_id, pt.product_code, csp.production_order nulls last
  ), washed as (
    select wc.customer_id, case when wr.wash_type = 'MOP' then 'MOP' else 'CLOTHES' end as product_code,
      sum(coalesce(wc.allocated_weight_kg, 0)) as kg, count(distinct wr.wash_run_id) as loads
    from public.sorting_wash_run_customers wc
    join public.sorting_wash_runs wr on wr.wash_run_id = wc.wash_run_id and wr.status = 'RECORDED'
    where wc.scheduled_for_date = v_date or (wc.scheduled_for_date is null and wr.business_date = v_date)
    group by 1, 2
  ), finish as (
    select e.customer_id, 'CLOTHES'::text as product_code,
      sum(case when l.unit_code = 'KG' then l.quantity else 0 end) as kg,
      sum(case when l.unit_code = 'UNIT' then l.quantity else 0 end) as units,
      max(e.production_business_date) as last_production_date,
      count(distinct e.entry_group_id) as entries
    from public.finish_production_entries e
    join public.finish_production_lines l on l.finish_production_entry_id = e.finish_production_entry_id
    left join public.production_flow_items fi on fi.production_flow_item_id = e.production_flow_item_id
    where e.status = 'ACTIVE'
      and (fi.scheduled_for_date = v_date or (fi.scheduled_for_date is null and e.production_business_date = v_date))
    group by 1
  ), finish_trolleys as (
    select e.customer_id, count(*) as trolleys
    from public.finish_production_entries e
    join public.finish_production_trolleys t on t.finish_production_entry_id = e.finish_production_entry_id
    left join public.production_flow_items fi on fi.production_flow_item_id = e.production_flow_item_id
    where e.status = 'ACTIVE'
      and (fi.scheduled_for_date = v_date or (fi.scheduled_for_date is null and e.production_business_date = v_date))
    group by 1
  ), mop as (
    select b.customer_id, 'MOP'::text as product_code, sum(b.total_weight_kg) as kg, sum(coalesce(b.total_units, 0)) as units,
      max(coalesce(b.physical_processed_on, b.business_date)) as last_production_date, count(*) as entries,
      (select count(distinct (t.mop_production_batch_id, t.trolley_id)) from public.sorting_mop_production_trolleys t
        where t.mop_production_batch_id = any(array_agg(b.mop_production_batch_id))) as trolleys
    from public.sorting_mop_production_batches b
    where b.status = 'RECORDED'
      and (b.scheduled_for_date = v_date or (b.scheduled_for_date is null and b.business_date = v_date))
    group by 1
  ), produced as (
    select f.customer_id, f.product_code, f.kg + f.units / v_units_per_kg as kg, f.kg as official_kg, f.units,
      f.last_production_date, f.entries, coalesce(ft.trolleys, 0) as trolleys
    from finish f left join finish_trolleys ft on ft.customer_id = f.customer_id
    union all
    select m.customer_id, m.product_code, m.kg, m.kg, m.units, m.last_production_date, m.entries, m.trolleys from mop m
  ), acknowledged as (
    select fi.customer_id, fi.product_code, max(r.outcome_code) as outcome
    from public.finish_delivery_reconciliations r
    join public.production_flow_items fi on fi.production_flow_item_id = r.production_flow_item_id
    where fi.scheduled_for_date = v_date
    group by 1, 2
    union all
    select fi.customer_id, fi.product_code, max(r.decision)
    from public.sorting_mop_reconciliations r
    join public.production_flow_items fi on fi.production_flow_item_id = r.production_flow_item_id
    where fi.scheduled_for_date = v_date
    group by 1, 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'customer_id', s.customer_id,
    'customer_name', s.customer_name,
    'customer_code', s.customer_code,
    'product_code', s.product_code,
    'production_order', s.production_order,
    'delivery_weekday', s.delivery_weekday,
    'route_code', s.route_code,
    'route_name', s.route_name,
    'route_color', s.route_color,
    'expected_kg', s.expected_kg,
    'washed_kg', round(coalesce(w.kg, 0), 1),
    'washed_loads', coalesce(w.loads, 0),
    'produced_kg', round(coalesce(p.kg, 0), 1),
    'produced_units', coalesce(p.units, 0),
    'trolleys', coalesce(p.trolleys, 0),
    'last_production_date', p.last_production_date,
    'late', coalesce(p.last_production_date > v_date, false),
    'acknowledged_outcome', a.outcome,
    'status', case
      when coalesce(p.kg, 0) > 0 or coalesce(p.units, 0) > 0 then 'PRODUCED'
      when a.outcome is not null then 'ACKNOWLEDGED'
      when coalesce(w.loads, 0) > 0 then 'WASHED_NOT_FINISHED'
      else 'NOT_STARTED' end
  ) order by s.product_code, s.route_code nulls last, s.production_order nulls last, s.customer_name), '[]'::jsonb),
  coalesce((select jsonb_agg(jsonb_build_object(
      'customer_id', p2.customer_id,
      'customer_name', coalesce(c2.customer_name, 'Unknown customer'),
      'product_code', p2.product_code,
      'produced_kg', round(p2.kg, 1),
      'trolleys', p2.trolleys
    ) order by c2.customer_name)
    from produced p2 left join public.customers c2 on c2.customer_id = p2.customer_id
    where not exists (select 1 from schedule s2 where s2.customer_id = p2.customer_id and s2.product_code = p2.product_code)), '[]'::jsonb)
  into v_customers, v_unscheduled
  from schedule s
  left join washed w on w.customer_id = s.customer_id and w.product_code = s.product_code
  left join produced p on p.customer_id = s.customer_id and p.product_code = s.product_code
  left join acknowledged a on a.customer_id = s.customer_id and a.product_code = s.product_code;

  -- Sorting and Finish reuse their Results functions, so the report matches those pages.
  -- Each one keeps its own permission check; a manager without that module sees no data
  -- for that area instead of an error for the whole report.
  begin
    v_raw := public.get_sorting_results_dashboard_v1(v_date);
    v_sorting := jsonb_build_object('access', 'ALLOWED', 'total', v_raw -> 'total', 'shifts', v_raw -> 'shifts', 'targets', v_raw -> 'targets',
      'staff', coalesce((select jsonb_agg(jsonb_build_object('shift_code', x ->> 'shift_code', 'display_name', x ->> 'display_name',
        'attendance_status', x ->> 'attendance_status', 'absence_reason', x ->> 'absence_reason', 'status', x ->> 'status',
        'worked_hours', x -> 'worked_hours', 'produced_kg', x -> 'produced_kg', 'efficiency_percent', x -> 'efficiency_percent'))
        from jsonb_array_elements(coalesce(v_raw -> 'staff', '[]'::jsonb)) x), '[]'::jsonb));
  exception when insufficient_privilege then
    v_sorting := jsonb_build_object('access', 'DENIED');
  end;

  begin
    v_raw := public.get_finish_results_dashboard(v_date);
    v_finish := jsonb_build_object('access', 'ALLOWED', 'total', v_raw -> 'total', 'shifts', v_raw -> 'shifts', 'tables', v_raw -> 'tables',
      'target_kg_per_staff_hour', coalesce(v_raw -> 'target_kg_per_staff_hour', v_raw -> 'targets'));
  exception when insufficient_privilege then
    v_finish := jsonb_build_object('access', 'DENIED');
  end;

  -- MOP production of the day (physical processing date).
  with batches as (
    select b.*, coalesce(b.physical_processed_on, b.business_date) as processed_on
    from public.sorting_mop_production_batches b
    where b.status = 'RECORDED' and coalesce(b.physical_processed_on, b.business_date) = v_date
  )
  select jsonb_build_object(
    'total', jsonb_build_object(
      'kg', round(coalesce(sum(total_weight_kg), 0), 1),
      'units', coalesce(sum(total_units), 0),
      'batches', count(*),
      'customers', count(distinct customer_id),
      'late_entries', count(*) filter (where entry_mode = 'LATE_RECONCILIATION'),
      'trolleys', (select count(distinct (t.mop_production_batch_id, t.trolley_id)) from public.sorting_mop_production_trolleys t
        join batches b2 on b2.mop_production_batch_id = t.mop_production_batch_id)),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('shift_code', x.shift_code, 'kg', x.kg, 'units', x.units, 'batches', x.batches, 'operators', x.operators)
        order by case x.shift_code when 'MORNING' then 1 else 2 end)
      from (select shift_code_snapshot as shift_code, round(sum(total_weight_kg), 1) as kg, sum(coalesce(total_units, 0)) as units,
              count(*) as batches, count(distinct operator_staff_id) as operators
            from batches group by 1) x), '[]'::jsonb)
  ) into v_mop
  from batches;

  return jsonb_build_object(
    'schema_version', 'PRODUCTION_DAILY_REPORT_V1',
    'generated_at', now(),
    'business_date', v_date,
    'weekday', extract(isodow from v_date)::integer,
    'customers', v_customers,
    'unscheduled', v_unscheduled,
    'sorting', v_sorting,
    'finish', v_finish,
    'mop', v_mop
  );
end;
$$;

revoke all on function public.get_production_daily_report(date) from public, anon;
grant execute on function public.get_production_daily_report(date) to authenticated;

comment on function public.get_production_daily_report(date) is
  'Permission-guarded Daily Production Report: scheduled customers against washed and produced, Sorting/Finish results of the day and MOP production. Replaces the Apps Script daily emails.';
