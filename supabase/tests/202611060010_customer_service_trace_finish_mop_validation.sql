-- Validation for 202611060010_customer_service_trace_finish_mop.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
-- (The rolled-back block in the shared folder, teste-sem-gravar.sql, runs the full
-- trace / link MOP / change customer / unlink / results flow before applying.)
begin;
select plan(9);

select has_column('public','customer_service_complaints','linked_mop_batch_id','complaints can link a MOP Production batch');
select has_function('public','link_customer_service_complaint_production_v2',array['uuid','uuid','uuid','uuid'],'link v2 exists');
select ok(not has_function_privilege('anon','public.link_customer_service_complaint_production_v2(uuid,uuid,uuid,uuid)','execute'),'anon cannot link production');
select ok(not has_function_privilege('anon','public.get_customer_service_production_trace_v1(uuid,date,date)','execute'),'anon cannot read the production trace');
select ok(not has_function_privilege('authenticated','public.customer_service_flow_washes(uuid,uuid)','execute'),'flow washes helper is internal');
select ok(not has_function_privilege('authenticated','public.customer_service_customer_has_mop(uuid)','execute'),'has-MOP helper is internal');
select ok(pg_get_functiondef('public.link_customer_service_complaint_production_v2(uuid,uuid,uuid,uuid)'::regprocedure) like '%require_customer_service_access%','linking checks permission');
select has_trigger('public','customer_service_complaints','customer_service_complaints_clear_mop_link','changing the customer clears the MOP link');

-- An account without Customer Service is refused.
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',(select ap.auth_user_id from public.account_access_profiles ap
  where not exists(select 1 from public.account_permission_grants g where g.auth_user_id=ap.auth_user_id and g.module_code='CUSTOMER_SERVICE')
    and ap.job_title_code not in ('ADMINISTRATOR') limit 1),'role','authenticated')::text,true);
select throws_ok($$select public.link_customer_service_complaint_production_v2(gen_random_uuid(),null,gen_random_uuid(),null)$$,'42501',null,'an account without Customer Service is refused');

select * from finish();
rollback;
