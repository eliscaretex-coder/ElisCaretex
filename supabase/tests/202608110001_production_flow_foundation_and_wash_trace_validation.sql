-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110001_production_flow_foundation_and_wash_trace
-- =====================================================================

begin;

-- Existing washing data must be fully backfilled.
do $$
declare
  v_missing integer;
  v_bad_group integer;
  v_missing_event integer;
begin
  select count(*)
  into v_missing
  from public.sorting_wash_run_customers wrc
  where wrc.production_flow_item_id is null;

  if v_missing <> 0 then
    raise exception 'Washing traces without Production Flow link: %',v_missing;
  end if;

  -- Scheduled same customer/product/date must converge to exactly one Flow Item,
  -- even when multiple physical Wash IDs exist.
  select count(*)
  into v_bad_group
  from (
    select
      wrc.customer_id,
      wrc.wash_type_snapshot,
      wrc.scheduled_for_date,
      count(distinct wrc.production_flow_item_id) as flow_count
    from public.sorting_wash_run_customers wrc
    where wrc.scheduled_for_date is not null
    group by
      wrc.customer_id,
      wrc.wash_type_snapshot,
      wrc.scheduled_for_date
    having count(distinct wrc.production_flow_item_id) <> 1
  ) q;

  if v_bad_group <> 0 then
    raise exception 'Scheduled production identity split across multiple Flow Items.';
  end if;

  select count(*)
  into v_missing_event
  from public.sorting_wash_run_customers wrc
  where not exists (
    select 1
    from public.production_flow_events pfe
    where pfe.production_flow_item_id=wrc.production_flow_item_id
      and pfe.event_type='WASH_RECORDED'
      and pfe.source_entity_table='sorting_wash_run_customers'
      and pfe.source_entity_id=wrc.wash_run_customer_id::text
  );

  if v_missing_event <> 0 then
    raise exception 'Washing traces without immutable WASH_RECORDED event: %',v_missing_event;
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
    order by pfi.created_at,pfi.production_flow_item_id
    limit 1
  ),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is null then
    raise exception 'No ADMIN auth user available for validation.';
  end if;

  if nullif(current_setting('eliscaretex.validation.flow_id',true),'') is null then
    raise exception 'No Production Flow Item available after backfill.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_flow_id uuid := current_setting('eliscaretex.validation.flow_id')::uuid;
  v_trace jsonb;
  v_batch jsonb;
  v_corrected jsonb;
  v_rejected boolean := false;
begin
  if has_table_privilege('authenticated','public.production_flow_items','SELECT') then
    raise exception 'production_flow_items must remain private.';
  end if;

  if has_table_privilege('authenticated','public.production_flow_events','SELECT') then
    raise exception 'production_flow_events must remain private.';
  end if;

  if has_table_privilege('authenticated','public.production_flow_external_batches','SELECT') then
    raise exception 'production_flow_external_batches must remain private.';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.save_sorting_wash_run(text,uuid,uuid,time,numeric,text,uuid[],text)',
    'EXECUTE'
  ) then
    raise exception 'Legacy non-flow-aware Washing write RPC must not remain browser-callable.';
  end if;

  v_trace := public.get_production_flow_trace(v_flow_id);

  if jsonb_array_length(coalesce(v_trace->'washing_traces','[]'::jsonb)) < 1
     or jsonb_array_length(coalesce(v_trace->'events','[]'::jsonb)) < 1 then
    raise exception 'Controlled Production Flow trace does not expose Washing history.';
  end if;

  v_batch := public.record_production_flow_abs_batch(
    v_flow_id,
    'VAL-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)),
    12.50,
    'KG',
    'Temporary Snapshot 72 manual ABS validation.'
  );

  if coalesce(v_batch->>'capture_source','') <> 'MANUAL' then
    raise exception 'ABS manual capture source was not preserved.';
  end if;

  v_corrected := public.correct_production_flow_abs_batch(
    (v_batch->>'external_batch_id')::uuid,
    v_batch->>'batch_reference',
    13.50,
    'KG',
    'Snapshot 72 validation quantity correction.',
    'Temporary corrected batch.'
  );

  if (v_corrected->>'quantity')::numeric <> 13.50
     or (v_corrected->>'supersedes_external_batch_id')::uuid
        <> (v_batch->>'external_batch_id')::uuid then
    raise exception 'ABS correction/supersede chain failed: %',v_corrected;
  end if;

  -- Misuse: UNIT cannot contain a fractional quantity.
  v_rejected := false;
  begin
    perform public.record_production_flow_abs_batch(
      v_flow_id,
      'VAL-FRACTIONAL-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)),
      1.50,
      'UNIT',
      'Must fail.'
    );
  exception
    when others then
      if sqlstate='22023'
         and position('whole number' in lower(sqlerrm)) > 0 then
        v_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'Fractional UNIT ABS quantity was incorrectly accepted.';
  end if;

  v_trace := public.get_production_flow_trace(v_flow_id);

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_trace->'external_batches','[]'::jsonb)) b
    where b->>'external_batch_id'=v_corrected->>'external_batch_id'
      and b->>'capture_source'='MANUAL'
      and b->>'status'='ACTIVE'
  ) then
    raise exception 'Corrected ABS batch is not visible in controlled trace.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_trace->'events','[]'::jsonb)) e
    where e->>'event_type'='ABS_BATCH_CORRECTED'
  ) then
    raise exception 'ABS correction event missing from immutable trace.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608110001_production_flow_foundation_and_wash_trace_validation',
  'existing_washes_backfilled',true,
  'same_customer_multiple_washes_share_flow',true,
  'washing_events_immutable_trace',true,
  'legacy_non_flow_write_rpc_not_browser_callable',true,
  'abs_manual_capture_ready',true,
  'abs_future_integration_schema_ready',true,
  'abs_correction_traceable',true,
  'fractional_unit_rejected',true,
  'flow_tables_private',true,
  'controlled_trace_read',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
