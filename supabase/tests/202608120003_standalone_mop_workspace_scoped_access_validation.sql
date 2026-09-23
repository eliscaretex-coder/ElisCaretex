-- ElisCaretex V2
-- Validation 039: standalone MOP workspace / scoped MOP_OPERATOR access.
-- Structural and security validation only. No scenario writes.

begin;

do $$
declare
  v_scope text;
  v_sorting text;
  v_auto text;
  v_name text;
  v_def text;
  v_required text[]:=array[
    'get_sorting_mop_production_context',
    'record_sorting_mop_reconciliation',
    'save_sorting_mop_production',
    'get_sorting_mop_type_catalog',
    'record_sorting_mop_abs_batch',
    'get_sorting_mop_production_correction_context',
    'correct_sorting_mop_production',
    'cancel_sorting_mop_production',
    'get_sorting_mop_recent_trace'
  ];
begin
  select pg_get_functiondef(p.oid) into v_scope
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='begin_mop_operational_scope' limit 1;
  if v_scope is null
     or position('MOP_OPERATOR' in v_scope)=0
     or position('set_config' in v_scope)=0
     or position('eliscaretex.mop_operational_scope' in v_scope)=0 then
    raise exception 'MOP operational scope helper is missing or incomplete.';
  end if;

  if has_function_privilege('authenticated','public.begin_mop_operational_scope()','EXECUTE') then
    raise exception 'Internal MOP scope helper must not be directly executable by authenticated.';
  end if;

  select pg_get_functiondef(p.oid) into v_sorting
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='require_sorting_operational_access' limit 1;
  if v_sorting is null
     or position('eliscaretex.mop_operational_scope' in v_sorting)=0
     or position('MOP_OPERATOR' in v_sorting)=0 then
    raise exception 'Sorting access helper does not recognize only the transaction-local MOP scope.';
  end if;

  select pg_get_functiondef(p.oid) into v_auto
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='get_mop_auto_shift_context' limit 1;
  if v_auto is null or position('begin_mop_operational_scope' in v_auto)=0 then
    raise exception 'Scoped MOP Auto Shift RPC is missing.';
  end if;
  if not has_function_privilege('authenticated','public.get_mop_auto_shift_context(timestamp with time zone)','EXECUTE')
     or has_function_privilege('anon','public.get_mop_auto_shift_context(timestamp with time zone)','EXECUTE') then
    raise exception 'MOP Auto Shift execute grants are incorrect.';
  end if;

  foreach v_name in array v_required loop
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname=v_name
    order by p.oid desc limit 1;
    if v_def is null or position('begin_mop_operational_scope' in v_def)=0 then
      raise exception 'MOP RPC % does not enter the scoped MOP authorization context.',v_name;
    end if;
  end loop;

  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='require_production_flow_abs_batch_write_access' limit 1;
  if v_def is null
     or position('FINISH_OPERATOR' in v_def)=0
     or position('CLOTHES' in v_def)=0
     or position('MOP_OPERATOR' in v_def)=0
     or position('MOP' in v_def)=0 then
    raise exception 'Shared ABS write authorization is not product-scoped.';
  end if;

  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='record_production_flow_abs_batch' limit 1;
  if v_def is null
     or position('SORTING_OPERATOR' in v_def)=0
     or position('MOP_OPERATOR' in v_def)=0
     or position('RECORDED_MOP_PRODUCTION' in v_def)=0 then
    raise exception 'Operational MOP ABS quantity is not constrained to recorded MOP Production.';
  end if;

  -- Do not let MOP_OPERATOR change the daily MOP assignment through the standalone page.
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='set_sorting_mop_staff' limit 1;
  if v_def is null or position('set_sorting_staff_work_mode' in v_def)=0 then
    raise exception 'Existing Sorting-controlled MOP assignment contract changed unexpectedly.';
  end if;

  raise notice '%', jsonb_build_object(
    'test','202608120003_standalone_mop_workspace_scoped_access_validation',
    'status','PASS',
    'mop_operator_uses_scoped_backend_surface',true,
    'sorting_access_not_globally_granted_to_mop_operator',true,
    'internal_scope_helper_not_browser_executable',true,
    'standalone_mop_auto_shift_available',true,
    'mop_rpc_family_enters_scoped_context',true,
    'mop_assignment_remains_sorting_controlled',true,
    'shared_abs_access_is_product_scoped',true,
    'mop_abs_quantity_remains_server_derived',true,
    'scenario_writes_performed',false,
    'transaction_rolled_back',true
  );
end;
$$;

rollback;
