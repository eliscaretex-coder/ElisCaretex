-- Customer KG history and weekday-specific automatic planning suggestions.
-- Only official Finish and MOP production is used; Sorting estimates are excluded.

create or replace function public.get_customer_kg_history(
  p_customer_id uuid,
  p_from_date date default null,
  p_to_date date default null,
  p_recent_limit integer default 3
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_from date:=coalesce(p_from_date,current_date-interval '18 months');
  v_to date:=coalesce(p_to_date,current_date);
  v_limit integer:=least(greatest(coalesce(p_recent_limit,3),1),12);
  v_result jsonb;
begin
  if auth.uid() is null or not (
    public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null)
    or public.has_any_role(array['ADMIN','MANAGER','PLANNER'])
  ) then
    raise exception using errcode='42501',message='This account cannot view customer KG history.';
  end if;
  if p_customer_id is null then
    raise exception using errcode='22023',message='Choose a customer.';
  end if;
  if v_from>v_to or v_to-v_from>1827 then
    raise exception using errcode='22023',message='Choose a valid date range of no more than five years.';
  end if;
  if not exists(select 1 from public.customers c where c.customer_id=p_customer_id and c.deleted_at is null) then
    raise exception using errcode='P0002',message='Customer not found.';
  end if;

  with daily as (
    select a.actual_date,a.customer_id,max(a.customer_code) customer_code,max(a.customer_name) customer_name,
      a.product_code,extract(isodow from a.actual_date)::integer production_weekday,
      round(sum(a.actual_kg),2) actual_kg,
      string_agg(distinct a.production_source,', ' order by a.production_source) production_source
    from public.production_official_actuals a
    where a.customer_id=p_customer_id and a.actual_date between v_from and v_to
    group by a.actual_date,a.customer_id,a.product_code
  ), ranked as (
    select d.*,row_number() over(
      partition by d.customer_id,d.product_code,d.production_weekday order by d.actual_date desc
    ) recency_rank
    from daily d
  ), suggestions as (
    select customer_id,max(customer_code) customer_code,max(customer_name) customer_name,product_code,production_weekday,
      count(*) filter(where recency_rank<=v_limit)::integer history_points,
      round(avg(actual_kg) filter(where recency_rank<=v_limit),2) suggested_kg,
      round(min(actual_kg) filter(where recency_rank<=v_limit),2) minimum_kg,
      round(max(actual_kg) filter(where recency_rank<=v_limit),2) maximum_kg,
      max(actual_date) last_actual_date,
      (array_agg(actual_kg order by actual_date desc))[1] last_actual_kg,
      coalesce(jsonb_agg(jsonb_build_object(
        'actual_date',actual_date,'actual_kg',actual_kg,'production_source',production_source
      ) order by actual_date desc) filter(where recency_rank<=v_limit),'[]'::jsonb) recent_records
    from ranked
    group by customer_id,product_code,production_weekday
  )
  select jsonb_build_object(
    'customer',coalesce((select jsonb_build_object(
      'customer_id',customer_id,'customer_code',customer_code,'customer_name',customer_name
    ) from daily limit 1),(select jsonb_build_object(
      'customer_id',c.customer_id,'customer_code',c.customer_code,'customer_name',c.customer_name
    ) from public.customers c where c.customer_id=p_customer_id)),
    'period',jsonb_build_object('from',v_from,'to',v_to),
    'policy',jsonb_build_object(
      'recent_records',v_limit,'minimum_records',3,'method','SAME_WEEKDAY_AVERAGE',
      'official_sources',jsonb_build_array('FINISH','MOP'),
      'message','Suggested KG is the average of the latest three official records for the same customer, product and weekday.'
    ),
    'suggestions',coalesce((select jsonb_agg(jsonb_build_object(
      'product_code',s.product_code,'production_weekday',s.production_weekday,
      'history_points',s.history_points,
      'suggested_kg',case when s.history_points>=3 then s.suggested_kg end,
      'observed_average_kg',s.suggested_kg,'minimum_kg',s.minimum_kg,'maximum_kg',s.maximum_kg,
      'last_actual_date',s.last_actual_date,'last_actual_kg',s.last_actual_kg,
      'recent_records',s.recent_records,
      'status',case when s.history_points>=3 then 'READY' else 'LEARNING' end
    ) order by s.production_weekday,s.product_code) from suggestions s),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(jsonb_build_object(
      'actual_date',d.actual_date,'production_weekday',d.production_weekday,'product_code',d.product_code,
      'actual_kg',d.actual_kg,'production_source',d.production_source
    ) order by d.actual_date desc,d.product_code) from daily d),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_customer_kg_history(uuid,date,date,integer) from public,anon;
grant execute on function public.get_customer_kg_history(uuid,date,date,integer) to authenticated;

comment on function public.get_customer_kg_history(uuid,date,date,integer) is
  'Official customer KG history plus same-weekday average suggestions. Finish/MOP only; never Sorting estimates.';

-- Make forward capacity use the same customer/product/weekday model shown in Customer Master.
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
    select d.work_date,csv.customer_id,c.customer_code,c.customer_name,pt.product_code,
      extract(isodow from d.work_date)::integer production_weekday
    from dates d
    join public.customer_schedule_versions csv on csv.status='PUBLISHED' and csv.effective_from<=d.work_date
      and (csv.effective_until is null or csv.effective_until>=d.work_date)
    join public.customers c on c.customer_id=csv.customer_id and c.active and c.deleted_at is null
    join public.customer_schedule_days csd on csd.schedule_version_id=csv.schedule_version_id and csd.active
      and csd.production_weekday=extract(isodow from d.work_date)::integer
    join public.customer_schedule_products csp on csp.schedule_day_id=csd.schedule_day_id and csp.active
    join public.product_types pt on pt.product_type_id=csp.product_type_id and pt.active and pt.product_code in ('CLOTHES','MOP')
  ), history_daily as (
    select actual_date,customer_id,product_code,extract(isodow from actual_date)::integer production_weekday,
      sum(actual_kg)::numeric actual_kg
    from public.production_official_actuals
    where actual_date>=v_start-interval '18 months' and actual_date<v_start
    group by actual_date,customer_id,product_code
  ), ranked as (
    select h.*,row_number() over(
      partition by customer_id,product_code,production_weekday order by actual_date desc
    ) recency_rank
    from history_daily h
  ), model as (
    select customer_id,product_code,production_weekday,
      count(*) filter(where recency_rank<=3)::integer history_points,
      case when count(*) filter(where recency_rank<=3)>=3 then
        round(avg(actual_kg) filter(where recency_rank<=3),2)
      end forecast_kg
    from ranked where recency_rank<=3
    group by customer_id,product_code,production_weekday
  ), demand_detail as (
    select s.*,m.history_points,m.forecast_kg
    from schedule s left join model m on m.customer_id=s.customer_id and m.product_code=s.product_code
      and m.production_weekday=s.production_weekday
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
    'policy',jsonb_build_object('minimum_history_records',3,'method','SAME_WEEKDAY_AVERAGE',
      'message','Demand uses the latest three official records for the same customer, product and weekday. Incomplete history remains Learning.'),
    'days',coalesce((select jsonb_agg(to_jsonb(r) order by work_date) from day_rows r),'[]'::jsonb),
    'weeks',coalesce((select jsonb_agg(to_jsonb(w) order by week_start) from week_rows w),'[]'::jsonb),
    'learning_customers',coalesce((select jsonb_agg(to_jsonb(l) order by customer_name,product_code,production_weekday) from (
      select customer_id,customer_code,customer_name,product_code,production_weekday,
        coalesce(max(history_points),0)::integer history_points,min(work_date) next_scheduled_date,
        count(distinct work_date)::integer scheduled_days
      from demand_detail where forecast_kg is null
      group by customer_id,customer_code,customer_name,product_code,production_weekday
    ) l),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_production_intelligence_forward_capacity(date,integer) from public,anon;
grant execute on function public.get_production_intelligence_forward_capacity(date,integer) to authenticated;

comment on function public.get_production_intelligence_forward_capacity(date,integer) is
  'Forward demand uses the latest three official KG records for the same customer, product and weekday.';
