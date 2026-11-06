-- Validation for 202611060013_legacy_sync_schedule_resync_once.sql.
-- Run in the SQL Editor. It ends with an error that starts with "PASSED": the error
-- rolls back every change (test route, run, stops, customer, sync run), so nothing is kept.
do $$
declare
  v_run uuid;
  v_route_id uuid;
  v_route_run uuid;
  v_customer uuid;
  v_days uuid[];
  v_n int;
  v_route jsonb := '{"record_type":"ROUTE","source_record_id":"VAL13","row":{"RouteID":"VAL13","DisplayName":"Route VAL13","Colour":"#131313"}}';
begin
  update integration.legacy_sync_settings set enabled=true, max_entries_per_run=200 where setting_key='SCHEDULE_IMPORT';
  v_run := integration.legacy_sync_start_run('FINISH_AREA','COMMIT',current_date,current_date,'validation 202611060013');

  -- 1. A schedule call through the dispatcher works and leaves the deferral off.
  perform integration.legacy_sync_dispatch_import('schedule', v_run, v_route);
  select route_id into v_route_id from public.distribution_routes where route_code='VAL13';
  if v_route_id is null or coalesce(current_setting('app.defer_distribution_resync', true), '') <> '' then
    raise exception 'FAILED 1: route % / setting %', v_route_id, current_setting('app.defer_distribution_resync', true);
  end if;

  -- A future Draft run of the test route with two stops from superseded schedule days:
  -- any resync removes them, because they are no longer in the schedule.
  select array_agg(d.schedule_day_id) into v_days from (
    select d.schedule_day_id from public.customer_schedule_days d
    join public.customer_schedule_versions v on v.schedule_version_id = d.schedule_version_id
    where v.status = 'SUPERSEDED' order by d.schedule_day_id limit 2) d;
  if coalesce(array_length(v_days, 1), 0) < 2 then raise exception 'FAILED setup: no superseded schedule days'; end if;
  insert into public.distribution_route_runs(business_date, route_id, run_status) values ('2031-01-06', v_route_id, 'DRAFT')
  returning run_id into v_route_run;
  insert into public.distribution_route_run_stops(run_id, source_schedule_day_id, stop_kind, stop_order, customer_name_snapshot)
  select v_route_run, d, 'SCHEDULED', 1, 'Validation 0013 stale' from unnest(v_days) d;
  insert into public.customers(customer_code, customer_name, active) values ('VALIDATION-0013','Validation 0013',true)
  returning customer_id into v_customer;

  -- 2. While deferred, a schedule version change does not resync the runs.
  perform set_config('app.defer_distribution_resync', 'on', true);
  insert into public.customer_schedule_versions(customer_id, version_number, status, effective_from, source_code)
  values (v_customer, 1, 'DRAFT', current_date, 'MANUAL');
  select count(*) into v_n from public.distribution_route_run_stops where run_id = v_route_run;
  if v_n <> 2 then raise exception 'FAILED 2: % stops left while deferred', v_n; end if;
  perform set_config('app.defer_distribution_resync', '', true);

  -- 3. The dispatcher resyncs once at the end of a schedule call.
  perform integration.legacy_sync_dispatch_import('schedule', v_run, v_route);
  select count(*) into v_n from public.distribution_route_run_stops where run_id = v_route_run;
  if v_n <> 0 then raise exception 'FAILED 3: % stale stops after the schedule batch', v_n; end if;

  -- 4. Outside the sync, a schedule change still resyncs at once (Customer Studio behaviour).
  insert into public.distribution_route_run_stops(run_id, source_schedule_day_id, stop_kind, stop_order, customer_name_snapshot)
  values (v_route_run, v_days[1], 'SCHEDULED', 1, 'Validation 0013 stale');
  update public.customer_schedule_versions set status = 'CANCELLED' where customer_id = v_customer;
  select count(*) into v_n from public.distribution_route_run_stops where run_id = v_route_run;
  if v_n <> 0 then raise exception 'FAILED 4: the trigger no longer resyncs outside the sync'; end if;

  -- 5. No client role can call the dispatcher.
  if has_function_privilege('authenticated','integration.legacy_sync_dispatch_import(text,uuid,jsonb)','execute')
     or has_function_privilege('anon','integration.legacy_sync_dispatch_import(text,uuid,jsonb)','execute') then
    raise exception 'FAILED 5: a client role can call the dispatcher';
  end if;

  raise exception 'PASSED: 202611060013 legacy sync schedule resync once (5 checks)';
end;
$$;
