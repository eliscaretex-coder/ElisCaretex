begin;
select plan(3);

select ok(pg_get_functiondef('public.publish_distribution_roster_week(uuid,integer)'::regprocedure) like '%ROSTER_REMOVED%','publish frees daily routes the new version no longer plans');
select ok(pg_get_functiondef('public.publish_distribution_roster_week(uuid,integer)'::regprocedure) like '%require_distribution_plan_access%','publish requires Distribution plan access');
select ok(not has_function_privilege('anon','public.publish_distribution_roster_week(uuid,integer)','execute'),'anon cannot publish rosters');

select * from finish();
rollback;
