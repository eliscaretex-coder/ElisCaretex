-- ElisCaretex V2 - Finish Results: trolley quantity/size errors by staff, Table and Shift.
--
-- Finish already stores the outcome of the trolley check on every save in
-- finish_production_entries.trolley_scan_status ('MISMATCH' when the operator chose
-- "Use with mismatch"). This migration adds one read-only RPC that counts those errors
-- for a date range. No table, column or existing function changes.
--
-- Counting rules (one row per customer contribution = entry_group_id):
--   checked      the contribution had a trolley check (MATCHED or MISMATCH in any revision)
--   error        any revision was saved as MISMATCH and the Finish team did not report the
--                published plan as wrong (report PENDING or RESOLVED). A REJECTED report
--                counts as an error again.
--   plan_reported MISMATCH contribution with a PENDING/RESOLVED trolley plan report
--   still_wrong  the current (ACTIVE) revision is still MISMATCH
--   fixed_later  had a MISMATCH revision but the current revision is no longer MISMATCH
-- The error is attributed to the "Processed by" person of the first MISMATCH revision.

create or replace function public.get_finish_trolley_errors_v1(
  p_date_from date default null,
  p_date_to date default null
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
  v_today date;
  v_from date;
  v_to date;
  v_rows jsonb;
begin
  perform public.require_finish_production_access();

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

  v_to := coalesce(p_date_to, p_date_from, v_today);
  v_from := coalesce(p_date_from, v_to);
  if v_from > v_to then
    raise exception using errcode = '22023', message = 'The start date must be on or before the end date.';
  end if;
  if v_to - v_from > 92 then
    raise exception using errcode = '22023', message = 'Choose a period of 93 days or fewer.';
  end if;

  with grp as (
    select e.entry_group_id,
      bool_or(e.trolley_scan_status = 'MISMATCH') as had_mismatch,
      bool_or(e.trolley_scan_status in ('MATCHED','MISMATCH')) as checked
    from public.finish_production_entries e
    where e.production_business_date between v_from and v_to
      and e.status in ('ACTIVE','SUPERSEDED')
    group by e.entry_group_id
    having bool_or(e.status = 'ACTIVE')
  ), first_mismatch as (
    select distinct on (e.entry_group_id)
      e.entry_group_id, e.finish_production_entry_id, e.processed_by_staff_id,
      e.processed_by_name_snapshot, e.recorded_at, e.revision_no
    from public.finish_production_entries e
    join grp g on g.entry_group_id = e.entry_group_id and g.had_mismatch
    where e.trolley_scan_status = 'MISMATCH'
    order by e.entry_group_id, e.revision_no
  ), base as (
    select a.entry_group_id, a.finish_production_entry_id, a.production_flow_item_id,
      a.production_business_date, a.shift_code_snapshot, a.table_code_snapshot, a.table_name_snapshot,
      a.recorded_at, a.revision_no, a.trolley_scan_status,
      g.had_mismatch,
      fm.finish_production_entry_id as mismatch_entry_id,
      fm.recorded_at as mismatch_recorded_at,
      coalesce(fm.processed_by_staff_id, a.processed_by_staff_id) as staff_id,
      coalesce(fm.processed_by_name_snapshot, a.processed_by_name_snapshot, 'Not recorded') as staff_name,
      exists (
        select 1 from public.operational_data_reports r
        where r.production_flow_item_id = a.production_flow_item_id
          and r.report_type = 'CUSTOMER_TROLLEY_REQUIREMENT'
          and r.source_area_code = 'FINISH'
          and r.status in ('PENDING','RESOLVED')
      ) as plan_reported
    from public.finish_production_entries a
    join grp g on g.entry_group_id = a.entry_group_id and g.checked
    left join first_mismatch fm on fm.entry_group_id = a.entry_group_id
    where a.status = 'ACTIVE'
  ), rows as (
    select b.*,
      (b.had_mismatch and not b.plan_reported) as is_error,
      (b.had_mismatch and b.plan_reported) as is_plan_reported,
      (b.trolley_scan_status = 'MISMATCH') as still_wrong
    from base b
  )
  select jsonb_build_object(
    'total', (
      select jsonb_build_object(
        'checked_count', count(*),
        'error_count', count(*) filter (where is_error),
        'still_wrong_count', count(*) filter (where is_error and still_wrong),
        'fixed_later_count', count(*) filter (where is_error and not still_wrong),
        'plan_reported_count', count(*) filter (where is_plan_reported),
        'error_percent', case when count(*) > 0 then round(100.0 * count(*) filter (where is_error) / count(*), 1) else 0 end
      ) from rows
    ),
    'by_staff', coalesce((
      select jsonb_agg(x order by (x->>'error_count')::int desc, (x->>'error_percent')::numeric desc, x->>'display_name')
      from (
        select jsonb_build_object(
          'staff_id', staff_id,
          'display_name', max(staff_name),
          'checked_count', count(*),
          'error_count', count(*) filter (where is_error),
          'still_wrong_count', count(*) filter (where is_error and still_wrong),
          'plan_reported_count', count(*) filter (where is_plan_reported),
          'error_percent', round(100.0 * count(*) filter (where is_error) / count(*), 1)
        ) x
        from rows group by staff_id
      ) s
    ), '[]'::jsonb),
    'by_table', coalesce((
      select jsonb_agg(x order by x->>'table_code')
      from (
        select jsonb_build_object(
          'table_code', table_code_snapshot,
          'table_name', max(table_name_snapshot),
          'checked_count', count(*),
          'error_count', count(*) filter (where is_error),
          'still_wrong_count', count(*) filter (where is_error and still_wrong),
          'plan_reported_count', count(*) filter (where is_plan_reported),
          'error_percent', round(100.0 * count(*) filter (where is_error) / count(*), 1)
        ) x
        from rows group by table_code_snapshot
      ) s
    ), '[]'::jsonb),
    'by_shift', coalesce((
      select jsonb_agg(x order by case x->>'shift_code' when 'MORNING' then 0 else 1 end)
      from (
        select jsonb_build_object(
          'shift_code', shift_code_snapshot,
          'checked_count', count(*),
          'error_count', count(*) filter (where is_error),
          'still_wrong_count', count(*) filter (where is_error and still_wrong),
          'plan_reported_count', count(*) filter (where is_plan_reported),
          'error_percent', round(100.0 * count(*) filter (where is_error) / count(*), 1)
        ) x
        from rows group by shift_code_snapshot
      ) s
    ), '[]'::jsonb),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entry_group_id', r.entry_group_id,
        'finish_production_entry_id', r.finish_production_entry_id,
        'business_date', r.production_business_date,
        'shift_code', r.shift_code_snapshot,
        'table_code', r.table_code_snapshot,
        'table_name', r.table_name_snapshot,
        'customer_name', pfi.customer_name_snapshot,
        'route_code', pfi.route_code_snapshot,
        'route_color', pfi.route_color_snapshot,
        'processed_by_staff_id', r.staff_id,
        'processed_by', r.staff_name,
        'recorded_at', r.mismatch_recorded_at,
        'still_wrong', r.still_wrong,
        'plan_reported', r.is_plan_reported,
        'planned_summary', coalesce((
          select string_agg(q.quantity || '× ' || coalesce(tt.display_code, tt.trolley_type_code), ' + ' order by tt.sort_order, tt.trolley_type_code)
          from public.customer_schedule_trolley_requirements q
          join public.trolley_types tt on tt.trolley_type_id = q.trolley_type_id
          where q.active = true and q.owner_schedule_product_id = pfi.source_schedule_product_id and q.quantity > 0
        ), 'No trolley'),
        'scanned_summary', coalesce((
          select string_agg(c.n || '× ' || c.code, ' + ' order by c.code)
          from (
            select coalesce(tt.display_code, tt.trolley_type_code, '?') as code, count(*) as n
            from public.finish_production_trolleys ft
            left join public.trolleys t on t.trolley_id = ft.trolley_id
            left join public.trolley_types tt on tt.trolley_type_id = t.trolley_type_id
            where ft.finish_production_entry_id = r.mismatch_entry_id
            group by 1
          ) c
        ), 'None'),
        'scanned_codes', coalesce((
          select jsonb_agg(ft.trolley_code_snapshot order by ft.trolley_code_snapshot)
          from public.finish_production_trolleys ft
          where ft.finish_production_entry_id = r.mismatch_entry_id
        ), '[]'::jsonb)
      ) order by r.production_business_date desc, r.mismatch_recorded_at desc)
      from rows r
      join public.production_flow_items pfi on pfi.production_flow_item_id = r.production_flow_item_id
      where r.had_mismatch
    ), '[]'::jsonb)
  ) into v_rows;

  return jsonb_build_object(
    'schema_version', 'FINISH_TROLLEY_ERRORS_V1',
    'date_from', v_from,
    'date_to', v_to
  ) || v_rows;
end;
$$;

revoke all on function public.get_finish_trolley_errors_v1(date, date) from public, anon;
grant execute on function public.get_finish_trolley_errors_v1(date, date) to authenticated;

comment on function public.get_finish_trolley_errors_v1(date, date) is
  'Finish Results: trolley quantity/size mismatches saved in Finish, counted by Processed by staff, Table and Shift for a date range. Read-only.';
