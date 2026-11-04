-- Validation for 202611040003_production_trolley_check_mop_detail.sql
-- Run against ElisCaretex-dev after the migration. Everything is rolled back.
begin;
select plan(6);

select has_function('public','production_trolley_check_expected',array['date'],'production_trolley_check_expected exists');
select ok(not has_function_privilege('authenticated','public.production_trolley_check_expected(date)','execute'),'expected helper stays internal (authenticated)');
select ok(not has_function_privilege('anon','public.production_trolley_check_expected(date)','execute'),'expected helper stays internal (anon)');
select ok(pg_get_functiondef('public.production_trolley_check_expected(date)'::regprocedure) like '%mop_lines%','expected returns MOP lines');
select ok(pg_get_functiondef('public.production_trolley_check_expected(date)'::regprocedure) like '%mop_abs_recorded%','expected returns ABS status');
select ok(pg_get_functiondef('public.production_trolley_check_expected(date)'::regprocedure) like '%planned_by_source%','expected keeps planned trolleys per area');

select * from finish();
rollback;
