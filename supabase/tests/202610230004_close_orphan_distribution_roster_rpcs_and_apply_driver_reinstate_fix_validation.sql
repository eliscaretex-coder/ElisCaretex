begin;
select plan(11);

select ok(not has_function_privilege('authenticated','public.save_distribution_roster_draft(date,jsonb,text,text)','execute'),'authenticated cannot call save_distribution_roster_draft');
select ok(not has_function_privilege('authenticated','public.publish_distribution_roster(date,text)','execute'),'authenticated cannot call publish_distribution_roster(date,text)');
select ok(not has_function_privilege('authenticated','public.get_distribution_roster_context(date)','execute'),'authenticated cannot call get_distribution_roster_context');
select ok(not has_function_privilege('authenticated','public.get_distribution_roster_history(date)','execute'),'authenticated cannot call get_distribution_roster_history');
select ok(not has_function_privilege('authenticated','public.require_distribution_roster_manage_access()','execute'),'authenticated cannot call require_distribution_roster_manage_access');
select ok(not has_function_privilege('anon','public.save_distribution_roster_draft(date,jsonb,text,text)','execute'),'anon cannot call save_distribution_roster_draft');

-- The current Distribution Roster path stays open.
select ok(has_function_privilege('authenticated','public.save_distribution_roster_week(jsonb)','execute'),'save_distribution_roster_week still callable');
select ok(has_function_privilege('authenticated','public.publish_distribution_roster_week(uuid,integer)','execute'),'publish_distribution_roster_week still callable');

select ok(pg_get_functiondef('public.reinstate_distribution_driver(uuid,integer,text)'::regprocedure) like '%when v_before.employment_status = ''INACTIVE'' then ''ACTIVE'' else d.employment_status end%','reinstate keeps the status of a scheduled exit');
select ok(pg_get_functiondef('public.reinstate_distribution_driver(uuid,integer,text)'::regprocedure) like '%require_distribution_master_access%','reinstate checks permission');
select ok(not has_function_privilege('anon','public.reinstate_distribution_driver(uuid,integer,text)','execute'),'anon cannot call reinstate_distribution_driver');

select * from finish();
rollback;
