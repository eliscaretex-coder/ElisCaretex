begin;
select plan(40);

-- Static checks
select has_function('public','request_driver_role_transfer',array['uuid','integer','date','text','text'],'request_driver_role_transfer exists');
select has_function('public','approve_driver_role_transfer',array['uuid','integer','text','text','text','text','boolean','text'],'approve_driver_role_transfer exists');
select ok(not has_function_privilege('anon','public.request_driver_role_transfer(uuid,integer,date,text,text)','execute'),'anon cannot request a transfer');
select ok(not has_function_privilege('anon','public.approve_driver_role_transfer(uuid,integer,text,text,text,text,boolean,text)','execute'),'anon cannot approve a transfer');
select ok(not has_function_privilege('authenticated','public.apply_driver_role_transfer(uuid)','execute'),'apply is internal');
select ok(not has_function_privilege('authenticated','public.process_driver_role_transfers()','execute'),'the daily job is internal');
select ok(pg_get_functiondef('public.request_driver_role_transfer(uuid,integer,date,text,text)'::regprocedure) like '%require_distribution_master_access%','request checks Distribution MANAGE');
select ok(exists(select 1 from cron.job where jobname = 'driver-role-transfers'),'daily transfer job is scheduled');

-- Accounts used by the test (rolled back at the end).
insert into auth.users(id, instance_id, aud, role, email) values
 ('00000000-0000-4000-8000-0000000000d1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','drt-logistics@example.invalid'),
 ('00000000-0000-4000-8000-0000000000d2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','drt-production-manager@example.invalid'),
 ('00000000-0000-4000-8000-0000000000d3','00000000-0000-0000-0000-000000000000','authenticated','authenticated','drt-supervisor@example.invalid'),
 ('00000000-0000-4000-8000-0000000000d4','00000000-0000-0000-0000-000000000000','authenticated','authenticated','drt-driver@example.invalid');
insert into public.account_access_profiles(auth_user_id, account_type, display_name, job_title_code) values
 ('00000000-0000-4000-8000-0000000000d1','USER','DRT Logistics','LOGISTICS_MANAGER'),
 ('00000000-0000-4000-8000-0000000000d2','USER','DRT Production Manager','PRODUCTION_MANAGER'),
 ('00000000-0000-4000-8000-0000000000d3','USER','DRT Supervisor','PRODUCTION_SUPERVISOR'),
 ('00000000-0000-4000-8000-0000000000d4','USER','DRT Driver','DRIVER');
insert into public.account_permission_grants(auth_user_id, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage)
select '00000000-0000-4000-8000-0000000000d1'::uuid, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage
from public.job_title_permission_templates where job_title_code = 'LOGISTICS_MANAGER'
union all
select '00000000-0000-4000-8000-0000000000d2'::uuid, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage
from public.job_title_permission_templates where job_title_code = 'PRODUCTION_MANAGER'
union all
select '00000000-0000-4000-8000-0000000000d3'::uuid, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage
from public.job_title_permission_templates where job_title_code = 'PRODUCTION_SUPERVISOR'
union all
select '00000000-0000-4000-8000-0000000000d4'::uuid, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage
from public.job_title_permission_templates where job_title_code = 'DRIVER';

-- Drivers: two without Staff Master, one linked to a non-production staff record with a login, one to cancel.
select set_config('request.jwt.claims', null, true);
insert into public.staff_members(staff_id, employee_code, display_name, active, production_staff, auth_user_id, joined_on)
values ('00000000-0000-4000-8000-0000000000e4','DRT-STAFF-4','DRT Linked Driver',true,false,'00000000-0000-4000-8000-0000000000d4','2026-01-05');
update public.staff_members set
  primary_operational_role_id = (select operational_role_id from public.operational_roles where role_code = 'DRIVER'),
  default_area_id = (select area_id from public.areas where area_code = 'DISTRIBUTION'),
  production_staff = false
where staff_id = '00000000-0000-4000-8000-0000000000e4';
select ok(not (select production_staff from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000000e4'),'an update keeps production_staff = false although the record has a role');

insert into public.distribution_drivers(driver_id, driver_code, display_name, joined_on, staff_id) values
 ('00000000-0000-4000-8000-0000000000f1','DRT-001','DRT Driver One','2026-01-05',null),
 ('00000000-0000-4000-8000-0000000000f2','DRT-002','DRT Driver Two','2026-01-05',null),
 ('00000000-0000-4000-8000-0000000000f3','DRT-003','DRT Linked Driver','2026-01-05','00000000-0000-4000-8000-0000000000e4'),
 ('00000000-0000-4000-8000-0000000000f4','DRT-004','DRT Driver Four','2026-01-05',null);

-- A driver account cannot start a transfer.
select set_config('request.jwt.claims', json_build_object('sub','00000000-0000-4000-8000-0000000000d4','role','authenticated')::text, true);
select throws_ok($$select public.request_driver_role_transfer('00000000-0000-4000-8000-0000000000f1', null, current_date - 2, 'LABEL_OPERATIVE', 'test')$$, '42501', null, 'a driver account cannot request a transfer');

-- Distribution (Logistics Manager) requests.
select set_config('request.jwt.claims', json_build_object('sub','00000000-0000-4000-8000-0000000000d1','role','authenticated')::text, true);
select throws_ok($$select public.request_driver_role_transfer('00000000-0000-4000-8000-0000000000f1', null, current_date - 2, 'AUDITOR', 'test')$$, '22023', null, 'only the offered job titles are accepted');
select throws_ok($$select public.request_driver_role_transfer('00000000-0000-4000-8000-0000000000f1', null, current_date - 2, 'LABEL_OPERATIVE', ' ')$$, '22023', null, 'a reason is required');
select lives_ok($$select public.request_driver_role_transfer('00000000-0000-4000-8000-0000000000f1', null, current_date - 2, 'LABEL_OPERATIVE', 'Moves to Label')$$, 'Distribution requests a past-dated transfer');
select throws_ok($$select public.request_driver_role_transfer('00000000-0000-4000-8000-0000000000f1', null, current_date + 5, 'CLEANER', 'again')$$, '23505', null, 'only one open transfer per driver');
select lives_ok($$select public.request_driver_role_transfer('00000000-0000-4000-8000-0000000000f2', null, current_date + 3, 'PRODUCTION_MANAGER', 'Promotion')$$, 'Distribution requests a Production Manager transfer');
select lives_ok($$select public.request_driver_role_transfer('00000000-0000-4000-8000-0000000000f3', null, current_date + 3, 'TEAM_LEADER', 'Moves to Team Leader')$$, 'Distribution requests a transfer for a driver with a login');
select lives_ok($$select public.request_driver_role_transfer('00000000-0000-4000-8000-0000000000f4', null, current_date + 3, 'CLEANER', 'Moves to Cleaner')$$, 'Distribution requests a transfer it will cancel');
select is((select employment_status||':'||coalesce(deactivated_on::text,'-') from public.distribution_drivers where driver_id = '00000000-0000-4000-8000-0000000000f1'),'ACTIVE:-','a request alone does not change the driver');
select throws_ok($$select public.approve_driver_role_transfer((select transfer_id from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f1'), null, 'LABEL', 'FINISH', null, 'MORNING', true, null)$$, '42501', null, 'Distribution cannot approve');

-- A supervisor (Staff Master view and edit only) cannot approve.
select set_config('request.jwt.claims', json_build_object('sub','00000000-0000-4000-8000-0000000000d3','role','authenticated')::text, true);
select throws_ok($$select public.approve_driver_role_transfer((select transfer_id from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f1'), null, 'LABEL', 'FINISH', null, 'MORNING', true, null)$$, '42501', null, 'a supervisor cannot approve');

-- The Production Manager approves below their own rank only.
select set_config('request.jwt.claims', json_build_object('sub','00000000-0000-4000-8000-0000000000d2','role','authenticated')::text, true);
select throws_ok($$select public.approve_driver_role_transfer((select transfer_id from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f2'), null, 'PRODUCTION_MANAGER', 'FINISH', null, 'MORNING', true, null)$$, '42501', null, 'a Production Manager cannot approve a Production Manager transfer');
select throws_ok($$select public.approve_driver_role_transfer((select transfer_id from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f1'), null, 'DRIVER', 'FINISH', null, 'MORNING', true, null)$$, '22023', null, 'the new role cannot be Driver');
select lives_ok($$select public.approve_driver_role_transfer((select transfer_id from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f1'), null, 'LABEL', 'FINISH', null, 'MORNING', true, 'ok')$$, 'the Production Manager approves the past-dated transfer');
select is((select transfer_status from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f1'),'COMPLETED','a past last day applies at approval');
select is((select employment_status from public.distribution_drivers where driver_id = '00000000-0000-4000-8000-0000000000f1'),'INACTIVE','the driver has left Distribution');
select ok(exists(
  select 1 from public.distribution_driver_role_transfers t
  join public.staff_members sm on sm.staff_id = t.staff_id
  join public.operational_roles r on r.operational_role_id = sm.primary_operational_role_id
  where t.driver_id = '00000000-0000-4000-8000-0000000000f1' and sm.production_staff and sm.roster_eligible and sm.active and r.role_code = 'LABEL' and sm.employee_code like 'EMP-%'
),'a new production Staff Master record was created with the chosen role');
select is((select count(*)::integer from public.get_driver_role_transfers(false) -> 'transfers'),3,'open transfers are listed in Staff Master');

-- The Production Manager approves a future transfer for the driver with a login.
select lives_ok($$select public.approve_driver_role_transfer((select transfer_id from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f3'), null, 'TEAM_LEADER', 'SORTING', null, 'EVENING', true, null)$$, 'the Production Manager approves the future transfer');
select is((select transfer_status||':'||d.deactivated_on::text from public.distribution_driver_role_transfers t join public.distribution_drivers d on d.driver_id = t.driver_id where t.driver_id = '00000000-0000-4000-8000-0000000000f3'),'APPROVED:'||(current_date + 3)::text,'approval schedules the driver exit on the last driver day');
select ok((select active and deactivated_on is null from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000000e4'),'the linked Staff Master record is not deactivated');

-- Distribution cancels the fourth request.
select set_config('request.jwt.claims', json_build_object('sub','00000000-0000-4000-8000-0000000000d1','role','authenticated')::text, true);
select lives_ok($$select public.cancel_driver_role_transfer((select transfer_id from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f4'), null, 'Changed plans')$$, 'Distribution cancels an open transfer');
select is((select transfer_status from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f4'),'CANCELLED','the transfer is cancelled');

-- The daily job applies the approved transfer the day after the last driver day.
select set_config('request.jwt.claims', null, true);
update public.distribution_driver_role_transfers set last_driver_day = current_date - 1 where driver_id = '00000000-0000-4000-8000-0000000000f3';
update public.distribution_drivers set deactivated_on = current_date - 1 where driver_id = '00000000-0000-4000-8000-0000000000f3';
select is(public.process_driver_role_transfers(),1,'the daily job applies one transfer');
select ok((select sm.production_staff and sm.roster_eligible and r.role_code = 'TEAM_LEADER' and sm.production_roster_until is null
  from public.staff_members sm join public.operational_roles r on r.operational_role_id = sm.primary_operational_role_id
  where sm.staff_id = '00000000-0000-4000-8000-0000000000e4'),'the existing Staff Master record moves to Production as Team Leader');
select ok((select staff_id is null from public.distribution_drivers where driver_id = '00000000-0000-4000-8000-0000000000f3'),'the driver record is unlinked from the person');
select is((select job_title_code from public.account_access_profiles where auth_user_id = '00000000-0000-4000-8000-0000000000d4'),'TEAM_LEADER','the login gets the new job title');
select ok(exists(select 1 from public.account_permission_grants where auth_user_id = '00000000-0000-4000-8000-0000000000d4' and module_code = 'MY_ROSTER' and active)
  and not exists(select 1 from public.account_permission_grants g where g.auth_user_id = '00000000-0000-4000-8000-0000000000d4' and g.active
    and not exists(select 1 from public.job_title_permission_templates t where t.job_title_code = 'TEAM_LEADER' and t.module_code = g.module_code)),
  'the login has exactly the Team Leader permissions');

-- Admin approves the Production Manager transfer.
select set_config('request.jwt.claims', json_build_object('sub',(select ar.auth_user_id from public.account_roles ar join public.roles r on r.role_id = ar.role_id where r.role_code = 'ADMIN' and ar.active limit 1),'role','authenticated')::text, true);
select lives_ok($$select public.approve_driver_role_transfer((select transfer_id from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f2'), null, 'PRODUCTION_MANAGER', 'FINISH', null, null, false, null)$$, 'an Administrator approves any offered job title');
select lives_ok($$select public.cancel_driver_role_transfer((select transfer_id from public.distribution_driver_role_transfers where driver_id = '00000000-0000-4000-8000-0000000000f2'), null, 'Not now')$$, 'an approved transfer can be cancelled before it applies');
select is((select employment_status||':'||coalesce(deactivated_on::text,'-') from public.distribution_drivers where driver_id = '00000000-0000-4000-8000-0000000000f2'),'ACTIVE:-','cancelling an approved transfer clears the scheduled driver exit');

select * from finish();
rollback;
