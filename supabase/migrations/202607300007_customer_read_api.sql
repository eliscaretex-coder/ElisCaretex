-- =====================================================================
-- ElisCaretex V2
-- Migration: 202607300007_customer_read_api.sql
-- Purpose:
--   Provide a controlled, read-only RPC API for the Customer Directory,
--   Customer Workspace, schedule history and area-specific weekly planners.
--
-- Security principles:
--   - The frontend does not join operational tables directly.
--   - Distribution-only fields are returned only by Distribution RPCs.
--   - Every RPC validates the authenticated staff member and role.
--   - Inactive customers are excluded from operational planners.
--   - Published schedule data is selected by an explicit effective date.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Safety guard
-- ---------------------------------------------------------------------

do $$
declare
  v_customers integer;
  v_active_customers integer;
  v_inactive_customers integer;
  v_versions integer;
  v_days integer;
  v_products integer;
begin
  select count(*),
         count(*) filter (where active),
         count(*) filter (where not active)
  into v_customers, v_active_customers, v_inactive_customers
  from public.customers
  where deleted_at is null;

  select count(*) into v_versions
  from public.customer_schedule_versions
  where status = 'PUBLISHED';

  select count(*) into v_days
  from public.customer_schedule_days;

  select count(*) into v_products
  from public.customer_schedule_products;

  if v_customers <> 141
     or v_active_customers <> 130
     or v_inactive_customers <> 11
     or v_versions <> 130
     or v_days <> 417
     or v_products <> 505 then
    raise exception using
      message = 'Safety stop: operational customer import totals are unexpected.',
      detail = format(
        'customers=%s, active=%s, inactive=%s, published_versions=%s, days=%s, products=%s',
        v_customers,
        v_active_customers,
        v_inactive_customers,
        v_versions,
        v_days,
        v_products
      ),
      hint = 'Run the operational import validation before applying the read API.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Internal access guard
-- ---------------------------------------------------------------------

create or replace function public.require_any_customer_read_role(
  p_role_codes text[]
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null or public.current_staff_id() is null then
    raise exception using
      errcode = '42501',
      message = 'An active authenticated staff account is required.';
  end if;

  if not public.has_any_role(p_role_codes) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to read this customer information.';
  end if;
end;
$$;

revoke all on function public.require_any_customer_read_role(text[])
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Frontend capability discovery
-- ---------------------------------------------------------------------

create or replace function public.get_customer_read_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR',
      'SORTING_OPERATOR', 'FINISH_OPERATOR', 'MOP_OPERATOR',
      'DISTRIBUTION_OPERATOR'
    ]
  );

  return jsonb_build_object(
    'business_date', public.current_business_date(),
    'can_view_customer_directory', public.has_any_role(
      array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
    ),
    'can_edit_customers', public.has_any_role(
      array['ADMIN', 'MANAGER', 'PLANNER']
    ),
    'can_deactivate_customers', public.has_any_role(
      array['ADMIN', 'MANAGER']
    ),
    'can_edit_schedules', public.has_any_role(
      array['ADMIN', 'MANAGER', 'PLANNER']
    ),
    'can_view_schedule_history', public.has_any_role(
      array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
    ),
    'can_view_clothes_planner', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
        'SORTING_OPERATOR', 'FINISH_OPERATOR', 'AUDITOR'
      ]
    ),
    'can_view_mop_planner', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
        'MOP_OPERATOR', 'AUDITOR'
      ]
    ),
    'can_view_distribution', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'PLANNER',
        'DISTRIBUTION_OPERATOR', 'AUDITOR'
      ]
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Customer Directory
-- ---------------------------------------------------------------------

create or replace function public.get_customer_directory(
  p_status text default 'ACTIVE',
  p_service_filter text default 'ALL',
  p_search text default null,
  p_effective_date date default public.current_business_date(),
  p_limit integer default 200,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_status text := upper(trim(coalesce(p_status, 'ACTIVE')));
  v_service_filter text := upper(trim(coalesce(p_service_filter, 'ALL')));
  v_search text := nullif(trim(p_search), '');
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
  );

  if v_status not in ('ACTIVE', 'INACTIVE', 'ALL') then
    raise exception using
      errcode = '22023',
      message = 'Invalid customer status filter.',
      detail = 'Allowed values: ACTIVE, INACTIVE, ALL.';
  end if;

  if v_service_filter not in (
    'ALL', 'CLOTHES', 'MOP',
    'CLOTHES_ONLY', 'MOP_ONLY', 'CLOTHES_AND_MOP'
  ) then
    raise exception using
      errcode = '22023',
      message = 'Invalid customer service filter.',
      detail = 'Allowed values: ALL, CLOTHES, MOP, CLOTHES_ONLY, MOP_ONLY, CLOTHES_AND_MOP.';
  end if;

  with customer_base as (
    select
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.eircode,
      c.operational_alert,
      c.active,
      c.deactivated_at,
      c.deactivation_reason,
      c.row_version,
      coalesce(
        array_agg(pt.product_code order by pt.sort_order, pt.product_code)
          filter (where pt.product_code is not null),
        array[]::text[]
      ) as product_services
    from public.customers c
    left join public.customer_product_services s
      on s.customer_id = c.customer_id
     and s.active = true
     and s.deleted_at is null
     and s.effective_from <= p_effective_date
     and (s.effective_until is null or s.effective_until >= p_effective_date)
    left join public.product_types pt
      on pt.product_type_id = s.product_type_id
     and pt.active = true
     and pt.deleted_at is null
    where c.deleted_at is null
    group by
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.eircode,
      c.operational_alert,
      c.active,
      c.deactivated_at,
      c.deactivation_reason,
      c.row_version
  ),
  enriched as (
    select
      cb.*,
      cv.schedule_version_id,
      cv.version_number,
      cv.status as schedule_status,
      cv.effective_from,
      cv.effective_until,
      coalesce(sc.schedule_day_count, 0) as schedule_day_count,
      coalesce(sc.schedule_product_count, 0) as schedule_product_count
    from customer_base cb
    left join lateral (
      select
        v.schedule_version_id,
        v.version_number,
        v.status,
        v.effective_from,
        v.effective_until
      from public.customer_schedule_versions v
      where v.customer_id = cb.customer_id
        and v.status = 'PUBLISHED'
        and p_effective_date >= v.effective_from
        and (v.effective_until is null or p_effective_date <= v.effective_until)
      order by v.effective_from desc, v.version_number desc
      limit 1
    ) cv on true
    left join lateral (
      select
        count(distinct d.schedule_day_id)::integer as schedule_day_count,
        count(p.schedule_product_id)::integer as schedule_product_count
      from public.customer_schedule_days d
      left join public.customer_schedule_products p
        on p.schedule_day_id = d.schedule_day_id
       and p.active = true
      where d.schedule_version_id = cv.schedule_version_id
        and d.active = true
    ) sc on true
  ),
  filtered as (
    select *
    from enriched e
    where
      (v_status = 'ALL'
       or (v_status = 'ACTIVE' and e.active)
       or (v_status = 'INACTIVE' and not e.active))
      and (
        v_service_filter = 'ALL'
        or (v_service_filter = 'CLOTHES' and 'CLOTHES' = any(e.product_services))
        or (v_service_filter = 'MOP' and 'MOP' = any(e.product_services))
        or (v_service_filter = 'CLOTHES_ONLY' and e.product_services = array['CLOTHES']::text[])
        or (v_service_filter = 'MOP_ONLY' and e.product_services = array['MOP']::text[])
        or (
          v_service_filter = 'CLOTHES_AND_MOP'
          and 'CLOTHES' = any(e.product_services)
          and 'MOP' = any(e.product_services)
        )
      )
      and (
        v_search is null
        or e.customer_name ilike '%' || v_search || '%'
        or e.customer_code ilike '%' || v_search || '%'
        or coalesce(e.eircode, '') ilike '%' || v_search || '%'
      )
  ),
  page_rows as (
    select *
    from filtered
    order by active desc, lower(customer_name), customer_code
    limit v_limit
    offset v_offset
  )
  select jsonb_build_object(
    'effective_date', p_effective_date,
    'status_filter', v_status,
    'service_filter', v_service_filter,
    'search', v_search,
    'limit', v_limit,
    'offset', v_offset,
    'total_count', (select count(*) from filtered),
    'items', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'customer_id', p.customer_id,
            'customer_code', p.customer_code,
            'customer_name', p.customer_name,
            'eircode', p.eircode,
            'product_services', p.product_services,
            'active', p.active,
            'deactivated_at', p.deactivated_at,
            'deactivation_reason', p.deactivation_reason,
            'operational_alert', p.operational_alert,
            'row_version', p.row_version,
            'current_schedule', case
              when p.schedule_version_id is null then null
              else jsonb_build_object(
                'schedule_version_id', p.schedule_version_id,
                'version_number', p.version_number,
                'status', p.schedule_status,
                'effective_from', p.effective_from,
                'effective_until', p.effective_until,
                'schedule_day_count', p.schedule_day_count,
                'schedule_product_count', p.schedule_product_count
              )
            end
          )
          order by p.active desc, lower(p.customer_name), p.customer_code
        )
        from page_rows p
      ),
      '[]'::jsonb
    )
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Customer Overview without Distribution-only fields
-- ---------------------------------------------------------------------

create or replace function public.get_customer_overview(
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
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
  );

  if p_customer_id is null then
    raise exception using errcode = '22004', message = 'Customer ID is required.';
  end if;

  select jsonb_build_object(
    'customer_id', c.customer_id,
    'customer_code', c.customer_code,
    'customer_name', c.customer_name,
    'eircode', c.eircode,
    'notes', c.notes,
    'operational_alert', c.operational_alert,
    'active', c.active,
    'deactivated_at', c.deactivated_at,
    'deactivation_reason', c.deactivation_reason,
    'created_at', c.created_at,
    'updated_at', c.updated_at,
    'row_version', c.row_version,
    'effective_date', p_effective_date,
    'product_services', coalesce(services.product_services, array[]::text[]),
    'current_schedule', case
      when cv.schedule_version_id is null then null
      else jsonb_build_object(
        'schedule_version_id', cv.schedule_version_id,
        'version_number', cv.version_number,
        'status', cv.status,
        'effective_from', cv.effective_from,
        'effective_until', cv.effective_until,
        'source_code', cv.source_code,
        'change_reason', cv.change_reason,
        'published_at', cv.published_at,
        'schedule_day_count', coalesce(counts.schedule_day_count, 0),
        'schedule_product_count', coalesce(counts.schedule_product_count, 0)
      )
    end,
    'can_view_distribution', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'PLANNER',
        'DISTRIBUTION_OPERATOR', 'AUDITOR'
      ]
    )
  )
  into v_result
  from public.customers c
  left join lateral (
    select array_agg(pt.product_code order by pt.sort_order, pt.product_code)
      as product_services
    from public.customer_product_services s
    join public.product_types pt
      on pt.product_type_id = s.product_type_id
    where s.customer_id = c.customer_id
      and s.active = true
      and s.deleted_at is null
      and s.effective_from <= p_effective_date
      and (s.effective_until is null or s.effective_until >= p_effective_date)
      and pt.active = true
      and pt.deleted_at is null
  ) services on true
  left join lateral (
    select v.*
    from public.customer_schedule_versions v
    where v.customer_id = c.customer_id
      and v.status = 'PUBLISHED'
      and p_effective_date >= v.effective_from
      and (v.effective_until is null or p_effective_date <= v.effective_until)
    order by v.effective_from desc, v.version_number desc
    limit 1
  ) cv on true
  left join lateral (
    select
      count(distinct d.schedule_day_id)::integer as schedule_day_count,
      count(p.schedule_product_id)::integer as schedule_product_count
    from public.customer_schedule_days d
    left join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
     and p.active = true
    where d.schedule_version_id = cv.schedule_version_id
      and d.active = true
  ) counts on true
  where c.customer_id = p_customer_id
    and c.deleted_at is null;

  if v_result is null then
    raise exception using errcode = 'P0002', message = 'Customer not found.';
  end if;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Customer weekly schedule without Distribution-only fields
-- ---------------------------------------------------------------------

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
    where d.schedule_version_id = v_version.schedule_version_id
      and d.active = true
    group by d.schedule_day_id, d.production_weekday, d.day_alert
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
-- Schedule history for management roles
-- ---------------------------------------------------------------------

create or replace function public.get_customer_schedule_history(
  p_customer_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_customer_name text;
  v_customer_code text;
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
  );

  select customer_name, customer_code
  into v_customer_name, v_customer_code
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0002', message = 'Customer not found.';
  end if;

  select jsonb_build_object(
    'customer_id', p_customer_id,
    'customer_code', v_customer_code,
    'customer_name', v_customer_name,
    'items', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'schedule_version_id', v.schedule_version_id,
          'version_number', v.version_number,
          'status', v.status,
          'effective_from', v.effective_from,
          'effective_until', v.effective_until,
          'based_on_version_id', v.based_on_version_id,
          'source_code', v.source_code,
          'change_reason', v.change_reason,
          'created_at', v.created_at,
          'updated_at', v.updated_at,
          'published_at', v.published_at,
          'superseded_at', v.superseded_at,
          'cancelled_at', v.cancelled_at,
          'row_version', v.row_version,
          'schedule_day_count', counts.schedule_day_count,
          'schedule_product_count', counts.schedule_product_count,
          'trolley_requirement_count', counts.trolley_requirement_count,
          'is_effective_on_business_date',
            v.status = 'PUBLISHED'
            and public.current_business_date() >= v.effective_from
            and (
              v.effective_until is null
              or public.current_business_date() <= v.effective_until
            ),
          'can_restore_as_draft', v.status in ('PUBLISHED', 'SUPERSEDED')
        )
        order by v.version_number desc
      ),
      '[]'::jsonb
    )
  ) into v_result
  from public.customer_schedule_versions v
  left join lateral (
    select
      count(distinct d.schedule_day_id)::integer as schedule_day_count,
      count(distinct p.schedule_product_id)::integer as schedule_product_count,
      count(distinct req.schedule_trolley_requirement_id)::integer
        as trolley_requirement_count
    from public.customer_schedule_days d
    left join public.customer_schedule_products p
      on p.schedule_day_id = d.schedule_day_id
    left join public.customer_schedule_trolley_requirements req
      on req.schedule_day_id = d.schedule_day_id
    where d.schedule_version_id = v.schedule_version_id
  ) counts on true
  where v.customer_id = p_customer_id;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Clothes weekly planner
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
-- Mop weekly planner
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

-- ---------------------------------------------------------------------
-- Distribution overview and weekly planner
-- ---------------------------------------------------------------------

create or replace function public.get_customer_distribution_overview(
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
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER',
      'DISTRIBUTION_OPERATOR', 'AUDITOR'
    ]
  );

  with selected_version as (
    select v.*
    from public.customer_schedule_versions v
    where v.customer_id = p_customer_id
      and v.status = 'PUBLISHED'
      and p_effective_date >= v.effective_from
      and (v.effective_until is null or p_effective_date <= v.effective_until)
    order by v.effective_from desc, v.version_number desc
    limit 1
  ),
  day_rows as (
    select
      d.schedule_day_id,
      d.production_weekday,
      public.weekday_name(d.production_weekday) as production_day,
      d.delivery_weekday,
      public.weekday_name(d.delivery_weekday) as delivery_day,
      d.delivery_window_start,
      d.delivery_window_end,
      d.delivery_order,
      d.day_alert,
      d.distribution_instructions,
      r.route_id as default_route_id,
      r.route_code as default_route_code,
      r.display_name as default_route_display_name,
      r.route_color as default_route_color,
      coalesce(products.product_codes, array[]::text[]) as scheduled_products,
      coalesce(trolley.total_quantity, 0) as planned_trolley_total,
      trolley.trolley_summary,
      coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown
    from selected_version v
    join public.customer_schedule_days d
      on d.schedule_version_id = v.schedule_version_id
     and d.active = true
    left join public.distribution_routes r
      on r.route_id = d.default_route_id
    left join lateral (
      select array_agg(pt.product_code order by pt.sort_order, pt.product_code)
        as product_codes
      from public.customer_schedule_products p
      join public.product_types pt
        on pt.product_type_id = p.product_type_id
      where p.schedule_day_id = d.schedule_day_id
        and p.active = true
        and pt.active = true
        and pt.deleted_at is null
    ) products on true
    left join lateral (
      select
        sum(req.quantity)::integer as total_quantity,
        string_agg(
          concat(
            req.quantity,
            coalesce(tt.display_code, tt.trolley_type_code),
            ' (', owner_pt.product_code,
            case when served.product_count > 1 then ', Shared' else '' end,
            case when req.empty_trolley then ', Empty' else '' end,
            ')'
          ),
          ' + ' order by tt.sort_order, req.created_at
        ) as trolley_summary,
        jsonb_agg(
          jsonb_build_object(
            'quantity', req.quantity,
            'trolley_type_code', tt.trolley_type_code,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'owner_product_code', owner_pt.product_code,
            'serves_product_codes', served.product_codes,
            'shared', served.product_count > 1,
            'empty_trolley', req.empty_trolley,
            'notes', req.notes
          ) order by tt.sort_order, req.created_at
        ) as trolley_breakdown
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id = req.trolley_type_id
      join public.customer_schedule_products owner_product
        on owner_product.schedule_product_id = req.owner_schedule_product_id
      join public.product_types owner_pt
        on owner_pt.product_type_id = owner_product.product_type_id
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
        and req.active = true
        and tt.active = true
        and tt.deleted_at is null
    ) trolley on true
  )
  select jsonb_build_object(
    'customer_id', c.customer_id,
    'customer_code', c.customer_code,
    'customer_name', c.customer_name,
    'eircode', c.eircode,
    'active', c.active,
    'distribution_estimated_kg', c.distribution_estimated_kg,
    'distribution_stop_count', c.distribution_stop_count,
    'operational_alert', c.operational_alert,
    'effective_date', p_effective_date,
    'route_semantics', jsonb_build_object(
      'source', 'CUSTOMER_DEFAULT_SCHEDULE',
      'actual_daily_route_may_differ', true,
      'actual_daily_route_does_not_rewrite_customer_schedule', true
    ),
    'days', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'schedule_day_id', dr.schedule_day_id,
            'production_weekday', dr.production_weekday,
            'production_day', dr.production_day,
            'delivery_weekday', dr.delivery_weekday,
            'delivery_day', dr.delivery_day,
            'delivery_window_start', dr.delivery_window_start,
            'delivery_window_end', dr.delivery_window_end,
            'delivery_order', dr.delivery_order,
            'day_alert', dr.day_alert,
            'distribution_instructions', dr.distribution_instructions,
            'default_route_id', dr.default_route_id,
            'default_route_code', dr.default_route_code,
            'default_route_display_name', dr.default_route_display_name,
            'default_route_color', dr.default_route_color,
            'scheduled_products', dr.scheduled_products,
            'planned_trolley_total', dr.planned_trolley_total,
            'trolley_summary', dr.trolley_summary,
            'trolley_breakdown', dr.trolley_breakdown
          ) order by dr.production_weekday
        )
        from day_rows dr
      ),
      '[]'::jsonb
    )
  ) into v_result
  from public.customers c
  where c.customer_id = p_customer_id
    and c.deleted_at is null;

  if v_result is null then
    raise exception using errcode = 'P0002', message = 'Customer not found.';
  end if;

  return v_result;
end;
$$;

create or replace function public.get_distribution_weekly_planner(
  p_effective_date date default public.current_business_date(),
  p_delivery_weekday smallint default null,
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
      'ADMIN', 'MANAGER', 'PLANNER',
      'DISTRIBUTION_OPERATOR', 'AUDITOR'
    ]
  );

  if p_delivery_weekday is not null
     and p_delivery_weekday not between 1 and 7 then
    raise exception using errcode = '22023', message = 'Delivery weekday must be between 1 and 7.';
  end if;

  with planner_rows as (
    select
      v.schedule_version_id,
      v.version_number,
      d.schedule_day_id,
      d.production_weekday,
      public.weekday_name(d.production_weekday) as production_day,
      d.delivery_weekday,
      public.weekday_name(d.delivery_weekday) as delivery_day,
      d.delivery_window_start,
      d.delivery_window_end,
      d.delivery_order,
      d.day_alert,
      d.distribution_instructions,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.eircode,
      c.distribution_estimated_kg,
      c.distribution_stop_count,
      c.operational_alert,
      r.route_id as default_route_id,
      r.route_code as default_route_code,
      r.display_name as default_route_display_name,
      r.route_color as default_route_color,
      coalesce(products.product_codes, array[]::text[]) as scheduled_products,
      coalesce(trolley.total_quantity, 0) as planned_trolley_total,
      trolley.trolley_summary,
      coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown
    from public.customer_schedule_versions v
    join public.customers c
      on c.customer_id = v.customer_id
    join public.customer_schedule_days d
      on d.schedule_version_id = v.schedule_version_id
    left join public.distribution_routes r
      on r.route_id = d.default_route_id
    left join lateral (
      select array_agg(pt.product_code order by pt.sort_order, pt.product_code)
        as product_codes
      from public.customer_schedule_products p
      join public.product_types pt
        on pt.product_type_id = p.product_type_id
      where p.schedule_day_id = d.schedule_day_id
        and p.active = true
        and pt.active = true
        and pt.deleted_at is null
    ) products on true
    left join lateral (
      select
        sum(req.quantity)::integer as total_quantity,
        string_agg(
          concat(
            req.quantity,
            coalesce(tt.display_code, tt.trolley_type_code),
            ' (', owner_pt.product_code,
            case when served.product_count > 1 then ', Shared' else '' end,
            case when req.empty_trolley then ', Empty' else '' end,
            ')'
          ),
          ' + ' order by tt.sort_order, req.created_at
        ) as trolley_summary,
        jsonb_agg(
          jsonb_build_object(
            'quantity', req.quantity,
            'trolley_type_code', tt.trolley_type_code,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'owner_product_code', owner_pt.product_code,
            'serves_product_codes', served.product_codes,
            'shared', served.product_count > 1,
            'empty_trolley', req.empty_trolley,
            'notes', req.notes
          ) order by tt.sort_order, req.created_at
        ) as trolley_breakdown
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id = req.trolley_type_id
      join public.customer_schedule_products owner_product
        on owner_product.schedule_product_id = req.owner_schedule_product_id
      join public.product_types owner_pt
        on owner_pt.product_type_id = owner_product.product_type_id
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
      and (
        p_delivery_weekday is null
        or d.delivery_weekday = p_delivery_weekday
      )
      and (
        v_search is null
        or c.customer_name ilike '%' || v_search || '%'
        or c.customer_code ilike '%' || v_search || '%'
        or coalesce(r.route_code, '') ilike '%' || v_search || '%'
        or coalesce(r.display_name, '') ilike '%' || v_search || '%'
      )
  )
  select jsonb_build_object(
    'effective_date', p_effective_date,
    'delivery_weekday', p_delivery_weekday,
    'search', v_search,
    'route_semantics', jsonb_build_object(
      'source', 'CUSTOMER_DEFAULT_SCHEDULE',
      'actual_daily_route_may_differ', true,
      'actual_daily_route_does_not_rewrite_customer_schedule', true
    ),
    'total_count', count(*),
    'items', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'schedule_version_id', pr.schedule_version_id,
          'version_number', pr.version_number,
          'schedule_day_id', pr.schedule_day_id,
          'production_weekday', pr.production_weekday,
          'production_day', pr.production_day,
          'delivery_weekday', pr.delivery_weekday,
          'delivery_day', pr.delivery_day,
          'delivery_window_start', pr.delivery_window_start,
          'delivery_window_end', pr.delivery_window_end,
          'delivery_order', pr.delivery_order,
          'day_alert', pr.day_alert,
          'distribution_instructions', pr.distribution_instructions,
          'customer_id', pr.customer_id,
          'customer_code', pr.customer_code,
          'customer_name', pr.customer_name,
          'eircode', pr.eircode,
          'distribution_estimated_kg', pr.distribution_estimated_kg,
          'distribution_stop_count', pr.distribution_stop_count,
          'operational_alert', pr.operational_alert,
          'default_route_id', pr.default_route_id,
          'default_route_code', pr.default_route_code,
          'default_route_display_name', pr.default_route_display_name,
          'default_route_color', pr.default_route_color,
          'scheduled_products', pr.scheduled_products,
          'planned_trolley_total', pr.planned_trolley_total,
          'trolley_summary', pr.trolley_summary,
          'trolley_breakdown', pr.trolley_breakdown
        )
        order by
          pr.delivery_weekday nulls last,
          pr.default_route_code nulls last,
          pr.delivery_order nulls last,
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
-- Function privileges
-- ---------------------------------------------------------------------

revoke all on function public.get_customer_read_capabilities()
  from public, anon;
revoke all on function public.get_customer_directory(text, text, text, date, integer, integer)
  from public, anon;
revoke all on function public.get_customer_overview(uuid, date)
  from public, anon;
revoke all on function public.get_customer_weekly_schedule(uuid, date)
  from public, anon;
revoke all on function public.get_customer_schedule_history(uuid)
  from public, anon;
revoke all on function public.get_clothes_weekly_planner(date, smallint, text)
  from public, anon;
revoke all on function public.get_mop_weekly_planner(date, smallint, text)
  from public, anon;
revoke all on function public.get_customer_distribution_overview(uuid, date)
  from public, anon;
revoke all on function public.get_distribution_weekly_planner(date, smallint, text)
  from public, anon;

grant execute on function public.get_customer_read_capabilities()
  to authenticated;
grant execute on function public.get_customer_directory(text, text, text, date, integer, integer)
  to authenticated;
grant execute on function public.get_customer_overview(uuid, date)
  to authenticated;
grant execute on function public.get_customer_weekly_schedule(uuid, date)
  to authenticated;
grant execute on function public.get_customer_schedule_history(uuid)
  to authenticated;
grant execute on function public.get_clothes_weekly_planner(date, smallint, text)
  to authenticated;
grant execute on function public.get_mop_weekly_planner(date, smallint, text)
  to authenticated;
grant execute on function public.get_customer_distribution_overview(uuid, date)
  to authenticated;
grant execute on function public.get_distribution_weekly_planner(date, smallint, text)
  to authenticated;

comment on function public.get_customer_directory(text, text, text, date, integer, integer)
  is 'Read-only Customer Directory for authorized management roles. Distribution-only fields are excluded.';
comment on function public.get_customer_weekly_schedule(uuid, date)
  is 'Read-only effective weekly customer schedule. Product visibility is restricted by the caller role.';
comment on function public.get_clothes_weekly_planner(date, smallint, text)
  is 'Read-only Clothes production planner. No Distribution-only fields are returned.';
comment on function public.get_mop_weekly_planner(date, smallint, text)
  is 'Read-only Mop production planner. No Distribution-only fields are returned.';
comment on function public.get_distribution_weekly_planner(date, smallint, text)
  is 'Read-only default Distribution schedule. Actual daily route assignment belongs to the future Distribution module.';

commit;
