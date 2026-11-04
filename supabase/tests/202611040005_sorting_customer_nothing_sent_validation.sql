-- Validation for 202611040005_sorting_customer_nothing_sent.sql (pgTAP, no data written).
begin;
select plan(12);

select has_table('public','sorting_customer_nothing_sent','table exists');
select ok((select relrowsecurity from pg_class where oid='public.sorting_customer_nothing_sent'::regclass),'RLS enabled');
select ok(not has_table_privilege('authenticated','public.sorting_customer_nothing_sent','select'),'authenticated cannot read the table directly');

select has_function('public','get_sorting_customer_nothing_sent',array['date','date'],'read rpc exists');
select has_function('public','terminal_record_sorting_customer_nothing_sent',array['text','uuid','date','uuid','text'],'terminal record rpc exists');
select has_function('public','terminal_cancel_sorting_customer_nothing_sent',array['uuid','text'],'terminal cancel rpc exists');

select ok(not has_function_privilege('anon','public.get_sorting_customer_nothing_sent(date,date)','execute'),'anon cannot read');
select ok(not has_function_privilege('authenticated','public.record_sorting_customer_nothing_sent(text,uuid,date,uuid,text)','execute'),'inner record rpc is not callable by users');
select ok(not has_function_privilege('authenticated','public.cancel_sorting_customer_nothing_sent(uuid,text)','execute'),'inner cancel rpc is not callable by users');

select ok(pg_get_functiondef('public.get_sorting_customer_nothing_sent(date,date)'::regprocedure) like '%require_sorting_operational_access%','read checks Sorting permission');
select ok(pg_get_functiondef('public.terminal_record_sorting_customer_nothing_sent(text,uuid,date,uuid,text)'::regprocedure) like '%require_production_terminal%','record requires the Sorting terminal');
select ok(pg_get_functiondef('public.terminal_cancel_sorting_customer_nothing_sent(uuid,text)'::regprocedure) like '%require_production_terminal%','cancel requires the Sorting terminal');

select * from finish();
rollback;
