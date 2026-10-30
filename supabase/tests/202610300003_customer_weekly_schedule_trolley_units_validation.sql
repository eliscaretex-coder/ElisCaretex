-- Validation for 202610300003_customer_weekly_schedule_trolley_units.
-- Reads the live HIGHFIELD customer (units on every trolley) as the Finish Table 1
-- terminal and rolls everything back.
begin;
select plan(8);

select ok(not has_function_privilege('anon','public.get_customer_weekly_schedule(uuid,date)','execute'),'anon cannot read the weekly schedule');
select ok(pg_get_functiondef('public.get_customer_weekly_schedule(uuid,date)'::regprocedure) like '%require_any_customer_read_role%','the weekly schedule still checks the reader role');

-- As a Finish operator terminal (FINISH-T1-PC01).
select set_config('request.jwt.claims', json_build_object('sub',(
  select auth_user_id from public.account_access_profiles where display_name = 'FINISH-T1-PC01' limit 1),'role','authenticated')::text, true);

create temporary table _s on commit drop as
select public.get_customer_weekly_schedule(c.customer_id, public.current_business_date()) as r
from public.customers c where c.customer_name = 'HIGHFIELD' and c.active and c.deleted_at is null limit 1;

select ok((select jsonb_path_exists(r, '$.days[*].products[*].trolley_breakdown[*].plates[*].subunit_names[*]') from _s),'the Finish terminal sees the unit names on the trolleys');
select ok((select jsonb_path_exists(r, '$.days[*].products[*].trolley_breakdown[*].plates[*] ? (exists(@.plate_number))') from _s),'every plate carries its trolley number');
select ok((select jsonb_array_length(r->'schedule_version'->'delivery_weekdays') > 0 from _s),'the schedule lists its delivery weekdays');
select ok((select jsonb_path_exists(r, '$.days[*].delivery_weekday') from _s),'every day carries its delivery weekday');
select ok((select not jsonb_path_exists(r, '$.days[*].products[*] ? (@.product_code == "MOP")') from _s),'the Finish terminal still sees only Clothes');

-- A Cleaner still cannot read customer schedules.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='CLEANER' and account_type='USER' limit 1),'role','authenticated')::text,true);
select throws_ok($$select public.get_customer_weekly_schedule(customer_id, public.current_business_date()) from public.customers where customer_name = 'HIGHFIELD' limit 1$$,'42501',null,'Cleaner cannot read the weekly schedule');

select * from finish();
rollback;
