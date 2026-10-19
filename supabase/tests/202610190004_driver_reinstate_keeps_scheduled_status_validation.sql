begin;
select plan(4);
select has_function('public','reinstate_distribution_driver',array['uuid','integer','text'],'driver reinstate RPC exists');
select ok(not has_function_privilege('anon','public.reinstate_distribution_driver(uuid,integer,text)','execute'),'anon cannot reinstate drivers');
select ok(pg_get_functiondef('public.reinstate_distribution_driver(uuid,integer,text)'::regprocedure) like '%require_distribution_master_access%','reinstate requires Distribution master access');
select ok(pg_get_functiondef('public.reinstate_distribution_driver(uuid,integer,text)'::regprocedure) like '%when v_before.employment_status = ''INACTIVE'' then ''ACTIVE'' else d.employment_status end%','a scheduled exit keeps the current employment status');
select * from finish();
rollback;
