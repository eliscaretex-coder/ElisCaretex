-- ElisCaretex V2
-- Validation 036: Sorting Daily Tracker V2
-- Status: PREPARED — OWNER MUST RUN AFTER Migration 036
-- Structural/read-contract validation only. No scenario writes are performed.

begin;

do $$
declare
  v_def text;
  v_norm text;
  v_comment text;
begin
  if to_regprocedure('public.get_sorting_tracker_v2(date)') is null then
    raise exception 'Validation 036 failed: get_sorting_tracker_v2(date) is missing.';
  end if;

  if not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='get_sorting_tracker_v2'
      and pg_get_function_identity_arguments(p.oid)='p_business_date date'
      and p.prosecdef=true
      and p.provolatile='s'
  ) then
    raise exception 'Validation 036 failed: Tracker RPC must remain STABLE SECURITY DEFINER.';
  end if;

  if has_function_privilege('anon','public.get_sorting_tracker_v2(date)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_sorting_tracker_v2(date)','EXECUTE') then
    raise exception 'Validation 036 failed: Tracker RPC permission contract is incorrect.';
  end if;

  -- The Tracker RPC may read private evidence through its governed definer contract,
  -- but it must never require direct browser SELECT on those source tables.
  if has_table_privilege('authenticated','public.production_flow_items','SELECT')
     or has_table_privilege('authenticated','public.production_flow_events','SELECT')
     or has_table_privilege('authenticated','public.sorting_wash_runs','SELECT')
     or has_table_privilege('authenticated','public.sorting_wash_run_customers','SELECT')
     or has_table_privilege('authenticated','public.sorting_mop_production_batches','SELECT')
     or has_table_privilege('authenticated','public.production_flow_external_batches','SELECT')
     or has_table_privilege('anon','public.production_flow_items','SELECT')
     or has_table_privilege('anon','public.sorting_wash_runs','SELECT')
     or has_table_privilege('anon','public.sorting_mop_production_batches','SELECT')
     or has_table_privilege('anon','public.production_flow_external_batches','SELECT') then
    raise exception 'Validation 036 failed: private Tracker source tables became directly readable by browser roles.';
  end if;

  select pg_get_functiondef('public.get_sorting_tracker_v2(date)'::regprocedure)
  into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));

  if position('require_sorting_operational_access' in v_norm)=0
     or position($q$v.status='published'$q$ in v_norm)=0
     or position('customer_schedule_products' in v_norm)=0
     or position('production_flow_items' in v_norm)=0
     or position('sorting_wash_run_customers' in v_norm)=0
     or position('sorting_mop_production_batches' in v_norm)=0
     or position('production_flow_external_batches' in v_norm)=0
     or position($q$eb.status='active'$q$ in v_norm)=0
     or position($q$mb.status='recorded'$q$ in v_norm)=0 then
    raise exception 'Validation 036 failed: Tracker source-of-truth contract is incomplete.';
  end if;

  if position($q$'sorting_tracker_v2'$q$ in v_norm)=0
     or position($q$'production_flow_tracker_v2'$q$ in v_norm)=0
     or position($q$then'not_started'$q$ in v_norm)=0
     or position($q$then'washed_only'$q$ in v_norm)=0
     or position($q$then'abs_pending'$q$ in v_norm)=0
     or position($q$then'tracker_ok'$q$ in v_norm)=0
     or position($q$else'in_progress'$q$ in v_norm)=0 then
    raise exception 'Validation 036 failed: Tracker status/schema contract is incomplete.';
  end if;

  if position('insertinto' in v_norm)>0
     or position('updatepublic.' in v_norm)>0
     or position('deletefrom' in v_norm)>0
     or position('truncate' in v_norm)>0 then
    raise exception 'Validation 036 failed: Tracker read RPC contains an unexpected write statement.';
  end if;

  select obj_description('public.get_sorting_tracker_v2(date)'::regprocedure::oid,'pg_proc')
  into v_comment;
  if position('No tracker shadow table' in coalesce(v_comment,''))=0 then
    raise exception 'Validation 036 failed: Tracker no-shadow-table governance comment is missing.';
  end if;
end;
$$;

select jsonb_build_object(
  'test','202608110016_sorting_daily_tracker_v2_validation',
  'status','PASS',
  'tracker_read_model_present',true,
  'published_schedule_is_planned_source',true,
  'production_flow_is_operational_identity',true,
  'washing_is_recorded_source',true,
  'active_mop_revision_is_processed_source',true,
  'shared_abs_is_batch_source',true,
  'strict_tracker_schema_contract_present',true,
  'private_source_tables_stay_private',true,
  'anon_tracker_access_revoked',true,
  'tracker_shadow_table_created',false,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
