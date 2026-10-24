-- Validation for 202610240001_production_intelligence_manager_views.sql.
-- Run against ElisCaretex-dev after the migration is applied. Read-only: rolled back.
begin;
select plan(16);

select has_function('public','production_intelligence_staff_hours',array['date','date'],'staff hours helper exists');
select has_function('public','get_production_intelligence_manager_view',array['date','date','text','date','date'],'manager view exists');
select has_function('public','get_production_daily_report',array['date'],'daily report exists');

-- Grants: the helper is internal, the two RPCs are for signed-in accounts only.
select ok(not has_function_privilege('authenticated','public.production_intelligence_staff_hours(date,date)','execute'),'authenticated cannot call the hours helper');
select ok(not has_function_privilege('anon','public.production_intelligence_staff_hours(date,date)','execute'),'anon cannot call the hours helper');
select ok(not has_function_privilege('anon','public.get_production_intelligence_manager_view(date,date,text,date,date)','execute'),'anon cannot call the manager view');
select ok(not has_function_privilege('anon','public.get_production_daily_report(date)','execute'),'anon cannot call the daily report');
select ok(has_function_privilege('authenticated','public.get_production_intelligence_manager_view(date,date,text,date,date)','execute'),'authenticated can call the manager view');
select ok(has_function_privilege('authenticated','public.get_production_daily_report(date)','execute'),'authenticated can call the daily report');
select ok(pg_get_functiondef('public.get_production_intelligence_manager_view(date,date,text,date,date)'::regprocedure) like '%has_account_permission(''PRODUCTION_INSIGHTS'', ''VIEW''%','manager view checks Production Intelligence permission');
select ok(pg_get_functiondef('public.get_production_daily_report(date)'::regprocedure) like '%has_account_permission(''PRODUCTION_INSIGHTS'', ''VIEW''%','daily report checks Production Intelligence permission');

-- Negative: no signed-in user.
select set_config('request.jwt.claims','{}',true);
select throws_ok($$select public.get_production_intelligence_manager_view(current_date-7,current_date,'DAY',null,null)$$,'42501',null,'manager view refuses an anonymous call');
select throws_ok($$select public.get_production_daily_report(current_date)$$,'42501',null,'daily report refuses an anonymous call');

-- Positive: the Administrator account (has Production Intelligence).
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='ADMINISTRATOR' limit 1),'role','authenticated')::text,true);
select is(public.get_production_intelligence_manager_view(current_date-30,current_date,'DAY',null,null)->>'schema_version','PRODUCTION_INTELLIGENCE_MANAGER_V1','administrator gets the manager view');
select is(public.get_production_daily_report(current_date-1)->>'schema_version','PRODUCTION_DAILY_REPORT_V1','administrator gets the daily report');
select throws_ok($$select public.get_production_intelligence_manager_view(current_date,current_date-1,'DAY',null,null)$$,'22023',null,'manager view refuses an inverted period');

select * from finish();
rollback;
