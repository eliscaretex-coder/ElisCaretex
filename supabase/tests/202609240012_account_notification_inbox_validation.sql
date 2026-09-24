begin;
select plan(4);
select has_function('public','get_my_notification_inbox',array[]::text[],'notification inbox function exists');
select function_privs_are('public','get_my_notification_inbox',array[]::text[],'authenticated',array['EXECUTE'],'authenticated accounts can open their inbox');
select function_privs_are('public','get_my_notification_inbox',array[]::text[],'anon',array[]::text[],'anonymous users cannot open an inbox');
select results_eq($$select count(*)::integer from public.job_title_permission_templates where module_code='NOTIFICATIONS' and job_title_code in('PRODUCTION_SUPERVISOR','PRODUCTION_MANAGER','GENERAL_MANAGER') and can_view$$,array[3],'production management notification templates exist');
select * from finish();
rollback;
