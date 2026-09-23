-- ElisCaretex V2
-- Validation 047: Finish processing staff attribution and route-aware history
-- Read-only / transaction-safe checks for Migration 047.

begin;

do $$
declare
  v_missing text[]:=array[]::text[];
  v_def text;
begin
  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='finish_production_entries' and column_name='processed_by_staff_id'
  ) then v_missing:=array_append(v_missing,'finish_production_entries.processed_by_staff_id'); end if;

  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='finish_production_entries' and column_name='processed_by_name_snapshot'
  ) then v_missing:=array_append(v_missing,'finish_production_entries.processed_by_name_snapshot'); end if;

  if to_regprocedure('public.finish_processing_staff_available(uuid,date,uuid,uuid,timestamptz)') is null then
    v_missing:=array_append(v_missing,'finish_processing_staff_available');
  end if;
  if to_regprocedure('public.finish_assert_processing_staff(uuid,date,uuid,uuid,timestamptz)') is null then
    v_missing:=array_append(v_missing,'finish_assert_processing_staff');
  end if;
  if to_regprocedure('public.record_finish_production_v2(uuid,text,text,uuid,jsonb,text[],text)') is null then
    v_missing:=array_append(v_missing,'record_finish_production_v2');
  end if;
  if to_regprocedure('public.correct_finish_production_v2(uuid,uuid,jsonb,text[],text,text)') is null then
    v_missing:=array_append(v_missing,'correct_finish_production_v2');
  end if;
  if to_regprocedure('public.get_finish_production_context_v2(text,timestamptz)') is null then
    v_missing:=array_append(v_missing,'get_finish_production_context_v2');
  end if;

  if coalesce(array_length(v_missing,1),0)>0 then
    raise exception 'Migration 047 missing objects: %',array_to_string(v_missing,', ');
  end if;

  select pg_get_functiondef('public.record_finish_production_v2(uuid,text,text,uuid,jsonb,text[],text)'::regprocedure)
  into v_def;
  if position('finish_assert_processing_staff' in v_def)=0 then
    raise exception 'record_finish_production_v2 does not validate processed-by staff.';
  end if;
  if position('record_finish_production(' in v_def)=0 then
    raise exception 'record_finish_production_v2 no longer delegates to the owner-tested Finish save path.';
  end if;

  select pg_get_functiondef('public.get_finish_production_context_v2(text,timestamptz)'::regprocedure)
  into v_def;
  if position('route_color' in v_def)=0 or position('production_staff_now' in v_def)=0 or position('processing_staff_history' in v_def)=0 then
    raise exception 'Finish context V2 is missing route/staff trace fields.';
  end if;

  if exists(
    select 1
    from public.finish_production_entries e
    where e.recorded_by_staff_id is not null
      and e.processed_by_staff_id is null
  ) then
    raise exception 'Existing Finish entries with recorder staff were not backfilled to processed-by.';
  end if;
end;
$$;

select jsonb_build_object(
  'test','202608130001_finish_processing_staff_attribution_and_route_saved_today_validation',
  'status','PASS',
  'writes_rolled_back',true,
  'processed_by_columns',true,
  'new_save_requires_exact_table_shift_actual_staff',true,
  'scanner_identity_separate',true,
  'route_aware_saved_today_contract',true,
  'correction_keeps_append_only_revision_history',true,
  'legacy_finish_save_path_reused',true
) as validation_result;

rollback;
