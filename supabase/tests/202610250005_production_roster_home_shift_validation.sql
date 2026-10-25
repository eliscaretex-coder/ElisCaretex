begin;
select plan(5);

select has_function('public', 'get_current_account_home_shift', array[]::text[], 'get_current_account_home_shift exists');
select ok(not has_function_privilege('anon', 'public.get_current_account_home_shift()', 'execute'), 'anon cannot call get_current_account_home_shift');
select ok(has_function_privilege('authenticated', 'public.get_current_account_home_shift()', 'execute'), 'authenticated can call get_current_account_home_shift');
select ok(pg_get_functiondef('public.get_current_account_home_shift()'::regprocedure) like '%require_production_roster_read_role%', 'get_current_account_home_shift checks Production Roster read access');
select ok(pg_get_functiondef('public.get_current_account_home_shift()'::regprocedure) like '%auth.uid()%', 'get_current_account_home_shift only reads the signed-in account');

select * from finish();
rollback;
