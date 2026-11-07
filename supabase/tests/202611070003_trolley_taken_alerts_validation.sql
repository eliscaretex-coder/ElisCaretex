begin;
select plan(4);
select has_function('public','get_trolley_taken_alerts_v1',array['text'],'get_trolley_taken_alerts_v1 exists');
select ok(not has_function_privilege('anon','public.get_trolley_taken_alerts_v1(text)','execute'),'anon cannot call get_trolley_taken_alerts_v1');
select ok(has_function_privilege('authenticated','public.get_trolley_taken_alerts_v1(text)','execute'),'signed-in production accounts can call it');
select ok(pg_get_functiondef('public.get_trolley_taken_alerts_v1(text)'::regprocedure) like '%require_production_flow_read_role%','checks the production read role');
select * from finish();
rollback;
