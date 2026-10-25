begin;
select plan(17);

select has_function('public','prepare_driver_role_transfer_staff',array['uuid'],'prepare function exists');
select ok(not has_function_privilege('authenticated','public.prepare_driver_role_transfer_staff(uuid)','execute'),'prepare is internal');
select ok(not has_function_privilege('authenticated','public.revert_driver_role_transfer_staff(uuid)','execute'),'revert is internal');

create temp table dps_dates as
select public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 14 as w;

-- An Administrator approves (an existing ADMIN account, rolled back at the end).
select set_config('request.jwt.claims', null, true);

-- Driver A has a non-production Staff Master record; driver B has none.
insert into public.staff_members(staff_id, employee_code, display_name, active, production_staff, joined_on)
values ('00000000-0000-4000-8000-0000000002b1','DPS-A','DPS Driver A',true,false,'2026-01-05');
update public.staff_members set
  production_staff = false,
  primary_operational_role_id = (select operational_role_id from public.operational_roles where role_code = 'DRIVER'),
  default_area_id = (select area_id from public.areas where area_code = 'DISTRIBUTION')
where staff_id = '00000000-0000-4000-8000-0000000002b1';
insert into public.distribution_drivers(driver_id, driver_code, display_name, joined_on, staff_id) values
 ('00000000-0000-4000-8000-0000000002d1','DPS-001','DPS Driver A','2026-01-05','00000000-0000-4000-8000-0000000002b1'),
 ('00000000-0000-4000-8000-0000000002d2','DPS-002','DPS Driver B','2026-01-05',null);
insert into public.distribution_driver_role_transfers(transfer_id, driver_id, staff_id, last_driver_day, job_title_code, reason) values
 ('00000000-0000-4000-8000-0000000002f1','00000000-0000-4000-8000-0000000002d1','00000000-0000-4000-8000-0000000002b1',(select w + 1 from dps_dates),'CLEANER','test'),
 ('00000000-0000-4000-8000-0000000002f2','00000000-0000-4000-8000-0000000002d2',null,(select w + 1 from dps_dates),'GENERAL_OPERATIVE','test');

select set_config('request.jwt.claims', json_build_object('sub',(select ar.auth_user_id from public.account_roles ar join public.roles r on r.role_id = ar.role_id where r.role_code = 'ADMIN' and ar.active limit 1),'role','authenticated')::text, true);
select lives_ok($$select public.approve_driver_role_transfer('00000000-0000-4000-8000-0000000002f1', null, 'CLEANER', 'FINISH', null, 'MORNING', true, null)$$, 'approve A');
select lives_ok($$select public.approve_driver_role_transfer('00000000-0000-4000-8000-0000000002f2', null, 'GENERAL_OPERATIVE', 'FINISH', null, 'MORNING', true, null)$$, 'approve B');

select is((select production_staff::text || ':' || production_roster_from::text from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000002b1'), 'true:' || (select w + 2 from dps_dates)::text, 'A is Production staff from the first day');
select is((select (select role_code from public.operational_roles r where r.operational_role_id = sm.primary_operational_role_id) from public.staff_members sm where staff_id = '00000000-0000-4000-8000-0000000002b1'), 'CLEANER', 'A has the approved role');
select ok((select staff_prepared_created and staff_id is not null from public.distribution_driver_role_transfers where transfer_id = '00000000-0000-4000-8000-0000000002f2'), 'a Staff Master record is created for B');
select ok((select staff_id from public.distribution_drivers where driver_id = '00000000-0000-4000-8000-0000000002d1') = '00000000-0000-4000-8000-0000000002b1', 'A stays linked to the driver until the day');

-- Production Roster pool.
select ok(exists(select 1 from jsonb_array_elements(public.get_production_roster_staff_pool((select w from dps_dates), 'MORNING', null)->'staff') s where s->>'staff_id' = '00000000-0000-4000-8000-0000000002b1' and s->>'production_roster_from' = (select w + 2 from dps_dates)::text), 'A is offered for the week of the first day, with the date');
select ok(not exists(select 1 from jsonb_array_elements(public.get_production_roster_staff_pool((select w - 7 from dps_dates), 'MORNING', null)->'staff') s where s->>'staff_id' = '00000000-0000-4000-8000-0000000002b1'), 'A is not offered the week before');

-- Production Roster check: no working day before the first day.
insert into public.roster_periods(roster_period_id, week_start) values ('00000000-0000-4000-8000-0000000002c1', (select w from dps_dates));
insert into public.production_roster_versions(roster_version_id, roster_period_id, shift_id, version_number, status)
values ('00000000-0000-4000-8000-0000000002e1','00000000-0000-4000-8000-0000000002c1',(select shift_id from public.shifts where shift_code = 'MORNING'),1,'DRAFT');
insert into public.production_roster_entries(roster_version_id, work_date, staff_id, day_status, assignment_type, operational_role_id, area_id, staff_display_name_snapshot, shift_code_snapshot, shift_name_snapshot)
values ('00000000-0000-4000-8000-0000000002e1', (select w + 1 from dps_dates), '00000000-0000-4000-8000-0000000002b1', 'WORKING', 'BASE',
  (select operational_role_id from public.operational_roles where role_code = 'CLEANER'), (select area_id from public.areas where area_code = 'FINISH'), 'DPS Driver A', 'MORNING', 'Morning');
select throws_ok($$select public.production_roster_assert_operational_rules('00000000-0000-4000-8000-0000000002e1')$$, '22023', null, 'a working day before the first Production day is rejected');

-- Cancelling restores A and removes B's new record.
select lives_ok($$select public.cancel_driver_role_transfer('00000000-0000-4000-8000-0000000002f1', null, 'Not now'), public.cancel_driver_role_transfer('00000000-0000-4000-8000-0000000002f2', null, 'Not now')$$, 'cancel both');
select is((select production_staff::text || ':' || coalesce(production_roster_from::text,'-') || ':' || (select role_code from public.operational_roles r where r.operational_role_id = sm.primary_operational_role_id) from public.staff_members sm where staff_id = '00000000-0000-4000-8000-0000000002b1'), 'false:-:DRIVER', 'A is back to Driver');
select ok((select deleted_at is not null from public.staff_members where staff_id = (select staff_id from public.distribution_driver_role_transfers where transfer_id = '00000000-0000-4000-8000-0000000002f2')), 'B''s record created for the transfer is removed');

-- Applying a prepared transfer clears the start date.
insert into public.distribution_drivers(driver_id, driver_code, display_name, joined_on) values ('00000000-0000-4000-8000-0000000002d3','DPS-003','DPS Driver C','2026-01-05');
insert into public.distribution_driver_role_transfers(transfer_id, driver_id, last_driver_day, job_title_code, reason)
values ('00000000-0000-4000-8000-0000000002f3','00000000-0000-4000-8000-0000000002d3',(select w + 1 from dps_dates),'LABEL_OPERATIVE','test');
select lives_ok($$select public.approve_driver_role_transfer('00000000-0000-4000-8000-0000000002f3', null, 'LABEL', 'FINISH', null, 'MORNING', true, null), public.apply_driver_role_transfer('00000000-0000-4000-8000-0000000002f3')$$, 'approve and apply C');
select is((select t.transfer_status || ':' || coalesce(sm.production_roster_from::text, '-') from public.distribution_driver_role_transfers t join public.staff_members sm on sm.staff_id = t.staff_id where t.transfer_id = '00000000-0000-4000-8000-0000000002f3'), 'COMPLETED:-', 'the applied transfer clears the start date and reuses the prepared record');

select * from finish();
rollback;
