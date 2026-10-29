-- Validation for 202610290002_customer_schedule_unit_checks.
-- Uses the live BLOOMFIELD customer (2 M + 3 S trolleys a day) inside a transaction
-- and rolls everything back.
begin;
select plan(15);

-- 1. Objects and grants.
select has_table('public','customer_schedule_unit_checks','customer_schedule_unit_checks exists');
select has_function('public','confirm_customer_schedule_units',array['uuid','text','text'],'confirm_customer_schedule_units exists');
select ok(not has_function_privilege('anon','public.confirm_customer_schedule_units(uuid,text,text)','execute'),'anon cannot confirm');
select ok(not has_function_privilege('authenticated','public.customer_schedule_units_check_state(uuid)','execute'),'the internal state builder is not callable');
select ok(not has_table_privilege('authenticated','public.customer_schedule_unit_checks','select'),'checks are read only through RPCs');

-- 2. As an account that can edit Customers.
select set_config('request.jwt.claims', json_build_object('sub',(
  select g.auth_user_id from public.account_permission_grants g
  join public.account_access_profiles ap on ap.auth_user_id = g.auth_user_id and ap.account_type = 'USER'
  where g.module_code = 'CUSTOMERS' and g.active and g.can_edit limit 1),'role','authenticated')::text, true);

create temporary table _cv on commit drop as
select distinct on (v.customer_id) v.customer_id, v.schedule_version_id as id
from public.customer_schedule_versions v join public.customers c using (customer_id)
where c.customer_name = 'BLOOMFIELD' and c.active and v.status = 'PUBLISHED'
  and v.effective_from <= public.current_business_date()
  and (v.effective_until is null or v.effective_until >= public.current_business_date())
order by v.customer_id, v.effective_from desc, v.version_number desc;

select is((select public.get_customer_schedule_units_check(id) ->> 'status' from _cv),'TO_CHECK','a schedule with 5 trolleys a day starts as to check');
select ok((select jsonb_path_exists(public.get_customer_units_check_overview(),'$.items[*] ? (@.status == "TO_CHECK")') ),'the overview lists customers to check');
select is((select public.confirm_customer_schedule_units(id,'Validation: units checked','VALIDATION') ->> 'status' from _cv),'CHECKED','confirming makes it checked');
select ok((select public.get_customer_schedule_units_check(id) ->> 'checked_by_name' is not null from _cv),'the check shows who confirmed it');
select throws_ok($$delete from public.customer_schedule_unit_checks$$,'P0001',null,'checks are append-only');

-- 3. A new draft with the same trolleys keeps the check; a quantity change needs a new one.
create temporary table _d on commit drop as
select public.create_customer_schedule_draft(customer_id, public.current_business_date() + 1, null, 'Validation: units check','VALIDATION') as id from _cv;
select is((select public.get_customer_schedule_units_check(id) ->> 'status' from _d),'CHECKED','a draft with the same trolleys and units stays checked');

update public.customer_schedule_trolley_requirements r set quantity = r.quantity + 1
where r.schedule_trolley_requirement_id = (
  select r2.schedule_trolley_requirement_id from public.customer_schedule_trolley_requirements r2
  join public.customer_schedule_days d using (schedule_day_id) join _d on d.schedule_version_id = _d.id
  where r2.active order by d.production_weekday limit 1);
select is((select public.get_customer_schedule_units_check(id) ->> 'status' from _d),'TO_CHECK','a trolley quantity change needs a new units check');

select lives_ok($$select public.save_customer_subunits(customer_id,'[{"subunit_name":"VALIDATION WARD"}]'::jsonb,'Validation: add unit','VALIDATION') from _cv$$,'a unit is added in Customer Master');
select is((select public.get_customer_schedule_units_check(id) ->> 'status' from _cv),'TO_CHECK','a unit list change needs a new units check');

-- 4. An account without Customers is refused.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='CLEANER' and account_type='USER' limit 1),'role','authenticated')::text,true);
select throws_ok($$select public.get_customer_schedule_units_check(id) from _cv$$,'42501',null,'Cleaner cannot read the units check');

select * from finish();
rollback;
