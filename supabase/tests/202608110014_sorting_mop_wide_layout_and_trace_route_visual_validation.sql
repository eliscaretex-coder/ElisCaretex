-- ElisCaretex V2
-- Validation: 202608110014_sorting_mop_wide_layout_and_trace_route_visual_validation
-- Status: PREPARED — OWNER MUST RUN AFTER Migration 034
-- Structural/read-contract validation only. No scenario writes are performed.

begin;

do $$
declare
  v_def text;
  v_norm text;
begin
  if to_regprocedure('public.get_sorting_mop_recent_trace(integer)') is null then
    raise exception 'Validation 034 failed: get_sorting_mop_recent_trace RPC is missing.';
  end if;

  if not has_function_privilege('authenticated','public.get_sorting_mop_recent_trace(integer)','EXECUTE')
     or has_function_privilege('anon','public.get_sorting_mop_recent_trace(integer)','EXECUTE') then
    raise exception 'Validation 034 failed: MOP trace read RPC permission contract is incorrect.';
  end if;

  -- Existing private operational source tables must not become direct browser data APIs.
  if has_table_privilege('authenticated','public.sorting_mop_production_batches','SELECT')
     or has_table_privilege('authenticated','public.production_flow_external_batches','SELECT')
     or has_table_privilege('anon','public.sorting_mop_production_batches','SELECT')
     or has_table_privilege('anon','public.production_flow_external_batches','SELECT') then
    raise exception 'Validation 034 failed: private MOP/ABS source tables became directly readable by browser roles.';
  end if;

  select pg_get_functiondef('public.get_sorting_mop_recent_trace(integer)'::regprocedure)
  into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));

  if position('production_flow_items' in v_norm)=0
     or position('route_code_snapshot' in v_norm)=0
     or position('route_display_name_snapshot' in v_norm)=0
     or position('route_color_snapshot' in v_norm)=0
     or position('asroute_code' in v_norm)=0
     or position('asroute_display_name' in v_norm)=0
     or position('asroute_color' in v_norm)=0 then
    raise exception 'Validation 034 failed: MOP trace does not expose preserved Production Flow route code/name/color.';
  end if;

  -- Snapshot 93 contracts must remain present after replacing the read RPC.
  if position('sorting_mop_production_lines' in v_norm)=0
     or position('sorting_mop_production_trolleys' in v_norm)=0
     or position('production_flow_external_batches' in v_norm)=0
     or position('active_abs_batches' in v_norm)=0
     or position('recorded_by_name' in v_norm)=0
     or position('pending_abs_count' in v_norm)=0
     or position('posted_abs_count' in v_norm)=0 then
    raise exception 'Validation 034 failed: existing MOP production/trolley/shared-ABS trace contract regressed.';
  end if;
end;
$$;

select jsonb_build_object(
  'test','202608110014_sorting_mop_wide_layout_and_trace_route_visual_validation',
  'status','PASS',
  'trace_uses_preserved_production_flow_route_snapshot',true,
  'trace_exposes_route_code_name_and_color',true,
  'shared_abs_trace_preserved',true,
  'private_source_tables_stay_private',true,
  'anon_trace_access_revoked',true,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
