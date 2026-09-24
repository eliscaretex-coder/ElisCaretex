begin;

select plan(3);

select has_function('public','get_my_account_roster_portal',array[]::text[],'administrator roster portal function exists');
select function_privs_are('public','get_my_account_roster_portal',array[]::text[],'authenticated',array['EXECUTE'],'authenticated can execute the roster portal');
select function_privs_are('public','get_my_account_roster_portal',array[]::text[],'anon',array[]::text[],'anonymous users cannot execute the roster portal');

select * from finish();
rollback;
