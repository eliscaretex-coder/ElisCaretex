-- ElisCaretex V2
-- Migration 036: Sorting Daily Tracker V2
-- Prepared 2026-08-11
--
-- Purpose:
--   Expose one governed read model for the Sorting Daily Tracker.
--   Source of truth stays in published Customer Schedule + Production Flow + Washing
--   + active MOP Production revisions + shared ABS evidence.
--
-- This migration does NOT create a parallel tracker table and does NOT rewrite any
-- operational evidence. The browser receives data only through the RPC below.

create or replace function public.get_sorting_tracker_v2(
  p_business_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public', 'auth', 'pg_temp'
as $$
declare
  v_business_date date := coalesce(p_business_date, public.current_business_date());
  v_result jsonb;
begin
  perform public.require_sorting_operational_access();

  with selected_versions as (
    select distinct on (v.customer_id)
      v.schedule_version_id,
      v.customer_id,
      v.version_number
    from public.customer_schedule_versions v
    join public.customers c
      on c.customer_id = v.customer_id
    where v.status = 'PUBLISHED'
      and v_business_date >= v.effective_from
      and (v.effective_until is null or v_business_date <= v.effective_until)
      and c.active = true
      and c.deleted_at is null
    order by v.customer_id, v.version_number desc
  ),
  scheduled_products as (
    select
      sv.schedule_version_id,
      d.schedule_day_id,
      sp.schedule_product_id,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      pt.product_code,
      sp.production_order,
      sp.expected_kg,
      sp.expected_units,
      sp.production_instructions,
      dr.route_code,
      dr.display_name as route_display_name,
      dr.route_color,
      true as scheduled
    from selected_versions sv
    join public.customers c
      on c.customer_id = sv.customer_id
    join public.customer_schedule_days d
      on d.schedule_version_id = sv.schedule_version_id
    join public.customer_schedule_products sp
      on sp.schedule_day_id = d.schedule_day_id
    join public.product_types pt
      on pt.product_type_id = sp.product_type_id
    left join public.distribution_routes dr
      on dr.route_id = d.default_route_id
    where d.active = true
      and d.production_weekday = extract(isodow from v_business_date)::smallint
      and sp.active = true
      and pt.active = true
      and pt.deleted_at is null
      and pt.product_code in ('CLOTHES', 'MOP')
  ),
  scheduled_with_flow as (
    select
      s.schedule_version_id,
      s.schedule_day_id,
      s.schedule_product_id,
      s.customer_id,
      s.customer_code,
      s.customer_name,
      s.product_code,
      s.production_order,
      s.expected_kg,
      s.expected_units,
      s.production_instructions,
      coalesce(pfi.route_code_snapshot, s.route_code) as route_code,
      coalesce(pfi.route_display_name_snapshot, s.route_display_name) as route_display_name,
      coalesce(pfi.route_color_snapshot, s.route_color) as route_color,
      s.scheduled,
      pfi.production_flow_item_id,
      pfi.flow_code,
      pfi.flow_origin,
      pfi.current_stage_code,
      pfi.flow_status,
      pfi.washed_kg_total as flow_washed_kg_total,
      pfi.washed_load_count as flow_washed_load_count,
      pfi.last_wash_at
    from scheduled_products s
    left join lateral (
      select p.*
      from public.production_flow_items p
      where p.source_schedule_product_id = s.schedule_product_id
        and p.scheduled_for_date = v_business_date
        and p.product_code = s.product_code
      order by p.created_at desc
      limit 1
    ) pfi on true
  ),
  flow_only as (
    select
      pfi.source_schedule_version_id as schedule_version_id,
      pfi.source_schedule_day_id as schedule_day_id,
      pfi.source_schedule_product_id as schedule_product_id,
      pfi.customer_id,
      pfi.customer_code_snapshot as customer_code,
      pfi.customer_name_snapshot as customer_name,
      pfi.product_code,
      pfi.production_order_snapshot as production_order,
      null::numeric as expected_kg,
      null::integer as expected_units,
      null::text as production_instructions,
      pfi.route_code_snapshot as route_code,
      pfi.route_display_name_snapshot as route_display_name,
      pfi.route_color_snapshot as route_color,
      false as scheduled,
      pfi.production_flow_item_id,
      pfi.flow_code,
      pfi.flow_origin,
      pfi.current_stage_code,
      pfi.flow_status,
      pfi.washed_kg_total as flow_washed_kg_total,
      pfi.washed_load_count as flow_washed_load_count,
      pfi.last_wash_at
    from public.production_flow_items pfi
    where pfi.scheduled_for_date = v_business_date
      and pfi.product_code in ('CLOTHES', 'MOP')
      and not exists (
        select 1
        from scheduled_with_flow swf
        where swf.production_flow_item_id = pfi.production_flow_item_id
           or (
             swf.schedule_product_id is not null
             and swf.schedule_product_id = pfi.source_schedule_product_id
           )
      )
  ),
  base_items as (
    select * from scheduled_with_flow
    union all
    select * from flow_only
  ),
  wash_agg as (
    select
      wrc.production_flow_item_id,
      sum(coalesce(wrc.allocated_weight_kg, 0)) as allocated_weight_kg,
      count(distinct wr.wash_run_id) as wash_count,
      jsonb_agg(
        jsonb_build_object(
          'wash_run_id', wr.wash_run_id,
          'wash_code', wr.wash_code,
          'washer_code', wr.washer_code_snapshot,
          'washer_name', wr.washer_name_snapshot,
          'operator_staff_id', wr.operator_staff_id,
          'operator_name', wr.operator_name_snapshot,
          'wash_type', wr.wash_type,
          'started_at', wr.started_at,
          'registered_at', wr.registered_at,
          'trace_code', wrc.trace_code,
          'allocated_weight_kg', wrc.allocated_weight_kg,
          'schedule_relation', wrc.schedule_relation
        )
        order by wr.started_at, wr.wash_code
      ) as wash_details
    from public.sorting_wash_run_customers wrc
    join public.sorting_wash_runs wr
      on wr.wash_run_id = wrc.wash_run_id
    where wr.status = 'RECORDED'
      and wrc.production_flow_item_id is not null
    group by wrc.production_flow_item_id
  ),
  active_mop as (
    select distinct on (mb.production_flow_item_id)
      mb.mop_production_batch_id,
      mb.production_flow_item_id,
      mb.operator_staff_id,
      operator.display_name as operator_name,
      mb.entry_mode,
      mb.physical_processed_on,
      mb.physical_processed_time,
      mb.total_weight_kg,
      mb.total_units,
      mb.trolley_capture_status,
      mb.recorded_at,
      mb.notes,
      mb.revision_no
    from public.sorting_mop_production_batches mb
    left join public.staff_members operator
      on operator.staff_id = mb.operator_staff_id
    where mb.status = 'RECORDED'
    order by
      mb.production_flow_item_id,
      mb.revision_no desc,
      mb.recorded_at desc,
      mb.mop_production_batch_id desc
  ),
  mop_line_agg as (
    select
      ml.mop_production_batch_id,
      jsonb_agg(
        jsonb_build_object(
          'product_variant_id', ml.product_variant_id,
          'variant_code', ml.variant_code_snapshot,
          'variant_name', ml.variant_name_snapshot,
          'weight_kg', ml.weight_kg,
          'units', ml.units,
          'unit_weight_grams', ml.unit_weight_grams_snapshot
        )
        order by lower(ml.variant_name_snapshot), ml.variant_code_snapshot
      ) as lines
    from public.sorting_mop_production_lines ml
    group by ml.mop_production_batch_id
  ),
  mop_trolley_agg as (
    select
      mt.mop_production_batch_id,
      jsonb_agg(
        jsonb_build_object(
          'trolley_code', mt.trolley_code_snapshot,
          'lifecycle_action', mt.lifecycle_action,
          'stay_id', mt.stay_id
        )
        order by mt.created_at, mt.trolley_code_snapshot
      ) as trolleys
    from public.sorting_mop_production_trolleys mt
    group by mt.mop_production_batch_id
  ),
  lifecycle_trolley_agg as (
    select
      s.source_schedule_product_id as schedule_product_id,
      s.production_business_date,
      jsonb_agg(
        jsonb_build_object(
          'trolley_code', t.trolley_code,
          'lifecycle_action', 'PRODUCTION_ASSIGNMENT',
          'stay_id', s.stay_id
        )
        order by t.trolley_code
      ) as trolleys
    from public.trolley_customer_stays s
    join public.trolleys t
      on t.trolley_id = s.trolley_id
    where s.source_schedule_product_id is not null
      and s.production_business_date = v_business_date
    group by s.source_schedule_product_id, s.production_business_date
  ),
  abs_agg as (
    select
      eb.production_flow_item_id,
      count(*) as abs_count,
      jsonb_agg(
        jsonb_build_object(
          'external_batch_id', eb.production_flow_external_batch_id,
          'batch_reference', eb.batch_reference,
          'quantity', eb.quantity,
          'unit_code', eb.unit_code,
          'capture_source', eb.capture_source,
          'recorded_at', eb.recorded_at,
          'recorded_by_staff_id', eb.recorded_by_staff_id,
          'recorded_by', recorder.display_name,
          'notes', eb.notes
        )
        order by eb.recorded_at, eb.batch_reference
      ) as abs_details,
      jsonb_agg(eb.batch_reference order by eb.recorded_at, eb.batch_reference) as batch_references
    from public.production_flow_external_batches eb
    left join public.staff_members recorder
      on recorder.staff_id = eb.recorded_by_staff_id
    where eb.external_system_code = 'ABS'
      and eb.status = 'ACTIVE'
    group by eb.production_flow_item_id
  ),
  enriched as (
    select
      b.*,
      case
        when coalesce(b.flow_washed_kg_total, 0) > 0 then b.flow_washed_kg_total
        else coalesce(wa.allocated_weight_kg, 0)
      end as washed_kg_total,
      greatest(coalesce(b.flow_washed_load_count, 0), coalesce(wa.wash_count, 0))::integer as washed_load_count,
      coalesce(wa.wash_details, '[]'::jsonb) as wash_details,
      am.mop_production_batch_id,
      am.operator_staff_id as production_operator_staff_id,
      am.operator_name as production_operator_name,
      am.entry_mode as production_entry_mode,
      am.physical_processed_on,
      am.physical_processed_time,
      am.total_weight_kg as processed_weight_kg,
      am.total_units as processed_units,
      am.trolley_capture_status,
      am.recorded_at as processed_at,
      am.notes as production_notes,
      am.revision_no as production_revision_no,
      coalesce(mla.lines, '[]'::jsonb) as production_lines,
      coalesce(mta.trolleys, '[]'::jsonb) as mop_trolleys,
      coalesce(lta.trolleys, '[]'::jsonb) as lifecycle_trolleys,
      coalesce(aa.abs_count, 0) as abs_count,
      coalesce(aa.abs_details, '[]'::jsonb) as abs_details,
      coalesce(aa.batch_references, '[]'::jsonb) as batch_references,
      case
        when coalesce(
          case when coalesce(b.flow_washed_kg_total, 0) > 0 then b.flow_washed_kg_total else wa.allocated_weight_kg end,
          0
        ) <= 0
        and greatest(coalesce(b.flow_washed_load_count, 0), coalesce(wa.wash_count, 0)) <= 0
          then 'NOT_STARTED'
        when b.product_code = 'MOP' and am.mop_production_batch_id is null
          then 'WASHED_ONLY'
        when b.product_code = 'MOP' and am.mop_production_batch_id is not null and coalesce(aa.abs_count, 0) = 0
          then 'ABS_PENDING'
        when b.product_code = 'MOP' and am.mop_production_batch_id is not null and coalesce(aa.abs_count, 0) > 0
          then 'TRACKER_OK'
        when b.product_code = 'CLOTHES'
          then 'WASHED_ONLY'
        else 'WASHED_ONLY'
      end as product_status
    from base_items b
    left join wash_agg wa
      on wa.production_flow_item_id = b.production_flow_item_id
    left join active_mop am
      on am.production_flow_item_id = b.production_flow_item_id
     and b.product_code = 'MOP'
    left join mop_line_agg mla
      on mla.mop_production_batch_id = am.mop_production_batch_id
    left join mop_trolley_agg mta
      on mta.mop_production_batch_id = am.mop_production_batch_id
    left join lifecycle_trolley_agg lta
      on lta.schedule_product_id = b.schedule_product_id
     and lta.production_business_date = v_business_date
    left join abs_agg aa
      on aa.production_flow_item_id = b.production_flow_item_id
  ),
  customer_rollup as (
    select
      e.customer_id,
      bool_or(e.scheduled) as scheduled,
      bool_and(e.product_status = 'NOT_STARTED') as all_not_started,
      bool_and(e.product_status = 'WASHED_ONLY') as all_washed_only,
      bool_and(e.product_status = 'TRACKER_OK') as all_tracker_ok,
      bool_or(e.product_status = 'ABS_PENDING') as any_abs_pending,
      bool_or(e.product_status <> 'NOT_STARTED') as any_started,
      count(*) as product_count
    from enriched e
    group by e.customer_id
  ),
  customer_status as (
    select
      cr.*,
      case
        when cr.all_tracker_ok then 'TRACKER_OK'
        when cr.all_not_started then 'NOT_STARTED'
        when cr.product_count = 1 and cr.all_washed_only then 'WASHED_ONLY'
        when cr.product_count = 1 and cr.any_abs_pending then 'ABS_PENDING'
        when cr.any_abs_pending
             and not exists (
               select 1
               from enriched e2
               where e2.customer_id = cr.customer_id
                 and e2.product_status not in ('ABS_PENDING', 'TRACKER_OK')
             ) then 'ABS_PENDING'
        when cr.all_washed_only then 'WASHED_ONLY'
        else 'IN_PROGRESS'
      end as customer_status
    from customer_rollup cr
  )
  select jsonb_build_object(
    'schema_version', 'SORTING_TRACKER_V2',
    'source_contract', 'PRODUCTION_FLOW_TRACKER_V2',
    'business_date', v_business_date,
    'generated_at', now(),
    'summary', jsonb_build_object(
      'scheduled', (select count(*) from customer_status cs where cs.scheduled),
      'total_customers', (select count(*) from customer_status),
      'not_started', (select count(*) from customer_status cs where cs.customer_status = 'NOT_STARTED'),
      'washed', (select count(*) from customer_status cs where cs.any_started),
      'abs_pending', (select count(*) from customer_status cs where cs.any_abs_pending),
      'tracker_ok', (select count(*) from customer_status cs where cs.customer_status = 'TRACKER_OK'),
      'in_progress', (select count(*) from customer_status cs where cs.customer_status = 'IN_PROGRESS'),
      'total_kg', coalesce((select sum(e.washed_kg_total) from enriched e), 0)
    ),
    'items', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'customer_id', e.customer_id,
            'customer_code', e.customer_code,
            'customer_name', e.customer_name,
            'customer_status', cs.customer_status,
            'scheduled', e.scheduled,
            'schedule_version_id', e.schedule_version_id,
            'schedule_day_id', e.schedule_day_id,
            'schedule_product_id', e.schedule_product_id,
            'scheduled_for_date', v_business_date,
            'product_code', e.product_code,
            'product_status', e.product_status,
            'production_order', e.production_order,
            'expected_kg', e.expected_kg,
            'expected_units', e.expected_units,
            'production_instructions', e.production_instructions,
            'route_code', e.route_code,
            'route_display_name', e.route_display_name,
            'route_color', e.route_color,
            'production_flow_item_id', e.production_flow_item_id,
            'flow_code', e.flow_code,
            'flow_origin', e.flow_origin,
            'current_stage_code', e.current_stage_code,
            'flow_status', e.flow_status,
            'washed_kg_total', e.washed_kg_total,
            'washed_load_count', e.washed_load_count,
            'last_wash_at', e.last_wash_at,
            'wash_details', e.wash_details,
            'mop_production_batch_id', e.mop_production_batch_id,
            'production_operator_staff_id', e.production_operator_staff_id,
            'production_operator_name', e.production_operator_name,
            'production_entry_mode', e.production_entry_mode,
            'physical_processed_on', e.physical_processed_on,
            'physical_processed_time', e.physical_processed_time,
            'processed_weight_kg', e.processed_weight_kg,
            'processed_units', e.processed_units,
            'processed_at', e.processed_at,
            'production_notes', e.production_notes,
            'production_revision_no', e.production_revision_no,
            'production_lines', e.production_lines,
            'trolley_capture_status', e.trolley_capture_status,
            'mop_trolleys', e.mop_trolleys,
            'lifecycle_trolleys', e.lifecycle_trolleys,
            'abs_count', e.abs_count,
            'abs_details', e.abs_details,
            'batch_references', e.batch_references
          )
          order by
            coalesce(e.production_order, 2147483647),
            lower(e.customer_name),
            case e.product_code when 'CLOTHES' then 1 when 'MOP' then 2 else 9 end
        )
        from enriched e
        join customer_status cs
          on cs.customer_id = e.customer_id
      ),
      '[]'::jsonb
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_sorting_tracker_v2(date) is
  'Sorting Daily Tracker V2 read model. Published schedule + Production Flow + recorded Washing + active MOP Production revision + active shared ABS evidence. No tracker shadow table.';

revoke all on function public.get_sorting_tracker_v2(date) from public;
revoke all on function public.get_sorting_tracker_v2(date) from anon;
grant execute on function public.get_sorting_tracker_v2(date) to authenticated;
