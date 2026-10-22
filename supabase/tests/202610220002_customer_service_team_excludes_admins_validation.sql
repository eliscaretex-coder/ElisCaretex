-- Validation for 202610220002_customer_service_team_excludes_admins.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
begin;
select plan(4);

select ok(not has_function_privilege('anon','public.get_customer_service_workspace_v1()','execute'),'anon cannot open the workspace');
select ok(pg_get_functiondef('public.get_customer_service_workspace_v1()'::regprocedure) like '%require_customer_service_access%','workspace checks permission');

set local role authenticated;
select set_config('request.jwt.claims',json_build_object('sub',(select ap.auth_user_id from public.account_access_profiles ap where ap.job_title_code='ADMINISTRATOR' limit 1),'role','authenticated')::text,true);
select is(public.get_customer_service_workspace_v1()->'me'->>'scope','ALL','administrator still has full access');
select ok(not exists(select 1 from jsonb_array_elements(public.get_customer_service_workspace_v1()->'agents') a
  where a->>'auth_user_id'=current_setting('request.jwt.claims')::jsonb->>'sub'),'administrator is not listed as a Customer Service person');

select * from finish();
rollback;
