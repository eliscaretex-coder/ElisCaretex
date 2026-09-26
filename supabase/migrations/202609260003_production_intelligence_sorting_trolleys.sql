-- Sorting and trolley operational indicators for Production Intelligence.
-- Sorting weight remains approximate and is never merged into official Finish/MOP KG.

create or replace function public.get_production_intelligence_sorting_trolleys(
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
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null) then
    raise exception using errcode='42501',message='This account cannot view Production Intelligence.';
  end if;
  if v_from>v_to or v_to-v_from>731 then
    raise exception using errcode='22023',message='Choose a valid operational range of no more than two years.';
  end if;

  with received as (
    select received_on activity_date,count(*)::integer trolley_count
    from public.trolley_customer_stays
    where received_on between v_from and v_to and status in ('RECEIVED','CLOSED')
    group by received_on
  ), sent as (
    select sent_on activity_date,count(*)::integer trolley_count
    from public.trolley_customer_stays
    where sent_on between v_from and v_to
    group by sent_on
  ), intake as (
    select coalesce(physical_received_on,business_date) activity_date,
      count(*) filter(where record_status='RECORDED')::integer intake_count,
      count(*) filter(where exception_type is not null or review_status not in ('NOT_REQUIRED','APPROVED'))::integer exception_count
    from public.sorting_trolley_intakes
    where coalesce(physical_received_on,business_date) between v_from and v_to
    group by coalesce(physical_received_on,business_date)
  ), wash as (
    select business_date activity_date,count(*) filter(where status='RECORDED')::integer wash_runs,
      coalesce(sum(total_weight_kg) filter(where status='RECORDED'),0)::numeric approximate_kg,
      coalesce(sum(washer_capacity_kg_snapshot) filter(where status='RECORDED'),0)::numeric available_load_capacity_kg,
      count(distinct washer_id) filter(where status='RECORDED')::integer washers_used
    from public.sorting_wash_runs where business_date between v_from and v_to group by business_date
  ), reception_exceptions as (
    select business_date activity_date,count(*)::integer exception_count
    from public.sorting_wash_reception_exceptions where business_date between v_from and v_to group by business_date
  ), dates as (
    select activity_date from received union select activity_date from sent union select activity_date from intake
    union select activity_date from wash union select activity_date from reception_exceptions
  ), daily as (
    select d.activity_date,
      coalesce(r.trolley_count,0)::integer trolleys_received,
      coalesce(s.trolley_count,0)::integer trolleys_sent,
      coalesce(i.intake_count,0)::integer sorting_intakes,
      (coalesce(i.exception_count,0)+coalesce(re.exception_count,0))::integer exceptions,
      coalesce(w.wash_runs,0)::integer wash_runs,coalesce(w.approximate_kg,0)::numeric approximate_sorting_kg,
      coalesce(w.available_load_capacity_kg,0)::numeric load_capacity_kg,coalesce(w.washers_used,0)::integer washers_used,
      case when coalesce(w.available_load_capacity_kg,0)>0 then round(w.approximate_kg/w.available_load_capacity_kg*100,1) end load_utilisation_percent
    from dates d left join received r using(activity_date) left join sent s using(activity_date)
    left join intake i using(activity_date) left join wash w using(activity_date) left join reception_exceptions re using(activity_date)
  ), washers as (
    select coalesce(washer_code_snapshot,'UNASSIGNED') washer_code,coalesce(washer_name_snapshot,'Unassigned washer') washer_name,
      count(*) filter(where status='RECORDED')::integer wash_runs,
      coalesce(sum(total_weight_kg) filter(where status='RECORDED'),0)::numeric approximate_kg,
      coalesce(sum(washer_capacity_kg_snapshot) filter(where status='RECORDED'),0)::numeric load_capacity_kg
    from public.sorting_wash_runs where business_date between v_from and v_to
    group by coalesce(washer_code_snapshot,'UNASSIGNED'),coalesce(washer_name_snapshot,'Unassigned washer')
  )
  select jsonb_build_object(
    'period',jsonb_build_object('from',v_from,'to',v_to),
    'weight_policy',jsonb_build_object('classification','APPROXIMATE_OPERATIONAL_ONLY',
      'message','Sorting KG is approximate and excluded from official Finish/MOP production totals.'),
    'summary',jsonb_build_object(
      'trolleys_received',coalesce((select sum(trolleys_received) from daily),0),
      'trolleys_sent',coalesce((select sum(trolleys_sent) from daily),0),
      'sorting_intakes',coalesce((select sum(sorting_intakes) from daily),0),
      'wash_runs',coalesce((select sum(wash_runs) from daily),0),
      'approximate_sorting_kg',coalesce((select round(sum(approximate_sorting_kg),2) from daily),0),
      'exceptions',coalesce((select sum(exceptions) from daily),0)
    ),
    'daily',coalesce((select jsonb_agg(to_jsonb(d) order by activity_date desc) from daily d),'[]'::jsonb),
    'washers',coalesce((select jsonb_agg(jsonb_build_object(
      'washer_code',washer_code,'washer_name',washer_name,'wash_runs',wash_runs,
      'approximate_kg',round(approximate_kg,2),'load_capacity_kg',round(load_capacity_kg,2),
      'load_utilisation_percent',case when load_capacity_kg>0 then round(approximate_kg/load_capacity_kg*100,1) end
    ) order by approximate_kg desc) from washers),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_production_intelligence_sorting_trolleys(date,date) from public,anon;
grant execute on function public.get_production_intelligence_sorting_trolleys(date,date) to authenticated;

comment on function public.get_production_intelligence_sorting_trolleys(date,date) is
  'Permission-guarded trolley flow and Sorting operational indicators. Sorting KG is explicitly approximate and excluded from official production KG.';
