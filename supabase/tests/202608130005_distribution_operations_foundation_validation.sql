-- ElisCaretex V2 -- Validation 051 -- Distribution operations foundation
-- Structural validation only. Safe in SQL Editor without app auth.

do $$
declare
  v_table text;
  v_function text;
begin
  foreach v_table in array array[
    'distribution_drivers', 'fleet_vehicles', 'fleet_vehicle_maintenance',
    'fleet_vehicle_defects', 'distribution_driver_absences',
    'distribution_route_runs', 'distribution_route_run_stops', 'distribution_run_events'
  ] loop
    if to_regclass('public.' || v_table) is null then
      raise exception 'VALIDATION 051 FAIL: table public.% is missing.', v_table;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('public.' || v_table)) then
      raise exception 'VALIDATION 051 FAIL: RLS is not enabled on public.%.', v_table;
    end if;
  end loop;

  foreach v_function in array array[
    'public.get_distribution_operations_capabilities()',
    'public.get_distribution_operations_dashboard(date)',
    'public.get_distribution_route_run_detail(uuid)',
    'public.save_distribution_route_run(jsonb)',
    'public.set_distribution_route_run_status(uuid,text,text)',
    'public.save_distribution_manual_stop(jsonb)',
    'public.set_distribution_stop_status(uuid,text,text)',
    'public.save_distribution_driver(jsonb)',
    'public.save_fleet_vehicle(jsonb)',
    'public.save_distribution_route(jsonb)',
    'public.save_fleet_vehicle_maintenance(jsonb)',
    'public.save_fleet_vehicle_defect(jsonb)',
    'public.save_distribution_driver_absence(jsonb)'
  ] loop
    if to_regprocedure(v_function) is null then
      raise exception 'VALIDATION 051 FAIL: % is missing.', v_function;
    end if;
    if not has_function_privilege('authenticated', v_function, 'EXECUTE') then
      raise exception 'VALIDATION 051 FAIL: authenticated cannot execute %.', v_function;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.get_distribution_operations_dashboard(date)', 'EXECUTE') then
    raise exception 'VALIDATION 051 FAIL: anon can execute the Distribution dashboard RPC.';
  end if;

  if position('DISTRIBUTION_OPERATIONS_V1' in pg_get_functiondef('public.get_distribution_operations_dashboard(date)'::regprocedure)) = 0 then
    raise exception 'VALIDATION 051 FAIL: dashboard contract marker is missing.';
  end if;
  if position('sync_distribution_route_run_stops' in pg_get_functiondef('public.save_distribution_route_run(jsonb)'::regprocedure)) = 0 then
    raise exception 'VALIDATION 051 FAIL: Route save does not snapshot published Schedule stops.';
  end if;
  if position('never rewrites' in coalesce(obj_description('public.distribution_route_runs'::regclass), '')) = 0 then
    raise exception 'VALIDATION 051 FAIL: Distribution Route Run lifecycle comment is missing.';
  end if;

  raise notice 'VALIDATION 051 PASS';
end;
$$;

select jsonb_build_object(
  'validation','051',
  'status','PASS',
  'dashboard_rpc',to_regprocedure('public.get_distribution_operations_dashboard(date)') is not null,
  'authenticated_execute',has_function_privilege('authenticated','public.get_distribution_operations_dashboard(date)','EXECUTE'),
  'anon_blocked',not has_function_privilege('anon','public.get_distribution_operations_dashboard(date)','EXECUTE'),
  'route_runs',(select count(*) from public.distribution_route_runs),
  'drivers',(select count(*) from public.distribution_drivers where deleted_at is null),
  'vehicles',(select count(*) from public.fleet_vehicles where deleted_at is null)
) as validation_result;
