-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110003_production_flow_trace_typed_event_quantity_contract
--
-- Migration 022 already stored typed event quantity correctly in
-- production_flow_events:
--   quantity_value
--   quantity_unit
--   quantity_basis
--
-- The controlled Tracker read model omitted those fields from each returned
-- event object. This migration fixes only that RPC contract.
--
-- No Production Flow data is rewritten.
-- No security boundary is weakened.
-- =====================================================================

begin;

create or replace function public.get_production_flow_trace(
  p_production_flow_item_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_flow jsonb;
  v_events jsonb := '[]'::jsonb;
  v_batches jsonb := '[]'::jsonb;
  v_washes jsonb := '[]'::jsonb;
begin
  perform public.require_production_flow_read_role();

  select to_jsonb(pfi)
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=p_production_flow_item_id;

  if v_flow is null then
    raise exception using errcode='P0002', message='Production Flow Item was not found.';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'production_flow_event_id',pfe.production_flow_event_id,
      'event_type',pfe.event_type,
      'stage_code',pfe.stage_code,
      'stage_rank',pfe.stage_rank,
      'area_code',pfe.area_code,
      'business_date',pfe.business_date,
      'occurred_at',pfe.occurred_at,
      'recorded_at',pfe.recorded_at,
      'performed_by_staff_id',pfe.performed_by_staff_id,
      'performed_by_staff_name',performed.display_name,
      'recorded_by_staff_id',pfe.recorded_by_staff_id,
      'recorded_by_staff_name',recorded.display_name,
      'source_application',pfe.source_application,
      'source_entity_table',pfe.source_entity_table,
      'source_entity_id',pfe.source_entity_id,
      'quantity_value',pfe.quantity_value,
      'quantity_unit',pfe.quantity_unit,
      'quantity_basis',pfe.quantity_basis,
      'event_data',pfe.event_data
    )
    order by pfe.occurred_at,pfe.recorded_at,pfe.production_flow_event_id
  ),'[]'::jsonb)
  into v_events
  from public.production_flow_events pfe
  left join public.staff_members performed
    on performed.staff_id=pfe.performed_by_staff_id
  left join public.staff_members recorded
    on recorded.staff_id=pfe.recorded_by_staff_id
  where pfe.production_flow_item_id=p_production_flow_item_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'external_batch_id',b.production_flow_external_batch_id,
      'external_system_code',b.external_system_code,
      'batch_reference',b.batch_reference,
      'quantity',b.quantity,
      'unit_code',b.unit_code,
      'capture_source',b.capture_source,
      'status',b.status,
      'batch_number',b.batch_number,
      'batch_business_date',b.batch_business_date,
      'batch_week_start',b.batch_week_start,
      'supersedes_external_batch_id',b.supersedes_external_batch_id,
      'notes',b.notes,
      'correction_reason',b.correction_reason,
      'recorded_at',b.recorded_at,
      'recorded_by_staff_id',b.recorded_by_staff_id,
      'recorded_by_staff_name',sm.display_name
    )
    order by b.recorded_at,b.production_flow_external_batch_id
  ),'[]'::jsonb)
  into v_batches
  from public.production_flow_external_batches b
  left join public.staff_members sm
    on sm.staff_id=b.recorded_by_staff_id
  where b.production_flow_item_id=p_production_flow_item_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'wash_run_customer_id',wrc.wash_run_customer_id,
      'trace_code',wrc.trace_code,
      'wash_run_id',wr.wash_run_id,
      'wash_code',wr.wash_code,
      'business_date',wr.business_date,
      'status',wr.status,
      'entry_mode',wr.entry_mode,
      'washer_code',wr.washer_code_snapshot,
      'operator_staff_id',wr.operator_staff_id,
      'operator_name',wr.operator_name_snapshot,
      'started_at',wr.started_at,
      'registered_at',wr.registered_at,
      'wash_load_total_kg',wr.total_weight_kg,
      'customer_allocated_weight_kg',wrc.allocated_weight_kg,
      'weight_allocation_method',wrc.weight_allocation_method,
      'weight_allocation_customer_count',wrc.weight_allocation_customer_count,
      'allocation_is_estimate',wrc.weight_allocation_method='EQUAL_SPLIT_ESTIMATE',
      'weight_scope','CUSTOMER_ALLOCATION_FROM_WASH_LOAD'
    )
    order by wr.started_at,wr.registered_at,wrc.trace_code
  ),'[]'::jsonb)
  into v_washes
  from public.sorting_wash_run_customers wrc
  join public.sorting_wash_runs wr
    on wr.wash_run_id=wrc.wash_run_id
  where wrc.production_flow_item_id=p_production_flow_item_id;

  return jsonb_build_object(
    'status','success',
    'flow_item',v_flow,
    'events',v_events,
    'external_batches',v_batches,
    'washing_summary',jsonb_build_object(
      'active_allocated_kg',coalesce((v_flow->>'washed_kg_total')::numeric,0),
      'active_wash_load_count',coalesce((v_flow->>'washed_load_count')::integer,0),
      'active_wash_trace_count',coalesce((v_flow->>'washed_trace_count')::integer,0),
      'last_wash_at',v_flow->>'last_wash_at',
      'allocation_basis','CUSTOMER_ALLOCATED_FROM_WASH_LOAD'
    ),
    'washing_traces',v_washes
  );
end;
$$;


comment on function public.get_production_flow_trace(uuid) is
  'Controlled Production Flow trace for Tracker and authorized operational investigation. Event objects expose typed quantity_value, quantity_unit and quantity_basis in addition to event_data.';

commit;
