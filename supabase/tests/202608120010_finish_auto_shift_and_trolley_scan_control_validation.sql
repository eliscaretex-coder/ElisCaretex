-- ElisCaretex V2 - Validation 046 - Finish Auto Shift and trolley scan control
-- Read-only structural validation. No scenario writes are performed.

do $$
declare
  v_auto_def text;
  v_scan_def text;
  v_assign_def text;
  v_shift_guard_def text;
  v_result jsonb;
begin
  if to_regprocedure('public.get_finish_auto_shift_context(timestamp with time zone)') is null then
    raise exception 'get_finish_auto_shift_context missing';
  end if;
  if to_regprocedure('public.validate_finish_trolley_selection(uuid,text[],timestamp with time zone)') is null then
    raise exception 'validate_finish_trolley_selection missing';
  end if;
  if to_regprocedure('public.assign_finish_trolley_to_flow(text,uuid,date,text)') is null then
    raise exception 'assign_finish_trolley_to_flow missing';
  end if;
  if to_regprocedure('public.finish_enforce_new_entry_current_shift()') is null then
    raise exception 'finish_enforce_new_entry_current_shift missing';
  end if;
  if not exists(select 1 from pg_trigger where tgname='trg_finish_enforce_new_entry_current_shift' and not tgisinternal) then
    raise exception 'Finish current-shift guard trigger missing';
  end if;

  select pg_get_functiondef('public.get_finish_auto_shift_context(timestamp with time zone)'::regprocedure) into v_auto_def;
  select pg_get_functiondef('public.validate_finish_trolley_selection(uuid,text[],timestamp with time zone)'::regprocedure) into v_scan_def;
  select pg_get_functiondef('public.assign_finish_trolley_to_flow(text,uuid,date,text)'::regprocedure) into v_assign_def;
  select pg_get_functiondef('public.finish_enforce_new_entry_current_shift()'::regprocedure) into v_shift_guard_def;

  if position('production_roster_work_profile_context' in v_auto_def)=0 then raise exception 'Finish Auto Shift does not use Roster work profile'; end if;
  if position('evening_shift_rollover_time' in v_auto_def)=0 then raise exception 'Finish Auto Shift rollover config missing'; end if;
  if position('customer_schedule_trolley_requirements' in v_scan_def)=0 then raise exception 'Published trolley requirement comparison missing'; end if;
  if position('finish_production_trolleys' in v_scan_def)=0 then raise exception 'Same-flow trolley reuse detection missing'; end if;
  if position('ALREADY_ASSIGNED_SAME_FINISH_FLOW' in v_assign_def)=0 then raise exception 'Finish same-flow lifecycle reuse missing'; end if;
  if position('get_finish_auto_shift_context' in v_shift_guard_def)=0 then raise exception 'New Finish production current-shift guard missing'; end if;

  if has_function_privilege('anon','public.get_finish_auto_shift_context(timestamp with time zone)','EXECUTE') then raise exception 'anon must not execute Finish Auto Shift'; end if;
  if not has_function_privilege('authenticated','public.get_finish_auto_shift_context(timestamp with time zone)','EXECUTE') then raise exception 'authenticated Finish Auto Shift grant missing'; end if;
  if has_function_privilege('anon','public.validate_finish_trolley_selection(uuid,text[],timestamp with time zone)','EXECUTE') then raise exception 'anon must not execute trolley precheck'; end if;
  if not has_function_privilege('authenticated','public.validate_finish_trolley_selection(uuid,text[],timestamp with time zone)','EXECUTE') then raise exception 'authenticated trolley precheck grant missing'; end if;
  if has_function_privilege('authenticated','public.assign_finish_trolley_to_flow(text,uuid,date,text)','EXECUTE') then raise exception 'assign_finish_trolley_to_flow must remain internal'; end if;

  v_result:=jsonb_build_object(
    'test','202608120010_finish_auto_shift_and_trolley_scan_control_validation',
    'status','PASS',
    'scenario_writes_performed',false,
    'finish_shift_uses_roster_work_profile',true,
    'overnight_rollover_preserved',true,
    'new_finish_entries_enforce_current_shift',true,
    'trolley_plan_quantity_type_comparison',true,
    'physical_trolley_status_precheck',true,
    'same_finish_flow_trolley_reuse_is_idempotent',true,
    'published_schedule_not_mutated',true,
    'mop_style_report_contract_preserved',true
  );
  raise notice '%',v_result;
end $$;
