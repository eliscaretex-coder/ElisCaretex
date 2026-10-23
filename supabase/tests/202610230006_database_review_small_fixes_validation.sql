begin;
select plan(6);

select ok(position(convert_from('\xc3a2e282ac'::bytea,'UTF8') in pg_get_functiondef('public.record_customer_driver_guide_event()'::regprocedure)) = 0,'guide history function has no mojibake');
select ok(pg_get_functiondef('public.record_customer_driver_guide_event()'::regprocedure) like '%%s — %s%s%','guide history uses an em dash');
select ok((select relrowsecurity from pg_class where oid='staging.dist1_import_rows'::regclass),'staging.dist1_import_rows has RLS');
select ok(not has_function_privilege('authenticated','public.get_customer_schedule_history(uuid)','execute'),'old get_customer_schedule_history overload closed');
select ok(has_function_privilege('authenticated','public.get_customer_schedule_history(uuid,uuid,date,integer)','execute'),'current get_customer_schedule_history still open');
select ok(not has_function_privilege('authenticated','public.terminal_correct_sorting_trolley_intake(uuid,uuid,date,text[],text,text)','execute'),'old terminal correction overload closed');

select * from finish();
rollback;
