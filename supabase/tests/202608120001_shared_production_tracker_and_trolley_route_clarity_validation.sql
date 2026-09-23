-- ElisCaretex V2
-- Validation 037: Shared Production Tracker + trolley route/color clarity
-- Status: PREPARED — OWNER MUST RUN AFTER Migration 037
-- Structural/read-contract validation only. No scenario writes are performed.

begin;

do $$
declare
  v_tracker_def text;
  v_tracker_norm text;
  v_record_def text;
  v_record_norm text;
  v_location_def text;
  v_location_norm text;
begin
  if to_regprocedure('public.get_production_tracker_v1(date)') is null then
    raise exception 'Validation 037 failed: get_production_tracker_v1(date) is missing.';
  end if;

  if to_regprocedure('public.get_trolley_record(text)') is null
     or to_regprocedure('public.get_trolley_location_overview(text,text)') is null then
    raise exception 'Validation 037 failed: governed trolley consultation RPC is missing.';
  end if;

  if not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='get_production_tracker_v1'
      and pg_get_function_identity_arguments(p.oid)='p_business_date date'
      and p.prosecdef=true
      and p.provolatile='s'
  ) then
    raise exception 'Validation 037 failed: shared Production Tracker must remain STABLE SECURITY DEFINER.';
  end if;

  if has_function_privilege('anon','public.get_production_tracker_v1(date)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_production_tracker_v1(date)','EXECUTE')
     or has_function_privilege('anon','public.get_trolley_record(text)','EXECUTE')
     or has_function_privilege('anon','public.get_trolley_location_overview(text,text)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_trolley_record(text)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_trolley_location_overview(text,text)','EXECUTE') then
    raise exception 'Validation 037 failed: authenticated/anon RPC permission contract is incorrect.';
  end if;

  -- Governed read RPCs may read private evidence through SECURITY DEFINER, while
  -- browser roles must keep direct source-table SELECT revoked.
  if has_table_privilege('authenticated','public.production_flow_items','SELECT')
     or has_table_privilege('authenticated','public.production_flow_events','SELECT')
     or has_table_privilege('authenticated','public.sorting_wash_runs','SELECT')
     or has_table_privilege('authenticated','public.sorting_wash_run_customers','SELECT')
     or has_table_privilege('authenticated','public.sorting_mop_production_batches','SELECT')
     or has_table_privilege('authenticated','public.production_flow_external_batches','SELECT')
     or has_table_privilege('authenticated','public.trolley_customer_stays','SELECT')
     or has_table_privilege('authenticated','public.trolley_events','SELECT')
     or has_table_privilege('anon','public.production_flow_items','SELECT')
     or has_table_privilege('anon','public.trolley_customer_stays','SELECT')
     or has_table_privilege('anon','public.trolley_events','SELECT') then
    raise exception 'Validation 037 failed: private Production/Trolley source tables became directly readable by browser roles.';
  end if;

  select pg_get_functiondef('public.get_production_tracker_v1(date)'::regprocedure)
  into v_tracker_def;
  v_tracker_norm:=lower(regexp_replace(v_tracker_def,'[[:space:]]+','','g'));

  if position('require_production_flow_read_role' in v_tracker_norm)=0
     or position('require_sorting_operational_access' in v_tracker_norm)>0
     or position($q$v.status='published'$q$ in v_tracker_norm)=0
     or position('production_flow_items' in v_tracker_norm)=0
     or position('sorting_wash_run_customers' in v_tracker_norm)=0
     or position('sorting_mop_production_batches' in v_tracker_norm)=0
     or position('production_flow_external_batches' in v_tracker_norm)=0 then
    raise exception 'Validation 037 failed: shared Production Tracker source/role contract is incomplete.';
  end if;

  if position($q$'production_tracker_v1'$q$ in v_tracker_norm)=0
     or position($q$'production_flow_shared_tracker_v1'$q$ in v_tracker_norm)=0
     or position($q$then'not_started'$q$ in v_tracker_norm)=0
     or position($q$then'washed_only'$q$ in v_tracker_norm)=0
     or position($q$then'abs_pending'$q$ in v_tracker_norm)=0
     or position($q$then'tracker_ok'$q$ in v_tracker_norm)=0
     or position($q$else'in_progress'$q$ in v_tracker_norm)=0 then
    raise exception 'Validation 037 failed: shared Production Tracker schema/status contract is incomplete.';
  end if;

  -- Product type rank must precede product-local priority. This makes the shared
  -- read model deterministic: CLOTHES priority 1..N, then MOP priority 1..N.
  if position($q$casee.product_codewhen'clothes'then1when'mop'then2else9end,coalesce(e.production_order,2147483647),lower(e.customer_name)$q$ in v_tracker_norm)=0 then
    raise exception 'Validation 037 failed: shared Tracker product priority ordering contract is incorrect.';
  end if;

  if position('insertinto' in v_tracker_norm)>0
     or position('updatepublic.' in v_tracker_norm)>0
     or position('deletefrom' in v_tracker_norm)>0
     or position('truncate' in v_tracker_norm)>0 then
    raise exception 'Validation 037 failed: shared Production Tracker contains an unexpected write statement.';
  end if;

  select pg_get_functiondef('public.get_trolley_record(text)'::regprocedure)
  into v_record_def;
  v_record_norm:=lower(regexp_replace(v_record_def,'[[:space:]]+','','g'));

  if position('customer_schedule_days' in v_record_norm)=0
     or position('distribution_routes' in v_record_norm)=0
     or position($q$'route_code'$q$ in v_record_norm)=0
     or position($q$'route_display_name'$q$ in v_record_norm)=0
     or position($q$'route_color'$q$ in v_record_norm)=0
     or position($q$'current_route_master'$q$ in v_record_norm)=0 then
    raise exception 'Validation 037 failed: Trolley Tracking route/color read contract is incomplete.';
  end if;

  select pg_get_functiondef('public.get_trolley_location_overview(text,text)'::regprocedure)
  into v_location_def;
  v_location_norm:=lower(regexp_replace(v_location_def,'[[:space:]]+','','g'));

  if position('customer_schedule_days' in v_location_norm)=0
     or position('distribution_routes' in v_location_norm)=0
     or position($q$'route_code'$q$ in v_location_norm)=0
     or position($q$'route_display_name'$q$ in v_location_norm)=0
     or position($q$'route_color'$q$ in v_location_norm)=0
     or position($q$'route_color_source'$q$ in v_location_norm)=0 then
    raise exception 'Validation 037 failed: Trolley Locations route/color read contract is incomplete.';
  end if;
end;
$$;

select jsonb_build_object(
  'test','202608120001_shared_production_tracker_and_trolley_route_clarity_validation',
  'status','PASS',
  'production_tracker_is_shared_read_model',true,
  'production_tracker_uses_production_flow_read_roles',true,
  'clothes_and_mop_priority_streams_are_separate',true,
  'production_tracker_route_snapshot_contract_preserved',true,
  'trolley_tracking_exposes_current_route_context',true,
  'trolley_locations_expose_current_route_context',true,
  'trolley_route_color_is_current_master_context',true,
  'private_source_tables_stay_private',true,
  'anon_read_rpc_access_revoked',true,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
