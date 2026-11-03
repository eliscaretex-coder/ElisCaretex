-- Validation for 202611030001_trolley_label_route_delivery_days.
-- Reads a live production item of a customer delivered by more than one route
-- as an administrator and rolls everything back.
begin;
select plan(5);

select ok(not has_function_privilege('anon','public.get_production_flow_trolley_plates(uuid)','execute'),'anon cannot read the trolley plates');
select ok(pg_get_functiondef('public.get_production_flow_trolley_plates(uuid)'::regprocedure) like '%account_module_allowed%','the trolley plates still check the module permission');
select ok(pg_get_functiondef('public.get_production_flow_trolley_plates(uuid)'::regprocedure) like '%d_route.default_route_id%','delivery days follow the route of the label');

select set_config('request.jwt.claims',json_build_object('sub',(select ap.auth_user_id from public.account_access_profiles ap where ap.job_title_code='ADMINISTRATOR' limit 1),'role','authenticated')::text,true);

-- Latest production item whose schedule day has a route, for a customer whose
-- schedule uses more than one route.
create temporary table _item on commit drop as
select i.production_flow_item_id, d.schedule_version_id, d.default_route_id
from public.production_flow_items i
join public.customer_schedule_days d on d.schedule_day_id = i.source_schedule_day_id
where d.default_route_id is not null
  and (select count(distinct d2.default_route_id) from public.customer_schedule_days d2
       where d2.schedule_version_id = d.schedule_version_id and d2.active) > 1
order by i.scheduled_for_date desc nulls last
limit 1;

create temporary table _r on commit drop as
select public.get_production_flow_trolley_plates(production_flow_item_id) as r from _item;

select is(
  (select r->'delivery_days' from _r),
  (select coalesce(jsonb_agg((array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'])[w] order by w), '[]'::jsonb)
   from (select distinct d.delivery_weekday w from public.customer_schedule_days d, _item
         where d.schedule_version_id = _item.schedule_version_id and d.active
           and d.default_route_id = _item.default_route_id and d.delivery_weekday between 1 and 7) x),
  'the label lists only the delivery days of its route');
select ok((select jsonb_array_length(r->'delivery_days') < (
  select count(distinct d.delivery_weekday) from public.customer_schedule_days d, _item
  where d.schedule_version_id = _item.schedule_version_id and d.active and d.delivery_weekday between 1 and 7) from _r),
  'days of the other routes are left out');

select * from finish();
rollback;
