-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110002_production_flow_wash_weight_allocation_and_confirmation_guard
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Owner-role structural / backfill integrity checks
-- ---------------------------------------------------------------------

do $$
declare
  v_bad integer;
begin
  -- Every physical wash must reconcile exactly to the sum of customer allocations.
  select count(*)
  into v_bad
  from (
    select
      wr.wash_run_id,
      round(wr.total_weight_kg,2) as load_kg,
      round(coalesce(sum(wrc.allocated_weight_kg),0),2) as allocated_kg
    from public.sorting_wash_runs wr
    join public.sorting_wash_run_customers wrc
      on wrc.wash_run_id=wr.wash_run_id
    group by wr.wash_run_id,wr.total_weight_kg
    having round(wr.total_weight_kg,2)
       <> round(coalesce(sum(wrc.allocated_weight_kg),0),2)
  ) q;

  if v_bad <> 0 then
    raise exception 'Wash loads with non-reconciled customer KG allocation: %',v_bad;
  end if;

  -- Multi-customer loads must be explicitly labelled as estimates.
  select count(*)
  into v_bad
  from public.sorting_wash_run_customers wrc
  join (
    select wash_run_id,count(*)::integer as customer_count
    from public.sorting_wash_run_customers
    group by wash_run_id
    having count(*) > 1
  ) m on m.wash_run_id=wrc.wash_run_id
  where wrc.weight_allocation_method <> 'EQUAL_SPLIT_ESTIMATE'
     or wrc.weight_allocation_customer_count <> m.customer_count
     or wrc.allocated_weight_kg is null;

  if v_bad <> 0 then
    raise exception 'Multi-customer allocation rows are not consistently marked EQUAL_SPLIT_ESTIMATE: %',v_bad;
  end if;

  -- Single customer gets the full physical load.
  select count(*)
  into v_bad
  from public.sorting_wash_run_customers wrc
  join public.sorting_wash_runs wr
    on wr.wash_run_id=wrc.wash_run_id
  where (
      select count(*)
      from public.sorting_wash_run_customers same_run
      where same_run.wash_run_id=wrc.wash_run_id
    )=1
    and (
      wrc.weight_allocation_method <> 'FULL_LOAD'
      or round(wrc.allocated_weight_kg,2) <> round(wr.total_weight_kg,2)
    );

  if v_bad <> 0 then
    raise exception 'Single-customer FULL_LOAD allocations are invalid: %',v_bad;
  end if;

  -- Every trace must have a typed immutable KG event.
  select count(*)
  into v_bad
  from public.sorting_wash_run_customers wrc
  where wrc.production_flow_item_id is not null
    and not exists (
      select 1
      from public.production_flow_events pfe
      where pfe.production_flow_item_id=wrc.production_flow_item_id
        and pfe.event_type='WASH_WEIGHT_ALLOCATED'
        and pfe.source_entity_table='sorting_wash_run_customers'
        and pfe.source_entity_id=wrc.wash_run_customer_id::text
        and pfe.quantity_unit='KG'
        and round(pfe.quantity_value,2)=round(wrc.allocated_weight_kg,2)
    );

  if v_bad <> 0 then
    raise exception 'Wash traces missing typed WASH_WEIGHT_ALLOCATED event: %',v_bad;
  end if;

  -- Flow current summary must equal only active RECORDED wash allocations.
  select count(*)
  into v_bad
  from public.production_flow_items pfi
  left join lateral (
    select
      coalesce(sum(wrc.allocated_weight_kg),0)::numeric(14,2) as active_kg,
      count(distinct wr.wash_run_id)::integer as load_count,
      count(wrc.wash_run_customer_id)::integer as trace_count
    from public.sorting_wash_run_customers wrc
    join public.sorting_wash_runs wr
      on wr.wash_run_id=wrc.wash_run_id
     and wr.status='RECORDED'
    where wrc.production_flow_item_id=pfi.production_flow_item_id
  ) actual on true
  where round(pfi.washed_kg_total,2) <> round(actual.active_kg,2)
     or pfi.washed_load_count <> actual.load_count
     or pfi.washed_trace_count <> actual.trace_count;

  if v_bad <> 0 then
    raise exception 'Production Flow current wash summary does not match active source data: %',v_bad;
  end if;

  -- At least one real Development multi-customer wash should demonstrate exact split.
  if not exists (
    select 1
    from public.sorting_wash_run_customers wrc
    where wrc.weight_allocation_method='EQUAL_SPLIT_ESTIMATE'
  ) then
    raise exception 'No multi-customer wash exists to verify equal-split allocation.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Authenticated controlled trace / ABS weekly context
-- ---------------------------------------------------------------------

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
    order by pfi.washed_load_count desc,pfi.washed_kg_total desc,pfi.created_at
    limit 1
  ),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is null then
    raise exception 'No ADMIN auth user available for Validation 022.';
  end if;

  if nullif(current_setting('eliscaretex.validation.flow_id',true),'') is null then
    raise exception 'No washed Production Flow Item available for Validation 022.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_flow_id uuid := current_setting('eliscaretex.validation.flow_id')::uuid;
  v_trace jsonb;
  v_batch jsonb;
  v_exception_batch jsonb;
  v_batch_row jsonb;
begin
  if has_table_privilege('authenticated','public.sorting_wash_run_customers','SELECT') then
    raise exception 'sorting_wash_run_customers must remain private.';
  end if;

  if has_table_privilege('authenticated','public.production_flow_events','SELECT') then
    raise exception 'production_flow_events must remain private.';
  end if;

  v_trace := public.get_production_flow_trace(v_flow_id);

  if coalesce((v_trace->'washing_summary'->>'active_allocated_kg')::numeric,0) <= 0 then
    raise exception 'Controlled Flow trace does not expose active allocated wash KG.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_trace->'washing_traces','[]'::jsonb)) w
    where (w->>'customer_allocated_weight_kg') is not null
      and (w->>'weight_allocation_method') in ('FULL_LOAD','EQUAL_SPLIT_ESTIMATE')
  ) then
    raise exception 'Controlled Flow trace does not expose per-customer wash allocation.';
  end if;

  -- Typical observed ABS number.
  v_batch := public.record_production_flow_abs_batch(
    v_flow_id,
    '5',
    10.00,
    'KG',
    'Validation 022 typical weekly ABS batch number.'
  );

  v_trace := public.get_production_flow_trace(v_flow_id);

  select value
  into v_batch_row
  from jsonb_array_elements(coalesce(v_trace->'external_batches','[]'::jsonb))
  where value->>'external_batch_id'=v_batch->>'external_batch_id'
  limit 1;

  if (v_batch_row->>'batch_number')::integer <> 5
     or (v_batch_row->>'batch_week_start')::date
        <> public.production_roster_week_start((v_batch_row->>'batch_business_date')::date) then
    raise exception 'ABS weekly batch context was not stored correctly: %',v_batch_row;
  end if;

  -- Observed 1..999 is intentionally NOT a hard constraint.
  v_exception_batch := public.record_production_flow_abs_batch(
    v_flow_id,
    '1205',
    11.00,
    'KG',
    'Validation 022 allowed ABS numbering exception.'
  );

  if coalesce(v_exception_batch->>'status','success') <> 'success' then
    raise exception 'ABS numbering exception outside 1..999 was incorrectly rejected.';
  end if;

  v_trace := public.get_production_flow_trace(v_flow_id);

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_trace->'events','[]'::jsonb)) e
    where e->>'event_type'='WASH_WEIGHT_ALLOCATED'
      and e->>'quantity_unit'='KG'
      and (e->>'quantity_value')::numeric > 0
  ) then
    raise exception 'Controlled Tracker trace lacks typed wash KG event.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608110002_production_flow_wash_weight_allocation_and_confirmation_guard_validation',
  'all_wash_allocations_reconcile_exactly',true,
  'multi_customer_equal_split_estimate',true,
  'single_customer_full_load',true,
  'flow_active_washed_kg_sum',true,
  'typed_wash_kg_events',true,
  'controlled_trace_allocation',true,
  'abs_week_context_stored',true,
  'abs_1_to_999_not_hard_constrained',true,
  'private_source_tables_protected',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
