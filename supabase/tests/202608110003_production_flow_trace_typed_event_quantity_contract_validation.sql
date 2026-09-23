-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110003_production_flow_trace_typed_event_quantity_contract
-- =====================================================================

begin;

-- Confirm Migration 022 source data is already correct.
do $$
declare
  v_missing integer;
begin
  select count(*)
  into v_missing
  from public.production_flow_events pfe
  where pfe.event_type='WASH_WEIGHT_ALLOCATED'
    and (
      pfe.quantity_value is null
      or pfe.quantity_unit <> 'KG'
      or pfe.quantity_basis not in ('FULL_LOAD','EQUAL_SPLIT_ESTIMATE')
    );

  if v_missing <> 0 then
    raise exception 'Typed WASH_WEIGHT_ALLOCATED source rows are incomplete: %',v_missing;
  end if;

  if not exists (
    select 1
    from public.production_flow_items pfi
    where pfi.washed_kg_total > 0
  ) then
    raise exception 'No washed Production Flow Item is available for Validation 023.';
  end if;
end;
$$;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr
      on sr.staff_id=sm.staff_id
     and sr.active=true
    join public.roles r
      on r.role_id=sr.role_id
     and r.active=true
     and r.role_code='ADMIN'
    where sm.auth_user_id is not null
      and sm.deleted_at is null
    order by sm.created_at
    limit 1
  ),
  true
);

select set_config(
  'eliscaretex.validation.flow_id',
  (
    select pfi.production_flow_item_id::text
    from public.production_flow_items pfi
    where pfi.washed_load_count > 0
    order by
      pfi.washed_load_count desc,
      pfi.washed_kg_total desc,
      pfi.created_at,
      pfi.production_flow_item_id
    limit 1
  ),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is null then
    raise exception 'No ADMIN auth user available for Validation 023.';
  end if;

  if nullif(current_setting('eliscaretex.validation.flow_id',true),'') is null then
    raise exception 'No washed Flow Item available for Validation 023.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_flow_id uuid := current_setting('eliscaretex.validation.flow_id')::uuid;
  v_trace jsonb;
  v_summary_kg numeric;
  v_trace_event_kg numeric;
  v_source_event_kg numeric;
  v_trace_count integer;
begin
  if has_table_privilege('authenticated','public.production_flow_events','SELECT') then
    raise exception 'production_flow_events must remain private.';
  end if;

  v_trace := public.get_production_flow_trace(v_flow_id);

  v_summary_kg := coalesce(
    (v_trace->'washing_summary'->>'active_allocated_kg')::numeric,
    0
  );

  select
    coalesce(sum((e.value->>'quantity_value')::numeric),0),
    count(*)::integer
  into
    v_trace_event_kg,
    v_trace_count
  from jsonb_array_elements(coalesce(v_trace->'events','[]'::jsonb)) e
  where e.value->>'event_type'='WASH_WEIGHT_ALLOCATED'
    and e.value->>'quantity_unit'='KG'
    and e.value->>'quantity_basis' in ('FULL_LOAD','EQUAL_SPLIT_ESTIMATE');

  if v_trace_count < 1 then
    raise exception 'Controlled Tracker trace still lacks typed wash KG events.';
  end if;

  -- Source-table comparison is executed indirectly through the already selected
  -- Flow summary contract. Active current KG can differ from immutable historical
  -- event KG if cancelled/replaced washes exist, so the contract also verifies
  -- every active washing trace has a matching typed event.
  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_trace->'events','[]'::jsonb)) e
    where e.value->>'event_type'='WASH_WEIGHT_ALLOCATED'
      and e.value ? 'quantity_value'
      and e.value ? 'quantity_unit'
      and e.value ? 'quantity_basis'
  ) then
    raise exception 'Typed quantity fields are not present at event top level.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_trace->'washing_traces','[]'::jsonb)) w
    where w.value->>'status'='RECORDED'
      and not exists (
        select 1
        from jsonb_array_elements(coalesce(v_trace->'events','[]'::jsonb)) e
        where e.value->>'event_type'='WASH_WEIGHT_ALLOCATED'
          and e.value->>'source_entity_id'=w.value->>'wash_run_customer_id'
          and e.value->>'quantity_unit'='KG'
          and round((e.value->>'quantity_value')::numeric,2)
              = round((w.value->>'customer_allocated_weight_kg')::numeric,2)
      )
  ) then
    raise exception 'A RECORDED washing trace lacks its matching typed KG event.';
  end if;

  if v_summary_kg <= 0 then
    raise exception 'Controlled Flow washing summary must expose positive active KG.';
  end if;
end;
$$;

reset role;

-- Owner-side exact comparison for the selected Flow Item.
do $$
declare
  v_flow_id uuid := current_setting('eliscaretex.validation.flow_id')::uuid;
  v_source_event_kg numeric;
  v_source_active_kg numeric;
  v_flow_summary_kg numeric;
begin
  select coalesce(sum(pfe.quantity_value),0)
  into v_source_event_kg
  from public.production_flow_events pfe
  where pfe.production_flow_item_id=v_flow_id
    and pfe.event_type='WASH_WEIGHT_ALLOCATED'
    and pfe.quantity_unit='KG';

  select coalesce(sum(wrc.allocated_weight_kg),0)
  into v_source_active_kg
  from public.sorting_wash_run_customers wrc
  join public.sorting_wash_runs wr
    on wr.wash_run_id=wrc.wash_run_id
   and wr.status='RECORDED'
  where wrc.production_flow_item_id=v_flow_id;

  select pfi.washed_kg_total
  into v_flow_summary_kg
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_flow_id;

  if round(v_source_active_kg,2) <> round(v_flow_summary_kg,2) then
    raise exception
      'Active source KG % does not match Flow washed_kg_total %.',
      v_source_active_kg,
      v_flow_summary_kg;
  end if;

  if v_source_event_kg < v_source_active_kg then
    raise exception
      'Immutable event KG % cannot be less than active current KG %.',
      v_source_event_kg,
      v_source_active_kg;
  end if;
end;
$$;

select jsonb_build_object(
  'status','PASS',
  'test','202608110003_production_flow_trace_typed_event_quantity_contract_validation',
  'migration022_typed_event_data_intact',true,
  'tracker_event_quantity_value_exposed',true,
  'tracker_event_quantity_unit_exposed',true,
  'tracker_event_quantity_basis_exposed',true,
  'recorded_wash_trace_matches_typed_event',true,
  'flow_active_kg_matches_source',true,
  'immutable_event_history_not_less_than_active_kg',true,
  'production_flow_events_remains_private',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
