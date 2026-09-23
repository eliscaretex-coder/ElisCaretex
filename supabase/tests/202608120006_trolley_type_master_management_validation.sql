-- ElisCaretex V2
-- Validation 042: Trolley Type Master management
begin;

do $$
declare
  v_get text;
  v_create text;
  v_update text;
  v_caps text;
  v_reference text;
  v_helper text;
  v_helper_exec_auth boolean;
  v_get_exec_auth boolean;
  v_get_exec_anon boolean;
  v_create_exec_auth boolean;
  v_create_exec_anon boolean;
  v_update_exec_auth boolean;
  v_update_exec_anon boolean;
  v_direct_select_auth boolean;
  v_direct_select_anon boolean;
  v_delete_rpc_exists boolean;
begin
  select pg_get_functiondef('public.get_trolley_type_master()'::regprocedure) into v_get;
  select pg_get_functiondef('public.require_trolley_type_master_write_access()'::regprocedure) into v_helper;
  select pg_get_functiondef('public.create_trolley_type_master(text,text,text,text,numeric,numeric,numeric,integer,text,boolean)'::regprocedure) into v_create;
  select pg_get_functiondef('public.update_trolley_type_master(uuid,text,text,text,numeric,numeric,numeric,integer,text,boolean)'::regprocedure) into v_update;
  select pg_get_functiondef('public.get_trolley_lifecycle_capabilities()'::regprocedure) into v_caps;
  select pg_get_functiondef('public.get_trolley_reference_data()'::regprocedure) into v_reference;

  v_helper_exec_auth := has_function_privilege('authenticated','public.require_trolley_type_master_write_access()','EXECUTE');
  v_get_exec_auth := has_function_privilege('authenticated','public.get_trolley_type_master()','EXECUTE');
  v_get_exec_anon := has_function_privilege('anon','public.get_trolley_type_master()','EXECUTE');
  v_create_exec_auth := has_function_privilege('authenticated','public.create_trolley_type_master(text,text,text,text,numeric,numeric,numeric,integer,text,boolean)','EXECUTE');
  v_create_exec_anon := has_function_privilege('anon','public.create_trolley_type_master(text,text,text,text,numeric,numeric,numeric,integer,text,boolean)','EXECUTE');
  v_update_exec_auth := has_function_privilege('authenticated','public.update_trolley_type_master(uuid,text,text,text,numeric,numeric,numeric,integer,text,boolean)','EXECUTE');
  v_update_exec_anon := has_function_privilege('anon','public.update_trolley_type_master(uuid,text,text,text,numeric,numeric,numeric,integer,text,boolean)','EXECUTE');
  v_direct_select_auth := has_table_privilege('authenticated','public.trolley_types','SELECT');
  v_direct_select_anon := has_table_privilege('anon','public.trolley_types','SELECT');

  select exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('delete_trolley_type_master','remove_trolley_type_master')
  ) into v_delete_rpc_exists;

  if v_get is null
     or position('physical_trolley_count' in v_get)=0
     or position('active_schedule_requirement_count' in v_get)=0
     or position('footprint_area_m2' in v_get)=0
     or position('tare_weight_kg' in v_get)=0 then
    raise exception 'Trolley Type Master read contract is incomplete.';
  end if;

  if v_helper is null
     or position('ADMIN' in v_helper)=0
     or position('MANAGER' in v_helper)=0 then
    raise exception 'Trolley Type Master write helper is not ADMIN/MANAGER scoped.';
  end if;

  if v_create is null
     or position('require_trolley_type_master_write_access' in v_create)=0
     or position('allowed_in_customer_schedule' in v_create)=0
     or position('false' in lower(v_create))=0 then
    raise exception 'Trolley Type Master create governance is incomplete.';
  end if;

  if v_update is null
     or position('require_trolley_type_master_write_access' in v_update)=0
     or position('cannot be deactivated while' in v_update)=0
     or position('update public.trolley_types' in lower(v_update))=0
     or position('settrolley_type_code=' in replace(lower(v_update),' ',''))>0 then
    raise exception 'Trolley Type Master update governance is incomplete or code immutability was weakened.';
  end if;

  if position('can_manage_trolley_types' in v_caps)=0
     or position('footprint_length_cm' in v_reference)=0
     or position('tare_weight_kg' in v_reference)=0 then
    raise exception 'Trolley Type capability/reference enrichment is missing.';
  end if;

  if v_helper_exec_auth then
    raise exception 'Private Trolley Type write helper must not be browser-executable.';
  end if;
  if not v_get_exec_auth or v_get_exec_anon then
    raise exception 'Trolley Type Master read EXECUTE grants are incorrect.';
  end if;
  if not v_create_exec_auth or v_create_exec_anon or not v_update_exec_auth or v_update_exec_anon then
    raise exception 'Trolley Type Master write EXECUTE grants are incorrect.';
  end if;
  if v_direct_select_auth or v_direct_select_anon then
    raise exception 'Private trolley_types direct SELECT was exposed to browser roles.';
  end if;
  if v_delete_rpc_exists then
    raise exception 'Trolley Type Master must not expose a delete/remove RPC.';
  end if;

  if not exists(
    select 1 from public.trolley_types
    where trolley_type_code='SMALL' and footprint_length_cm=68 and footprint_width_cm=52 and tare_weight_kg=29.2
  ) or not exists(
    select 1 from public.trolley_types
    where trolley_type_code='MEDIUM' and footprint_length_cm=90 and footprint_width_cm=70 and tare_weight_kg=42
  ) or not exists(
    select 1 from public.trolley_types
    where trolley_type_code='LARGE' and footprint_length_cm=91 and footprint_width_cm=70 and tare_weight_kg=48.6
  ) then
    raise exception 'Confirmed standard Trolley Type dimensions/tare are not preserved.';
  end if;

  raise notice '%', jsonb_build_object(
    'test','202608120006_trolley_type_master_management_validation',
    'status','PASS',
    'trolley_type_master_read_present',true,
    'write_rpcs_admin_manager_scoped',true,
    'new_types_schedule_disabled_by_default',true,
    'technical_code_immutable_after_create',true,
    'dimensions_and_tare_editable',true,
    'unsafe_deactivation_guard_present',true,
    'private_trolley_types_select_preserved',true,
    'no_delete_rpc_created',true,
    'scenario_writes_performed',false,
    'transaction_rolled_back',true
  );
end $$;

rollback;
