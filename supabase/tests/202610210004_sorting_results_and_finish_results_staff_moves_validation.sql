begin;
select plan(9);

select has_function('public', 'get_sorting_results_dashboard_v1', array['date'], 'get_sorting_results_dashboard_v1 exists');
select ok(not has_function_privilege('anon', 'public.get_sorting_results_dashboard_v1(date)', 'execute'), 'anon cannot call get_sorting_results_dashboard_v1');
select ok(pg_get_functiondef('public.get_sorting_results_dashboard_v1(date)'::regprocedure) like '%require_sorting_operational_access%', 'Sorting Results checks Sorting access');
select ok(pg_get_functiondef('public.get_sorting_results_dashboard_v1(date)'::regprocedure) like '%status <> ''CANCELLED''%', 'Sorting Results ignores cancelled work sessions');

select ok(not has_function_privilege('anon', 'public.get_finish_results_dashboard_normal_v1(date)', 'execute'), 'anon cannot call get_finish_results_dashboard_normal_v1');
select ok(pg_get_functiondef('public.get_finish_results_dashboard_normal_v1(date)'::regprocedure) like '%require_finish_production_access%', 'Finish Results checks Finish access');
select ok(pg_get_functiondef('public.get_finish_results_dashboard_normal_v1(date)'::regprocedure) like '%finish_staff_table_segments%', 'Finish Results splits hours by table segments');
select ok(pg_get_functiondef('public.get_finish_results_dashboard_normal_v1(date)'::regprocedure) like '%finish_daily_staff_attendance%', 'Finish Results removes Finish absences');

-- Without a signed-in Sorting user the RPC is refused.
select throws_ok(
  $$select public.get_sorting_results_dashboard_v1('2026-09-25'::date)$$,
  null, null, 'Sorting Results refuses a caller without Sorting access'
);

select * from finish();
rollback;
