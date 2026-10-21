-- Validation for 202610210001_trolley_check_urgent_alert.sql
begin;
select plan(11);

select has_function('public','can_handle_trolley_plan_checks',array[]::text[],'can_handle_trolley_plan_checks exists');
select has_function('public','get_open_trolley_checks',array[]::text[],'get_open_trolley_checks exists');
select ok(not has_function_privilege('anon','public.can_handle_trolley_plan_checks()','execute'),'anon cannot call can_handle_trolley_plan_checks');
select ok(not has_function_privilege('anon','public.get_open_trolley_checks()','execute'),'anon cannot call get_open_trolley_checks');
select ok(not has_function_privilege('anon','public.review_operational_schedule_report(uuid,text,text)','execute'),'anon cannot review trolley checks');
select ok(pg_get_functiondef('public.get_open_trolley_checks()'::regprocedure) like '%can_handle_trolley_plan_checks()%','get_open_trolley_checks checks the audience');
select ok(pg_get_functiondef('public.review_operational_schedule_report(uuid,text,text)'::regprocedure) like '%can_handle_trolley_plan_checks()%','review checks the audience');
select ok(pg_get_functiondef('public.get_my_notification_summary()'::regprocedure) like '%trolley_check_count%','summary counts open trolley checks');
select ok(pg_get_functiondef('public.get_my_notification_inbox()'::regprocedure) like '%trolley-checks%','inbox lists open trolley checks');

-- Negative: a signed-in account outside the audience gets an empty list and cannot resolve.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
select is((public.get_open_trolley_checks()->>'can_handle')::boolean, false, 'an account outside the audience sees no trolley checks');
select throws_ok(
  $$select public.review_operational_schedule_report(gen_random_uuid(),'RESOLVED','test')$$,
  '42501', null, 'an account outside the audience cannot resolve a trolley check');
reset role;

select * from finish();
rollback;
