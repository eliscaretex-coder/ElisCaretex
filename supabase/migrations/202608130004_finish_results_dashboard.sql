-- ElisCaretex V2 — Migration 050 — Finish Results dashboard
-- PREPARED. Owner executes in Development.
--
-- Purpose
-- - Reproduce the operational Results concept already used by the current Finish Google Script.
-- - Daily totals + Morning/Evening + Table 1/2/3 x Shift metrics.
-- - Planned KG = governed staff hours x governed Finish target.
-- - Efficiency = Produced KG / Planned KG.
-- - Keep production detail traceable to active Finish revisions, processor and scanner.
-- - No parallel production ledger and no inferred Finish KG.

begin;

create or replace function public.get_finish_results_dashboard(
  p_business_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_date date;
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_target numeric := 23.5;
  v_morning jsonb;
  v_evening jsonb;
  v_tables jsonb := '[]'::jsonb;
  v_shifts jsonb := '[]'::jsonb;
  v_total jsonb := '{}'::jsonb;
  v_entries jsonb := '[]'::jsonb;
begin
  perform public.require_finish_production_access();

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

  if p_business_date is not null then
    v_date := p_business_date;
  else
    v_date := (now() at time zone v_timezone)::date;
    if (now() at time zone v_timezone)::time < v_rollover then
      v_date := v_date - 1;
    end if;
  end if;

  select coalesce(
    (select target_value
     from public.production_targets
     where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR'
       and active=true
     limit 1),
    23.5
  ) into v_target;

  -- Reuse the same governed Planned -> Actual staffing contract already used
  -- by the operational Finish screen. Historical results therefore do not
  -- invent a second interpretation of staff hours.
  v_morning := public.get_finish_staff_context_v2(
    'MORNING',
    public.operational_timestamp_for_shift(v_date,'MORNING',time '12:00')
  );
  v_evening := public.get_finish_staff_context_v2(
    'EVENING',
    public.operational_timestamp_for_shift(v_date,'EVENING',time '18:00')
  );

  with staff_source as (
    select 'MORNING'::text as shift_code, x.value as item
    from jsonb_array_elements(coalesce(v_morning->'staff','[]'::jsonb)) x
    union all
    select 'EVENING'::text as shift_code, x.value as item
    from jsonb_array_elements(coalesce(v_evening->'staff','[]'::jsonb)) x
  ), staff_normalized as (
    select
      nullif(item->>'staff_id','')::uuid as staff_id,
      shift_code,
      nullif(item->>'effective_table_code','') as table_code,
      nullif(item->>'effective_start_time','')::time as start_time,
      nullif(item->>'effective_end_time','')::time as end_time,
      greatest(0,coalesce(nullif(item->>'break_minutes','')::integer,0))
        + greatest(0,coalesce(nullif(item->>'extra_non_work_minutes','')::integer,0)) as non_work_minutes
    from staff_source
    where coalesce(nullif(item->>'actual_in_finish','')::boolean,true)=true
      and nullif(item->>'effective_table_code','') in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
  ), staff_calc as (
    select
      staff_id,
      shift_code,
      table_code,
      greatest(
        0::numeric,
        case
          when start_time is null or end_time is null then 0::numeric
          else (
            extract(epoch from (
              (v_date + end_time + case when end_time < start_time then interval '1 day' else interval '0 day' end)
              - (v_date + start_time)
            )) / 3600.0
          ) - (non_work_minutes / 60.0)
        end
      )::numeric as staff_hours
    from staff_normalized
  ), production_by_cell as (
    select
      e.table_code_snapshot as table_code,
      e.shift_code_snapshot as shift_code,
      coalesce(sum(l.quantity) filter(where l.unit_code='KG'),0)::numeric as produced_kg,
      coalesce(sum(l.quantity) filter(where l.unit_code='UNIT'),0)::numeric as produced_units,
      count(distinct e.entry_group_id)::integer as contribution_count
    from public.finish_production_entries e
    join public.finish_production_lines l
      on l.finish_production_entry_id=e.finish_production_entry_id
    where e.status='ACTIVE'
      and e.production_business_date=v_date
      and e.table_code_snapshot in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
      and e.shift_code_snapshot in ('MORNING','EVENING')
    group by e.table_code_snapshot,e.shift_code_snapshot
  ), staff_by_cell as (
    select
      table_code,
      shift_code,
      coalesce(sum(staff_hours),0)::numeric as staff_hours,
      count(distinct staff_id)::integer as staff_count
    from staff_calc
    group by table_code,shift_code
  ), cells as (
    select
      t.table_code,
      case t.table_code
        when 'FINISH_TABLE_1' then 'Table 1'
        when 'FINISH_TABLE_2' then 'Table 2'
        when 'FINISH_TABLE_3' then 'Table 3'
      end as table_name,
      s.shift_code,
      coalesce(p.produced_kg,0)::numeric as produced_kg,
      coalesce(p.produced_units,0)::numeric as produced_units,
      coalesce(p.contribution_count,0)::integer as contribution_count,
      coalesce(st.staff_hours,0)::numeric as staff_hours,
      coalesce(st.staff_count,0)::integer as staff_count
    from (values ('FINISH_TABLE_1'),('FINISH_TABLE_2'),('FINISH_TABLE_3')) t(table_code)
    cross join (values ('MORNING'),('EVENING')) s(shift_code)
    left join production_by_cell p
      on p.table_code=t.table_code and p.shift_code=s.shift_code
    left join staff_by_cell st
      on st.table_code=t.table_code and st.shift_code=s.shift_code
  ), final_cells as (
    select
      c.*,
      round((c.staff_hours*v_target)::numeric,2) as planned_kg,
      case when c.staff_hours*v_target>0
        then round((c.produced_kg/(c.staff_hours*v_target)*100)::numeric,2)
        else 0::numeric
      end as efficiency_percent,
      case when c.staff_hours>0
        then round((c.produced_kg/c.staff_hours)::numeric,2)
        else 0::numeric
      end as kg_per_staff_hour
    from cells c
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'table_code',table_code,
    'table_name',table_name,
    'shift_code',shift_code,
    'produced_kg',round(produced_kg,2),
    'produced_units',round(produced_units,0),
    'planned_kg',planned_kg,
    'efficiency_percent',efficiency_percent,
    'staff_hours',round(staff_hours,2),
    'staff_count',staff_count,
    'kg_per_staff_hour',kg_per_staff_hour,
    'contribution_count',contribution_count
  ) order by case shift_code when 'MORNING' then 1 else 2 end, table_code),'[]'::jsonb)
  into v_tables
  from final_cells;

  with cell_rows as (
    select x.value as item
    from jsonb_array_elements(v_tables) x
  ), shifts as (
    select
      item->>'shift_code' as shift_code,
      sum((item->>'produced_kg')::numeric) as produced_kg,
      sum((item->>'produced_units')::numeric) as produced_units,
      sum((item->>'planned_kg')::numeric) as planned_kg,
      sum((item->>'staff_hours')::numeric) as staff_hours,
      sum((item->>'contribution_count')::integer) as contribution_count
    from cell_rows
    group by item->>'shift_code'
  ), shift_staff as (
    select shift_code,count(distinct staff_id)::integer as staff_count
    from (
      select 'MORNING'::text shift_code,nullif(x.value->>'staff_id','')::uuid staff_id
      from jsonb_array_elements(coalesce(v_morning->'staff','[]'::jsonb)) x
      where coalesce(nullif(x.value->>'actual_in_finish','')::boolean,true)=true
        and nullif(x.value->>'effective_table_code','') in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
      union all
      select 'EVENING'::text shift_code,nullif(x.value->>'staff_id','')::uuid staff_id
      from jsonb_array_elements(coalesce(v_evening->'staff','[]'::jsonb)) x
      where coalesce(nullif(x.value->>'actual_in_finish','')::boolean,true)=true
        and nullif(x.value->>'effective_table_code','') in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
    ) q
    group by shift_code
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'shift_code',s.shift_code,
    'produced_kg',round(s.produced_kg,2),
    'produced_units',round(s.produced_units,0),
    'planned_kg',round(s.planned_kg,2),
    'missing_kg',round(greatest(s.planned_kg-s.produced_kg,0),2),
    'efficiency_percent',case when s.planned_kg>0 then round((s.produced_kg/s.planned_kg*100)::numeric,2) else 0 end,
    'staff_hours',round(s.staff_hours,2),
    'staff_count',coalesce(ss.staff_count,0),
    'contribution_count',s.contribution_count
  ) order by case s.shift_code when 'MORNING' then 1 else 2 end),'[]'::jsonb)
  into v_shifts
  from shifts s
  left join shift_staff ss on ss.shift_code=s.shift_code;

  with totals as (
    select
      coalesce(sum((x.value->>'produced_kg')::numeric),0) as produced_kg,
      coalesce(sum((x.value->>'produced_units')::numeric),0) as produced_units,
      coalesce(sum((x.value->>'planned_kg')::numeric),0) as planned_kg,
      coalesce(sum((x.value->>'staff_hours')::numeric),0) as staff_hours,
      coalesce(sum((x.value->>'contribution_count')::integer),0) as contribution_count
    from jsonb_array_elements(v_tables) x
  ), all_staff as (
    select count(distinct staff_id)::integer as staff_count
    from (
      select nullif(x.value->>'staff_id','')::uuid staff_id
      from jsonb_array_elements(coalesce(v_morning->'staff','[]'::jsonb)) x
      where coalesce(nullif(x.value->>'actual_in_finish','')::boolean,true)=true
        and nullif(x.value->>'effective_table_code','') in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
      union all
      select nullif(x.value->>'staff_id','')::uuid staff_id
      from jsonb_array_elements(coalesce(v_evening->'staff','[]'::jsonb)) x
      where coalesce(nullif(x.value->>'actual_in_finish','')::boolean,true)=true
        and nullif(x.value->>'effective_table_code','') in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
    ) q
  )
  select jsonb_build_object(
    'produced_kg',round(t.produced_kg,2),
    'produced_units',round(t.produced_units,0),
    'planned_kg',round(t.planned_kg,2),
    'missing_kg',round(greatest(t.planned_kg-t.produced_kg,0),2),
    'efficiency_percent',case when t.planned_kg>0 then round((t.produced_kg/t.planned_kg*100)::numeric,2) else 0 end,
    'staff_hours',round(t.staff_hours,2),
    'staff_count',coalesce(a.staff_count,0),
    'contribution_count',t.contribution_count
  )
  into v_total
  from totals t cross join all_staff a;

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
      coalesce(nullif(e.processed_by_name_snapshot,''),ps.display_name,'Not recorded') as processed_by,
      e.recorded_by_staff_id,
      coalesce(rs.display_name,'—') as recorded_by,
      e.trolley_scan_status,
      pfi.customer_name_snapshot as customer_name,
      pfi.customer_code_snapshot as customer_code,
      pfi.route_code_snapshot as route_code,
      pfi.route_display_name_snapshot as route_name,
      pfi.route_color_snapshot as route_color,
      pfi.production_order_snapshot as production_order
    from public.finish_production_entries e
    join public.production_flow_items pfi on pfi.production_flow_item_id=e.production_flow_item_id
    left join public.staff_members ps on ps.staff_id=e.processed_by_staff_id
    left join public.staff_members rs on rs.staff_id=e.recorded_by_staff_id
    where e.status='ACTIVE'
      and e.production_business_date=v_date
  ), detail as (
    select
      a.*,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'line_no',l.line_no,
          'batch_reference',l.batch_reference,
          'unit_code',l.unit_code,
          'quantity',l.quantity
        ) order by l.line_no)
        from public.finish_production_lines l
        where l.finish_production_entry_id=a.finish_production_entry_id
      ),'[]'::jsonb) as lines,
      coalesce((
        select jsonb_agg(t.trolley_code_snapshot order by t.trolley_code_snapshot)
        from public.finish_production_trolleys t
        where t.finish_production_entry_id=a.finish_production_entry_id
      ),'[]'::jsonb) as trolley_codes
    from active_entries a
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'finish_production_entry_id',d.finish_production_entry_id,
    'entry_group_id',d.entry_group_id,
    'revision_no',d.revision_no,
    'production_flow_item_id',d.production_flow_item_id,
    'customer_id',d.customer_id,
    'customer_name',d.customer_name,
    'customer_code',d.customer_code,
    'route_code',d.route_code,
    'route_name',d.route_name,
    'route_color',d.route_color,
    'production_order',d.production_order,
    'business_date',d.production_business_date,
    'shift_code',d.shift_code_snapshot,
    'table_code',d.table_code_snapshot,
    'table_name',d.table_name_snapshot,
    'recorded_at',d.recorded_at,
    'processed_by_staff_id',d.processed_by_staff_id,
    'processed_by',d.processed_by,
    'recorded_by_staff_id',d.recorded_by_staff_id,
    'recorded_by',d.recorded_by,
    'trolley_scan_status',d.trolley_scan_status,
    'trolley_codes',d.trolley_codes,
    'lines',d.lines,
    'processed_kg',coalesce((select sum((x.value->>'quantity')::numeric) from jsonb_array_elements(d.lines) x where x.value->>'unit_code'='KG'),0),
    'processed_units',coalesce((select sum((x.value->>'quantity')::numeric) from jsonb_array_elements(d.lines) x where x.value->>'unit_code'='UNIT'),0)
  ) order by coalesce(d.production_order,2147483647),d.route_code,d.recorded_at),'[]'::jsonb)
  into v_entries
  from detail d;

  return jsonb_build_object(
    'schema_version','FINISH_RESULTS_V1',
    'source_contract','FINISH_ACTIVE_REVISIONS_PLUS_ROSTER_ACTUAL_STAFF',
    'generated_at',now(),
    'business_date',v_date,
    'target_kg_per_staff_hour',v_target,
    'total',v_total,
    'shifts',v_shifts,
    'tables',v_tables,
    'entries',v_entries,
    'rewash_separate_metric_supported',false,
    'notes','Results use active Finish revisions and the same Planned-to-Actual staff-hours contract as Finish Production.'
  );
end;
$$;

revoke all on function public.get_finish_results_dashboard(date) from public,anon;
grant execute on function public.get_finish_results_dashboard(date) to authenticated;

comment on function public.get_finish_results_dashboard(date) is
'Finish daily Results dashboard based on active Finish revisions and governed Roster/Actual staff hours. Mirrors the operational Google Script Results concepts without a parallel production ledger.';

commit;
