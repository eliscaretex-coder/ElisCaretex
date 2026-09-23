-- =====================================================================
-- ElisCaretex V2
-- Migration: 202607310001_customer_route_visual_read_api.sql
--
-- Purpose:
-- - add the route master colour to Customer operational read payloads;
-- - support the familiar colour-guided weekly planner without exposing
--   Distribution-only route identifiers or delivery fields;
-- - preserve the existing RPC signatures, role checks and row counts.
--
-- Security:
-- - SECURITY DEFINER functions keep the existing explicit role checks;
-- - authenticated users still receive no direct SELECT on customers,
--   schedules or distribution_routes;
-- - only route_visual_color is added to non-Distribution customer views.
-- =====================================================================

create or replace function public.get_customer_weekly_schedule(
  p_customer_id uuid,
  p_effective_date date default public.current_business_date()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_management boolean;
  v_clothes boolean;
  v_mop boolean;
  v_customer public.customers%rowtype;
  v_version public.customer_schedule_versions%rowtype;
  v_result jsonb;
begin
  v_management := public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
  );
  v_clothes := v_management or public.has_any_role(
    array['SORTING_OPERATOR', 'FINISH_OPERATOR']
  );
  v_mop := v_management or public.has_any_role(array['MOP_OPERATOR']);

  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR',
      'SORTING_OPERATOR', 'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  select * into v_customer
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0002', message = 'Customer not found.';
  end if;

  if not v_management and not v_customer.active then
    raise exception using errcode = '42501', message = 'Inactive customers are not available in operational views.';
  end if;

  select * into v_version
  from public.customer_schedule_versions
  where customer_id = p_customer_id
    and status = 'PUBLISHED'
    and p_effective_date >= effective_from
    and (effective_until is null or p_effective_date <= effective_until)
  order by effective_from desc, version_number desc
  limit 1;

  if not found then
    return jsonb_build_object(
      'customer_id', v_customer.customer_id,
      'customer_code', v_customer.customer_code,
      'customer_name', v_customer.customer_name,
      'effective_date', p_effective_date,
      'schedule_version', null,
      'visible_product_codes', array_remove(array[
        case when v_clothes then 'CLOTHES' end,
        case when v_mop then 'MOP' end
      ], null),
      'days', '[]'::jsonb
    );
  end if;

  with visible_products as (
    select
      d.schedule_day_id,
      p.schedule_product_id,
      pt.product_code,
      pt.display_name as product_name,
      pt.sort_order as product_sort_order,
      p.production_order,
      p.expected_kg,
      p.expected_units,
      p.production_instructions,
      coalesce(variants.variant_names, array[]::text[]) as product_variants,
      coalesce(trolley.total_quantity, 0) as planned_trolley_total,
      trolley.trolley_summary,
      coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown,
      coalesce(trolley.has_shared_trolley, false) as has_shared_trolley
    from public.customer_schedule_days d
    join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
     and p.active = true
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
     and pt.active = true
     and pt.deleted_at is null
    left join lateral (
      select array_agg(pv.display_name order by pv.sort_order, pv.display_name)
        as variant_names
      from public.customer_schedule_product_variants spv
      join public.product_variants pv
        on pv.product_variant_id = spv.product_variant_id
      where spv.schedule_product_id = p.schedule_product_id
        and pv.active = true
        and pv.deleted_at is null
    ) variants on true
    left join lateral (
      select
        sum(req.quantity)::integer as total_quantity,
        string_agg(
          concat(
            req.quantity,
            coalesce(tt.display_code, tt.trolley_type_code),
            case when req.empty_trolley then ' Empty' else '' end
          ),
          ' + ' order by tt.sort_order, req.created_at
        ) as trolley_summary,
        jsonb_agg(
          jsonb_build_object(
            'schedule_trolley_requirement_id', req.schedule_trolley_requirement_id,
            'quantity', req.quantity,
            'trolley_type_code', tt.trolley_type_code,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'empty_trolley', req.empty_trolley,
            'shared', served.product_count > 1,
            'serves_product_codes', served.product_codes,
            'notes', req.notes
          )
          order by tt.sort_order, req.created_at
        ) as trolley_breakdown,
        bool_or(served.product_count > 1) as has_shared_trolley
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id = req.trolley_type_id
      left join lateral (
        select
          count(*)::integer as product_count,
          coalesce(
            jsonb_agg(pt2.product_code order by pt2.sort_order, pt2.product_code),
            '[]'::jsonb
          ) as product_codes
        from public.customer_schedule_trolley_requirement_products map
        join public.customer_schedule_products mapped_product
          on mapped_product.schedule_product_id = map.schedule_product_id
        join public.product_types pt2
          on pt2.product_type_id = mapped_product.product_type_id
        where map.schedule_trolley_requirement_id = req.schedule_trolley_requirement_id
      ) served on true
      where req.schedule_day_id = d.schedule_day_id
        and req.owner_schedule_product_id = p.schedule_product_id
        and req.active = true
        and tt.active = true
        and tt.deleted_at is null
    ) trolley on true
    where d.schedule_version_id = v_version.schedule_version_id
      and d.active = true
      and (
        (pt.product_code = 'CLOTHES' and v_clothes)
        or (pt.product_code = 'MOP' and v_mop)
      )
  ),
  day_payload as (
    select
      d.schedule_day_id,
      d.production_weekday,
      public.weekday_name(d.production_weekday) as production_day,
      d.day_alert,
      route_visual.route_color as route_visual_color,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'schedule_product_id', vp.schedule_product_id,
            'product_code', vp.product_code,
            'product_name', vp.product_name,
            'production_order', vp.production_order,
            'expected_kg', vp.expected_kg,
            'expected_units', vp.expected_units,
            'production_instructions', vp.production_instructions,
            'product_variants', vp.product_variants,
            'planned_trolley_total', vp.planned_trolley_total,
            'trolley_summary', vp.trolley_summary,
            'trolley_breakdown', vp.trolley_breakdown,
            'has_shared_trolley', vp.has_shared_trolley
          )
          order by vp.product_sort_order, vp.production_order nulls last
        ) filter (where vp.schedule_product_id is not null),
        '[]'::jsonb
      ) as products,
      coalesce(sum(vp.planned_trolley_total), 0)::integer as visible_trolley_total
    from public.customer_schedule_days d
    join visible_products vp
      on vp.schedule_day_id = d.schedule_day_id
    left join public.distribution_routes route_visual
      on route_visual.route_id = d.default_route_id
     and route_visual.active = true
     and route_visual.deleted_at is null
    where d.schedule_version_id = v_version.schedule_version_id
      and d.active = true
    group by
      d.schedule_day_id,
      d.production_weekday,
      d.day_alert,
      route_visual.route_color
  )
  select jsonb_build_object(
    'customer_id', v_customer.customer_id,
    'customer_code', v_customer.customer_code,
    'customer_name', v_customer.customer_name,
    'active', v_customer.active,
    'operational_alert', v_customer.operational_alert,
    'effective_date', p_effective_date,
    'visible_product_codes', array_remove(array[
      case when v_clothes then 'CLOTHES' end,
      case when v_mop then 'MOP' end
    ], null),
    'schedule_version', jsonb_build_object(
      'schedule_version_id', v_version.schedule_version_id,
      'version_number', v_version.version_number,
      'status', v_version.status,
      'effective_from', v_version.effective_from,
      'effective_until', v_version.effective_until,
      'source_code', v_version.source_code,
      'change_reason', v_version.change_reason,
      'general_instructions', v_version.general_instructions,
      'published_at', v_version.published_at
    ),
    'days', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'schedule_day_id', dp.schedule_day_id,
            'production_weekday', dp.production_weekday,
            'production_day', dp.production_day,
            'day_alert', dp.day_alert,
            'route_visual_color', dp.route_visual_color,
            'visible_trolley_total', dp.visible_trolley_total,
            'products', dp.products
          )
          order by dp.production_weekday
        )
        from day_payload dp
      ),
      '[]'::jsonb
    )
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Clothes weekly planner with route visual colour
-- ---------------------------------------------------------------------

create or replace function public.get_clothes_weekly_planner(
  p_effective_date date default public.current_business_date(),
  p_production_weekday smallint default null,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_search text := nullif(trim(p_search), '');
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
      'SORTING_OPERATOR', 'FINISH_OPERATOR', 'AUDITOR'
    ]
  );

  if p_production_weekday is not null
     and p_production_weekday not between 1 and 7 then
    raise exception using errcode = '22023', message = 'Production weekday must be between 1 and 7.';
  end if;

  with planner_rows as (
    select
      v.schedule_version_id,
      v.version_number,
      d.schedule_day_id,
      d.production_weekday,
      public.weekday_name(d.production_weekday) as production_day,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.operational_alert,
      route_visual.route_color as route_visual_color,
      p.schedule_product_id,
      p.production_order,
      p.expected_kg,
      p.expected_units,
      p.production_instructions as finish_instructions,
      coalesce(trolley.total_quantity, 0) as planned_trolley_total,
      trolley.trolley_summary,
      coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown,
      coalesce(trolley.has_shared_trolley, false) as has_shared_trolley
    from public.customer_schedule_versions v
    join public.customers c
      on c.customer_id = v.customer_id
    join public.customer_schedule_days d
      on d.schedule_version_id = v.schedule_version_id
    join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
    left join public.distribution_routes route_visual
      on route_visual.route_id = d.default_route_id
     and route_visual.active = true
     and route_visual.deleted_at is null
    left join lateral (
      select
        sum(req.quantity)::integer as total_quantity,
        string_agg(
          concat(
            req.quantity,
            coalesce(tt.display_code, tt.trolley_type_code),
            case when req.empty_trolley then ' Empty' else '' end
          ),
          ' + ' order by tt.sort_order, req.created_at
        ) as trolley_summary,
        jsonb_agg(
          jsonb_build_object(
            'quantity', req.quantity,
            'trolley_type_code', tt.trolley_type_code,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'empty_trolley', req.empty_trolley,
            'shared', served.product_count > 1,
            'serves_product_codes', served.product_codes,
            'notes', req.notes
          ) order by tt.sort_order, req.created_at
        ) as trolley_breakdown,
        bool_or(served.product_count > 1) as has_shared_trolley
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id = req.trolley_type_id
      left join lateral (
        select
          count(*)::integer as product_count,
          coalesce(
            jsonb_agg(pt2.product_code order by pt2.sort_order, pt2.product_code),
            '[]'::jsonb
          ) as product_codes
        from public.customer_schedule_trolley_requirement_products map
        join public.customer_schedule_products mp
          on mp.schedule_product_id = map.schedule_product_id
        join public.product_types pt2
          on pt2.product_type_id = mp.product_type_id
        where map.schedule_trolley_requirement_id = req.schedule_trolley_requirement_id
      ) served on true
      where req.schedule_day_id = d.schedule_day_id
        and req.owner_schedule_product_id = p.schedule_product_id
        and req.active = true
        and tt.active = true
        and tt.deleted_at is null
    ) trolley on true
    where v.status = 'PUBLISHED'
      and p_effective_date >= v.effective_from
      and (v.effective_until is null or p_effective_date <= v.effective_until)
      and c.active = true
      and c.deleted_at is null
      and d.active = true
      and p.active = true
      and pt.active = true
      and pt.deleted_at is null
      and pt.product_code = 'CLOTHES'
      and (p_production_weekday is null or d.production_weekday = p_production_weekday)
      and (
        v_search is null
        or c.customer_name ilike '%' || v_search || '%'
        or c.customer_code ilike '%' || v_search || '%'
      )
  )
  select jsonb_build_object(
    'effective_date', p_effective_date,
    'production_weekday', p_production_weekday,
    'search', v_search,
    'total_count', count(*),
    'items', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'schedule_version_id', pr.schedule_version_id,
          'version_number', pr.version_number,
          'schedule_day_id', pr.schedule_day_id,
          'production_weekday', pr.production_weekday,
          'production_day', pr.production_day,
          'customer_id', pr.customer_id,
          'customer_code', pr.customer_code,
          'customer_name', pr.customer_name,
          'operational_alert', pr.operational_alert,
          'route_visual_color', pr.route_visual_color,
          'schedule_product_id', pr.schedule_product_id,
          'production_order', pr.production_order,
          'expected_kg', pr.expected_kg,
          'expected_units', pr.expected_units,
          'finish_instructions', pr.finish_instructions,
          'planned_trolley_total', pr.planned_trolley_total,
          'trolley_summary', pr.trolley_summary,
          'trolley_breakdown', pr.trolley_breakdown,
          'has_shared_trolley', pr.has_shared_trolley
        )
        order by
          pr.production_weekday,
          pr.production_order nulls last,
          lower(pr.customer_name)
      ),
      '[]'::jsonb
    )
  ) into v_result
  from planner_rows pr;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- MOP weekly planner with route visual colour
-- ---------------------------------------------------------------------

create or replace function public.get_mop_weekly_planner(
  p_effective_date date default public.current_business_date(),
  p_production_weekday smallint default null,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_search text := nullif(trim(p_search), '');
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
      'MOP_OPERATOR', 'AUDITOR'
    ]
  );

  if p_production_weekday is not null
     and p_production_weekday not between 1 and 7 then
    raise exception using errcode = '22023', message = 'Production weekday must be between 1 and 7.';
  end if;

  with planner_rows as (
    select
      v.schedule_version_id,
      v.version_number,
      d.schedule_day_id,
      d.production_weekday,
      public.weekday_name(d.production_weekday) as production_day,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.operational_alert,
      route_visual.route_color as route_visual_color,
      p.schedule_product_id,
      p.production_order,
      p.expected_kg,
      p.expected_units,
      p.production_instructions as mop_instructions,
      coalesce(variants.product_variants, array[]::text[]) as mop_products,
      coalesce(trolley.total_quantity, 0) as planned_trolley_total,
      trolley.trolley_summary,
      coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown
    from public.customer_schedule_versions v
    join public.customers c
      on c.customer_id = v.customer_id
    join public.customer_schedule_days d
      on d.schedule_version_id = v.schedule_version_id
    join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
    left join public.distribution_routes route_visual
      on route_visual.route_id = d.default_route_id
     and route_visual.active = true
     and route_visual.deleted_at is null
    left join lateral (
      select array_agg(pv.display_name order by pv.sort_order, pv.display_name)
        as product_variants
      from public.customer_schedule_product_variants spv
      join public.product_variants pv
        on pv.product_variant_id = spv.product_variant_id
      where spv.schedule_product_id = p.schedule_product_id
        and pv.active = true
        and pv.deleted_at is null
    ) variants on true
    left join lateral (
      select
        sum(req.quantity)::integer as total_quantity,
        string_agg(
          concat(
            req.quantity,
            coalesce(tt.display_code, tt.trolley_type_code),
            case when req.empty_trolley then ' Empty' else '' end
          ),
          ' + ' order by tt.sort_order, req.created_at
        ) as trolley_summary,
        jsonb_agg(
          jsonb_build_object(
            'quantity', req.quantity,
            'trolley_type_code', tt.trolley_type_code,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'empty_trolley', req.empty_trolley,
            'notes', req.notes
          ) order by tt.sort_order, req.created_at
        ) as trolley_breakdown
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id = req.trolley_type_id
      where req.schedule_day_id = d.schedule_day_id
        and req.owner_schedule_product_id = p.schedule_product_id
        and req.active = true
        and tt.active = true
        and tt.deleted_at is null
    ) trolley on true
    where v.status = 'PUBLISHED'
      and p_effective_date >= v.effective_from
      and (v.effective_until is null or p_effective_date <= v.effective_until)
      and c.active = true
      and c.deleted_at is null
      and d.active = true
      and p.active = true
      and pt.active = true
      and pt.deleted_at is null
      and pt.product_code = 'MOP'
      and (p_production_weekday is null or d.production_weekday = p_production_weekday)
      and (
        v_search is null
        or c.customer_name ilike '%' || v_search || '%'
        or c.customer_code ilike '%' || v_search || '%'
      )
  )
  select jsonb_build_object(
    'effective_date', p_effective_date,
    'production_weekday', p_production_weekday,
    'search', v_search,
    'total_count', count(*),
    'items', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'schedule_version_id', pr.schedule_version_id,
          'version_number', pr.version_number,
          'schedule_day_id', pr.schedule_day_id,
          'production_weekday', pr.production_weekday,
          'production_day', pr.production_day,
          'customer_id', pr.customer_id,
          'customer_code', pr.customer_code,
          'customer_name', pr.customer_name,
          'operational_alert', pr.operational_alert,
          'route_visual_color', pr.route_visual_color,
          'schedule_product_id', pr.schedule_product_id,
          'production_order', pr.production_order,
          'expected_kg', pr.expected_kg,
          'expected_units', pr.expected_units,
          'mop_instructions', pr.mop_instructions,
          'mop_products', pr.mop_products,
          'planned_trolley_total', pr.planned_trolley_total,
          'trolley_summary', pr.trolley_summary,
          'trolley_breakdown', pr.trolley_breakdown
        )
        order by
          pr.production_weekday,
          pr.production_order nulls last,
          lower(pr.customer_name)
      ),
      '[]'::jsonb
    )
  ) into v_result
  from planner_rows pr;

  return v_result;
end;
$$;

comment on function public.get_customer_weekly_schedule(uuid, date) is
  'Returns the permission-filtered published weekly schedule. Includes route_visual_color only for familiar operational colour guidance; Distribution details remain permission controlled.';

comment on function public.get_clothes_weekly_planner(date, smallint, text) is
  'Returns the active published Clothes planner with route_visual_color for operational colour guidance.';

comment on function public.get_mop_weekly_planner(date, smallint, text) is
  'Returns the active published MOP planner with route_visual_color for operational colour guidance.';
