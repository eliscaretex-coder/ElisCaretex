-- ElisCaretex V2 -- Validation 052 -- Distribution weekly roster
-- Run after 202608130006_distribution_weekly_roster.sql.

do $$
declare
  v_table text;
  v_function text;
begin
  foreach v_table in array array[
    'distribution_roster_versions', 'distribution_roster_entries', 'distribution_roster_events'
  ] loop
    if to_regclass('public.' || v_table) is null then
      raise exception 'VALIDATION 052 FAIL: table public.% is missing.', v_table;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('public.' || v_table)) then
      raise exception 'VALIDATION 052 FAIL: RLS is not enabled on public.%.', v_table;
    end if;
  end loop;

  foreach v_function in array array[
    'public.get_distribution_roster_week(date,uuid)',
    'public.save_distribution_roster_week(jsonb)',
    'public.publish_distribution_roster_week(uuid,integer)',
    'public.get_distribution_roster_history(date)'
  ] loop
    if to_regprocedure(v_function) is null then
      raise exception 'VALIDATION 052 FAIL: % is missing.', v_function;
    end if;
    if not has_function_privilege('authenticated', v_function, 'EXECUTE') then
      raise exception 'VALIDATION 052 FAIL: authenticated cannot execute %.', v_function;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.get_distribution_roster_week(date,uuid)', 'EXECUTE') then
    raise exception 'VALIDATION 052 FAIL: anon can execute the Roster RPC.';
  end if;
  if position('validate_distribution_roster_version' in pg_get_functiondef('public.publish_distribution_roster_week(uuid,integer)'::regprocedure)) = 0 then
    raise exception 'VALIDATION 052 FAIL: Roster publish does not validate driver and vehicle assignments.';
  end if;

  raise notice 'VALIDATION 052 PASS';
end;
$$;

select jsonb_build_object(
  'validation', '052',
  'status', 'PASS',
  'roster_rpc', to_regprocedure('public.get_distribution_roster_week(date,uuid)') is not null,
  'authenticated_execute', has_function_privilege('authenticated', 'public.get_distribution_roster_week(date,uuid)', 'EXECUTE'),
  'anon_blocked', not has_function_privilege('anon', 'public.get_distribution_roster_week(date,uuid)', 'EXECUTE'),
  'roster_versions', (select count(*) from public.distribution_roster_versions)
) as validation_result;
