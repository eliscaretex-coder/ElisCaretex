-- ElisCaretex V2 -- Validation 053 -- Distribution driver roster matrix
-- Run after 202608130007_distribution_roster_driver_matrix.sql.

do $$
declare
  v_definition text;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'distribution_routes' and column_name = 'default_km'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'distribution_routes' and column_name = 'default_hours'
  ) then
    raise exception 'VALIDATION 053 FAIL: route planning metric columns are missing.';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'distribution_roster_versions' and column_name = 'required_routes'
  ) then
    raise exception 'VALIDATION 053 FAIL: distribution_roster_versions.required_routes is missing.';
  end if;

  foreach v_definition in array array[
    'public.get_distribution_roster_week(date,uuid)',
    'public.save_distribution_roster_week(jsonb)',
    'public.save_distribution_route(jsonb)'
  ] loop
    if to_regprocedure(v_definition) is null then
      raise exception 'VALIDATION 053 FAIL: % is missing.', v_definition;
    end if;
    if not has_function_privilege('authenticated', v_definition, 'EXECUTE') then
      raise exception 'VALIDATION 053 FAIL: authenticated cannot execute %.', v_definition;
    end if;
    if has_function_privilege('anon', v_definition, 'EXECUTE') then
      raise exception 'VALIDATION 053 FAIL: anon can execute %.', v_definition;
    end if;
  end loop;

  if position('daily_metrics' in pg_get_functiondef('public.get_distribution_roster_week(date,uuid)'::regprocedure)) = 0
    or position('route_day_metrics' in pg_get_functiondef('public.get_distribution_roster_week(date,uuid)'::regprocedure)) = 0 then
    raise exception 'VALIDATION 053 FAIL: roster read RPC does not return driver-matrix metrics.';
  end if;

  if position('required_routes' in pg_get_functiondef('public.save_distribution_roster_week(jsonb)'::regprocedure)) = 0 then
    raise exception 'VALIDATION 053 FAIL: roster save RPC does not persist daily route requirements.';
  end if;

  raise notice 'VALIDATION 053 PASS';
end;
$$;

select jsonb_build_object(
  'validation', '053',
  'status', 'PASS',
  'route_metrics', (select count(*) from public.distribution_routes where default_km >= 0 and default_hours >= 0),
  'authenticated_execute', has_function_privilege('authenticated', 'public.get_distribution_roster_week(date,uuid)', 'EXECUTE'),
  'anon_blocked', not has_function_privilege('anon', 'public.get_distribution_roster_week(date,uuid)', 'EXECUTE')
) as validation_result;
