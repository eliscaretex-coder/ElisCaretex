begin;
select plan(29);

-- Static checks
select has_function('public','transfer_staff_to_distribution_driver',array['uuid','integer','uuid','text','text','text','text','text[]','date','date','text','text','text','date'],'transfer takes the first day as Driver');
select ok(not exists(select 1 from pg_proc where proname = 'transfer_staff_to_distribution_driver' and pronargs = 13),'the old 13-argument version is gone');
select ok(not has_function_privilege('anon','public.transfer_staff_to_distribution_driver(uuid,integer,uuid,text,text,text,text,text[],date,date,text,text,text,date)','execute'),'anon cannot transfer');
select ok(not has_function_privilege('authenticated','public.production_roster_close_staff_from(uuid,date,text,text)','execute'),'closing a roster is internal');

-- Dates: a far week (W) keeps the test away from live rosters.
create temp table sdt_dates as
select public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 56 as w,
       public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 58 as e;

-- Accounts used by the test (rolled back at the end).
insert into auth.users(id, instance_id, aud, role, email) values
 ('00000000-0000-4000-8000-0000000001a1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','sdt-admin@example.invalid'),
 ('00000000-0000-4000-8000-0000000001a2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','sdt-operative@example.invalid');
insert into public.account_access_profiles(auth_user_id, account_type, display_name, job_title_code) values
 ('00000000-0000-4000-8000-0000000001a1','USER','SDT Admin','ADMINISTRATOR'),
 ('00000000-0000-4000-8000-0000000001a2','USER','SDT Operative','GENERAL_OPERATIVE');
insert into public.account_permission_grants(auth_user_id, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage)
select '00000000-0000-4000-8000-0000000001a1'::uuid, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage
from public.job_title_permission_templates where job_title_code = 'ADMINISTRATOR'
union all
select '00000000-0000-4000-8000-0000000001a2'::uuid, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage
from public.job_title_permission_templates where job_title_code = 'GENERAL_OPERATIVE';

-- Production staff: S moves to Driver, T stays, U moves today, V uses the old call.
select set_config('request.jwt.claims', null, true);
insert into public.staff_members(staff_id, employee_code, display_name, active, production_staff, roster_eligible, joined_on,
  primary_operational_role_id, default_area_id, default_shift_id)
select x.id::uuid, x.code, x.name, true, true, true, '2026-01-05',
  (select operational_role_id from public.operational_roles where role_code = 'GENERAL_OPERATIVE'),
  (select area_id from public.areas where area_code = 'FINISH'),
  (select shift_id from public.shifts where shift_code = 'MORNING')
from (values
  ('00000000-0000-4000-8000-0000000001b1','SDT-S','SDT Staff S'),
  ('00000000-0000-4000-8000-0000000001b2','SDT-T','SDT Staff T'),
  ('00000000-0000-4000-8000-0000000001b3','SDT-U','SDT Staff U'),
  ('00000000-0000-4000-8000-0000000001b4','SDT-V','SDT Staff V')
) x(id, code, name);

-- Rosters: W published (no draft), W+7 draft, W+14 published with a draft.
insert into public.roster_periods(roster_period_id, week_start)
select x.id::uuid, (select w from sdt_dates) + x.off from (values
  ('00000000-0000-4000-8000-0000000001c1', 0),
  ('00000000-0000-4000-8000-0000000001c2', 7),
  ('00000000-0000-4000-8000-0000000001c3', 14)) x(id, off);
insert into public.production_roster_versions(roster_version_id, roster_period_id, shift_id, version_number, status)
select x.id::uuid, x.period::uuid, (select shift_id from public.shifts where shift_code = 'MORNING'), x.n, 'DRAFT' from (values
  ('00000000-0000-4000-8000-0000000001d1','00000000-0000-4000-8000-0000000001c1',1),
  ('00000000-0000-4000-8000-0000000001d2','00000000-0000-4000-8000-0000000001c2',1),
  ('00000000-0000-4000-8000-0000000001d3','00000000-0000-4000-8000-0000000001c3',1)) x(id, period, n);
insert into public.production_roster_entries(roster_version_id, work_date, staff_id, day_status, assignment_type,
  operational_role_id, area_id, staff_display_name_snapshot, shift_code_snapshot, shift_name_snapshot,
  operational_role_code_snapshot, area_code_snapshot)
select v.id::uuid, rp.week_start + d, s.id::uuid, 'WORKING', 'BASE',
  (select operational_role_id from public.operational_roles where role_code = 'GENERAL_OPERATIVE'),
  (select area_id from public.areas where area_code = 'FINISH'),
  s.name, 'MORNING', 'Morning', 'GENERAL_OPERATIVE', 'FINISH'
from (values ('00000000-0000-4000-8000-0000000001d1'),('00000000-0000-4000-8000-0000000001d2'),
             ('00000000-0000-4000-8000-0000000001d3')) v(id)
join public.production_roster_versions prv on prv.roster_version_id = v.id::uuid
join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
cross join generate_series(0, 5) d
cross join (values ('00000000-0000-4000-8000-0000000001b1','SDT Staff S'),('00000000-0000-4000-8000-0000000001b2','SDT Staff T')) s(id, name);
update public.production_roster_versions set status = 'PUBLISHED', published_at = now()
where roster_version_id in ('00000000-0000-4000-8000-0000000001d1','00000000-0000-4000-8000-0000000001d3');
-- Week W+14 also has a draft (version 2) based on its published version.
insert into public.production_roster_versions(roster_version_id, roster_period_id, shift_id, version_number, status, based_on_version_id)
values ('00000000-0000-4000-8000-0000000001d4','00000000-0000-4000-8000-0000000001c3',(select shift_id from public.shifts where shift_code = 'MORNING'),2,'DRAFT','00000000-0000-4000-8000-0000000001d3');
insert into public.production_roster_entries(roster_version_id, work_date, staff_id, day_status, assignment_type,
  operational_role_id, area_id, staff_display_name_snapshot, shift_code_snapshot, shift_name_snapshot,
  operational_role_code_snapshot, area_code_snapshot)
select '00000000-0000-4000-8000-0000000001d4', work_date, staff_id, day_status, assignment_type,
  operational_role_id, area_id, staff_display_name_snapshot, shift_code_snapshot, shift_name_snapshot,
  operational_role_code_snapshot, area_code_snapshot
from public.production_roster_entries where roster_version_id = '00000000-0000-4000-8000-0000000001d3';

-- A general operative cannot transfer.
select set_config('request.jwt.claims', json_build_object('sub','00000000-0000-4000-8000-0000000001a2','role','authenticated')::text, true);
select throws_ok($$select public.transfer_staff_to_distribution_driver('00000000-0000-4000-8000-0000000001b1', (select row_version from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000001b1'), null, 'SDT-DRV-S', '0870000000', null, 'L1', array['C'], current_date + 400, current_date + 400, null, 'test', 'TEST', (select e from sdt_dates))$$, '42501', null, 'a general operative cannot transfer');

select set_config('request.jwt.claims', json_build_object('sub','00000000-0000-4000-8000-0000000001a1','role','authenticated')::text, true);
select throws_ok($$select public.transfer_staff_to_distribution_driver('00000000-0000-4000-8000-0000000001b1', (select row_version from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000001b1'), null, 'SDT-DRV-S', '0870000000', null, 'L1', array['C'], current_date + 400, current_date + 400, null, 'test', 'TEST', current_date - 3)$$, '22023', null, 'the first day as Driver cannot be in the past');

-- S becomes a Driver on Wednesday of week W.
create temp table sdt_result as
select public.transfer_staff_to_distribution_driver('00000000-0000-4000-8000-0000000001b1', (select row_version from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000001b1'), null, 'SDT-DRV-S', '0870000000', null, 'L1', array['C'], current_date + 400, current_date + 400, null, 'Moves to Driver', 'TEST', (select e from sdt_dates)) as r;

select is((select (r->>'first_day_as_driver')::date from sdt_result), (select e from sdt_dates), 'the result returns the first day as Driver');
select is((select production_roster_until from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000001b1'), (select e - 1 from sdt_dates), 'Production ends the day before');
select ok((select production_staff from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000001b1'), 'the Staff Master record stays in Production until the date');
select is((select joined_on from public.distribution_drivers where staff_id = '00000000-0000-4000-8000-0000000001b1'), (select e from sdt_dates), 'the Driver starts on the date');

-- Week W: published, no draft -> new published version, old one kept.
select is((select status from public.production_roster_versions where roster_version_id = '00000000-0000-4000-8000-0000000001d1'), 'SUPERSEDED', 'the published week W is kept as SUPERSEDED');
select is((select count(*)::int from public.production_roster_versions where roster_period_id = '00000000-0000-4000-8000-0000000001c1' and status = 'PUBLISHED' and based_on_version_id = '00000000-0000-4000-8000-0000000001d1' and version_number = 2), 1, 'week W has a new published version 2');
select is((select count(*)::int from public.production_roster_entries where roster_version_id = '00000000-0000-4000-8000-0000000001d1' and staff_id = '00000000-0000-4000-8000-0000000001b1' and day_status = 'WORKING'), 6, 'the old version still has S working all week');
select is((select string_agg(day_status, ',' order by work_date) from public.production_roster_entries pre join public.production_roster_versions prv using (roster_version_id) where prv.roster_period_id = '00000000-0000-4000-8000-0000000001c1' and prv.status = 'PUBLISHED' and pre.staff_id = '00000000-0000-4000-8000-0000000001b1'), 'WORKING,WORKING,OFF,OFF,OFF,OFF', 'in the new version S works Mon-Tue and is OFF from Wednesday');
select is((select count(*)::int from public.production_roster_entries pre join public.production_roster_versions prv using (roster_version_id) where prv.roster_period_id = '00000000-0000-4000-8000-0000000001c1' and prv.status = 'PUBLISHED' and pre.staff_id = '00000000-0000-4000-8000-0000000001b2' and pre.day_status = 'WORKING'), 6, 'T is unchanged in the new version');
select ok(exists(select 1 from public.production_roster_events pe join public.production_roster_versions prv using (roster_version_id) where prv.roster_period_id = '00000000-0000-4000-8000-0000000001c1' and prv.status = 'PUBLISHED' and pe.event_type = 'PUBLISHED'), 'the new version has a PUBLISHED event');

-- Week W+7: draft loses S, keeps T.
select is((select count(*)::int from public.production_roster_entries where roster_version_id = '00000000-0000-4000-8000-0000000001d2' and staff_id = '00000000-0000-4000-8000-0000000001b1'), 0, 'the later draft no longer has S');
select is((select count(*)::int from public.production_roster_entries where roster_version_id = '00000000-0000-4000-8000-0000000001d2' and staff_id = '00000000-0000-4000-8000-0000000001b2'), 6, 'the later draft keeps T');

-- Week W+14: the draft changes, the published version waits for it.
select is((select count(*)::int from public.production_roster_entries where roster_version_id = '00000000-0000-4000-8000-0000000001d4' and staff_id = '00000000-0000-4000-8000-0000000001b1'), 0, 'with a draft, only the draft changes');
select is((select status from public.production_roster_versions where roster_version_id = '00000000-0000-4000-8000-0000000001d3'), 'PUBLISHED', 'the published version with a draft is left for the draft to replace');

-- Production Roster check: no working day after the last Production day.
insert into public.production_roster_versions(roster_version_id, roster_period_id, shift_id, version_number, status)
values ('00000000-0000-4000-8000-0000000001d5','00000000-0000-4000-8000-0000000001c1',(select shift_id from public.shifts where shift_code = 'MORNING'),3,'DRAFT');
insert into public.production_roster_entries(roster_version_id, work_date, staff_id, day_status, assignment_type, operational_role_id, area_id, staff_display_name_snapshot, shift_code_snapshot, shift_name_snapshot)
values ('00000000-0000-4000-8000-0000000001d5',(select e + 1 from sdt_dates),'00000000-0000-4000-8000-0000000001b1','WORKING','BASE',
  (select operational_role_id from public.operational_roles where role_code = 'GENERAL_OPERATIVE'),(select area_id from public.areas where area_code = 'FINISH'),'SDT Staff S','MORNING','Morning');
select throws_ok($$select public.production_roster_assert_operational_rules('00000000-0000-4000-8000-0000000001d5')$$, '22023', null, 'a working day after the last Production day is rejected');

-- Driver Roster: shown from the week of the first day, days before blocked.
select ok(not exists(select 1 from jsonb_array_elements(public.get_distribution_roster_week((select w - 7 from sdt_dates), null)->'drivers') d where d->>'staff_id' = '00000000-0000-4000-8000-0000000001b1'), 'the Driver is not in the week before');
select ok(exists(select 1 from jsonb_array_elements(public.get_distribution_roster_week((select w from sdt_dates), null)->'drivers') d where d->>'staff_id' = '00000000-0000-4000-8000-0000000001b1'), 'the Driver is in the week of the first day');
select throws_ok($$select public.save_distribution_roster_week(jsonb_build_object('week_start', (select w from sdt_dates), 'entries', jsonb_build_array(jsonb_build_object('work_date', (select w from sdt_dates), 'assignment_status', 'OFF', 'primary_driver_id', (select driver_id from public.distribution_drivers where staff_id = '00000000-0000-4000-8000-0000000001b1')))))$$, '22023', null, 'the Driver Roster rejects a day before the first day');
select lives_ok($$select public.save_distribution_roster_week(jsonb_build_object('week_start', (select w from sdt_dates), 'entries', jsonb_build_array(jsonb_build_object('work_date', (select e from sdt_dates), 'assignment_status', 'OFF', 'primary_driver_id', (select driver_id from public.distribution_drivers where staff_id = '00000000-0000-4000-8000-0000000001b1')))))$$, 'the Driver Roster accepts the first day');

-- U starts today: the move completes at once.
select is((select (public.transfer_staff_to_distribution_driver('00000000-0000-4000-8000-0000000001b3', (select row_version from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000001b3'), null, 'SDT-DRV-U', '0870000001', null, 'L2', array['C'], current_date + 400, current_date + 400, null, 'Moves today', 'TEST', (now() at time zone 'Europe/Dublin')::date)->>'completed_now')::boolean), true, 'a transfer that starts today completes now');
select is((select production_staff::text || ':' || (select role_code from public.operational_roles r where r.operational_role_id = sm.primary_operational_role_id) from public.staff_members sm where staff_id = '00000000-0000-4000-8000-0000000001b3'), 'false:DRIVER', 'U left Production as a Driver');

-- V: an older screen without the date starts next Monday.
select lives_ok($$select public.transfer_staff_to_distribution_driver(p_staff_id => '00000000-0000-4000-8000-0000000001b4', p_expected_row_version => (select row_version from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000001b4'), p_existing_driver_id => null, p_driver_code => 'SDT-DRV-V', p_phone => '0870000002', p_email => null, p_licence_number => 'L3', p_licence_categories => array['C'], p_licence_expires_on => current_date + 400, p_cpc_expires_on => current_date + 400, p_notes => null, p_change_reason => 'Old screen', p_source_application => 'TEST')$$, 'the call without a date still works');
select is((select production_roster_until from public.staff_members where staff_id = '00000000-0000-4000-8000-0000000001b4'), public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 6, 'without a date Production ends this Sunday');

select * from finish();
rollback;
