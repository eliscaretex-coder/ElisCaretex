-- Production Roster: scheduled customer KG per day under Finish capacity.
-- Sums the automatic Expected KG (customer_kg_estimates, 202610200001) of every customer
-- scheduled on each production day, split into Clothes + other products and MOP. Manual
-- schedule Expected KG is the fallback while a slot is still learning; slots with neither
-- are counted as learning so the planner sees the number is incomplete.

create or replace function public.get_production_roster_customer_kg(
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
  v_result jsonb;
begin
  perform public.require_production_roster_read_role();
  if p_from_date is null or p_to_date is null or p_from_date>p_to_date or p_to_date-p_from_date>41 then
    raise exception using errcode='22023',message='Choose a date range of up to six weeks.';
  end if;

  with estimates as materialized (
    select e.customer_id,e.product_code,e.production_weekday,e.estimated_kg
    from public.customer_kg_estimates(public.current_business_date(),null) e
  ), dates as (
    select gs::date work_date from generate_series(p_from_date,p_to_date,interval '1 day') gs
  ), slots as (
    select d.work_date,v.customer_id,pt.product_code,coalesce(e.estimated_kg,sp.expected_kg) kg
    from dates d
    join public.customer_schedule_versions v on v.status='PUBLISHED' and v.effective_from<=d.work_date
      and (v.effective_until is null or v.effective_until>=d.work_date)
    join public.customers c on c.customer_id=v.customer_id and c.active and c.deleted_at is null
    join public.customer_schedule_days sd on sd.schedule_version_id=v.schedule_version_id and sd.active
      and sd.production_weekday=extract(isodow from d.work_date)::integer
    join public.customer_schedule_products sp on sp.schedule_day_id=sd.schedule_day_id and sp.active
    join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.active and pt.deleted_at is null
    left join estimates e on e.customer_id=v.customer_id and e.product_code=pt.product_code
      and e.production_weekday=sd.production_weekday
  ), day_rows as (
    select d.work_date,
      count(distinct s.customer_id)::integer customer_count,
      round(coalesce(sum(s.kg) filter(where s.product_code<>'MOP'),0),1) clothes_kg,
      round(coalesce(sum(s.kg) filter(where s.product_code='MOP'),0),1) mop_kg,
      count(*) filter(where s.product_code<>'MOP')::integer clothes_slots,
      count(*) filter(where s.product_code='MOP')::integer mop_slots,
      count(*) filter(where s.product_code<>'MOP' and s.kg is null)::integer clothes_learning,
      count(*) filter(where s.product_code='MOP' and s.kg is null)::integer mop_learning
    from dates d left join slots s on s.work_date=d.work_date
    group by d.work_date
  )
  select jsonb_build_object(
    'from',p_from_date,'to',p_to_date,
    'method','Automatic Expected KG (latest 8 official services per customer and weekday), manual Expected KG while learning.',
    'days',coalesce(jsonb_agg(to_jsonb(r) order by r.work_date),'[]'::jsonb)
  ) into v_result
  from day_rows r;

  return v_result;
end;
$$;

revoke all on function public.get_production_roster_customer_kg(date,date) from public,anon;
grant execute on function public.get_production_roster_customer_kg(date,date) to authenticated;

comment on function public.get_production_roster_customer_kg(date,date) is
  'Production Roster: scheduled customer KG per day (Clothes + other vs MOP) from the automatic Expected KG. Roster readers only.';
