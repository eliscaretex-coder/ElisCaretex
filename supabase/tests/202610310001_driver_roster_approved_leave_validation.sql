begin;
select plan(5);
select has_function('public','get_my_driver_roster',array['date'],'get_my_driver_roster exists');
select ok(not has_function_privilege('anon','public.get_my_driver_roster(date)','execute'),'anon cannot call get_my_driver_roster');
select ok(pg_get_functiondef('public.get_my_driver_roster(date)'::regprocedure) like '%can_manage_driver_guides%','get_my_driver_roster keeps the management check');
select ok(pg_get_functiondef('public.get_my_driver_roster(date)'::regprocedure) like '%''approved_leave''%','get_my_driver_roster returns approved_leave');
select ok(pg_get_functiondef('public.get_my_driver_roster(date)'::regprocedure) like '%v_management or a.driver_id=v_driver%','approved_leave is limited to the driver unless management');
select * from finish();
rollback;
