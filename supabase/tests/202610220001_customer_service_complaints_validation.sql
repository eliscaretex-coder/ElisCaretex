-- Validation for 202610220001_customer_service_complaints.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
begin;
select plan(23);

select has_table('public','customer_service_complaints','complaints table exists');
select has_table('public','customer_service_alerts','alerts table exists');
select has_table('public','customer_service_tasks','tasks table exists');
select has_table('public','customer_service_customer_owners','customer blocks table exists');
select has_table('public','customer_service_events','history table exists');
select ok((select relrowsecurity from pg_class where oid='public.customer_service_complaints'::regclass),'complaints have RLS enabled');
select ok(not has_table_privilege('authenticated','public.customer_service_complaints','select'),'authenticated cannot read complaints directly');
select ok(exists(select 1 from public.application_modules where module_code='CUSTOMER_SERVICE' and active),'CUSTOMER_SERVICE module exists');
select ok(exists(select 1 from public.job_title_permission_templates where job_title_code='CUSTOMER_SERVICE' and module_code='CUSTOMER_SERVICE' and can_manage),'Customer Service job title can be given Manage');
select ok((select count(*) from public.customer_service_complaint_types where active)>=10,'complaint types are seeded');

select ok(not has_function_privilege('anon','public.get_customer_service_workspace_v1()','execute'),'anon cannot open the workspace');
select ok(not has_function_privilege('anon','public.save_customer_service_complaint_v1(uuid,uuid,date,text,text,text,date,text,text)','execute'),'anon cannot log complaints');
select ok(not has_function_privilege('anon','public.get_production_customer_alerts_v1(text)','execute'),'anon cannot read production alerts');
select ok(not has_function_privilege('authenticated','public.customer_service_access_scope()','execute'),'scope helper is internal');
select ok(pg_get_functiondef('public.save_customer_service_complaint_v1(uuid,uuid,date,text,text,text,date,text,text)'::regprocedure) like '%require_customer_service_access%','saving checks permission');
select ok(pg_get_functiondef('public.get_customer_service_production_trace_v1(uuid,date,date)'::regprocedure) like '%require_customer_service_access%','trace checks permission');
select ok(pg_get_functiondef('public.set_customer_service_customer_owner_v1(uuid[],uuid)'::regprocedure) like '%MANAGE%','customer blocks need Manage');
select ok(pg_get_functiondef('public.complete_production_customer_task_v1(uuid,text)'::regprocedure) like '%require_production_flow_read_role%','production task completion needs a production role');

-- Administrator: full flow on a real customer.
set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',(select ap.auth_user_id from public.account_access_profiles ap where ap.job_title_code='ADMINISTRATOR' limit 1),'role','authenticated')::text,true);
select is(public.get_customer_service_workspace_v1()->'me'->>'scope','ALL','administrator sees all customers');
create temporary table cs_probe on commit drop as
select public.save_customer_service_complaint_v1(null,(select customer_id from public.customers where active and deleted_at is null order by customer_name limit 1),current_date,'LOST_ITEM','Validation complaint','HIGH',null,'PHONE',null) as c;
select is((select c->>'status' from cs_probe),'OPEN','new complaint is open');
select is((public.save_customer_service_task_v1(null,'FINISH','Validation task',null,current_date+1,(select (c->>'complaint_id')::uuid from cs_probe),null))->>'status','OPEN','task created for Finish');
select is((public.set_customer_service_complaint_status_v1((select (c->>'complaint_id')::uuid from cs_probe),'RESOLVED','JUSTIFIED','Validation resolved'))->>'status','RESOLVED','complaint resolved');

-- A General Operative has no Customer Service access.
select set_config('request.jwt.claims',json_build_object('sub',(select ap.auth_user_id from public.account_access_profiles ap where ap.job_title_code='GENERAL_OPERATIVE' limit 1),'role','authenticated')::text,true);
select throws_ok('select public.get_customer_service_workspace_v1()','42501',null,'general operative cannot open Customer Service');

select * from finish();
rollback;
