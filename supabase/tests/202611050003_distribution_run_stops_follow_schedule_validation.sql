-- Validation for 202611050003_distribution_run_stops_follow_schedule.sql
-- Run after the migration is applied. Read-only: everything is rolled back.
begin;
select plan(6);

select has_function('public', 'distribution_resync_open_runs', 'distribution_resync_open_runs exists');
select ok(not has_function_privilege('authenticated', 'public.sync_distribution_route_run_stops(uuid)', 'execute'), 'authenticated cannot call sync_distribution_route_run_stops');
select ok(not has_function_privilege('authenticated', 'public.distribution_resync_open_runs()', 'execute'), 'authenticated cannot call distribution_resync_open_runs');
select ok(exists (select 1 from pg_trigger where tgname = 'customer_schedule_versions_resync_distribution_runs' and tgrelid = 'public.customer_schedule_versions'::regclass), 'schedule version trigger exists');

-- Fire the trigger without changing any row, then compare runs with the schedule.
update public.customer_schedule_versions set status = status where false;

select is(
  (select count(*)::integer from (
    select s.run_id, s.customer_id from public.distribution_route_run_stops s
    join public.distribution_route_runs u using (run_id)
    where u.business_date >= current_date and s.stop_kind = 'SCHEDULED'
    group by 1, 2 having count(*) > 1) x),
  0, 'no customer appears twice on a run from today onwards');

select is(
  (select count(*)::integer from public.distribution_route_runs u
   where u.business_date >= current_date and u.run_status in ('DRAFT', 'READY')
     and (select count(*) from public.distribution_route_run_stops s where s.run_id = u.run_id and s.stop_kind = 'SCHEDULED')
      <> (select count(*) from public.distribution_source_stops(u.business_date, u.route_id))),
  0, 'every open run has exactly the scheduled stops');

select * from finish();
rollback;
