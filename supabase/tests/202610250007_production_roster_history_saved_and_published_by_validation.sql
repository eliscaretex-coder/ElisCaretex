begin;
select plan(9);

select has_function('public', 'get_production_roster_history', array['date', 'text'], 'get_production_roster_history exists');
select ok(not has_function_privilege('anon', 'public.get_production_roster_history(date, text)', 'execute'), 'anon cannot call get_production_roster_history');
select ok(has_function_privilege('authenticated', 'public.get_production_roster_history(date, text)', 'execute'), 'authenticated can call get_production_roster_history');
select ok(pg_get_functiondef('public.get_production_roster_history(date, text)'::regprocedure) like '%require_production_roster_read_role%', 'get_production_roster_history checks Production Roster read access');
select ok(pg_get_functiondef('public.get_production_roster_history(date, text)'::regprocedure) like '%saved_by_name%published_by_name%activity%', 'history returns saved by, published by and the activity trail');

select has_function('public', 'production_roster_actor_name', array['uuid', 'uuid'], 'production_roster_actor_name exists');
select ok(not has_function_privilege('anon', 'public.production_roster_actor_name(uuid, uuid)', 'execute'), 'anon cannot call production_roster_actor_name');
select ok(not has_function_privilege('authenticated', 'public.production_roster_actor_name(uuid, uuid)', 'execute'), 'authenticated cannot call production_roster_actor_name directly');

-- Every manual publication keeps its publisher, so the history can name them.
select is(
  (select count(*)::int from public.production_roster_events e
   where e.event_type = 'PUBLISHED' and e.actor_auth_user_id is not null
     and public.production_roster_actor_name(e.actor_auth_user_id, e.actor_staff_id) is null),
  0, 'every manually published version resolves to a name');

select * from finish();
rollback;
