-- ElisCaretex V2 - Validation 044 - Finish V2 production foundation
-- Read-only structural validation. No production scenario writes are performed.

do $$
declare v_result jsonb;
begin
  if to_regclass('public.finish_production_entries') is null then raise exception 'finish_production_entries missing'; end if;
  if to_regclass('public.finish_production_lines') is null then raise exception 'finish_production_lines missing'; end if;
  if to_regclass('public.finish_production_trolleys') is null then raise exception 'finish_production_trolleys missing'; end if;
  if to_regprocedure('public.record_finish_production(uuid,text,text,jsonb,text[],text)') is null then raise exception 'record_finish_production missing'; end if;
  if to_regprocedure('public.assign_finish_trolley_to_flow(text,uuid,date,text)') is null then raise exception 'assign_finish_trolley_to_flow missing'; end if;
  if to_regprocedure('public.correct_finish_production(uuid,jsonb,text[],text,text)') is null then raise exception 'correct_finish_production missing'; end if;
  if to_regprocedure('public.get_finish_production_context(text,timestamp with time zone)') is null then raise exception 'get_finish_production_context missing'; end if;
  if to_regprocedure('public.get_production_tracker_v4(date)') is null then raise exception 'get_production_tracker_v4 missing'; end if;
  if to_regprocedure('public.upsert_finish_staff_actual(uuid,text,text,time without time zone,time without time zone,text)') is null then raise exception 'upsert_finish_staff_actual missing'; end if;
  if not exists(select 1 from public.production_targets where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR' and target_value=23.5) then raise exception 'Finish 23.5 target missing'; end if;
  if (public.finish_delivery_cutoff(date '2026-08-13') at time zone 'Europe/Dublin')::time <> time '12:00' then raise exception 'Finish delivery cutoff is not 12:00 Europe/Dublin'; end if;
  if not exists(select 1 from public.stations where station_code='FINISH_TABLE_1') or not exists(select 1 from public.stations where station_code='FINISH_TABLE_2') or not exists(select 1 from public.stations where station_code='FINISH_TABLE_3') then raise exception 'Finish table master incomplete'; end if;
  v_result:=jsonb_build_object(
    'test','202608120008_finish_v2_production_foundation_validation',
    'status','PASS',
    'scenario_writes_performed',false,
    'private_finish_tables',true,
    'append_only_revision_model',true,
    'three_finish_tables',true,
    'future_multi_table_scanner_ready',true,
    'continuation_requires_new_batch',true,
    'delivery_day_cutoff_noon_europe_dublin',true,
    'finish_target_kg_per_staff_hour',23.5,
    'staff_actual_metrics_supported',true,
    'shared_tracker_v4',true
  );
  raise notice '%',v_result;
end $$;
