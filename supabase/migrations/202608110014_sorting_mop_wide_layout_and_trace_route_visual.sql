-- ElisCaretex V2
-- Migration: 202608110014_sorting_mop_wide_layout_and_trace_route_visual
-- Status: PREPARED — OWNER MUST RUN
-- Purpose: Extend the already-validated MOP Trace read model with preserved Production Flow route metadata.
-- Frontend width/image changes are source-only and do not require database state beyond this read-contract extension.

begin;

create or replace function public.get_sorting_mop_recent_trace(
  p_limit integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,30),1),100);
  v_rows jsonb := '[]'::jsonb;
  v_pending integer := 0;
  v_posted integer := 0;
begin
  perform public.require_sorting_operational_access();

  with recent as (
    select mb.*
    from public.sorting_mop_production_batches mb
    where mb.status='RECORDED'
    order by mb.recorded_at desc,mb.mop_production_batch_id desc
    limit v_limit
  ), trace_rows as (
    select
      mb.mop_production_batch_id,
      mb.production_flow_item_id,
      mb.customer_id,
      mb.customer_name_snapshot as customer_name,
      pfi.route_code_snapshot as route_code,
      pfi.route_display_name_snapshot as route_display_name,
      pfi.route_color_snapshot as route_color,
      mb.business_date,
      mb.scheduled_for_date,
      mb.delivery_due_date,
      mb.operator_staff_id,
      sm.display_name as operator_name,
      mb.entry_mode,
      mb.physical_processed_on,
      mb.physical_processed_time,
      mb.physical_time_precision,
      mb.total_weight_kg as total_kg,
      mb.total_units,
      mb.trolley_capture_status,
      mb.planned_output_trolley_quantity,
      mb.recorded_at,
      mb.notes,
      coalesce(lines.lines,'[]'::jsonb) as lines,
      coalesce(trolleys.trolley_codes,'[]'::jsonb) as trolley_codes,
      coalesce(abs_data.active_abs_batches,'[]'::jsonb) as active_abs_batches,
      coalesce(abs_data.abs_history_count,0)::integer as abs_history_count,
      case when coalesce(abs_data.active_abs_count,0)>0 then 'POSTED' else 'PENDING' end as abs_status
    from recent mb
    left join public.staff_members sm on sm.staff_id=mb.operator_staff_id
    join public.production_flow_items pfi on pfi.production_flow_item_id=mb.production_flow_item_id
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product_variant_id',ml.product_variant_id,
        'variant_code',ml.variant_code_snapshot,
        'variant_name',ml.variant_name_snapshot,
        'weight_kg',ml.weight_kg,
        'units',ml.units,
        'unit_weight_grams',ml.unit_weight_grams_snapshot
      ) order by ml.created_at,ml.mop_production_line_id),'[]'::jsonb) as lines
      from public.sorting_mop_production_lines ml
      where ml.mop_production_batch_id=mb.mop_production_batch_id
    ) lines on true
    left join lateral (
      select coalesce(jsonb_agg(mt.trolley_code_snapshot order by mt.created_at,mt.mop_production_trolley_id),'[]'::jsonb) as trolley_codes
      from public.sorting_mop_production_trolleys mt
      where mt.mop_production_batch_id=mb.mop_production_batch_id
    ) trolleys on true
    left join lateral (
      select
        count(*) filter(where b.status='ACTIVE')::integer as active_abs_count,
        count(*)::integer as abs_history_count,
        coalesce(jsonb_agg(jsonb_build_object(
          'external_batch_id',b.production_flow_external_batch_id,
          'batch_reference',b.batch_reference,
          'batch_number',b.batch_number,
          'batch_business_date',b.batch_business_date,
          'batch_week_start',b.batch_week_start,
          'quantity',b.quantity,
          'unit_code',b.unit_code,
          'capture_source',b.capture_source,
          'status',b.status,
          'recorded_at',b.recorded_at,
          'recorded_by_staff_id',b.recorded_by_staff_id,
          'recorded_by_name',abs_staff.display_name,
          'notes',b.notes,
          'supersedes_external_batch_id',b.supersedes_external_batch_id,
          'correction_reason',b.correction_reason,
          'cancelled_at',b.cancelled_at
        ) order by
          case b.status when 'ACTIVE' then 0 when 'SUPERSEDED' then 1 else 2 end,
          b.recorded_at desc,b.production_flow_external_batch_id desc
        ) filter(where b.status='ACTIVE'),'[]'::jsonb) as active_abs_batches
      from public.production_flow_external_batches b
      left join public.staff_members abs_staff on abs_staff.staff_id=b.recorded_by_staff_id
      where b.production_flow_item_id=mb.production_flow_item_id
        and b.external_system_code='ABS'
    ) abs_data on true
  )
  select
    coalesce(jsonb_agg(to_jsonb(t) order by t.recorded_at desc,t.mop_production_batch_id desc),'[]'::jsonb),
    count(*) filter(where t.abs_status='PENDING')::integer,
    count(*) filter(where t.abs_status='POSTED')::integer
  into v_rows,v_pending,v_posted
  from trace_rows t;

  return jsonb_build_object(
    'rows',v_rows,
    'pending_abs_count',v_pending,
    'posted_abs_count',v_posted,
    'limit',v_limit,
    'source','MOP_PRODUCTION_PLUS_SHARED_PRODUCTION_FLOW_ABS'
  );
end;
$$;

revoke all on function public.get_sorting_mop_recent_trace(integer)
  from public, anon, authenticated;
grant execute on function public.get_sorting_mop_recent_trace(integer)
  to authenticated;

comment on function public.get_sorting_mop_recent_trace(integer)
  is 'MOP Production trace with preserved Production Flow route code/name/color, processed MOP lines, trolley evidence and current shared ABS batch posting details. Direct source tables remain private.';

commit;
