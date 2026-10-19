begin;
select plan(3);

select ok(pg_get_functiondef('public.validate_distribution_roster_version(uuid)'::regprocedure) like '%An assignment already in the published roster stays%','roster validation keeps published vehicle days');
select ok(pg_get_functiondef('public.save_distribution_route_run(jsonb)'::regprocedure) like '%The vehicle the route already has%','daily route plan keeps the vehicle a route already has');
select ok(not has_function_privilege('authenticated','public.validate_distribution_roster_version(uuid)','execute'),'roster validation stays internal');

select * from finish();
rollback;
