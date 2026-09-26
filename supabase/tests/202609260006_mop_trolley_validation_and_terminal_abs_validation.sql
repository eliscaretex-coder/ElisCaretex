begin;

do $$
declare
  v_validate text;
  v_save text;
  v_abs text;
begin
  if to_regprocedure('public.validate_mop_trolley_selection(uuid,text[])') is null then
    raise exception 'MOP trolley validator is missing.';
  end if;
  if to_regprocedure('public.save_sorting_mop_production_v2(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text,boolean)') is null then
    raise exception 'Guarded MOP production save RPC is missing.';
  end if;
  if to_regprocedure('public.record_sorting_mop_abs_batch(uuid,text,text)') is null then
    raise exception 'MOP ABS RPC is missing.';
  end if;

  select lower(pg_get_functiondef('public.validate_mop_trolley_selection(uuid,text[])'::regprocedure)) into v_validate;
  select lower(pg_get_functiondef('public.save_sorting_mop_production_v2(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text,boolean)'::regprocedure)) into v_save;
  select lower(pg_get_functiondef('public.record_sorting_mop_abs_batch(uuid,text,text)'::regprocedure)) into v_abs;

  if position('customer_schedule_trolley_requirements' in v_validate)=0
     or position('trolley_type_id' in v_validate)=0
     or position('hard_issues' in v_validate)=0
     or position('plan_issues' in v_validate)=0 then
    raise exception 'MOP trolley validator does not enforce quantity, type and physical availability.';
  end if;
  if position('p_accept_trolley_mismatch' in v_save)=0
     or position('validate_mop_trolley_selection' in v_save)=0 then
    raise exception 'MOP save does not enforce server-side trolley confirmation.';
  end if;
  if position('production_station_device_context' in v_abs)=0
     or position('v_mop_batch.operator_staff_id' in v_abs)=0
     or position('mop_production_operator' in v_abs)=0 then
    raise exception 'Terminal ABS posting does not derive staff from recorded MOP production.';
  end if;

  if has_function_privilege('anon','public.validate_mop_trolley_selection(uuid,text[])','EXECUTE')
     or not has_function_privilege('authenticated','public.validate_mop_trolley_selection(uuid,text[])','EXECUTE') then
    raise exception 'MOP trolley validator grants are unsafe.';
  end if;
  if has_function_privilege('authenticated','public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text)','EXECUTE') then
    raise exception 'Legacy unguarded MOP save remains callable by authenticated clients.';
  end if;
end;
$$;

rollback;
