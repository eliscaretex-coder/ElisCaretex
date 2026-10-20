begin;
select plan(10);

select ok(pg_get_functiondef('public.production_roster_assert_operational_rules(uuid)'::regprocedure) like '%between 1 and 2%','Roster accepts one or two dedicated MOP staff');
select ok(pg_get_functiondef('public.get_sorting_staff_work_context_v2(text)'::regprocedure) like '%v_actual_mop_count between 1 and 2%','Actual MOP coverage is DEDICATED with one or two MOP');
select ok(pg_get_functiondef('public.get_sorting_staff_work_context_v2(text)'::regprocedure) like '%''mop_staff_names''%','Work context lists every MOP staff');
select ok(pg_get_functiondef('public.get_sorting_staff_dashboard_context_v2(text)'::regprocedure) like '%v_effective_mop_count between 1 and 2%','Operational MOP coverage is DEDICATED with one or two MOP');
select ok(pg_get_functiondef('public.get_sorting_staff_dashboard_context_v2(text)'::regprocedure) like '%''operational_mop_staff''%','Dashboard context lists every operational MOP staff');
select ok(pg_get_functiondef('public.get_sorting_mop_production_context(text,timestamptz)'::regprocedure) like '%''operational_mop_staff''%','MOP production context lists every operational MOP staff');
select ok(pg_get_functiondef('public.set_sorting_staff_work_mode(text,uuid,text,text)'::regprocedure) like '%already has two Actual MOP staff%','A third Actual MOP is refused');
select ok(pg_get_functiondef('public.set_sorting_staff_work_mode(text,uuid,text,text)'::regprocedure) like '%require_sorting_operational_access%','set_sorting_staff_work_mode checks Sorting access');
select ok(not has_function_privilege('anon','public.set_sorting_staff_work_mode(text,uuid,text,text)','execute'),'anon cannot call set_sorting_staff_work_mode');
select ok(not has_function_privilege('authenticated','public.production_roster_assert_operational_rules(uuid)','execute'),'Roster guard stays private');

select * from finish();
rollback;
