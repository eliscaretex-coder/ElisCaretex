-- Validation for 202611040001_production_trolley_shift_check.sql
-- Run against ElisCaretex-dev after the migration. Everything is rolled back.
begin;
select plan(16);

select has_table('public','production_trolley_checks','production_trolley_checks exists');
select has_table('public','production_trolley_check_items','production_trolley_check_items exists');
select ok((select relrowsecurity from pg_class where oid = 'public.production_trolley_checks'::regclass), 'checks: RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.production_trolley_check_items'::regclass), 'items: RLS enabled');
select ok(not has_table_privilege('authenticated','public.production_trolley_check_items','select'), 'authenticated cannot read items directly');

select has_function('public','get_production_trolley_check_v1',array['date','text'],'get_production_trolley_check_v1 exists');
select has_function('public','record_production_trolley_check_item',array['date','text','uuid','text','text[]','integer','integer','text'],'record_production_trolley_check_item exists');
select has_function('public','complete_production_trolley_check',array['uuid','text'],'complete_production_trolley_check exists');
select has_function('public','get_production_trolley_check_history_v1',array['date','date'],'get_production_trolley_check_history_v1 exists');

select ok(not has_function_privilege('anon','public.get_production_trolley_check_v1(date,text)','execute'),'anon cannot read the check');
select ok(not has_function_privilege('anon','public.record_production_trolley_check_item(date,text,uuid,text,text[],integer,integer,text)','execute'),'anon cannot record');
select ok(not has_function_privilege('authenticated','public.production_trolley_check_expected(date)','execute'),'expected helper is internal');

select ok(pg_get_functiondef('public.get_production_trolley_check_v1(date,text)'::regprocedure) like '%require_production_flow_read_role%','read checks Production Flow access');
select ok(pg_get_functiondef('public.record_production_trolley_check_item(date,text,uuid,text,text[],integer,integer,text)'::regprocedure) like '%require_production_trolley_check_write_access%','record checks write access');
select ok(pg_get_functiondef('public.require_production_trolley_check_write_access()'::regprocedure) like '%production_station_devices%','production terminals cannot sign a check');

-- Negative: anonymous call is refused
set local role anon;
select throws_ok($$select public.get_production_trolley_check_v1()$$, '42501', null, 'anonymous read is refused');
reset role;

select * from finish();
rollback;
