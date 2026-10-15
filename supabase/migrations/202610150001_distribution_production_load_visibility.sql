begin;

create or replace function public.get_distribution_production_load(
  p_delivery_date date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_delivery_date date := coalesce(p_delivery_date, current_date);
  v_result jsonb;
begin
  perform public.require_distribution_read_access();

  with scheduled_stops as (
    select
      s.source_schedule_day_id,
      s.customer_id,
      s.route_id,
      s.route_code,
      s.route_display_name,
      s.route_color,
      s.customer_name,
      s.planned_product_codes,
      coalesce(s.estimated_kg, 0)::numeric as expected_kg,
      coalesce(s.planned_trolley_total, 0)::integer as planned_trolleys,
      (
        v_delivery_date
        - ((extract(isodow from v_delivery_date)::integer - d.production_weekday::integer + 7) % 7)
      )::date as production_date
    from public.distribution_source_stops(v_delivery_date, null) s
    join public.customer_schedule_days d
      on d.schedule_day_id = s.source_schedule_day_id
  ),
  scheduled_streams as (
    select
      s.*,
      upper(product.product_code) as product_code,
      flow.production_flow_item_id,
      flow.flow_status,
      flow.washed_kg_total,
      finish.finish_kg,
      finish.finish_units,
      finish.finish_contributions,
      mop.mop_production_batch_id,
      mop.mop_kg,
      mop.mop_units,
      coalesce(abs_batch.abs_count, 0) as abs_count
    from scheduled_stops s
    cross join lateral unnest(s.planned_product_codes) product(product_code)
    left join lateral (
      select pfi.*
      from public.production_flow_items pfi
      where pfi.customer_id = s.customer_id
        and pfi.source_schedule_day_id = s.source_schedule_day_id
        and pfi.scheduled_for_date = s.production_date
        and upper(pfi.product_code) = upper(product.product_code)
        and pfi.flow_status <> 'CANCELLED'
      order by pfi.updated_at desc, pfi.production_flow_item_id desc
      limit 1
    ) flow on true
    left join lateral (
      select
        coalesce(sum(line.quantity) filter (where line.unit_code = 'KG'), 0)::numeric as finish_kg,
        coalesce(sum(line.quantity) filter (where line.unit_code = 'UNIT'), 0)::numeric as finish_units,
        count(distinct entry.entry_group_id)::integer as finish_contributions
      from public.finish_production_entries entry
      join public.finish_production_lines line
        on line.finish_production_entry_id = entry.finish_production_entry_id
      where entry.status = 'ACTIVE'
        and entry.production_flow_item_id = flow.production_flow_item_id
    ) finish on true
    left join lateral (
      select
        batch.mop_production_batch_id,
        coalesce(batch.total_weight_kg, 0)::numeric as mop_kg,
        coalesce(batch.total_units, 0)::numeric as mop_units
      from public.sorting_mop_production_batches batch
      where batch.status = 'RECORDED'
        and batch.production_flow_item_id = flow.production_flow_item_id
      order by batch.revision_no desc, batch.recorded_at desc, batch.mop_production_batch_id desc
      limit 1
    ) mop on true
    left join lateral (
      select count(*)::integer as abs_count
      from public.production_flow_external_batches external_batch
      where external_batch.production_flow_item_id = flow.production_flow_item_id
        and external_batch.external_system_code = 'ABS'
        and external_batch.status = 'ACTIVE'
    ) abs_batch on true
  ),
  stream_status as (
    select
      stream.*,
      case
        when stream.product_code = 'CLOTHES' then coalesce(stream.finish_contributions, 0) > 0
        when stream.product_code = 'MOP' then stream.mop_production_batch_id is not null and stream.abs_count > 0
        else false
      end as ready,
      case
        when stream.production_flow_item_id is null then false
        when coalesce(stream.washed_kg_total, 0) > 0 then true
        when coalesce(stream.finish_contributions, 0) > 0 then true
        when stream.mop_production_batch_id is not null then true
        else false
      end as started
    from scheduled_streams stream
  ),
  customer_stats as (
    select
      route_id,
      min(route_code) as route_code,
      min(route_display_name) as route_display_name,
      min(route_color) as route_color,
      customer_id,
      min(customer_name) as customer_name,
      min(production_date) as production_date,
      max(expected_kg) as expected_kg,
      max(planned_trolleys) as planned_trolleys,
      count(*)::integer as stream_count,
      count(*) filter (where ready)::integer as ready_streams,
      bool_and(ready) as ready,
      bool_or(started) as started,
      coalesce(sum(finish_kg), 0)::numeric as finish_kg,
      coalesce(sum(finish_units), 0)::numeric as finish_units,
      coalesce(sum(mop_kg), 0)::numeric as mop_kg,
      coalesce(sum(mop_units), 0)::numeric as mop_units
    from stream_status
    group by route_id, customer_id
  ),
  trolley_stats as (
    select
      schedule_day.default_route_id as route_id,
      count(*)::integer as trolley_count,
      coalesce(sum(trolley_type.tare_weight_kg), 0)::numeric as trolley_tare_kg,
      count(*) filter (where trolley_type.tare_weight_kg is null or trolley_type.tare_weight_kg <= 0)::integer as trolleys_without_tare
    from public.trolley_customer_stays stay
    join public.trolleys trolley
      on trolley.trolley_id = stay.trolley_id
     and trolley.deleted_at is null
    left join public.trolley_types trolley_type
      on trolley_type.trolley_type_id = trolley.trolley_type_id
    left join public.customer_schedule_days schedule_day
      on schedule_day.schedule_day_id = stay.source_schedule_day_id
    where stay.production_business_date is not null
      and stay.planned_delivery_on = v_delivery_date
      and stay.received_on is null
    group by schedule_day.default_route_id
  ),
  route_stats as (
    select
      customer.route_id,
      min(customer.route_code) as route_code,
      min(customer.route_display_name) as route_display_name,
      min(customer.route_color) as route_color,
      count(*)::integer as scheduled_customers,
      count(*) filter (where customer.ready)::integer as ready_customers,
      count(*) filter (where customer.started and not customer.ready)::integer as in_progress_customers,
      count(*) filter (where not customer.started)::integer as not_started_customers,
      coalesce(sum(customer.stream_count), 0)::integer as scheduled_streams,
      coalesce(sum(customer.ready_streams), 0)::integer as ready_streams,
      coalesce(sum(customer.expected_kg), 0)::numeric as expected_kg,
      coalesce(sum(customer.finish_kg), 0)::numeric as finish_kg,
      coalesce(sum(customer.finish_units), 0)::numeric as finish_units,
      coalesce(sum(customer.mop_kg), 0)::numeric as mop_kg,
      coalesce(sum(customer.mop_units), 0)::numeric as mop_units,
      coalesce(sum(customer.planned_trolleys), 0)::integer as planned_trolleys,
      coalesce(max(trolley.trolley_count), 0)::integer as trolley_count,
      coalesce(max(trolley.trolley_tare_kg), 0)::numeric as trolley_tare_kg,
      coalesce(max(trolley.trolleys_without_tare), 0)::integer as trolleys_without_tare,
      min(customer.production_date) as first_production_date,
      max(customer.production_date) as last_production_date
    from customer_stats customer
    left join trolley_stats trolley
      on trolley.route_id = customer.route_id
    group by customer.route_id
  )
  select jsonb_build_object(
    'schema_version', 'DISTRIBUTION_PRODUCTION_LOAD_V1',
    'delivery_date', v_delivery_date,
    'summary', jsonb_build_object(
      'scheduled_customers', coalesce(sum(route.scheduled_customers), 0),
      'ready_customers', coalesce(sum(route.ready_customers), 0),
      'in_progress_customers', coalesce(sum(route.in_progress_customers), 0),
      'not_started_customers', coalesce(sum(route.not_started_customers), 0),
      'expected_kg', coalesce(sum(route.expected_kg), 0),
      'finish_kg', coalesce(sum(route.finish_kg), 0),
      'mop_kg', coalesce(sum(route.mop_kg), 0),
      'mop_units', coalesce(sum(route.mop_units), 0),
      'produced_kg', coalesce(sum(route.finish_kg + route.mop_kg), 0),
      'trolley_count', coalesce(sum(route.trolley_count), 0),
      'trolley_tare_kg', coalesce(sum(route.trolley_tare_kg), 0),
      'known_vehicle_load_kg', coalesce(sum(route.finish_kg + route.mop_kg + route.trolley_tare_kg), 0)
    ),
    'routes', coalesce(jsonb_agg(
      jsonb_build_object(
        'route_id', route.route_id,
        'route_code', route.route_code,
        'route_display_name', route.route_display_name,
        'route_color', route.route_color,
        'scheduled_customers', route.scheduled_customers,
        'ready_customers', route.ready_customers,
        'in_progress_customers', route.in_progress_customers,
        'not_started_customers', route.not_started_customers,
        'scheduled_streams', route.scheduled_streams,
        'ready_streams', route.ready_streams,
        'expected_kg', route.expected_kg,
        'finish_kg', route.finish_kg,
        'finish_units', route.finish_units,
        'mop_kg', route.mop_kg,
        'mop_units', route.mop_units,
        'produced_kg', route.finish_kg + route.mop_kg,
        'planned_trolleys', route.planned_trolleys,
        'trolley_count', route.trolley_count,
        'trolley_tare_kg', route.trolley_tare_kg,
        'trolleys_without_tare', route.trolleys_without_tare,
        'known_vehicle_load_kg', route.finish_kg + route.mop_kg + route.trolley_tare_kg,
        'load_is_partial', route.ready_customers < route.scheduled_customers or route.trolleys_without_tare > 0,
        'first_production_date', route.first_production_date,
        'last_production_date', route.last_production_date
      ) order by route.route_code
    ), '[]'::jsonb)
  )
  into v_result
  from route_stats route;

  return v_result;
end;
$$;

revoke all on function public.get_distribution_production_load(date) from public, anon;
grant execute on function public.get_distribution_production_load(date) to authenticated;

create or replace function public.get_distribution_operations_dashboard_v2(
  p_business_date date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_date date := coalesce(p_business_date, current_date);
  v_dashboard jsonb;
begin
  v_dashboard := public.get_distribution_operations_dashboard(v_date);
  return (v_dashboard - 'schema_version') || jsonb_build_object(
    'schema_version', 'DISTRIBUTION_OPERATIONS_V2',
    'production_load', public.get_distribution_production_load(v_date)
  );
end;
$$;

revoke all on function public.get_distribution_operations_dashboard_v2(date) from public, anon;
grant execute on function public.get_distribution_operations_dashboard_v2(date) to authenticated;

comment on function public.get_distribution_production_load(date)
  is 'Returns actual Finish and MOP output, physical trolley tare and known vehicle load grouped by delivery route.';

comment on function public.get_distribution_operations_dashboard_v2(date)
  is 'Distribution dashboard V2 with production readiness and known vehicle load.';

commit;
