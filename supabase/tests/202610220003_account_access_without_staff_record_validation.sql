-- Validation for 202610220003_account_access_without_staff_record.sql.
-- Run against ElisCaretex-dev after the migration is applied. Everything is rolled back.
begin;
select plan(9);

select ok(not has_function_privilege('anon','public.require_distribution_read_access()','execute'),'anon cannot call the Distribution guard');
select ok(not exists(
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f' and pg_get_functiondef(p.oid) ~ 'current_staff_id\(\) is null'
),'no guard requires a staff record any more');

-- An ADMIN account that has account roles but no staff record.
create temporary table t_admin on commit drop as
select ap.auth_user_id from public.account_access_profiles ap
join public.account_roles ar on ar.auth_user_id=ap.auth_user_id and ar.active
join public.roles r on r.role_id=ar.role_id and r.role_code='ADMIN'
where not exists(select 1 from public.staff_members sm where sm.auth_user_id=ap.auth_user_id)
limit 1;
-- A Sorting terminal account without staff record and without Distribution or Finish roles.
create temporary table t_sorting on commit drop as
select d.device_auth_user_id as auth_user_id from public.production_station_devices d
where d.active
  and exists(select 1 from public.account_roles ar join public.roles r on r.role_id=ar.role_id
             where ar.auth_user_id=d.device_auth_user_id and ar.active and r.role_code='SORTING_OPERATOR')
  and not exists(select 1 from public.account_roles ar join public.roles r on r.role_id=ar.role_id
             where ar.auth_user_id=d.device_auth_user_id and ar.active
               and r.role_code in ('ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR','AUDITOR','FINISH_OPERATOR'))
limit 1;

-- The guards are internal (not executable by authenticated), so the claims are set on the
-- current role; auth.uid() reads them.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from t_admin),'role','authenticated')::text,true);
select ok(public.current_staff_id() is null,'the ADMIN account has no staff record');
select lives_ok('select public.require_distribution_read_access()','ADMIN without staff record opens Distribution');
select lives_ok('select public.require_distribution_plan_access()','ADMIN without staff record can plan Distribution');
select lives_ok('select public.require_finish_production_access()','ADMIN without staff record opens Finish');
select lives_ok('select public.require_customer_schedule_edit_role()','ADMIN without staff record edits Customer Schedules');

select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from t_sorting),'role','authenticated')::text,true);
select throws_ok('select public.require_distribution_read_access()','42501','Your active role does not allow access to Distribution.','Sorting terminal is still refused by Distribution');
select throws_ok('select public.require_finish_production_access()','42501','Your role cannot use Finish Production.','Sorting terminal is still refused by Finish');

select * from finish();
rollback;
