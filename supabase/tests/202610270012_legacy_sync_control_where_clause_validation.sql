-- Validation for 202610270012_legacy_sync_control_where_clause.sql.
-- Run in the SQL Editor. It ends with an error that starts with "PASSED": the error
-- rolls back every change, so nothing is kept.
do $$
declare
  v_safeupdate boolean := true;
  v_result jsonb;
  v_total int;
  v_on int;
begin
  if pg_get_functiondef('integration.legacy_sync_control(text,text)'::regprocedure)
     not like '%where setting_key is not null%' then
    raise exception 'FAILED 1: legacy_sync_control has no WHERE clause on legacy_sync_settings';
  end if;
  if has_function_privilege('anon', 'integration.legacy_sync_control(text,text)', 'execute')
     or has_function_privilege('authenticated', 'integration.legacy_sync_control(text,text)', 'execute') then
    raise exception 'FAILED 2: legacy_sync_control is callable by client roles';
  end if;

  -- The Data API session runs with pg-safeupdate; load it here too when allowed.
  begin
    load 'safeupdate';
  exception when others then
    v_safeupdate := false;
  end;

  select count(*) into v_total from integration.legacy_sync_settings;

  v_result := integration.legacy_sync_control('ON', 'validation 202610270012');
  select count(*) into v_on from integration.legacy_sync_settings where enabled and max_entries_per_run = 300;
  if v_on <> v_total or not (v_result->>'auto_enabled')::boolean then
    raise exception 'FAILED 3: ON switched % of % imports', v_on, v_total;
  end if;

  v_result := integration.legacy_sync_control('OFF', 'validation 202610270012');
  select count(*) into v_on from integration.legacy_sync_settings where enabled;
  if v_on <> 0 or (v_result->>'auto_enabled')::boolean then
    raise exception 'FAILED 4: OFF left % imports on', v_on;
  end if;

  raise exception 'PASSED: all 4 legacy sync control checks (safeupdate loaded: %; nothing was kept)', v_safeupdate;
end;
$$;
