-- Operational breakdown for Production Intelligence.
-- Uses the canonical Finish/MOP actual ledger introduced by migration 202609260001.

create or replace function public.get_production_intelligence_breakdown(
  p_from_date date,
  p_to_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_from date:=coalesce(p_from_date,date_trunc('month',current_date)::date);
  v_to date:=coalesce(p_to_date,current_date);
  v_target numeric;
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null) then
    raise exception using errcode='42501',message='This account cannot view Production Intelligence.';
  end if;
  if v_from>v_to or v_to-v_from>731 then
    raise exception using errcode='22023',message='Choose a valid breakdown range of no more than two years.';
  end if;

  select coalesce((select target_value from public.production_targets
    where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR' and active limit 1),23.5)
  into v_target;

  with actuals as (
    select * from public.production_official_actuals
    where actual_date between v_from and v_to
  ), attendance as (
    select ws.work_date actual_date,coalesce(sh.shift_code,'UNASSIGNED') shift_code,
           coalesce(st.station_code,'UNASSIGNED') workstation_code,
           sum(greatest(0,extract(epoch from (ws.actual_end_at-ws.actual_start_at))/3600.0
             -coalesce(ws.break_minutes,0)/60.0-coalesce(ws.extra_non_work_minutes,0)/60.0))::numeric staff_hours,
           count(distinct ws.staff_id)::integer staff_count
    from public.work_sessions ws
    join public.areas ar on ar.area_id=ws.area_id and ar.area_code='FINISH'
    left join public.shifts sh on sh.shift_id=ws.shift_id
    left join public.stations st on st.station_id=ws.station_id
    where ws.work_date between v_from and v_to
      and ws.actual_start_at is not null and ws.actual_end_at is not null
      and ws.status not in ('CANCELLED','VOID')
    group by ws.work_date,coalesce(sh.shift_code,'UNASSIGNED'),coalesce(st.station_code,'UNASSIGNED')
  ), daily_actual as (
    select actual_date,
      sum(actual_kg)::numeric total_kg,
      sum(actual_kg) filter(where production_source='FINISH')::numeric finish_kg,
      sum(actual_kg) filter(where production_source='MOP')::numeric mop_kg,
      count(distinct customer_id)::integer customers
    from actuals group by actual_date
  ), daily_attendance as (
    select actual_date,sum(staff_hours)::numeric staff_hours,count(distinct (shift_code,workstation_code)) filter(where staff_hours>0)::integer staffed_cells
    from attendance group by actual_date
  ), by_shift as (
    select production_source,coalesce(shift_code,'UNASSIGNED') shift_code,
      sum(actual_kg)::numeric actual_kg,count(distinct actual_date)::integer production_days,
      count(distinct customer_id)::integer customers
    from actuals group by production_source,coalesce(shift_code,'UNASSIGNED')
  ), by_workstation as (
    select production_source,coalesce(workstation_code,'UNASSIGNED') workstation_code,
      sum(actual_kg)::numeric actual_kg,count(distinct actual_date)::integer production_days,
      count(distinct customer_id)::integer customers
    from actuals group by production_source,coalesce(workstation_code,'UNASSIGNED')
  )
  select jsonb_build_object(
    'period',jsonb_build_object('from',v_from,'to',v_to),
    'finish_target_kg_per_staff_hour',v_target,
    'daily',coalesce((select jsonb_agg(jsonb_build_object(
      'date',d.actual_date,'total_kg',round(d.total_kg,2),'finish_kg',round(coalesce(d.finish_kg,0),2),
      'mop_kg',round(coalesce(d.mop_kg,0),2),'customers',d.customers,
      'finish_staff_hours',round(coalesce(a.staff_hours,0),2),
      'finish_capacity_kg',case when coalesce(a.staff_hours,0)>0 then round(a.staff_hours*v_target,2) end,
      'finish_efficiency_percent',case when coalesce(a.staff_hours,0)>0 then round(coalesce(d.finish_kg,0)/(a.staff_hours*v_target)*100,1) end,
      'capacity_status',case when coalesce(a.staff_hours,0)>0 then 'RECORDED' else 'NOT_RECORDED' end
    ) order by d.actual_date desc) from daily_actual d left join daily_attendance a on a.actual_date=d.actual_date),'[]'::jsonb),
    'shifts',coalesce((select jsonb_agg(jsonb_build_object(
      'source',production_source,'shift_code',shift_code,'actual_kg',round(actual_kg,2),
      'production_days',production_days,'customers',customers
    ) order by production_source,case shift_code when 'MORNING' then 1 when 'EVENING' then 2 else 3 end) from by_shift),'[]'::jsonb),
    'workstations',coalesce((select jsonb_agg(jsonb_build_object(
      'source',production_source,'workstation_code',workstation_code,'actual_kg',round(actual_kg,2),
      'production_days',production_days,'customers',customers
    ) order by production_source,workstation_code) from by_workstation),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_production_intelligence_breakdown(date,date) from public,anon;
grant execute on function public.get_production_intelligence_breakdown(date,date) to authenticated;

comment on function public.get_production_intelligence_breakdown(date,date) is
  'Permission-guarded official production breakdown by day, shift and workstation, with recorded Finish attendance capacity only.';
