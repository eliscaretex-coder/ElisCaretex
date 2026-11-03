begin;
select plan(19);
select has_function('public','job_title_for_primary_role',array['text'],'job_title_for_primary_role exists');
select has_function('public','can_change_login_job_title',array['text','text'],'can_change_login_job_title exists');
select ok(not has_function_privilege('authenticated','public.can_change_login_job_title(text,text)','execute'),'authenticated cannot call can_change_login_job_title directly');
select ok(pg_get_functiondef('public.update_staff_master_with_current_roster_role(uuid,integer,text,text,text,text,text,text,boolean,text[],boolean,boolean,boolean,date,text,boolean,text,text,text,boolean)'::regprocedure) like '%apply_account_job_title_template%','Staff Master save updates the login job title');
select is(public.job_title_for_primary_role('SUPERVISOR'),'PRODUCTION_SUPERVISOR','SUPERVISOR maps to PRODUCTION_SUPERVISOR');
select set_config('request.jwt.claims',json_build_object('sub',(select ap.auth_user_id from public.account_access_profiles ap join public.account_roles ar on ar.auth_user_id=ap.auth_user_id and ar.active join public.roles r on r.role_id=ar.role_id and r.role_code='ADMIN' where ap.account_type='USER' limit 1),'role','authenticated')::text,true);

create temporary table _t on commit drop as
select sm.staff_id, sm.display_name, sm.auth_user_id from public.staff_members sm where sm.employee_code='EMP-00002' and sm.deleted_at is null;

select is((select ap.job_title_code from public.account_access_profiles ap join _t using(auth_user_id) where ap.account_type='USER'),'PRODUCTION_MANAGER'::text,'Repair: EMP-00002 login is now Production Manager');
select is((select count(*)::int from public.account_permission_grants g join _t using(auth_user_id) where g.active),
          (select count(*)::int from public.job_title_permission_templates where job_title_code='PRODUCTION_MANAGER'),'Repair: login has the Production Manager standard permissions');
select ok(exists(select 1 from public.account_roles ar join public.roles r using(role_id) join _t using(auth_user_id) where ar.active and r.role_code='MANAGER'),'Repair: login has the MANAGER legacy role');
select is((select count(*)::int from public.staff_members sm join public.operational_roles r on r.operational_role_id=sm.primary_operational_role_id
  join public.account_access_profiles ap on ap.auth_user_id=sm.auth_user_id and ap.account_type='USER'
  where sm.deleted_at is null and sm.production_staff and public.job_title_follows_primary_role(ap.job_title_code)
    and public.job_title_for_primary_role(r.role_code) is distinct from ap.job_title_code and public.job_title_for_primary_role(r.role_code) is not null),0,'Repair: no login disagrees with Staff Master any more');
select ok(exists(select 1 from public.audit_log where action='SYNC_LOGIN_JOB_TITLE_FROM_STAFF_MASTER' and source_application='migration 202611030002'),'Repair is in audit_log');

-- Administrator changes the primary role back to General Operative: the login follows.
create function pg_temp.save_role(p_staff uuid, p_role text) returns jsonb language plpgsql as $f$
declare r jsonb; begin
  r := to_jsonb(public.get_staff_master_record(p_staff));
  return public.update_staff_master_with_current_roster_role(p_staff, (r->>'row_version')::int, r->>'display_name', r->>'employee_code',
    r->>'default_shift_code', p_role, r->>'default_area_code', r->>'default_station_code',
    coalesce((r->>'roster_eligible')::boolean,false), coalesce(array(select jsonb_array_elements_text(coalesce(r->'cover_role_codes','[]'::jsonb))),array[]::text[]),
    coalesce((r->>'fire_training')::boolean,false), coalesce((r->>'first_aid_training')::boolean,false), coalesce((r->>'eod_capable')::boolean,false),
    (r->>'joined_on')::date, r->>'notes', coalesce((r->>'import_review_required')::boolean,false), r->>'import_review_notes',
    'validation 202611030002', 'VALIDATION', false);
end $f$;

select is((pg_temp.save_role((select staff_id from _t),'GENERAL_OPERATIVE')->>'login_job_title_code'),'GENERAL_OPERATIVE'::text,'Admin saves GO in Staff Master: result says the login changed');
select is((select ap.job_title_code from public.account_access_profiles ap join _t using(auth_user_id) where ap.account_type='USER'),'GENERAL_OPERATIVE'::text,'Login is now General Operative');
select is((select count(*)::int from public.account_permission_grants g join _t using(auth_user_id) where g.active),
          (select count(*)::int from public.job_title_permission_templates where job_title_code='GENERAL_OPERATIVE'),'Login has the General Operative standard permissions');
select ok(not exists(select 1 from public.account_roles ar join _t using(auth_user_id) where ar.active),'MANAGER legacy role removed');
select ok(exists(select 1 from public.audit_log a join _t on a.entity_id=_t.auth_user_id::text where a.action='SYNC_LOGIN_JOB_TITLE_FROM_STAFF_MASTER' and a.reason='validation 202611030002' and a.actor_auth_user_id=auth.uid()),'Change is in audit_log with who made it');

-- Saving without changing the role does not touch the login.
select is((pg_temp.save_role((select staff_id from _t),'GENERAL_OPERATIVE')->>'login_job_title_updated'),'false'::text,'Save without role change leaves the login alone');

-- Supervisor: may promote a General Operative to Team Leader, not to Production Manager.
select set_config('request.jwt.claims',json_build_object('sub',(select auth_user_id from public.account_access_profiles where job_title_code='PRODUCTION_SUPERVISOR' and account_type='USER' limit 1),'role','authenticated')::text,true);
select throws_ok(format($q$select pg_temp.save_role(%L::uuid,'PRODUCTION_MANAGER')$q$,(select staff_id from _t)),'42501',null,'Supervisor cannot make anyone Production Manager');
select is((select r.role_code from public.staff_members sm join public.operational_roles r on r.operational_role_id=sm.primary_operational_role_id join _t using(staff_id)),'GENERAL_OPERATIVE'::text,'Refused save changed nothing in Staff Master');
select is((pg_temp.save_role((select staff_id from _t),'TEAM_LEADER')->>'login_job_title_code'),'TEAM_LEADER'::text,'Supervisor makes a General Operative a Team Leader, login follows');

select * from finish();
rollback;
