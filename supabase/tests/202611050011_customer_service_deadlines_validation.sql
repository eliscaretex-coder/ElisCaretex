-- Validation for 202611050011_customer_service_deadlines.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
-- (The rolled-back block in the shared folder, teste-sem-gravar.sql, runs the full
-- create / move date / resolve / reopen / severity / block flow before applying.)
begin;
select plan(8);

select has_column('public','customer_service_complaints','resolve_by','complaints have a resolve-by date');
select ok(not exists(select 1 from public.customer_service_complaints where resolve_by is null),'every complaint has a resolve-by date');
select has_function('public','set_customer_service_complaint_due_v1',array['uuid','date','text'],'set_customer_service_complaint_due_v1 exists');
select ok(not has_function_privilege('anon','public.set_customer_service_complaint_due_v1(uuid,date,text)','execute'),'anon cannot move a resolve-by date');
select ok(not has_function_privilege('authenticated','public.customer_service_target_days(text)','execute'),'target days helper is internal');
select ok(pg_get_functiondef('public.set_customer_service_complaint_due_v1(uuid,date,text)'::regprocedure) like '%require_customer_service_access%','moving the date checks permission');
select is(public.customer_service_target_days('HIGH'),2,'High complaints: 2 days by default');

-- A General Operative (no Customer Service access) is refused.
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',(select ap.auth_user_id from public.account_access_profiles ap
  where not exists(select 1 from public.account_permission_grants g where g.auth_user_id=ap.auth_user_id and g.module_code='CUSTOMER_SERVICE')
    and ap.job_title_code not in ('ADMINISTRATOR') limit 1),'role','authenticated')::text,true);
select throws_ok($$select public.set_customer_service_complaint_due_v1(gen_random_uuid(),current_date+1,'reason')$$,'42501',null,'an account without Customer Service is refused');

select * from finish();
rollback;
