-- ElisCaretex V2
-- Validation: 202608110013_sorting_mop_trace_abs_and_ui_compaction_validation
-- Status: PREPARED — OWNER MUST RUN AFTER Migration 033
-- Structural/read-contract validation only. No scenario writes are performed.

begin;

do $$
declare
  v_def text;
  v_norm text;
  v_bool boolean;
begin
  if to_regprocedure('public.require_production_flow_abs_batch_write_access(uuid)') is null then
    raise exception 'Validation 033 failed: private flow-aware ABS authorization helper is missing.';
  end if;

  if to_regprocedure('public.record_sorting_mop_abs_batch(uuid,text,text)') is null then
    raise exception 'Validation 033 failed: record_sorting_mop_abs_batch RPC is missing.';
  end if;

  if to_regprocedure('public.get_sorting_mop_recent_trace(integer)') is null then
    raise exception 'Validation 033 failed: get_sorting_mop_recent_trace RPC is missing.';
  end if;

  if to_regprocedure('public.record_production_flow_abs_batch(uuid,text,numeric,text,text)') is null then
    raise exception 'Validation 033 failed: shared Production Flow ABS RPC is missing.';
  end if;

  -- The private helper must not become a browser endpoint.
  if has_function_privilege('authenticated','public.require_production_flow_abs_batch_write_access(uuid)','EXECUTE')
     or has_function_privilege('anon','public.require_production_flow_abs_batch_write_access(uuid)','EXECUTE') then
    raise exception 'Validation 033 failed: private ABS authorization helper is executable by browser roles.';
  end if;

  -- Public controlled RPC contract.
  if not has_function_privilege('authenticated','public.record_sorting_mop_abs_batch(uuid,text,text)','EXECUTE')
     or has_function_privilege('anon','public.record_sorting_mop_abs_batch(uuid,text,text)','EXECUTE') then
    raise exception 'Validation 033 failed: MOP ABS write RPC permission contract is incorrect.';
  end if;

  if not has_function_privilege('authenticated','public.get_sorting_mop_recent_trace(integer)','EXECUTE')
     or has_function_privilege('anon','public.get_sorting_mop_recent_trace(integer)','EXECUTE') then
    raise exception 'Validation 033 failed: MOP trace read RPC permission contract is incorrect.';
  end if;

  if not has_function_privilege('authenticated','public.record_production_flow_abs_batch(uuid,text,numeric,text,text)','EXECUTE')
     or has_function_privilege('anon','public.record_production_flow_abs_batch(uuid,text,numeric,text,text)','EXECUTE') then
    raise exception 'Validation 033 failed: shared ABS RPC browser-role permission contract is incorrect.';
  end if;

  if has_table_privilege('authenticated','public.production_flow_external_batches','SELECT')
     or has_table_privilege('authenticated','public.production_flow_external_batches','INSERT')
     or has_table_privilege('authenticated','public.production_flow_external_batches','UPDATE')
     or has_table_privilege('authenticated','public.production_flow_external_batches','DELETE')
     or has_table_privilege('anon','public.production_flow_external_batches','SELECT')
     or has_table_privilege('anon','public.production_flow_external_batches','INSERT')
     or has_table_privilege('anon','public.production_flow_external_batches','UPDATE')
     or has_table_privilege('anon','public.production_flow_external_batches','DELETE') then
    raise exception 'Validation 033 failed: shared ABS table became directly accessible to browser roles.';
  end if;

  select pg_get_functiondef('public.require_production_flow_abs_batch_write_access(uuid)'::regprocedure)
  into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));
  if position('sorting_operator' in v_norm)=0
     or position($q$v_product_code='mop'$q$ in v_norm)=0
     or position('sorting_mop_production_batches' in v_norm)=0
     or position($q$mb.status='recorded'$q$ in v_norm)=0 then
    raise exception 'Validation 033 failed: Sorting ABS access is not constrained to recorded MOP Production evidence.';
  end if;

  select pg_get_functiondef('public.record_production_flow_abs_batch(uuid,text,numeric,text,text)'::regprocedure)
  into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));
  if position('require_production_flow_abs_batch_write_access' in v_norm)=0
     or position('production_flow_external_batches' in v_norm)=0
     or position('abs_batch_recorded' in v_norm)=0
     or position('v_sorting_constrained' in v_norm)=0
     or position('sorting_mop_production_batches' in v_norm)=0
     or position('v_effective_quantity' in v_norm)=0
     or position('v_effective_unit' in v_norm)=0 then
    raise exception 'Validation 033 failed: shared ABS RPC does not preserve flow-aware authorization, shared event storage and server-derived Sorting quantity.';
  end if;

  select pg_get_functiondef('public.record_sorting_mop_abs_batch(uuid,text,text)'::regprocedure)
  into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));
  if position('require_sorting_operational_access' in v_norm)=0
     or position('sorting_mop_production_batches' in v_norm)=0
     or position($q$mb.status='recorded'$q$ in v_norm)=0
     or position('record_production_flow_abs_batch' in v_norm)=0
     or position('total_weight_kg' in v_norm)=0
     or position('total_units' in v_norm)=0
     or position($q$b.status='active'$q$ in v_norm)=0 then
    raise exception 'Validation 033 failed: MOP ABS wrapper does not preserve recorded-production, server-derived quantity and active-batch guards.';
  end if;

  select pg_get_functiondef('public.get_sorting_mop_recent_trace(integer)'::regprocedure)
  into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));
  if position('sorting_mop_production_batches' in v_norm)=0
     or position('sorting_mop_production_lines' in v_norm)=0
     or position('sorting_mop_production_trolleys' in v_norm)=0
     or position('production_flow_external_batches' in v_norm)=0
     or position('recorded_by_name' in v_norm)=0
     or position('active_abs_batches' in v_norm)=0
     or position('pending_abs_count' in v_norm)=0 then
    raise exception 'Validation 033 failed: MOP trace read model is missing production/trolley/ABS evidence.';
  end if;

  -- Existing shared external batch table still uses RLS.
  select c.relrowsecurity
  into v_bool
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='production_flow_external_batches';
  if not coalesce(v_bool,false) then
    raise exception 'Validation 033 failed: production_flow_external_batches RLS is not enabled.';
  end if;
end;
$$;

select jsonb_build_object(
  'test','202608110013_sorting_mop_trace_abs_and_ui_compaction_validation',
  'status','PASS',
  'mop_abs_uses_shared_production_flow_store',true,
  'sorting_abs_requires_recorded_mop_production',true,
  'abs_quantity_is_server_derived',true,
  'mop_trace_exposes_abs_batch_logger_and_time',true,
  'direct_external_batch_table_access_stays_revoked',true,
  'anon_write_access_revoked',true,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
