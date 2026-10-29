-- Validation for 202610290004_production_tracker_same_day_schedule_version.sql
-- Run against ElisCaretex-dev after the migration. Read-only; rolled back.
begin;
select plan(6);

select has_function('public','get_production_tracker_v4',array['date'],'get_production_tracker_v4 exists');
select ok(not has_function_privilege('anon','public.get_production_tracker_v4(date)','execute'),'anon cannot call get_production_tracker_v4');
select ok(pg_get_functiondef('public.get_production_tracker_v1(date)'::regprocedure) like '%p.customer_id = s.customer_id%','V1 binds flow items by customer, product and date');
select ok(pg_get_functiondef('public.get_production_tracker_v4(date)'::regprocedure) like '%finish_processed_by%','V4 returns the Finish processing staff');

select set_config('request.jwt.claims', json_build_object('sub',(
  select g.auth_user_id from public.account_permission_grants g
  join public.account_access_profiles ap on ap.auth_user_id = g.auth_user_id and ap.account_type = 'USER'
  where g.module_code = 'PRODUCTION_TRACKER' and g.active and g.can_view limit 1),'role','authenticated')::text, true);

create temporary table _after on commit drop as
select d::date as business_date, i.item
from generate_series(public.current_business_date() - 14, public.current_business_date() + 1, interval '1 day') d
cross join lateral jsonb_array_elements(public.get_production_tracker_v4(d::date)->'items') i(item);

select is((select count(*) from (
  select business_date, item->>'customer_id', item->>'product_code' from _after
  group by 1,2,3 having count(*) > 1) x)::integer, 0,
  'no customer shows the same product twice on any day of the last two weeks');

select is((select count(*) from public.production_flow_items pfi
  where pfi.scheduled_for_date between public.current_business_date() - 14 and public.current_business_date() + 1
    and pfi.product_code in ('CLOTHES','MOP')
    and not exists (select 1 from _after a where a.business_date = pfi.scheduled_for_date
                    and a.item->>'production_flow_item_id' = pfi.production_flow_item_id::text))::integer, 0,
  'every production flow item of those days is still on the tracker');

select * from finish();
rollback;
