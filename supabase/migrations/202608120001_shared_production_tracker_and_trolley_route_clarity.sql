-- ElisCaretex V2
-- Migration 037: Shared Production Tracker + trolley route/color clarity
-- Prepared 2026-08-12
--
-- Purpose:
--   1. Promote the Daily Production Tracker from a Sorting-only read model to a
--      shared Production Flow read model for authorized operational areas.
--   2. Keep CLOTHES and MOP as separate product streams, ordered by their own
--      production priority (all CLOTHES priorities first, then MOP priorities).
--   3. Add current Route master display/color context to trolley consultation.
--
-- Important evidence rule:
--   Production Tracker route/color values use Production Flow snapshots whenever
--   available, preserving historical production meaning. Trolley consultation is
--   about current operational location, so its route/color is derived from the
--   current Route master linked by the stay's source schedule day. Route colors may
--   therefore change later without rewriting trolley lifecycle evidence.
--
-- This migration creates/replaces read RPCs only. It does not rewrite Production
-- Flow, Washing, MOP Production, ABS, customer schedules, trolley stays or events.

create or replace function public.get_production_tracker_v1(
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
  perform public.require_production_flow_read_role();

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
    'schema_version', 'PRODUCTION_TRACKER_V1',
    'source_contract', 'PRODUCTION_FLOW_SHARED_TRACKER_V1',
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
            case e.product_code when 'CLOTHES' then 1 when 'MOP' then 2 else 9 end,
            coalesce(e.production_order, 2147483647),
            lower(e.customer_name)
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


create or replace function public.get_trolley_record(
  p_trolley_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_trolley_id uuid;
  v_result jsonb;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  select t.trolley_id into v_trolley_id
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(p_trolley_code))
    and t.deleted_at is null;

  if v_trolley_id is null then
    raise exception using
      errcode = 'P0002',
      message = format('Trolley not found: %s', trim(p_trolley_code));
  end if;

  select jsonb_build_object(
    'trolley', jsonb_build_object(
      'trolley_id', t.trolley_id,
      'trolley_code', t.trolley_code,
      'status', case
        when t.status in ('OUT_OF_SERVICE', 'RETIRED') then t.status
        when current_stay.stay_id is not null and current_stay.sent_on > current_date then 'IN_PRODUCTION'
        when current_stay.stay_id is not null then 'AT_CUSTOMER'
        else t.status
      end,
      'stored_status', t.status,
      'active', t.active,
      'registered_on', t.registered_on,
      'retired_on', t.retired_on,
      'notes', t.notes,
      'metadata', t.metadata,
      'trolley_type_id', tt.trolley_type_id,
      'trolley_type_code', tt.trolley_type_code,
      'trolley_type_name', tt.trolley_type_name,
      'trolley_type_display_code', coalesce(tt.display_code, tt.trolley_type_code)
    ),
    'suggestion', (
      select to_jsonb(suggestion)
      from public.suggest_trolley_customer(t.trolley_code) suggestion
    ),
    'current_stay', case
      when current_stay.stay_id is null then null
      else jsonb_build_object(
        'stay_id', current_stay.stay_id,
        'outbound_customer_id', current_stay.outbound_customer_id,
        'customer_code', current_customer.customer_code,
        'customer_name', current_customer.customer_name,
        'route_code', current_route.route_code,
        'route_display_name', current_route.display_name,
        'route_color', current_route.route_color,
        'route_color_source', case when current_route.route_id is null then null else 'CURRENT_ROUTE_MASTER' end,
        'production_business_date', current_stay.production_business_date,
        'production_area_code', current_stay.production_area_code,
        'planned_delivery_on', current_stay.planned_delivery_on,
        'sent_on', current_stay.sent_on,
        'custody_start_source', current_stay.custody_start_source,
        'days_out', case
          when current_stay.sent_on is null or current_stay.sent_on > current_date then null
          else current_date - current_stay.sent_on
        end,
        'notes', current_stay.notes
      )
    end,
    'history', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'stay_id', history.stay_id,
            'outbound_customer_id', history.outbound_customer_id,
            'outbound_customer_code', outbound.customer_code,
            'outbound_customer_name', outbound.customer_name,
            'route_code', history_route.route_code,
            'route_display_name', history_route.display_name,
            'route_color', history_route.route_color,
            'route_color_source', case when history_route.route_id is null then null else 'CURRENT_ROUTE_MASTER' end,
            'received_from_customer_id', history.received_from_customer_id,
            'received_customer_code', received.customer_code,
            'received_customer_name', received.customer_name,
            'production_business_date', history.production_business_date,
            'production_area_code', history.production_area_code,
            'planned_delivery_on', history.planned_delivery_on,
            'sent_on', history.sent_on,
            'custody_start_source', history.custody_start_source,
            'received_on', history.received_on,
            'days_out', case
              when history.sent_on is null then null
              when history.received_on is null and history.sent_on <= current_date then current_date - history.sent_on
              when history.received_on is null then null
              else history.received_on - history.sent_on
            end,
            'production_to_sorting_days', case
              when history.production_business_date is null or history.received_on is null then null
              else history.received_on - history.production_business_date
            end,
            'status', history.status,
            'exception_type', history.exception_type,
            'confirmation_source', history.confirmation_source,
            'review_status', history.review_status,
            'review_decision', history.review_decision,
            'review_notes', history.review_notes,
            'reviewed_at', history.reviewed_at,
            'notes', history.notes,
            'created_at', history.created_at
          ) order by history.created_at desc
        )
        from (
          select s.*
          from public.trolley_customer_stays s
          where s.trolley_id = t.trolley_id
          order by s.created_at desc
          limit 50
        ) history
        left join public.customers outbound
          on outbound.customer_id = history.outbound_customer_id
        left join public.customers received
          on received.customer_id = history.received_from_customer_id
        left join public.customer_schedule_days history_day
          on history_day.schedule_day_id = history.source_schedule_day_id
        left join public.distribution_routes history_route
          on history_route.route_id = history_day.default_route_id
      ),
      '[]'::jsonb
    ),
    'events', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'trolley_event_id', event_rows.trolley_event_id,
            'stay_id', event_rows.stay_id,
            'event_type', event_rows.event_type,
            'customer_id', event_rows.customer_id,
            'customer_code', event_customer.customer_code,
            'customer_name', event_customer.customer_name,
            'business_date', event_rows.business_date,
            'performed_by', performer.display_name,
            'source_application', event_rows.source_application,
            'reason', event_rows.reason,
            'metadata', event_rows.metadata,
            'created_at', event_rows.created_at
          ) order by event_rows.created_at desc
        )
        from (
          select e.*
          from public.trolley_events e
          where e.trolley_id = t.trolley_id
          order by e.created_at desc
          limit 50
        ) event_rows
        left join public.customers event_customer
          on event_customer.customer_id = event_rows.customer_id
        left join public.staff_members performer
          on performer.staff_id = event_rows.performed_by
      ),
      '[]'::jsonb
    )
  ) into v_result
  from public.trolleys t
  left join public.trolley_types tt
    on tt.trolley_type_id = t.trolley_type_id
  left join lateral (
    select s.*
    from public.trolley_customer_stays s
    where s.trolley_id = t.trolley_id
      and s.received_on is null
    order by s.created_at desc
    limit 1
  ) current_stay on true
  left join public.customers current_customer
    on current_customer.customer_id = current_stay.outbound_customer_id
  left join public.customer_schedule_days current_day
    on current_day.schedule_day_id = current_stay.source_schedule_day_id
  left join public.distribution_routes current_route
    on current_route.route_id = current_day.default_route_id
  where t.trolley_id = v_trolley_id;

  return v_result;
end;
$$;

create or replace function public.get_trolley_location_overview(
  p_search text default null,
  p_location_filter text default 'ALL'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_search text := lower(nullif(trim(p_search), ''));
  v_filter text := upper(coalesce(nullif(trim(p_location_filter), ''), 'ALL'));
  v_warning_days integer;
  v_overdue_days integer;
  v_result jsonb;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  if v_filter not in ('ALL', 'ELIS_LAUNDRY', 'CUSTOMERS', 'LOCATION_UNCONFIRMED') then
    raise exception using errcode = '22023', message = 'Invalid trolley location filter.';
  end if;

  select coalesce((value_json #>> '{}')::integer, 14)
  into v_warning_days
  from public.app_config
  where config_key = 'trolley_warning_days';

  select coalesce((value_json #>> '{}')::integer, 30)
  into v_overdue_days
  from public.app_config
  where config_key = 'trolley_overdue_days';

  with trolley_state as (
    select
      t.trolley_id,
      t.trolley_code,
      t.status as stored_status,
      t.active,
      t.registered_on,
      t.retired_on,
      t.notes,
      t.metadata,
      tt.trolley_type_code,
      tt.trolley_type_name,
      coalesce(tt.display_code, tt.trolley_type_code) as trolley_type_display_code,
      open_stay.stay_id as open_stay_id,
      open_stay.outbound_customer_id,
      c.customer_code,
      c.customer_name,
      current_route.route_code,
      current_route.display_name as route_display_name,
      current_route.route_color,
      case when current_route.route_id is null then null else 'CURRENT_ROUTE_MASTER' end as route_color_source,
      open_stay.production_business_date,
      open_stay.production_area_code,
      open_stay.planned_delivery_on,
      open_stay.sent_on,
      open_stay.custody_start_source,
      last_arrival.business_date as last_arrival_on,
      case
        when t.status = 'RETIRED' then 'RETIRED'
        when t.status = 'OUT_OF_SERVICE' then 'OUT_OF_SERVICE'
        when open_stay.stay_id is not null and open_stay.sent_on <= current_date then 'CUSTOMER'
        when open_stay.stay_id is not null and open_stay.sent_on > current_date then 'ELIS_LAUNDRY'
        when t.status = 'AVAILABLE' then 'ELIS_LAUNDRY'
        when t.status = 'LOCATION_UNCONFIRMED' then 'LOCATION_UNCONFIRMED'
        else 'LOCATION_UNCONFIRMED'
      end as location_type,
      case
        when open_stay.stay_id is not null and open_stay.sent_on <= current_date then open_stay.sent_on
        when open_stay.stay_id is not null and open_stay.sent_on > current_date then
          coalesce(open_stay.production_business_date, current_date)
        when t.status = 'AVAILABLE' then coalesce(last_arrival.business_date, t.registered_on)
        else null
      end as location_since,
      case
        when open_stay.stay_id is not null and open_stay.sent_on <= current_date then
          greatest(current_date - open_stay.sent_on, 0)
        when open_stay.stay_id is not null and open_stay.sent_on > current_date then
          greatest(current_date - coalesce(open_stay.production_business_date, current_date), 0)
        when t.status = 'AVAILABLE' then
          greatest(current_date - coalesce(last_arrival.business_date, t.registered_on), 0)
        else null
      end as days_at_location,
      exists (
        select 1
        from public.trolley_customer_stays review_stay
        where review_stay.trolley_id = t.trolley_id
          and review_stay.exception_type is not null
          and review_stay.review_status in ('PENDING', 'UNDER_REVIEW')
      ) as has_review_required
    from public.trolleys t
    join public.trolley_types tt
      on tt.trolley_type_id = t.trolley_type_id
    left join lateral (
      select s.*
      from public.trolley_customer_stays s
      where s.trolley_id = t.trolley_id
        and s.received_on is null
      order by s.created_at desc
      limit 1
    ) open_stay on true
    left join public.customers c
      on c.customer_id = open_stay.outbound_customer_id
    left join public.customer_schedule_days current_day
      on current_day.schedule_day_id = open_stay.source_schedule_day_id
    left join public.distribution_routes current_route
      on current_route.route_id = current_day.default_route_id
    left join lateral (
      select e.business_date
      from public.trolley_events e
      where e.trolley_id = t.trolley_id
        and e.event_type in (
          'ARRIVED_AT_SORTING',
          'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND',
          'RECEIVED_FROM_CUSTOMER',
          'RECEIVED_WITHOUT_OUTBOUND',
          'RETURNED_TO_SERVICE'
        )
      order by e.business_date desc, e.created_at desc
      limit 1
    ) last_arrival on true
    where t.deleted_at is null
  ), operational_locations as (
    select
      ts.*,
      case
        when ts.location_type = 'CUSTOMER' then ts.outbound_customer_id::text
        when ts.location_type = 'ELIS_LAUNDRY' then 'ELIS_LAUNDRY'
        else 'LOCATION_UNCONFIRMED'
      end as location_key,
      case
        when ts.location_type = 'CUSTOMER' then ts.customer_name
        when ts.location_type = 'ELIS_LAUNDRY' then 'Elis Laundry'
        else 'Location unconfirmed'
      end as location_name,
      case
        when ts.location_type = 'CUSTOMER' then ts.customer_code
        when ts.location_type = 'ELIS_LAUNDRY' then 'ELIS'
        else null
      end as location_code,
      case
        when ts.location_type = 'CUSTOMER'
             and ts.days_at_location >= coalesce(v_overdue_days, 30) then 'OVERDUE'
        when ts.location_type = 'CUSTOMER'
             and ts.days_at_location >= coalesce(v_warning_days, 14) then 'WARNING'
        else 'NORMAL'
      end as attention_status,
      case
        when ts.location_type = 'ELIS_LAUNDRY'
             and ts.open_stay_id is not null
             and ts.sent_on > current_date then 'PREPARED_FOR_DELIVERY'
        when ts.location_type = 'ELIS_LAUNDRY' then 'AT_LAUNDRY'
        when ts.location_type = 'CUSTOMER' then 'AT_CUSTOMER'
        else 'LOCATION_UNCONFIRMED'
      end as location_status
    from trolley_state ts
    where ts.location_type in ('ELIS_LAUNDRY', 'CUSTOMER', 'LOCATION_UNCONFIRMED')
  ), filtered as (
    select ol.*
    from operational_locations ol
    where (
      v_search is null
      or lower(ol.trolley_code) like '%' || v_search || '%'
      or lower(coalesce(ol.trolley_type_name, '')) like '%' || v_search || '%'
      or lower(coalesce(ol.location_name, '')) like '%' || v_search || '%'
      or lower(coalesce(ol.location_code, '')) like '%' || v_search || '%'
    )
      and case v_filter
        when 'ALL' then true
        when 'ELIS_LAUNDRY' then ol.location_type = 'ELIS_LAUNDRY'
        when 'CUSTOMERS' then ol.location_type = 'CUSTOMER'
        when 'LOCATION_UNCONFIRMED' then ol.location_type = 'LOCATION_UNCONFIRMED'
        else false
      end
  ), location_groups as (
    select
      f.location_key,
      f.location_type,
      f.location_name,
      f.location_code,
      case
        when f.location_type = 'ELIS_LAUNDRY' then 1
        when f.location_type = 'CUSTOMER' then 2
        else 3
      end as sort_group,
      count(*) as trolley_count,
      count(*) filter (where f.location_status = 'PREPARED_FOR_DELIVERY') as prepared_count,
      count(*) filter (where f.attention_status = 'WARNING') as warning_count,
      count(*) filter (where f.attention_status = 'OVERDUE') as overdue_count,
      count(*) filter (where f.has_review_required) as review_required_count,
      max(f.days_at_location) as longest_days,
      min(f.location_since) as oldest_location_since,
      jsonb_agg(
        jsonb_build_object(
          'trolley_id', f.trolley_id,
          'trolley_code', f.trolley_code,
          'trolley_type_code', f.trolley_type_code,
          'trolley_type_name', f.trolley_type_name,
          'trolley_type_display_code', f.trolley_type_display_code,
          'location_status', f.location_status,
          'location_since', f.location_since,
          'days_at_location', f.days_at_location,
          'attention_status', f.attention_status,
          'has_review_required', f.has_review_required,
          'customer_id', f.outbound_customer_id,
          'customer_code', f.customer_code,
          'customer_name', f.customer_name,
          'route_code', f.route_code,
          'route_display_name', f.route_display_name,
          'route_color', f.route_color,
          'route_color_source', f.route_color_source,
          'production_business_date', f.production_business_date,
          'production_area_code', f.production_area_code,
          'planned_delivery_on', f.planned_delivery_on,
          'custody_start_source', f.custody_start_source
        )
        order by
          case f.attention_status when 'OVERDUE' then 1 when 'WARNING' then 2 else 3 end,
          f.days_at_location desc nulls last,
          lower(f.trolley_code)
      ) as trolleys
    from filtered f
    group by f.location_key, f.location_type, f.location_name, f.location_code
  )
  select jsonb_build_object(
    'generated_on', current_date,
    'warning_days', coalesce(v_warning_days, 14),
    'overdue_days', coalesce(v_overdue_days, 30),
    'filter', v_filter,
    'search', p_search,
    'summary', jsonb_build_object(
      'operational_trolleys', (
        select count(*)
        from operational_locations
      ),
      'at_laundry', (
        select count(*)
        from operational_locations
        where location_type = 'ELIS_LAUNDRY'
      ),
      'prepared_for_delivery', (
        select count(*)
        from operational_locations
        where location_status = 'PREPARED_FOR_DELIVERY'
      ),
      'at_customers', (
        select count(*)
        from operational_locations
        where location_type = 'CUSTOMER'
      ),
      'customer_locations', (
        select count(distinct outbound_customer_id)
        from operational_locations
        where location_type = 'CUSTOMER'
      ),
      'location_unconfirmed', (
        select count(*)
        from operational_locations
        where location_type = 'LOCATION_UNCONFIRMED'
      ),
      'warning', (
        select count(*)
        from operational_locations
        where attention_status = 'WARNING'
      ),
      'overdue', (
        select count(*)
        from operational_locations
        where attention_status = 'OVERDUE'
      ),
      'out_of_service', (
        select count(*)
        from trolley_state
        where stored_status = 'OUT_OF_SERVICE'
      ),
      'retired', (
        select count(*)
        from trolley_state
        where stored_status = 'RETIRED'
      )
    ),
    'groups', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'location_key', lg.location_key,
            'location_type', lg.location_type,
            'location_name', lg.location_name,
            'location_code', lg.location_code,
            'trolley_count', lg.trolley_count,
            'prepared_count', lg.prepared_count,
            'warning_count', lg.warning_count,
            'overdue_count', lg.overdue_count,
            'review_required_count', lg.review_required_count,
            'longest_days', lg.longest_days,
            'oldest_location_since', lg.oldest_location_since,
            'trolleys', lg.trolleys
          )
          order by lg.sort_group, lower(lg.location_name), lg.location_code
        )
        from location_groups lg
      ),
      '[]'::jsonb
    )
  )
  into v_result;

  return v_result;
end;
$$;
comment on function public.get_production_tracker_v1(date) is
  'Shared Production Tracker V1. Published schedule + Production Flow + Washing + active MOP Production + shared ABS; readable by Production Flow read roles.';

revoke all on function public.get_production_tracker_v1(date) from public;
revoke all on function public.get_production_tracker_v1(date) from anon;
grant execute on function public.get_production_tracker_v1(date) to authenticated;

comment on function public.get_trolley_record(text) is
  'Trolley record with lifecycle history plus current Route master context when the stay is linked to a published schedule day.';
revoke all on function public.get_trolley_record(text) from public;
revoke all on function public.get_trolley_record(text) from anon;
grant execute on function public.get_trolley_record(text) to authenticated;

comment on function public.get_trolley_location_overview(text, text) is
  'Current trolley locations grouped by Elis Laundry/customer/location-unconfirmed, enriched with current Route master context where available.';
revoke all on function public.get_trolley_location_overview(text, text) from public;
revoke all on function public.get_trolley_location_overview(text, text) from anon;
grant execute on function public.get_trolley_location_overview(text, text) to authenticated;
