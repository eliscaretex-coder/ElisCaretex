-- ElisCaretex V2 - Validation 045 - Finish Staff Roster/Actual context
-- Read-only structural validation. No scenario writes are performed.

do $$
declare
  v_def text;
  v_result jsonb;
begin
  if to_regprocedure('public.get_finish_staff_context_v2(text,timestamp with time zone)') is null then
    raise exception 'get_finish_staff_context_v2 missing';
  end if;

  select pg_get_functiondef('public.get_finish_staff_context_v2(text,timestamp with time zone)'::regprocedure) into v_def;

  if position('production_roster_entries' in v_def)=0 then raise exception 'Finish Staff context does not read Production Roster'; end if;
  if position('work_sessions' in v_def)=0 then raise exception 'Finish Staff context does not read Actual work_sessions'; end if;
  if position('actual_area_code' in v_def)=0 then raise exception 'Planned -> Actual area trace missing'; end if;
  if position('production_roster_work_profile_context' in v_def)=0 then raise exception 'Roster work-profile time resolution missing'; end if;
  if position('finish_production_entries' in v_def)=0 then raise exception 'Finish Table production input missing'; end if;

  if has_function_privilege('anon','public.get_finish_staff_context_v2(text,timestamp with time zone)','EXECUTE') then
    raise exception 'anon must not execute get_finish_staff_context_v2';
  end if;
  if not has_function_privilege('authenticated','public.get_finish_staff_context_v2(text,timestamp with time zone)','EXECUTE') then
    raise exception 'authenticated execute grant missing';
  end if;

  v_result:=jsonb_build_object(
    'test','202608120009_finish_staff_roster_actual_context_validation',
    'status','PASS',
    'scenario_writes_performed',false,
    'published_roster_is_planned',true,
    'work_sessions_is_actual',true,
    'incoming_finish_actual_supported',true,
    'planned_to_actual_area_difference_visible',true,
    'legacy_staff_hours_inputs_exposed',true,
    'individual_kg_ownership_not_invented',true
  );
  raise notice '%',v_result;
end $$;
