-- Forward demand versus published Finish roster capacity.
-- Customer schedule defines who is expected; official Finish/MOP history supplies learned KG.

create or replace function public.get_production_intelligence_forward_capacity(
  p_week_start date default null,
  p_weeks integer default 6
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_start date:=coalesce(p_week_start,(date_trunc('week',current_date)+interval '7 days')::date);
  v_weeks integer:=least(greatest(coalesce(p_weeks,6),1),12);
  v_end date;
  v_target numeric;
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null) then
    raise exception using errcode='42501',message='This account cannot view Production Intelligence.';
  end if;
  if extract(isodow from v_start)<>1 then
    raise exception using errcode='22023',message='Forward capacity must start on a Monday.';
  end if;
  v_end:=v_start+(v_weeks*7-1);
  select coalesce((select target_value from public.production_targets where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR' and active limit 1),23.5) into v_target;

  with dates as (
    select d::date work_date from generate_series(v_start,v_end,interval '1 day') d where extract(isodow from d)<7
  ), schedule as (
    select d.work_date,csv.customer_id,c.customer_code,c.customer_name,pt.product_code
    from dates d
    join public.customer_schedule_versions csv on csv.status='PUBLISHED' and csv.effective_from<=d.work_date
      and (csv.effective_until is null or csv.effective_until>=d.work_date)
    join public.customers c on c.customer_id=csv.customer_id and c.active and c.deleted_at is null
    join public.customer_schedule_days csd on csd.schedule_version_id=csv.schedule_version_id and csd.active
      and csd.production_weekday=extract(isodow from d.work_date)::integer
    join public.customer_schedule_products csp on csp.schedule_day_id=csd.schedule_day_id and csp.active
    join public.product_types pt on pt.product_type_id=csp.product_type_id and pt.active and pt.product_code in ('CLOTHES','MOP')
  ), history_daily as (
    select actual_date,customer_id,product_code,sum(actual_kg)::numeric actual_kg
    from public.production_official_actuals
    where actual_date>=v_start-interval '84 days' and actual_date<v_start
    group by actual_date,customer_id,product_code
  ), ranked as (
    select h.*,row_number() over(partition by customer_id,product_code order by actual_date desc) recency_rank
    from history_daily h
  ), model as (
    select customer_id,product_code,count(*) filter(where recency_rank<=8)::integer history_points,
      case when count(*) filter(where recency_rank<=8)>=3 then
        round(sum(actual_kg*(9-recency_rank)) filter(where recency_rank<=8)
          /nullif(sum(9-recency_rank) filter(where recency_rank<=8),0),2)
      end forecast_kg
    from ranked where recency_rank<=8 group by customer_id,product_code
  ), demand_detail as (
    select s.*,m.history_points,m.forecast_kg
    from schedule s left join model m on m.customer_id=s.customer_id and m.product_code=s.product_code
  ), demand_by_day as (
    select work_date,count(*)::integer scheduled_services,
      count(*) filter(where forecast_kg is not null)::integer learned_services,
      coalesce(sum(forecast_kg),0)::numeric forecast_kg,
      coalesce(sum(forecast_kg) filter(where product_code='CLOTHES'),0)::numeric finish_forecast_kg,
      coalesce(sum(forecast_kg) filter(where product_code='MOP'),0)::numeric mop_forecast_kg,
      count(*) filter(where forecast_kg is null)::integer learning_services,
      count(*) filter(where forecast_kg is null and product_code='CLOTHES')::integer finish_learning_services
    from demand_detail group by work_date
  ), capacity_by_day as (
    select pre.work_date,count(distinct pre.staff_id)::integer finish_staff,
      sum(pwp.net_minutes/60.0)::numeric finish_staff_hours,
      sum(pwp.net_minutes/60.0*v_target)::numeric finish_capacity_kg
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id and prv.status='PUBLISHED'
    join public.production_roster_work_profiles pwp on pwp.active and pwp.shift_code=pre.shift_code_snapshot
      and extract(isodow from pre.work_date)::integer=any(pwp.iso_days)
    where pre.work_date between v_start and v_end and pre.day_status='WORKING' and pre.area_code_snapshot='FINISH'
    group by pre.work_date
  ), day_rows as (
    select d.work_date,date_trunc('week',d.work_date)::date week_start,
      coalesce(db.scheduled_services,0)::integer scheduled_services,coalesce(db.learned_services,0)::integer learned_services,
      coalesce(db.learning_services,0)::integer learning_services,round(coalesce(db.forecast_kg,0),2) forecast_kg,
      coalesce(db.finish_learning_services,0)::integer finish_learning_services,
      round(coalesce(db.finish_forecast_kg,0),2) finish_forecast_kg,round(coalesce(db.mop_forecast_kg,0),2) mop_forecast_kg,
      coalesce(cb.finish_staff,0)::integer finish_staff,round(coalesce(cb.finish_staff_hours,0),2) finish_staff_hours,
      case when cb.finish_capacity_kg is not null then round(cb.finish_capacity_kg,2) end finish_capacity_kg,
      case when coalesce(db.finish_learning_services,0)>0 then 'LEARNING'
           when cb.finish_capacity_kg is null then 'ROSTER_NOT_PUBLISHED'
           when coalesce(db.finish_forecast_kg,0)>cb.finish_capacity_kg then 'AT_RISK'
           when coalesce(db.finish_forecast_kg,0)>=cb.finish_capacity_kg*.85 then 'WATCH'
           else 'COVERED' end capacity_status
    from dates d left join demand_by_day db using(work_date) left join capacity_by_day cb using(work_date)
  ), week_rows as (
    select week_start,sum(forecast_kg)::numeric forecast_kg,sum(finish_forecast_kg)::numeric finish_forecast_kg,
      sum(mop_forecast_kg)::numeric mop_forecast_kg,
      case when count(finish_capacity_kg)>0 then sum(coalesce(finish_capacity_kg,0))::numeric end finish_capacity_kg,
      sum(scheduled_services)::integer scheduled_services,sum(learning_services)::integer learning_services,
      sum(finish_learning_services)::integer finish_learning_services,
      count(*) filter(where capacity_status='AT_RISK')::integer risk_days,
      count(*) filter(where capacity_status='ROSTER_NOT_PUBLISHED')::integer unpublished_days
    from day_rows group by week_start
  )
  select jsonb_build_object(
    'period',jsonb_build_object('from',v_start,'to',v_end,'weeks',v_weeks),
    'target_kg_per_staff_hour',v_target,
    'policy',jsonb_build_object('minimum_history_records',3,
      'message','Demand uses learned official Finish/MOP history. Days with incomplete history remain Learning and are not treated as complete demand.'),
    'days',coalesce((select jsonb_agg(to_jsonb(r) order by work_date) from day_rows r),'[]'::jsonb),
    'weeks',coalesce((select jsonb_agg(to_jsonb(w) order by week_start) from week_rows w),'[]'::jsonb),
    'learning_customers',coalesce((select jsonb_agg(to_jsonb(l) order by customer_name,product_code) from (
      select customer_id,customer_code,customer_name,product_code,coalesce(max(history_points),0)::integer history_points,
        min(work_date) next_scheduled_date,count(distinct work_date)::integer scheduled_days
      from demand_detail where forecast_kg is null
      group by customer_id,customer_code,customer_name,product_code
    ) l),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_production_intelligence_forward_capacity(date,integer) from public,anon;
grant execute on function public.get_production_intelligence_forward_capacity(date,integer) to authenticated;

comment on function public.get_production_intelligence_forward_capacity(date,integer) is
  'Six-to-twelve week demand learning versus published Finish roster capacity, guarded by Production Intelligence permission.';
