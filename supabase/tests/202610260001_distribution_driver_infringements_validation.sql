begin;
select plan(16);

select has_table('public', 'distribution_driver_infringements', 'distribution_driver_infringements exists');
select ok((select relrowsecurity from pg_class where oid = 'public.distribution_driver_infringements'::regclass), 'RLS is enabled');
select ok(not has_table_privilege('authenticated', 'public.distribution_driver_infringements', 'select'), 'signed-in users cannot read the table directly');
select has_function('public', 'get_distribution_driver_infringements', array['uuid'], 'get_distribution_driver_infringements exists');
select has_function('public', 'save_distribution_driver_infringement', array['jsonb'], 'save_distribution_driver_infringement exists');
select has_function('public', 'cancel_distribution_driver_infringement', array['uuid', 'integer', 'text'], 'cancel_distribution_driver_infringement exists');
select ok(not has_function_privilege('anon', 'public.get_distribution_driver_infringements(uuid)', 'execute'), 'anon cannot read infringements');
select ok(not has_function_privilege('anon', 'public.save_distribution_driver_infringement(jsonb)', 'execute'), 'anon cannot save infringements');
select ok(not has_function_privilege('anon', 'public.cancel_distribution_driver_infringement(uuid, integer, text)', 'execute'), 'anon cannot cancel infringements');
select ok(pg_get_functiondef('public.get_distribution_driver_infringements(uuid)'::regprocedure) like '%require_distribution_read_access%', 'reading checks Distribution access');
select ok(pg_get_functiondef('public.save_distribution_driver_infringement(jsonb)'::regprocedure) like '%require_distribution_plan_access%', 'saving checks Distribution edit access');
select ok(pg_get_functiondef('public.cancel_distribution_driver_infringement(uuid, integer, text)'::regprocedure) like '%require_distribution_plan_access%', 'cancelling checks Distribution edit access');
select is(public.distribution_infringement_validity_months(), 7, 'an infringement counts for 7 months');

-- Negative: a signed-in account without Distribution access is refused.
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok($$ select public.get_distribution_driver_infringements(null) $$, '42501', null, 'an account without Distribution access cannot read');
select throws_ok(
  $$ select public.save_distribution_driver_infringement(jsonb_build_object('driver_id', (select driver_id from public.distribution_drivers limit 1), 'occurred_local', '2026-10-20T10:00', 'severity_level', 'MINOR', 'infringement_type', 'Speeding')) $$,
  '42501', null, 'an account without Distribution access cannot record');
reset role;

select ok(pg_get_functiondef('public.get_distribution_driver_master()'::regprocedure) like '%infringements%', 'driver master returns the infringement summary');

select * from finish();
rollback;
