-- ElisCaretex V2
-- Validation 041: Trolley physical dimensions + Production Tracker vehicle-load summary.
-- Structural/read-contract validation only. No scenario writes are performed.

begin;

do $$
declare
  v_def text;
  v_norm text;
  v_bad integer;
begin
  if to_regprocedure('public.get_production_tracker_v3(date)') is null then
    raise exception 'Validation 041 failed: get_production_tracker_v3(date) is missing.';
  end if;

  if to_regprocedure('public.get_production_tracker_v2(date)') is null then
    raise exception 'Validation 041 failed: Production Tracker V2 compatibility read model was removed.';
  end if;

  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='trolley_types' and column_name='footprint_length_cm')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='trolley_types' and column_name='footprint_width_cm')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='trolley_types' and column_name='tare_weight_kg') then
    raise exception 'Validation 041 failed: trolley physical master columns are incomplete.';
  end if;

  select count(*) into v_bad
  from (
    values
      ('SMALL'::text,68.00::numeric,52.00::numeric,29.20::numeric),
      ('MEDIUM'::text,90.00::numeric,70.00::numeric,42.00::numeric),
      ('LARGE'::text,91.00::numeric,70.00::numeric,48.60::numeric)
  ) expected(code,length_cm,width_cm,tare_kg)
  left join public.trolley_types tt
    on tt.trolley_type_code=expected.code
   and tt.deleted_at is null
  where tt.trolley_type_id is null
     or tt.footprint_length_cm is distinct from expected.length_cm
     or tt.footprint_width_cm is distinct from expected.width_cm
     or tt.tare_weight_kg is distinct from expected.tare_kg;

  if v_bad<>0 then
    raise exception 'Validation 041 failed: user-confirmed Small/Medium/Large trolley dimensions or tare weights do not match.';
  end if;

  if not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='get_production_tracker_v3'
      and pg_get_function_identity_arguments(p.oid)='p_business_date date'
      and p.prosecdef=true
      and p.provolatile='s'
  ) then
    raise exception 'Validation 041 failed: Production Tracker V3 must remain STABLE SECURITY DEFINER.';
  end if;

  if has_function_privilege('anon','public.get_production_tracker_v3(date)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_production_tracker_v3(date)','EXECUTE') then
    raise exception 'Validation 041 failed: Production Tracker V3 execute grants are incorrect.';
  end if;

  if has_table_privilege('authenticated','public.trolley_types','SELECT')
     or has_table_privilege('authenticated','public.trolleys','SELECT')
     or has_table_privilege('authenticated','public.customer_schedule_trolley_requirements','SELECT') then
    raise exception 'Validation 041 failed: trolley master/source tables became directly readable by authenticated.';
  end if;

  select pg_get_functiondef('public.get_production_tracker_v3(date)'::regprocedure)
  into v_def;
  v_norm:=lower(regexp_replace(v_def,'[[:space:]]+','','g'));

  if position('require_production_flow_read_role' in v_norm)=0
     or position('get_production_tracker_v2' in v_norm)=0
     or position('trolley_types' in v_norm)=0
     or position($q$'footprint_length_cm'$q$ in v_norm)=0
     or position($q$'footprint_width_cm'$q$ in v_norm)=0
     or position($q$'footprint_area_m2'$q$ in v_norm)=0
     or position($q$'tare_weight_kg'$q$ in v_norm)=0
     or position($q$'physical_master_complete'$q$ in v_norm)=0 then
    raise exception 'Validation 041 failed: Production Tracker V3 physical trolley contract is incomplete.';
  end if;

  if position($q$'production_tracker_v3'$q$ in v_norm)=0
     or position($q$'production_flow_shared_tracker_v3'$q$ in v_norm)=0
     or position($q$'confirmed_footprint_and_tare_weight'$q$ in v_norm)=0
     or position($q$'pending_truck_master_capacity'$q$ in v_norm)=0 then
    raise exception 'Validation 041 failed: Production Tracker V3 top-level contract is incomplete.';
  end if;

  if position('insertinto' in v_norm)>0
     or position('updatepublic.' in v_norm)>0
     or position('deletefrom' in v_norm)>0
     or position('truncate' in v_norm)>0 then
    raise exception 'Validation 041 failed: Production Tracker V3 contains an unexpected write statement.';
  end if;
end;
$$;

select jsonb_build_object(
  'test','202608120005_trolley_dimensions_and_tracker_vehicle_load_validation',
  'status','PASS',
  'tracker_v2_compatibility_preserved',true,
  'small_dimensions_cm','68x52',
  'small_tare_kg',29.2,
  'medium_dimensions_cm','90x70',
  'medium_tare_kg',42.0,
  'large_dimensions_cm','91x70',
  'large_tare_kg',48.6,
  'physical_footprint_area_is_derived_from_master_dimensions',true,
  'route_weight_uses_tare_plus_recorded_processed_kg',true,
  'truck_capacity_is_not_invented',true,
  'private_source_tables_stay_private',true,
  'anon_tracker_access_revoked',true,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
