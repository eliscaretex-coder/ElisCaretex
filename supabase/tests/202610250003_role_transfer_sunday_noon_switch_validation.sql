begin;
select plan(13);

-- When a role transfer takes effect.
select is(public.role_transfer_switch_at('2026-11-02'), '2026-11-01 12:00:00+00'::timestamptz, 'Monday start (winter): Sunday 12:00 Dublin');
select is(public.role_transfer_switch_at('2026-07-06'), '2026-07-05 11:00:00+00'::timestamptz, 'Monday start (summer): Sunday 12:00 Dublin');
select is(public.role_transfer_switch_at('2026-11-04'), '2026-11-04 00:00:00+00'::timestamptz, 'Other days: midnight Dublin on the first day');

select ok(not has_function_privilege('authenticated','public.apply_account_job_title_template(uuid,text,uuid)','execute'), 'account job title helper is internal');
select ok(not has_function_privilege('authenticated','public.process_driver_role_transfers()','execute'), 'driver role transfer job is internal');
select ok(not has_function_privilege('authenticated','public.process_production_roster_exits()','execute'), 'production roster exit job is internal');
select is((select string_agg(jobname || '=' || schedule, ',' order by jobname) from cron.job where jobname in ('driver-role-transfers','production-roster-exits')),
  'driver-role-transfers=8 * * * *,production-roster-exits=7 * * * *', 'both jobs run every hour');

create temp table rts_dates as select (now() at time zone 'Europe/Dublin')::date as today;

-- Driver -> Cleaner: one transfer past its switch moment, one in the future.
select set_config('request.jwt.claims', null, true);
insert into public.distribution_drivers(driver_id, driver_code, display_name, joined_on) values
 ('00000000-0000-4000-8000-0000000003d1','RTS-001','RTS Driver A','2026-01-05'),
 ('00000000-0000-4000-8000-0000000003d2','RTS-002','RTS Driver B','2026-01-05');
insert into public.distribution_driver_role_transfers(transfer_id, driver_id, last_driver_day, job_title_code, reason) values
 ('00000000-0000-4000-8000-0000000003f1','00000000-0000-4000-8000-0000000003d1',(select today + 3 from rts_dates),'CLEANER','test'),
 ('00000000-0000-4000-8000-0000000003f2','00000000-0000-4000-8000-0000000003d2',(select today + 3 from rts_dates),'CLEANER','test');
select set_config('request.jwt.claims', json_build_object('sub',(select ar.auth_user_id from public.account_roles ar join public.roles r on r.role_id = ar.role_id where r.role_code = 'ADMIN' and ar.active limit 1),'role','authenticated')::text, true);
select public.approve_driver_role_transfer('00000000-0000-4000-8000-0000000003f1', null, 'CLEANER', 'FINISH', null, 'MORNING', true, null);
select public.approve_driver_role_transfer('00000000-0000-4000-8000-0000000003f2', null, 'CLEANER', 'FINISH', null, 'MORNING', true, null);
select set_config('request.jwt.claims', null, true);
-- A's last driver day is moved to yesterday (its switch moment has passed).
update public.distribution_driver_role_transfers set last_driver_day = (select today - 1 from rts_dates) where transfer_id = '00000000-0000-4000-8000-0000000003f1';
update public.distribution_drivers set deactivated_on = (select today - 1 from rts_dates) where driver_id = '00000000-0000-4000-8000-0000000003d1';
select public.process_driver_role_transfers();
select is((select transfer_status from public.distribution_driver_role_transfers where transfer_id = '00000000-0000-4000-8000-0000000003f1'), 'COMPLETED', 'a transfer past its switch moment is applied');
select is((select transfer_status from public.distribution_driver_role_transfers where transfer_id = '00000000-0000-4000-8000-0000000003f2'), 'APPROVED', 'a transfer before its switch moment waits');

-- Staff -> Driver: a Cleaner login becomes Driver when Staff Master moves.
insert into auth.users(id, instance_id, aud, role, email) values
 ('00000000-0000-4000-8000-0000000003a1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rts-a@example.invalid'),
 ('00000000-0000-4000-8000-0000000003a2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rts-b@example.invalid');
insert into public.account_access_profiles(auth_user_id, account_type, display_name, job_title_code) values
 ('00000000-0000-4000-8000-0000000003a1','USER','RTS Staff A','CLEANER'),
 ('00000000-0000-4000-8000-0000000003a2','USER','RTS Staff B','CLEANER')
on conflict (auth_user_id) do update set account_type = excluded.account_type, display_name = excluded.display_name, job_title_code = excluded.job_title_code;
select public.apply_account_job_title_template('00000000-0000-4000-8000-0000000003a1','CLEANER',null);
insert into public.staff_members(staff_id, employee_code, display_name, active, production_staff, roster_eligible, joined_on, auth_user_id,
  primary_operational_role_id, default_area_id, default_shift_id)
select v.staff_id, v.code, v.name, true, true, true, '2026-01-05', v.auth_user_id,
  (select operational_role_id from public.operational_roles where role_code = 'CLEANER'),
  (select area_id from public.areas where area_code = 'FINISH'),
  (select shift_id from public.shifts where shift_code = 'MORNING')
from (values
  ('00000000-0000-4000-8000-0000000003b1'::uuid,'RTS-A','RTS Staff A','00000000-0000-4000-8000-0000000003a1'::uuid),
  ('00000000-0000-4000-8000-0000000003b2'::uuid,'RTS-B','RTS Staff B','00000000-0000-4000-8000-0000000003a2'::uuid)
) v(staff_id, code, name, auth_user_id);
insert into public.distribution_drivers(driver_id, driver_code, display_name, joined_on, staff_id) values
 ('00000000-0000-4000-8000-0000000003d3','RTS-003','RTS Staff A',(select today from rts_dates),'00000000-0000-4000-8000-0000000003b1'),
 ('00000000-0000-4000-8000-0000000003d4','RTS-004','RTS Staff B',(select today + 4 from rts_dates),'00000000-0000-4000-8000-0000000003b2');
update public.staff_members set production_roster_until = (select today - 1 from rts_dates) where staff_id = '00000000-0000-4000-8000-0000000003b1';
update public.staff_members set production_roster_until = (select today + 3 from rts_dates) where staff_id = '00000000-0000-4000-8000-0000000003b2';
select public.process_production_roster_exits();
select is((select production_staff::text || ':' || (select role_code from public.operational_roles r where r.operational_role_id = sm.primary_operational_role_id) from public.staff_members sm where staff_id = '00000000-0000-4000-8000-0000000003b1'), 'false:DRIVER', 'Staff Master moves to Driver after the switch moment');
select is((select job_title_code from public.account_access_profiles where auth_user_id = '00000000-0000-4000-8000-0000000003a1'), 'DRIVER', 'the Cleaner login becomes Driver');
select ok(exists(select 1 from public.account_permission_grants where auth_user_id = '00000000-0000-4000-8000-0000000003a1' and module_code = 'MY_DRIVER_ROSTER' and active)
  and not exists(select 1 from public.account_permission_grants where auth_user_id = '00000000-0000-4000-8000-0000000003a1' and module_code = 'MY_ROSTER' and active), 'the login sees My Driver Roster instead of My Roster');
select is((select job_title_code || ':' || (select production_staff::text from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000003b2') from public.account_access_profiles where auth_user_id = '00000000-0000-4000-8000-0000000003a2'), 'CLEANER:true', 'a move before its switch moment waits');

select * from finish();
rollback;
