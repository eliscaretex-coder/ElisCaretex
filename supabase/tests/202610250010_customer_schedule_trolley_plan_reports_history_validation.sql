begin;
select plan(8);

select has_function('public', 'get_customer_trolley_plan_reports', array['uuid', 'integer'], 'get_customer_trolley_plan_reports exists');
select ok(not has_function_privilege('anon', 'public.get_customer_trolley_plan_reports(uuid, integer)', 'execute'), 'anon cannot call get_customer_trolley_plan_reports');
select ok(has_function_privilege('authenticated', 'public.get_customer_trolley_plan_reports(uuid, integer)', 'execute'), 'authenticated can call get_customer_trolley_plan_reports');
select ok(pg_get_functiondef('public.get_customer_trolley_plan_reports(uuid, integer)'::regprocedure) like '%require_customer_schedule_history_role%', 'checks Customer Schedule history access');
select ok(pg_get_functiondef('public.get_customer_trolley_plan_reports(uuid, integer)'::regprocedure) like '%reported_by%reviewed_by%reviewed_at%review_notes%', 'returns who asked and who reviewed');

-- Negative: a signed-in account without a Customer Schedule history role is refused.
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok(
  $$ select public.get_customer_trolley_plan_reports((select customer_id from public.customers limit 1), 10) $$,
  '42501', null, 'an account without the history role is refused'
);
reset role;

-- Every report of every customer is returned by its customer's list, with names.
select is(
  (select count(*)::int from public.operational_data_reports r
   where r.reviewed_at is not null
     and public.production_roster_actor_name(r.reviewed_by_auth_user_id, r.reviewed_by_staff_id) is null),
  0, 'every reviewed report resolves the reviewer name');
select is(
  (select count(*)::int from public.operational_data_reports r
   where public.production_roster_actor_name(r.reported_by_auth_user_id, r.reported_by_staff_id) is null),
  0, 'every report resolves the reporter name');

select * from finish();
rollback;
