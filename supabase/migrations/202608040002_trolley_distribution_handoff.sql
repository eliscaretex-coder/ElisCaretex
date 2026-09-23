-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608040002_trolley_distribution_handoff.sql
-- Purpose:
--   Provide a read-only physical trolley handoff for Distribution:
--   - uses the published Customer Schedule route captured by the production
--     assignment source schedule day;
--   - groups physical trolley codes by delivery date, route and customer;
--   - does not create a manual Distribution Daily Plan;
--   - does not claim that delivery was scanner-confirmed;
--   - preserves PRODUCTION_NEXT_DAY_INFERENCE provenance until portable
--     Distribution scanning is introduced.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Extend capability reporting
-- ---------------------------------------------------------------------

create or replace function public.get_trolley_lifecycle_capabilities()
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select jsonb_build_object(
    'can_view_trolleys', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
        'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
        'FINISH_OPERATOR', 'MOP_OPERATOR'
      ]
    ),
    'can_assign_trolleys_from_production', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'FINISH_OPERATOR', 'MOP_OPERATOR']
    ),
    'can_assign_finish_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'FINISH_OPERATOR']
    ),
    'can_assign_mop_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'MOP_OPERATOR']
    ),
    'can_view_distribution_handoff', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'DISTRIBUTION_OPERATOR', 'AUDITOR']
    ),
    'can_dispatch_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR']
    ),
    'can_receive_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']
    ),
    'can_confirm_sorting_arrival', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']
    ),
    'can_view_trolley_exceptions', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR']
    ),
    'can_review_trolley_exceptions', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR']
    ),
    'can_manage_trolley_master', public.has_any_role(
      array['ADMIN', 'MANAGER']
    )
  );
$$;

comment on function public.get_trolley_lifecycle_capabilities()
  is 'Returns role-aware capabilities for the Physical Trolley Lifecycle module, including the read-only Distribution handoff.';

-- ---------------------------------------------------------------------
-- 2. Read-only Distribution trolley handoff
-- ---------------------------------------------------------------------

create or replace function public.get_trolley_distribution_handoff(
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
  perform public.require_any_trolley_role(
    array['ADMIN', 'MANAGER', 'SUPERVISOR', 'DISTRIBUTION_OPERATOR', 'AUDITOR']
  );

  with handoff_rows as (
    select
      s.stay_id,
      s.trolley_id,
      t.trolley_code,
      tt.trolley_type_code,
      tt.trolley_type_name,
      coalesce(tt.display_code, tt.trolley_type_code) as trolley_type_display_code,
      s.outbound_customer_id as customer_id,
      c.customer_code,
      c.customer_name,
      c.eircode,
      s.production_business_date,
      s.production_area_code,
      s.planned_delivery_on,
      s.sent_on,
      s.received_on,
      s.custody_start_source,
      s.notes,
      d.default_route_id,
      d.delivery_order,
      d.delivery_window_start,
      d.delivery_window_end,
      d.distribution_instructions,
      d.day_alert,
      r.route_code,
      r.display_name as route_display_name,
      r.route_color,
      r.sort_order as route_sort_order,
      case
        when s.received_on is not null then 'RETURNED_TO_LAUNDRY'
        when v_delivery_date > current_date then 'PREPARED_FOR_DISTRIBUTION'
        else 'AT_CUSTOMER_INFERRED'
      end as handoff_status
    from public.trolley_customer_stays s
    join public.trolleys t
      on t.trolley_id = s.trolley_id
     and t.deleted_at is null
    left join public.trolley_types tt
      on tt.trolley_type_id = t.trolley_type_id
    join public.customers c
      on c.customer_id = s.outbound_customer_id
    left join public.customer_schedule_days d
      on d.schedule_day_id = s.source_schedule_day_id
    left join public.distribution_routes r
      on r.route_id = d.default_route_id
    where s.production_business_date is not null
      and s.planned_delivery_on = v_delivery_date
  ),
  route_keys as (
    select distinct
      coalesce(default_route_id::text, 'UNASSIGNED') as route_key,
      default_route_id,
      route_code,
      route_display_name,
      route_color,
      route_sort_order
    from handoff_rows
  ),
  route_payload as (
    select
      rk.route_key,
      rk.default_route_id,
      rk.route_code,
      rk.route_display_name,
      rk.route_color,
      rk.route_sort_order,
      (
        select coalesce(
          jsonb_agg(
            jsonb_build_object(
              'customer_id', customer_rows.customer_id,
              'customer_code', customer_rows.customer_code,
              'customer_name', customer_rows.customer_name,
              'eircode', customer_rows.eircode,
              'delivery_order', customer_rows.delivery_order,
              'delivery_window_start', customer_rows.delivery_window_start,
              'delivery_window_end', customer_rows.delivery_window_end,
              'distribution_instructions', customer_rows.distribution_instructions,
              'day_alert', customer_rows.day_alert,
              'trolley_count', jsonb_array_length(customer_rows.trolleys),
              'trolleys', customer_rows.trolleys
            )
            order by customer_rows.delivery_order nulls last,
                     lower(customer_rows.customer_name),
                     customer_rows.customer_code
          ),
          '[]'::jsonb
        )
        from (
          select
            hr.customer_id,
            hr.customer_code,
            hr.customer_name,
            hr.eircode,
            min(hr.delivery_order) as delivery_order,
            min(hr.delivery_window_start) as delivery_window_start,
            min(hr.delivery_window_end) as delivery_window_end,
            min(hr.distribution_instructions) as distribution_instructions,
            min(hr.day_alert) as day_alert,
            jsonb_agg(
              jsonb_build_object(
                'stay_id', hr.stay_id,
                'trolley_id', hr.trolley_id,
                'trolley_code', hr.trolley_code,
                'trolley_type_code', hr.trolley_type_code,
                'trolley_type_name', hr.trolley_type_name,
                'trolley_type_display_code', hr.trolley_type_display_code,
                'production_business_date', hr.production_business_date,
                'production_area_code', hr.production_area_code,
                'planned_delivery_on', hr.planned_delivery_on,
                'sent_on', hr.sent_on,
                'received_on', hr.received_on,
                'custody_start_source', hr.custody_start_source,
                'handoff_status', hr.handoff_status,
                'notes', hr.notes
              )
              order by lower(hr.trolley_code)
            ) as trolleys
          from handoff_rows hr
          where coalesce(hr.default_route_id::text, 'UNASSIGNED') = rk.route_key
          group by
            hr.customer_id,
            hr.customer_code,
            hr.customer_name,
            hr.eircode
        ) customer_rows
      ) as customers
    from route_keys rk
  )
  select jsonb_build_object(
    'delivery_date', v_delivery_date,
    'delivery_tracking_mode', 'PRODUCTION_NEXT_DAY_INFERENCE',
    'is_sunday', extract(isodow from v_delivery_date)::integer = 7,
    'summary', jsonb_build_object(
      'route_count', (
        select count(*)
        from route_payload rp
        where rp.default_route_id is not null
      ),
      'customer_count', (
        select count(distinct hr.customer_id)
        from handoff_rows hr
      ),
      'trolley_count', (
        select count(*)
        from handoff_rows hr
      ),
      'unassigned_route_trolleys', (
        select count(*)
        from handoff_rows hr
        where hr.default_route_id is null
      ),
      'returned_trolleys', (
        select count(*)
        from handoff_rows hr
        where hr.received_on is not null
      )
    ),
    'routes', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'route_id', rp.default_route_id,
            'route_code', coalesce(rp.route_code, 'UNASSIGNED'),
            'route_display_name', coalesce(rp.route_display_name, 'Route not assigned'),
            'route_color', rp.route_color,
            'customer_count', jsonb_array_length(rp.customers),
            'trolley_count', (
              select coalesce(sum((customer_item ->> 'trolley_count')::integer), 0)
              from jsonb_array_elements(rp.customers) customer_item
            ),
            'customers', rp.customers
          )
          order by
            case when rp.default_route_id is null then 1 else 0 end,
            rp.route_sort_order nulls last,
            rp.route_code nulls last,
            rp.route_display_name nulls last
        )
        from route_payload rp
      ),
      '[]'::jsonb
    )
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.get_trolley_distribution_handoff(date)
  is 'Returns the read-only physical trolley load handoff for a delivery date, grouped by the immutable source schedule route. It does not confirm delivery.';

revoke all on function public.get_trolley_distribution_handoff(date) from public, anon;
grant execute on function public.get_trolley_distribution_handoff(date) to authenticated;

commit;
