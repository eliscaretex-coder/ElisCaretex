begin;
select plan(18);

-- Static checks
select has_function('public','account_module_allowed',array['text[]','text','text[]'],'account_module_allowed exists');
select ok(not has_function_privilege('anon','public.account_module_allowed(text[],text,text[])','execute'),'anon cannot call account_module_allowed');
select ok(not exists(select 1 from public.job_title_legacy_roles where job_title_code='DRIVER' and role_code='DISTRIBUTION_OPERATOR'),'DRIVER no longer carries DISTRIBUTION_OPERATOR');
select ok((select can_manage from public.job_title_permission_templates where job_title_code='GENERAL_MANAGER' and module_code='DISTRIBUTION'),'General Manager manages Distribution');
select ok((select can_edit from public.job_title_permission_templates where job_title_code='PRODUCTION_MANAGER' and module_code='SORTING'),'Production Manager template includes Sorting');
select ok(not exists(select 1 from public.job_title_permission_templates where job_title_code in ('PRODUCTION_MANAGER','PRODUCTION_SUPERVISOR') and module_code='DISTRIBUTION'),'Production titles have no Distribution template');
select ok(pg_get_functiondef('public.require_distribution_master_access()'::regprocedure) like '%account_module_allowed(array[''DISTRIBUTION''],''MANAGE''%','Distribution master guard uses module permission');
select ok(pg_get_functiondef('public.require_sorting_operational_access()'::regprocedure) like '%account_module_allowed(array[''SORTING''],''EDIT''%','Sorting guard uses module permission');
select ok(pg_get_functiondef('public.require_finish_production_access()'::regprocedure) like '%account_module_allowed(array[''FINISH''],''EDIT''%','Finish guard uses module permission');
select ok(pg_get_functiondef('public.production_roster_action_allowed(text)'::regprocedure) like '%account_uses_module_permissions()%','Production Roster switches on the account type, not on any grant');
select is(public.legacy_role_modules(array['SUPERVISOR','DISTRIBUTION_OPERATOR'])::text, '{DISTRIBUTION,FINISH,MOP,SORTING}','legacy role to module mapping');
select is(public.trolley_action_for_roles(array['ADMIN','MANAGER']),'MANAGE','trolley master actions need MANAGE');

create temporary table t_terminal as
select ap.auth_user_id
from public.account_access_profiles ap
join public.account_roles ar on ar.auth_user_id = ap.auth_user_id and ar.active
join public.roles r on r.role_id = ar.role_id and r.role_code = 'SORTING_OPERATOR'
where ap.account_type = 'TERMINAL'
limit 1;
-- A throw-away personal account with only DISTRIBUTION:VIEW and the MANAGER role.
insert into auth.users(id, instance_id, aud, role, email) values ('00000000-0000-4000-8000-0000000000aa','00000000-0000-0000-0000-000000000000','authenticated','authenticated','perm-test@example.invalid');
insert into public.account_access_profiles(auth_user_id, account_type, display_name) values ('00000000-0000-4000-8000-0000000000aa','USER','Permission test');
insert into public.account_roles(auth_user_id, role_id, active) select '00000000-0000-4000-8000-0000000000aa', role_id, true from public.roles where role_code='MANAGER';
insert into public.account_permission_grants(auth_user_id, module_code, access_scope, can_view) values ('00000000-0000-4000-8000-0000000000aa','DISTRIBUTION','ALL',true);

select set_config('request.jwt.claims', json_build_object('sub','00000000-0000-4000-8000-0000000000aa','role','authenticated')::text, true);
select ok(public.account_module_allowed(array['DISTRIBUTION'],'VIEW',array['ADMIN']),'personal account: grant VIEW allows reading Distribution');
select ok(not public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['MANAGER']),'personal account: MANAGER role alone no longer allows Distribution planning');
select ok(not public.account_module_allowed(array['SORTING'],'EDIT',array['MANAGER']),'personal account: no Sorting grant, no Sorting');
select ok(not public.legacy_role_allowed(array['ADMIN','MANAGER']),'personal account: role shortcuts no longer apply');

select set_config('request.jwt.claims', json_build_object('sub',(select auth_user_id from t_terminal),'role','authenticated')::text, true);
select ok(public.account_module_allowed(array['SORTING'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR']),'Sorting terminal still works through its role');
select ok(not public.account_module_allowed(array['DISTRIBUTION'],'VIEW',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR','AUDITOR']),'Sorting terminal cannot read Distribution');

select * from finish();
rollback;
