-- Validation 030 V4
-- Permission-model correction: private trolley-schedule helper is verified structurally
-- and by privilege, but is never invoked while SET LOCAL ROLE authenticated is active.
-- Owner-run only. Do not treat as SQL VALIDATED until the owner reports PASS.

-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110010_sorting_mop_production_and_no_trolley_arrival
--
-- Owner-run validation. All optional scenario writes are rolled back.
-- =====================================================================

begin;

-- Structural checks run with migration-owner visibility first.
do $$
declare
  v_def text;
  v_cfg jsonb;
begin
  if to_regclass('public.sorting_non_trolley_arrivals') is null
     or to_regclass('public.sorting_mop_production_batches') is null
     or to_regclass('public.sorting_mop_production_lines') is null
     or to_regclass('public.sorting_mop_production_trolleys') is null
     or to_regclass('public.sorting_mop_reconciliations') is null then
    raise exception 'Migration 030 tables are incomplete.';
  end if;

  if to_regprocedure('public.record_sorting_non_trolley_arrival(text,uuid,date,text,uuid,text)') is null
     or to_regprocedure('public.get_sorting_trolley_intake_context_v3(text)') is null
     or to_regprocedure('public.get_sorting_customer_board_v4(text)') is null
     or to_regprocedure('public.get_sorting_mop_production_context(text,timestamp with time zone)') is null
     or to_regprocedure('public.record_sorting_mop_reconciliation(text,uuid,uuid,text,text)') is null
     or to_regprocedure('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text)') is null
     or to_regprocedure('public.sorting_schedule_product_has_trolley(uuid)') is null then
    raise exception 'Migration 030 RPC contract is incomplete.';
  end if;

  select value_json into v_cfg
  from public.app_config
  where config_key='sorting_mop_reconciliation';
  if coalesce(v_cfg->>'timezone','')<>'Europe/Dublin'
     or coalesce(v_cfg->>'cutoff_local_time','')<>'12:00:00'
     or nullif(v_cfg->>'enforcement_from','') is null then
    raise exception 'MOP reconciliation config is invalid: %',v_cfg;
  end if;

  v_def:=pg_get_functiondef('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text)'::regprocedure);
  if position('washed_trace_count<=0' in replace(v_def,' ',''))=0
     or position('UNKNOWN_LATE_ENTRY' in v_def)=0
     or position('Resolve %s overdue MOP delivery-day confirmation' in v_def)=0
     or position('customer_schedule_product_variants' in v_def)=0
     or position($q$pt.product_code='MOP'$q$ in replace(v_def,' ',''))=0 then
    raise exception 'MOP write function is missing a critical washed/reconciliation/trolley/variant-master guard.';
  end if;

  v_def:=pg_get_functiondef('public.get_sorting_trolley_intake_context_v3(text)'::regprocedure);
  if position('sorting_schedule_product_has_trolley' in v_def)=0
     or position('no_trolley_eligible' in v_def)=0
     or position('trolley_reception_expected' in v_def)=0 then
    raise exception 'Reception V3 does not derive no-trolley eligibility from the private schedule helper.';
  end if;

  v_def:=pg_get_functiondef('public.get_sorting_customer_board_v4(text)'::regprocedure);
  if position('sorting_schedule_product_has_trolley' in v_def)=0
     or position('no_trolley_eligible' in v_def)=0
     or position('trolley_reception_expected' in v_def)=0 then
    raise exception 'Washing board V4 does not derive no-trolley eligibility from the private schedule helper.';
  end if;

  if has_function_privilege('authenticated','public.sorting_schedule_product_has_trolley(uuid)','EXECUTE')
     or has_function_privilege('anon','public.sorting_schedule_product_has_trolley(uuid)','EXECUTE') then
    raise exception 'Private helper sorting_schedule_product_has_trolley(uuid) must not be executable by browser roles.';
  end if;

  v_def:=pg_get_functiondef('public.sorting_assert_wash_scan_gate(date,text,jsonb)'::regprocedure);
  if position('sorting_non_trolley_arrivals' in v_def)=0
     or position('Receive without trolley' in v_def)=0 then
    raise exception 'Washing gate does not include controlled no-trolley Reception evidence.';
  end if;

  v_def:=pg_get_functiondef('public.assign_trolley_to_customer_from_production(text,uuid,date,text,text,text)'::regprocedure);
  if position('SORTING_OPERATOR' in v_def)=0 then
    raise exception 'Sorting workstation is not allowed through the guarded MOP trolley assignment path.';
  end if;
end;
$$;

-- Use a real authenticated ADMIN identity for browser-facing RPC checks.
select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr on sr.staff_id=sm.staff_id and sr.active=true
    join public.roles r on r.role_id=sr.role_id and r.active=true and r.role_code='ADMIN'
    where sm.auth_user_id is not null and sm.deleted_at is null
    order by sm.created_at
    limit 1
  ),
  true
);

set local role authenticated;

do $$
declare
  v_reception jsonb;
  v_wash jsonb;
  v_mop_now jsonb;
  v_mop_noon jsonb;
  v_row jsonb;
begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is null then
    raise exception 'No ADMIN auth user available for Validation 030.';
  end if;

  if has_table_privilege('authenticated','public.sorting_non_trolley_arrivals','SELECT')
     or has_table_privilege('authenticated','public.sorting_mop_production_batches','SELECT')
     or has_table_privilege('authenticated','public.sorting_mop_reconciliations','SELECT') then
    raise exception 'New operational tables must remain private from authenticated browser sessions.';
  end if;

  if not has_function_privilege('authenticated','public.record_sorting_non_trolley_arrival(text,uuid,date,text,uuid,text)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_sorting_trolley_intake_context_v3(text)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_sorting_customer_board_v4(text)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_sorting_mop_production_context(text,timestamp with time zone)','EXECUTE')
     or not has_function_privilege('authenticated','public.record_sorting_mop_reconciliation(text,uuid,uuid,text,text)','EXECUTE')
     or not has_function_privilege('authenticated','public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text)','EXECUTE') then
    raise exception 'Authenticated workstation is missing one or more Migration 030 RPC permissions.';
  end if;

  if has_function_privilege('anon','public.record_sorting_non_trolley_arrival(text,uuid,date,text,uuid,text)','EXECUTE')
     or has_function_privilege('anon','public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text)','EXECUTE') then
    raise exception 'Anon must not execute new Reception/MOP write RPCs.';
  end if;

  v_reception:=public.get_sorting_trolley_intake_context_v3('MORNING');
  if jsonb_typeof(coalesce(v_reception->'board','[]'::jsonb))<>'array'
     or coalesce(v_reception->>'source','') not like '%NO_TROLLEY%' then
    raise exception 'Reception V3 contract is invalid: %',v_reception;
  end if;

  v_wash:=public.get_sorting_customer_board_v4('MORNING');
  if jsonb_typeof(coalesce(v_wash->'customers','[]'::jsonb))<>'array'
     or coalesce(v_wash->>'wash_scan_gate_required','false')::boolean<>true then
    raise exception 'Washing board V4 contract is invalid: %',v_wash;
  end if;

  -- Do not invoke the private schedule helper under the authenticated role.
  -- The structural block above proves that Reception derives these flags from that
  -- helper, while this browser-role block checks the returned contract is coherent.
  for v_row in select value from jsonb_array_elements(coalesce(v_reception->'board','[]'::jsonb))
  loop
    if coalesce((v_row->>'no_trolley_eligible')::boolean,false) then
      if nullif(v_row->>'schedule_product_id','') is null
         or coalesce((v_row->>'trolley_reception_expected')::boolean,true) then
        raise exception 'Reception returned an inconsistent no-trolley eligibility row: %',v_row;
      end if;
    end if;
  end loop;

  v_mop_now:=public.get_sorting_mop_production_context('MORNING',now());
  if jsonb_typeof(coalesce(v_mop_now->'queue','[]'::jsonb))<>'array'
     or jsonb_typeof(coalesce(v_mop_now->'recent_production','[]'::jsonb))<>'array' then
    raise exception 'MOP Production context JSON contract is invalid: %',v_mop_now;
  end if;

  -- The queue must contain washed MOP only.
  for v_row in select value from jsonb_array_elements(coalesce(v_mop_now->'queue','[]'::jsonb))
  loop
    if coalesce((v_row->>'washed_load_count')::integer,0)<=0
       or coalesce((v_row->>'washed_trace_count')::integer,0)<=0
       or coalesce((v_row->>'washed_kg_total')::numeric,0)<0 then
      raise exception 'MOP queue contains a non-washed Flow item: %',v_row;
    end if;
  end loop;

  -- Read-model cutoff can be simulated without writing data.
  v_mop_noon:=public.get_sorting_mop_production_context(
    'MORNING',
    ((now() at time zone 'Europe/Dublin')::date + time '12:01') at time zone 'Europe/Dublin'
  );
  if coalesce(v_mop_noon->>'cutoff_local_time','')<>'12:00:00' then
    raise exception 'MOP cutoff was not preserved in simulated-noon context: %',v_mop_noon;
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608110010_sorting_mop_production_and_no_trolley_arrival_validation',
  'only_washed_mop_enters_queue',true,
  'no_trolley_reception_is_schedule_guarded',true,
  'private_trolley_schedule_helper_not_exposed',true,
  'washing_accepts_controlled_no_trolley_contents',true,
  'delivery_day_cutoff_local_time','12:00:00 Europe/Dublin',
  'late_trolley_unknown_is_explicit',true,
  'new_operational_tables_stay_private',true,
  'anon_write_access_revoked',true,
  'scenario_writes_performed',false,
  'transaction_rolled_back',true
) as validation_result;

rollback;
