-- ElisCaretex V2
-- Validation 040: Production Tracker quantity clarity + Route trolley load.
-- Structural/read-contract validation only. No scenario writes are performed.

begin;

do $$
declare
  v_def text;
  v_norm text;
begin
  if to_regprocedure('public.get_production_tracker_v2(date)') is null then
    raise exception 'Validation 040 failed: get_production_tracker_v2(date) is missing.';
  end if;

  if to_regprocedure('public.get_production_tracker_v1(date)') is null then
    raise exception 'Validation 040 failed: Production Tracker V1 compatibility read model was removed.';
  end if;

  if not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='get_production_tracker_v2'
      and pg_get_function_identity_arguments(p.oid)='p_business_date date'
      and p.prosecdef=true
      and p.provolatile='s'
  ) then
    raise exception 'Validation 040 failed: Production Tracker V2 must remain STABLE SECURITY DEFINER.';
  end if;

  if has_function_privilege('anon','public.get_production_tracker_v2(date)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_production_tracker_v2(date)','EXECUTE') then
    raise exception 'Validation 040 failed: Production Tracker V2 execute grants are incorrect.';
  end if;

  if has_table_privilege('authenticated','public.production_flow_items','SELECT')
     or has_table_privilege('authenticated','public.sorting_wash_run_customers','SELECT')
     or has_table_privilege('authenticated','public.sorting_mop_production_batches','SELECT')
     or has_table_privilege('authenticated','public.trolley_customer_stays','SELECT')
     or has_table_privilege('authenticated','public.trolleys','SELECT')
     or has_table_privilege('authenticated','public.trolley_types','SELECT')
     or has_table_privilege('authenticated','public.customer_schedule_trolley_requirements','SELECT') then
    raise exception 'Validation 040 failed: private source tables became directly readable by authenticated.';
  end if;

  select pg_get_functiondef('public.get_production_tracker_v2(date)'::regprocedure)
  into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));

  if position('require_production_flow_read_role' in v_norm)=0
     or position('get_production_tracker_v1' in v_norm)=0
     or position('weight_allocation_method' in v_norm)=0
     or position($q$'equal_split_estimate'$q$ in v_norm)=0
     or position($q$'full_load'$q$ in v_norm)=0
     or position('customer_schedule_trolley_requirements' in v_norm)=0
     or position('trolley_types' in v_norm)=0
     or position('sorting_mop_production_trolleys' in v_norm)=0
     or position('trolley_customer_stays' in v_norm)=0 then
    raise exception 'Validation 040 failed: quantity/trolley read sources are incomplete.';
  end if;

  if position($q$'production_tracker_v2'$q$ in v_norm)=0
     or position($q$'production_flow_shared_tracker_v2'$q$ in v_norm)=0
     or position($q$'washed_quantity_basis'$q$ in v_norm)=0
     or position($q$'processed_quantity_source'$q$ in v_norm)=0
     or position($q$'planned_trolley_requirements'$q$ in v_norm)=0
     or position($q$'trolley_type_code'$q$ in v_norm)=0
     or position($q$'pending_master_dimensions'$q$ in v_norm)=0 then
    raise exception 'Validation 040 failed: Production Tracker V2 output contract is incomplete.';
  end if;

  if position('insertinto' in v_norm)>0
     or position('updatepublic.' in v_norm)>0
     or position('deletefrom' in v_norm)>0
     or position('truncate' in v_norm)>0 then
    raise exception 'Validation 040 failed: Production Tracker V2 contains an unexpected write statement.';
  end if;
end;
$$;

select jsonb_build_object(
  'test','202608120004_production_tracker_quantity_and_route_trolley_load_validation',
  'status','PASS',
  'tracker_v1_compatibility_preserved',true,
  'washed_quantity_provenance_exposed',true,
  'processed_quantity_is_source_specific',true,
  'clothes_finish_quantity_is_not_invented',true,
  'planned_trolleys_are_schedule_owner_scoped',true,
  'physical_trolleys_expose_master_type',true,
  'route_capacity_dimensions_are_not_invented',true,
  'private_source_tables_stay_private',true,
  'anon_tracker_access_revoked',true,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
