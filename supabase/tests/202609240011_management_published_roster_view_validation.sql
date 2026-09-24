begin;
select plan(4);
select results_eq($$select count(*)::integer from public.job_title_permission_templates where module_code='MY_ROSTER' and can_view and job_title_code in('PRODUCTION_SUPERVISOR','PRODUCTION_MANAGER','GENERAL_MANAGER')$$,array[3],'production management job titles can view the published roster');
select results_eq($$select access_scope from public.job_title_permission_templates where job_title_code='PRODUCTION_SUPERVISOR' and module_code='MY_ROSTER'$$,array['PRODUCTION'::text],'supervisor scope is Production');
select results_eq($$select access_scope from public.job_title_permission_templates where job_title_code='PRODUCTION_MANAGER' and module_code='MY_ROSTER'$$,array['PRODUCTION'::text],'production manager scope is Production');
select results_eq($$select access_scope from public.job_title_permission_templates where job_title_code='GENERAL_MANAGER' and module_code='MY_ROSTER'$$,array['ALL'::text],'general manager scope is All');
select * from finish();
rollback;
