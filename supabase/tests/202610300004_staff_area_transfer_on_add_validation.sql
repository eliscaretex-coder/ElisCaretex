-- Validation for 202610300004_staff_area_transfer_on_add.sql.
-- Run manually against the development project after the migration is applied.
-- The full scenario test (transfers between Sorting, Tables and Label, returns and the
-- Finish context) is delivered with the change as a self-rolling-back DO block.
begin;
select plan(12);

select has_function('public', 'staff_area_presence_v1', array['uuid', 'text', 'time']);
select has_function('public', 'staff_area_transfer_plan_v1', array['uuid', 'text', 'text', 'text', 'time']);
select has_function('public', 'get_staff_area_transfer_check_v1', array['uuid', 'text', 'text', 'text', 'time']);
select has_function('public', 'transfer_staff_into_area_v1', array['uuid', 'text', 'text', 'text', 'time', 'text', 'boolean']);
select has_function('public', 'terminal_transfer_staff_into_area_v1', array['uuid', 'text', 'text', 'text', 'time', 'text', 'boolean']);

select ok(not has_function_privilege('authenticated', 'public.staff_area_presence_v1(uuid,text,time)', 'execute'),
  'presence helper is internal');
select ok(not has_function_privilege('authenticated', 'public.staff_area_transfer_plan_v1(uuid,text,text,text,time)', 'execute'),
  'transfer plan helper is internal');
select ok(not has_function_privilege('anon', 'public.transfer_staff_into_area_v1(uuid,text,text,text,time,text,boolean)', 'execute'),
  'anon cannot transfer staff');
select ok(not has_function_privilege('anon', 'public.get_staff_area_transfer_check_v1(uuid,text,text,text,time)', 'execute'),
  'anon cannot check transfers');
select ok(has_function_privilege('authenticated', 'public.get_staff_area_transfer_check_v1(uuid,text,text,text,time)', 'execute'),
  'signed-in users can check transfers (access is checked inside)');

select ok(exists (select 1 from public.stations where station_code = 'FINISH_CLEANER' and active),
  'Finish Cleaner station exists');
select ok(exists (
  select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid
  where t.tgrelid = 'public.work_sessions'::regclass and t.tgname = 'work_sessions_set_updated_at'
    and p.proname = 'work_sessions_set_updated_at_v2'),
  'work_sessions keeps transfer write order');

select * from finish();
rollback;
