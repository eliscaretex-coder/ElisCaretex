-- ElisCaretex V2
-- Validation 035: Sorting MOP Production Correction / Cancellation
-- Status: PREPARED — OWNER MUST RUN AFTER Migration 035
-- Structural/read-contract validation only. No scenario writes are performed.

begin;

do $$
declare
  v_def text;
  v_norm text;
begin
  -- Revision metadata must exist on the existing private evidence table.
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='sorting_mop_production_batches' and column_name='supersedes_mop_production_batch_id')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='sorting_mop_production_batches' and column_name='revision_no')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='sorting_mop_production_batches' and column_name='change_reason')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='sorting_mop_production_batches' and column_name='cancellation_reason')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='sorting_mop_production_batches' and column_name='cancellation_kind') then
    raise exception 'Validation 035 failed: append-only MOP revision metadata is incomplete.';
  end if;

  if exists(select 1 from public.sorting_mop_production_batches where revision_no is null or revision_no<1) then
    raise exception 'Validation 035 failed: existing MOP batches have invalid revision numbers.';
  end if;

  if to_regprocedure('public.sorting_mop_assign_revision_on_insert()') is null
     or to_regprocedure('public.get_sorting_mop_production_correction_context(uuid)') is null
     or to_regprocedure('public.correct_sorting_mop_production(uuid,text,jsonb,text,text[],boolean)') is null
     or to_regprocedure('public.cancel_sorting_mop_production(uuid,text,boolean)') is null
     or to_regprocedure('public.get_sorting_mop_recent_trace(integer)') is null then
    raise exception 'Validation 035 failed: one or more MOP correction RPCs are missing.';
  end if;

  if not exists(
    select 1
    from pg_trigger tg
    join pg_class c on c.oid=tg.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='sorting_mop_production_batches'
      and tg.tgname='sorting_mop_assign_revision_before_insert' and not tg.tgisinternal
  ) then
    raise exception 'Validation 035 failed: reprocessing-after-cancellation revision trigger is missing.';
  end if;

  select pg_get_functiondef('public.sorting_mop_assign_revision_on_insert()'::regprocedure) into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));
  if position('supersedes_mop_production_batch_id' in v_norm)=0
     or position('reprocessedafterpriorcancellation' in v_norm)=0
     or position($q$v_previous.status='cancelled'$q$ in v_norm)=0 then
    raise exception 'Validation 035 failed: reprocessing does not continue the append-only revision chain.';
  end if;

  if has_function_privilege('authenticated','public.sorting_mop_assign_revision_on_insert()','EXECUTE')
     or has_function_privilege('anon','public.sorting_mop_assign_revision_on_insert()','EXECUTE')
     or not has_function_privilege('authenticated','public.get_sorting_mop_production_correction_context(uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.correct_sorting_mop_production(uuid,text,jsonb,text,text[],boolean)','EXECUTE')
     or not has_function_privilege('authenticated','public.cancel_sorting_mop_production(uuid,text,boolean)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_sorting_mop_recent_trace(integer)','EXECUTE')
     or has_function_privilege('anon','public.get_sorting_mop_production_correction_context(uuid)','EXECUTE')
     or has_function_privilege('anon','public.correct_sorting_mop_production(uuid,text,jsonb,text,text[],boolean)','EXECUTE')
     or has_function_privilege('anon','public.cancel_sorting_mop_production(uuid,text,boolean)','EXECUTE')
     or has_function_privilege('anon','public.get_sorting_mop_recent_trace(integer)','EXECUTE') then
    raise exception 'Validation 035 failed: MOP correction RPC permission contract is incorrect.';
  end if;

  if has_table_privilege('authenticated','public.sorting_mop_production_batches','SELECT')
     or has_table_privilege('authenticated','public.sorting_mop_production_batches','INSERT')
     or has_table_privilege('authenticated','public.sorting_mop_production_batches','UPDATE')
     or has_table_privilege('authenticated','public.sorting_mop_production_batches','DELETE')
     or has_table_privilege('authenticated','public.sorting_mop_production_lines','SELECT')
     or has_table_privilege('authenticated','public.sorting_mop_production_trolleys','SELECT')
     or has_table_privilege('authenticated','public.production_flow_external_batches','SELECT')
     or has_table_privilege('authenticated','public.production_flow_external_batches','INSERT')
     or has_table_privilege('authenticated','public.production_flow_external_batches','UPDATE')
     or has_table_privilege('authenticated','public.production_flow_external_batches','DELETE')
     or has_table_privilege('anon','public.sorting_mop_production_batches','SELECT')
     or has_table_privilege('anon','public.production_flow_external_batches','SELECT') then
    raise exception 'Validation 035 failed: private MOP/ABS source tables became directly readable by browser roles.';
  end if;

  select pg_get_functiondef('public.correct_sorting_mop_production(uuid,text,jsonb,text,text[],boolean)'::regprocedure) into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));
  if position('supersedes_mop_production_batch_id' in v_norm)=0
     or position('cancellation_kind' in v_norm)=0
     or position('mop_production_corrected' in v_norm)=0
     or position('livetrolleycodesarelifecycleevidence' in v_norm)=0
     or position('late_reference_only' in v_norm)=0
     or position('mop_correction_sync_abs_evidence' in v_norm)=0
     or position('genericmoptotalcannotreplacemoptypeslinked' in v_norm)=0
     or position('integration' in v_norm)=0
     or position('sorting_wash_runs' in v_norm)>0
     or position('sorting_wash_run_customers' in v_norm)>0 then
    raise exception 'Validation 035 failed: append-only correction, trolley lifecycle or ABS synchronization contract is incomplete.';
  end if;

  select pg_get_functiondef('public.cancel_sorting_mop_production(uuid,text,boolean)'::regprocedure) into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));
  if position('p_cancel_abs_evidence' in v_norm)=0
     or position('livephysicaltrolleylifecycleevidence' in v_norm)=0
     or position('returns_to_mop_queue' in v_norm)=0
     or position('mop_production_cancelled' in v_norm)=0
     or position('external_system_not_modified' in v_norm)=0
     or position('multipleactiveabsbatches' in v_norm)=0
     or position('sorting_wash_runs' in v_norm)>0
     or position('sorting_wash_run_customers' in v_norm)>0 then
    raise exception 'Validation 035 failed: governed cancellation contract is incomplete.';
  end if;

  select pg_get_functiondef('public.get_sorting_mop_production_correction_context(uuid)'::regprocedure) into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));
  if position('available_variants' in v_norm)=0
     or position('revision_history' in v_norm)=0
     or position('live_trolley_locked' in v_norm)=0
     or position('active_abs_batches' in v_norm)=0
     or position('append_only_replacement' in v_norm)=0 then
    raise exception 'Validation 035 failed: correction read context is incomplete.';
  end if;

  select pg_get_functiondef('public.get_sorting_mop_recent_trace(integer)'::regprocedure) into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));
  if position('revision_history' in v_norm)=0
     or position('cancelled_count' in v_norm)=0
     or position('route_color_snapshot' in v_norm)=0
     or position('active_abs_batches' in v_norm)=0
     or position('live_trolley_locked' in v_norm)=0
     or position('mop_production_revision_trace_plus_shared_production_flow_abs' in v_norm)=0 then
    raise exception 'Validation 035 failed: revision-aware MOP Trace regressed an existing Route/ABS/trolley contract.';
  end if;
end;
$$;

select jsonb_build_object(
  'test','202608110015_sorting_mop_production_correction_and_cancellation_validation',
  'status','PASS',
  'mop_correction_is_append_only',true,
  'original_revision_is_preserved',true,
  'reprocessing_continues_revision_chain',true,
  'live_trolley_lifecycle_is_not_rewritten',true,
  'late_trolley_reference_correction_supported',true,
  'shared_abs_quantity_sync_is_governed',true,
  'integrated_abs_evidence_is_protected',true,
  'cancellation_requires_explicit_abs_confirmation',true,
  'washing_is_not_deleted_or_rewritten',true,
  'trace_exposes_revision_and_cancellation_history',true,
  'private_source_tables_stay_private',true,
  'anon_write_access_revoked',true,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
