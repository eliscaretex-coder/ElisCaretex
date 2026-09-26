-- Customer contribution and seasonal learning for Production Intelligence.
-- All values use official Finish/MOP KG only.

create or replace function public.get_production_intelligence_customer_seasonality(
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
  v_from date:=coalesce(p_from_date,date_trunc('year',current_date)::date);
  v_to date:=coalesce(p_to_date,current_date);
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null) then
    raise exception using errcode='42501',message='This account cannot view Production Intelligence.';
  end if;
  if v_from>v_to or v_to-v_from>1827 then
    raise exception using errcode='22023',message='Choose a valid seasonality range of no more than five years.';
  end if;

  with actuals as (
    select * from public.production_official_actuals where actual_date between v_from and v_to
  ), months as (
    select generate_series(date_trunc('month',v_from)::date,date_trunc('month',v_to)::date,interval '1 month')::date month_start
  ), monthly_values as (
    select date_trunc('month',actual_date)::date month_start,
      sum(actual_kg)::numeric total_kg,
      sum(actual_kg) filter(where production_source='FINISH')::numeric finish_kg,
      sum(actual_kg) filter(where production_source='MOP')::numeric mop_kg,
      count(distinct customer_id)::integer customers,
      count(distinct actual_date)::integer production_days
    from actuals group by date_trunc('month',actual_date)::date
  ), customer_weekly as (
    select customer_id,max(customer_code) customer_code,max(customer_name) customer_name,product_code,
      date_trunc('week',actual_date)::date week_start,sum(actual_kg)::numeric weekly_kg
    from actuals group by customer_id,product_code,date_trunc('week',actual_date)::date
  ), customer_stats as (
    select customer_id,max(customer_code) customer_code,max(customer_name) customer_name,product_code,
      sum(weekly_kg)::numeric total_kg,avg(weekly_kg)::numeric average_weekly_kg,
      min(weekly_kg)::numeric minimum_weekly_kg,max(weekly_kg)::numeric maximum_weekly_kg,
      stddev_samp(weekly_kg)::numeric weekly_stddev_kg,count(*)::integer recorded_weeks
    from customer_weekly group by customer_id,product_code
  ), totals as (select coalesce(sum(actual_kg),0)::numeric total_kg from actuals)
  select jsonb_build_object(
    'period',jsonb_build_object('from',v_from,'to',v_to),
    'learning_policy',jsonb_build_object(
      'minimum_weeks',8,'minimum_months_for_seasonality',6,
      'message','Seasonality remains in learning mode until enough official Finish/MOP history exists.'
    ),
    'monthly',coalesce((select jsonb_agg(jsonb_build_object(
      'month_start',m.month_start,'total_kg',round(coalesce(v.total_kg,0),2),
      'finish_kg',round(coalesce(v.finish_kg,0),2),'mop_kg',round(coalesce(v.mop_kg,0),2),
      'customers',coalesce(v.customers,0),'production_days',coalesce(v.production_days,0),
      'data_status',case when v.month_start is null then 'NO_DATA' else 'RECORDED' end
    ) order by m.month_start) from months m left join monthly_values v using(month_start)),'[]'::jsonb),
    'customers',coalesce((select jsonb_agg(jsonb_build_object(
      'customer_id',s.customer_id,'customer_code',s.customer_code,'customer_name',s.customer_name,'product_code',s.product_code,
      'total_kg',round(s.total_kg,2),'share_percent',case when t.total_kg>0 then round(s.total_kg/t.total_kg*100,2) else 0 end,
      'average_weekly_kg',round(s.average_weekly_kg,2),'minimum_weekly_kg',round(s.minimum_weekly_kg,2),
      'maximum_weekly_kg',round(s.maximum_weekly_kg,2),'weekly_stddev_kg',round(coalesce(s.weekly_stddev_kg,0),2),
      'variation_percent',case when s.average_weekly_kg>0 then round(coalesce(s.weekly_stddev_kg,0)/s.average_weekly_kg*100,1) else 0 end,
      'recorded_weeks',s.recorded_weeks,
      'learning_status',case when s.recorded_weeks>=8 then 'BASELINE_READY' else 'LEARNING' end
    ) order by s.total_kg desc,s.customer_name) from customer_stats s cross join totals t),'[]'::jsonb),
    'recorded_months',(select count(*) from monthly_values),
    'seasonality_status',case when (select count(*) from monthly_values)>=6 then 'BASELINE_READY' else 'LEARNING' end
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_production_intelligence_customer_seasonality(date,date) from public,anon;
grant execute on function public.get_production_intelligence_customer_seasonality(date,date) to authenticated;

comment on function public.get_production_intelligence_customer_seasonality(date,date) is
  'Permission-guarded monthly and customer analytics based exclusively on official Finish/MOP KG.';
