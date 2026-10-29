-- Production Tracker: one stream per customer and product after a same-day schedule change.
--
-- Cause: get_production_tracker_v1 bound each scheduled product to its Production Flow
-- item by source_schedule_product_id only. When a customer's schedule gets a new
-- published version effective on the production day (a Customer Studio edit or a
-- legacy-sync delivery-order change), the scheduled row carries the new schedule
-- product id while the day's flow item (washes, Finish, MOP, ABS) still points to the
-- previous version. The tracker then showed an empty "Not started" scheduled row plus
-- the real work as a second, unscheduled row.
--
-- Fix: production_flow_items is unique per (customer_id, product_code,
-- scheduled_for_date), so the scheduled row now binds to that item, preferring an exact
-- schedule-product match. Lifecycle trolley stays are read through either schedule
-- product id. V4 also returns the Finish staff who processed the Clothes
-- (finish_processed_by), shown in the Processed actual card like the MOP operator.
--
-- Read-only RPCs only: no table, data or permission change.

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
      pfi.last_wash_at,
      pfi.source_schedule_product_id as flow_schedule_product_id
    from scheduled_products s
    left join lateral (
      select p.*
      from public.production_flow_items p
      -- A flow item is unique per customer, product and scheduled date. Match on
      -- that key, not only on the schedule product id: when a new schedule
      -- version is published on the production day (Customer Studio edit or
      -- legacy sync), the day's flow item still points to the previous
      -- version's schedule product and must not show up as a second stream.
      where p.customer_id = s.customer_id
        and p.scheduled_for_date = v_business_date
        and p.product_code = s.product_code
      order by
        (p.source_schedule_product_id is not distinct from s.schedule_product_id) desc,
        p.created_at desc
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
      pfi.last_wash_at,
      pfi.source_schedule_product_id as flow_schedule_product_id
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
    left join lateral (
      select
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
      where s.production_business_date = v_business_date
        and s.source_schedule_product_id in (b.schedule_product_id, b.flow_schedule_product_id)
    ) lta on true
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
            'flow_schedule_product_id', e.flow_schedule_product_id,
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

create or replace function public.get_production_tracker_v2(
  p_business_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $function$
declare
  v_base jsonb;
  v_items jsonb;
begin
  perform public.require_production_flow_read_role();

  -- Keep the established V1 Production Flow read model authoritative for schedule,
  -- Washing, MOP Production and ABS. V2 enriches it with quantity provenance and
  -- typed physical/planned trolley evidence for Route readiness.
  v_base := public.get_production_tracker_v1(p_business_date);

  with base_items as (
    select item, ordinality
    from jsonb_array_elements(coalesce(v_base -> 'items', '[]'::jsonb))
         with ordinality as x(item, ordinality)
  ),
  enriched as (
    select
      b.ordinality,
      b.item || jsonb_build_object(
        'washed_quantity_kg', nullif(b.item ->> 'washed_kg_total', '')::numeric,
        'washed_quantity_units', null,
        'washed_quantity_basis', wb.quantity_basis,
        'washed_units_source', 'NOT_MEASURED_IN_WASHING',
        'processed_quantity_kg', nullif(b.item ->> 'processed_weight_kg', '')::numeric,
        'processed_quantity_units', nullif(b.item ->> 'processed_units', '')::integer,
        'processed_quantity_source', case
          when upper(coalesce(b.item ->> 'product_code',''))='MOP'
               and nullif(b.item ->> 'mop_production_batch_id','') is not null
            then 'MOP_PRODUCTION'
          when upper(coalesce(b.item ->> 'product_code',''))='CLOTHES'
            then 'FINISH_PENDING'
          else 'NOT_RECORDED'
        end,
        'planned_trolley_quantity', coalesce(pt.planned_quantity,0),
        'planned_trolley_requirements', coalesce(pt.requirements,'[]'::jsonb),
        'mop_trolleys', coalesce(mt.trolleys,'[]'::jsonb),
        'lifecycle_trolleys', coalesce(lt.trolleys,'[]'::jsonb)
      ) as item
    from base_items b
    left join lateral (
      select case
        when count(*)=0 then null
        when bool_and(wrc.weight_allocation_method='FULL_LOAD') then 'FULL_LOAD'
        when bool_and(wrc.weight_allocation_method='EQUAL_SPLIT_ESTIMATE') then 'EQUAL_SPLIT_ESTIMATE'
        else 'MIXED_WASH_ALLOCATION'
      end as quantity_basis
      from public.sorting_wash_run_customers wrc
      join public.sorting_wash_runs wr
        on wr.wash_run_id=wrc.wash_run_id
       and wr.status='RECORDED'
      where wrc.production_flow_item_id=nullif(b.item ->> 'production_flow_item_id','')::uuid
    ) wb on true
    left join lateral (
      select
        coalesce(sum(req.quantity),0)::integer as planned_quantity,
        coalesce(
          jsonb_agg(
            jsonb_build_object(
              'trolley_type_id',tt.trolley_type_id,
              'trolley_type_code',tt.trolley_type_code,
              'display_code',tt.display_code,
              'trolley_type_name',tt.trolley_type_name,
              'trolley_category',tt.trolley_category,
              'quantity',req.quantity,
              'empty_trolley',req.empty_trolley
            )
            order by tt.sort_order,tt.display_code,tt.trolley_type_code
          ),
          '[]'::jsonb
        ) as requirements
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id=req.trolley_type_id
       and tt.active=true
       and tt.deleted_at is null
      where req.owner_schedule_product_id=nullif(b.item ->> 'schedule_product_id','')::uuid
        and req.active=true
    ) pt on true
    left join lateral (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'trolley_code',mtx.trolley_code_snapshot,
            'trolley_id',coalesce(mtx.trolley_id,t.trolley_id),
            'trolley_type_id',tt.trolley_type_id,
            'trolley_type_code',tt.trolley_type_code,
            'display_code',tt.display_code,
            'trolley_type_name',tt.trolley_type_name,
            'trolley_category',tt.trolley_category,
            'lifecycle_action',mtx.lifecycle_action,
            'stay_id',mtx.stay_id
          )
          order by mtx.created_at,mtx.trolley_code_snapshot
        ),
        '[]'::jsonb
      ) as trolleys
      from public.sorting_mop_production_trolleys mtx
      left join public.trolleys t
        on t.deleted_at is null
       and (
         t.trolley_id=mtx.trolley_id
         or (
           mtx.trolley_id is null
           and upper(t.trolley_code)=upper(mtx.trolley_code_snapshot)
         )
       )
      left join public.trolley_types tt
        on tt.trolley_type_id=t.trolley_type_id
       and tt.deleted_at is null
      where mtx.mop_production_batch_id=nullif(b.item ->> 'mop_production_batch_id','')::uuid
    ) mt on true
    left join lateral (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'trolley_code',t.trolley_code,
            'trolley_id',t.trolley_id,
            'trolley_type_id',tt.trolley_type_id,
            'trolley_type_code',tt.trolley_type_code,
            'display_code',tt.display_code,
            'trolley_type_name',tt.trolley_type_name,
            'trolley_category',tt.trolley_category,
            'lifecycle_action','PRODUCTION_ASSIGNMENT',
            'stay_id',s.stay_id
          )
          order by t.trolley_code
        ),
        '[]'::jsonb
      ) as trolleys
      from public.trolley_customer_stays s
      join public.trolleys t
        on t.trolley_id=s.trolley_id
       and t.deleted_at is null
      left join public.trolley_types tt
        on tt.trolley_type_id=t.trolley_type_id
       and tt.deleted_at is null
      where s.source_schedule_product_id in (
          nullif(b.item ->> 'schedule_product_id','')::uuid,
          nullif(b.item ->> 'flow_schedule_product_id','')::uuid
        )
        and s.production_business_date=(v_base ->> 'business_date')::date
    ) lt on true
  )
  select coalesce(jsonb_agg(e.item order by e.ordinality),'[]'::jsonb)
  into v_items
  from enriched e;

  return (v_base - 'schema_version' - 'source_contract' - 'items') || jsonb_build_object(
    'schema_version','PRODUCTION_TRACKER_V2',
    'source_contract','PRODUCTION_FLOW_SHARED_TRACKER_V2',
    'quantity_contract','WASHED_ESTIMATE_VS_PROCESSED_ACTUAL',
    'route_trolley_contract','PHYSICAL_TYPED_TROLLEYS_PLUS_SCHEDULE_REQUIREMENTS',
    'trolley_capacity_area_contract','PENDING_MASTER_DIMENSIONS',
    'items',v_items
  );
end;
$function$;


create or replace function public.get_production_tracker_v4(p_business_date date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb;
  v_items jsonb;
begin
  v_base:=public.get_production_tracker_v3(p_business_date);

  with base_items as (
    select item,ordinality
    from jsonb_array_elements(coalesce(v_base->'items','[]'::jsonb)) with ordinality x(item,ordinality)
  ), enriched as (
    select b.ordinality,
      case when upper(coalesce(b.item->>'product_code',''))='CLOTHES' then
        b.item || jsonb_build_object(
          'processed_quantity_kg',coalesce(f.kg,0),
          'processed_quantity_units',coalesce(f.units,0),
          'processed_quantity_source',case when coalesce(f.contributions,0)>0 then 'FINISH_PRODUCTION' else 'FINISH_PENDING' end,
          'product_status',case when coalesce(f.contributions,0)>0 then 'TRACKER_OK' else coalesce(b.item->>'product_status','WASHED_ONLY') end,
          'finish_contribution_count',coalesce(f.contributions,0),
          'finish_last_processed_at',f.last_at,
          'finish_processed_by',coalesce(f.processed_by,'[]'::jsonb),
          'finish_tables',coalesce(f.tables,'[]'::jsonb),
          'finish_trolleys',coalesce(f.trolleys,'[]'::jsonb),
          'batch_references',coalesce(f.batch_references,'[]'::jsonb),
          'trolley_intake_count',coalesce(ti.intake_count,0),
          'trolley_intake_received',coalesce(ti.intake_count,0)>0,
          'trolley_intake_last_at',ti.last_at
        )
      else b.item end as item
    from base_items b
    left join lateral (
      select
        coalesce(sum(l.quantity) filter(where l.unit_code='KG'),0) kg,
        coalesce(sum(l.quantity) filter(where l.unit_code='UNIT'),0) units,
        count(distinct e.entry_group_id) contributions,
        max(e.recorded_at) last_at,
        coalesce(jsonb_agg(distinct e.table_code_snapshot),'[]'::jsonb) tables,
        coalesce(
          jsonb_agg(distinct coalesce(nullif(btrim(e.processed_by_name_snapshot),''),ps.display_name))
            filter(where coalesce(nullif(btrim(e.processed_by_name_snapshot),''),ps.display_name) is not null),
          '[]'::jsonb
        ) processed_by,
        coalesce(jsonb_agg(distinct l.batch_reference order by l.batch_reference),'[]'::jsonb) batch_references,
        coalesce((
          select jsonb_agg(distinct jsonb_build_object('trolley_code',ft.trolley_code_snapshot,'stay_id',ft.stay_id))
          from public.finish_production_entries ee
          join public.finish_production_trolleys ft on ft.finish_production_entry_id=ee.finish_production_entry_id
          where ee.status='ACTIVE'
            and ee.production_flow_item_id=nullif(b.item->>'production_flow_item_id','')::uuid
        ),'[]'::jsonb) trolleys
      from public.finish_production_entries e
      join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
      left join public.staff_members ps on ps.staff_id=e.processed_by_staff_id
      where e.status='ACTIVE'
        and e.production_flow_item_id=nullif(b.item->>'production_flow_item_id','')::uuid
    ) f on true
    left join lateral (
      select count(*)::integer intake_count,max(sti.arrived_at) last_at
      from public.sorting_trolley_intakes sti
      where sti.customer_id=nullif(b.item->>'customer_id','')::uuid
        and sti.scheduled_for_date=nullif(b.item->>'scheduled_for_date','')::date
        and upper(coalesce(sti.product_scope,''))='CLOTHES'
    ) ti on true
  )
  select coalesce(jsonb_agg(item order by ordinality),'[]'::jsonb) into v_items from enriched;

  return (v_base-'schema_version'-'source_contract'-'items') || jsonb_build_object(
    'schema_version','PRODUCTION_TRACKER_V4',
    'source_contract','PRODUCTION_FLOW_SHARED_TRACKER_V4',
    'finish_processed_actual_contract','FINISH_PRODUCTION_LEDGER',
    'items',v_items
  );
end;
$$;

revoke all on function public.get_production_tracker_v1(date) from public, anon;
grant execute on function public.get_production_tracker_v1(date) to authenticated;
revoke all on function public.get_production_tracker_v2(date) from public, anon;
grant execute on function public.get_production_tracker_v2(date) to authenticated;
revoke all on function public.get_production_tracker_v4(date) from public, anon;
grant execute on function public.get_production_tracker_v4(date) to authenticated;

comment on function public.get_production_tracker_v4(date) is
  'Shared Production Tracker V4 including Finish actuals and processing staff, Finish batch references and Clothes trolley-intake evidence. Flow items bind to scheduled rows by customer, product and date.';
