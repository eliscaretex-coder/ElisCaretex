-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608030005_distribution_schedule_alignment.sql
-- Purpose:
--   Align Distribution with the confirmed operational rule.
--
-- Confirmed semantics:
--   - There is no manual Distribution Daily Plan in this phase.
--   - Delivery is always the next day after production, skipping Sunday.
--   - Saturday production is delivered Monday.
--   - Driver-to-route assignment belongs to a future Distribution Roster.
--   - Published Customer Schedule history remains protected.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Central delivery-day rule
-- ---------------------------------------------------------------------

create or replace function public.next_distribution_weekday(
  p_production_weekday smallint
)
returns smallint
language plpgsql
immutable
strict
set search_path = public, pg_temp
as $$
begin
  if p_production_weekday not between 1 and 7 then
    raise exception using
      errcode = '22023',
      message = 'Production weekday must be between 1 and 7.';
  end if;

  return case
    when p_production_weekday in (6, 7) then 1
    else (p_production_weekday + 1)::smallint
  end;
end;
$$;

comment on function public.next_distribution_weekday(smallint)
  is 'Returns the automatic Distribution delivery weekday: next day after production, skipping Sunday.';

revoke all on function public.next_distribution_weekday(smallint)
  from public, anon, authenticated;

grant execute on function public.next_distribution_weekday(smallint)
  to authenticated;

create or replace function public.set_automatic_schedule_delivery_weekday()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.delivery_weekday := public.next_distribution_weekday(new.production_weekday);
  return new;
end;
$$;

drop trigger if exists customer_schedule_days_automatic_delivery_weekday
  on public.customer_schedule_days;

create trigger customer_schedule_days_automatic_delivery_weekday
before insert or update of production_weekday, delivery_weekday
on public.customer_schedule_days
for each row
execute function public.set_automatic_schedule_delivery_weekday();

comment on function public.set_automatic_schedule_delivery_weekday()
  is 'Enforces the automatic next-day Distribution rule on new or edited schedule days.';

revoke all on function public.set_automatic_schedule_delivery_weekday()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Read models use the derived rule even for historical stored rows
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
      public.next_distribution_weekday(d.production_weekday) as delivery_weekday,
      public.weekday_name(public.next_distribution_weekday(d.production_weekday)) as delivery_day,
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
      'delivery_rule', 'NEXT_DAY_SKIP_SUNDAY',
      'manual_daily_plan_enabled', false,
      'future_driver_assignment', 'DISTRIBUTION_ROSTER_BY_ROUTE'
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
      public.next_distribution_weekday(d.production_weekday) as delivery_weekday,
      public.weekday_name(public.next_distribution_weekday(d.production_weekday)) as delivery_day,
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
        or public.next_distribution_weekday(d.production_weekday) = p_delivery_weekday
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
      'delivery_rule', 'NEXT_DAY_SKIP_SUNDAY',
      'manual_daily_plan_enabled', false,
      'future_driver_assignment', 'DISTRIBUTION_ROSTER_BY_ROUTE'
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
-- 3. Remove the manual Daily Plan API and preserve any accidental data
-- ---------------------------------------------------------------------

drop function if exists public.get_distribution_daily_plan(date);
drop function if exists public.create_distribution_daily_plan(date, text, text);
drop function if exists public.save_distribution_daily_plan(uuid, integer, jsonb, text, text, text);
drop function if exists public.set_distribution_daily_plan_status(uuid, integer, text, text, text);
drop function if exists public.distribution_daily_source_signature(date);
drop function if exists public.distribution_daily_source_stops(date);

do $$
begin
  if to_regclass('public.distribution_daily_stops') is not null
     and to_regclass('public.distribution_daily_stops_deprecated_20260803') is null then
    alter table public.distribution_daily_stops
      rename to distribution_daily_stops_deprecated_20260803;
  end if;

  if to_regclass('public.distribution_daily_plans') is not null
     and to_regclass('public.distribution_daily_plans_deprecated_20260803') is null then
    alter table public.distribution_daily_plans
      rename to distribution_daily_plans_deprecated_20260803;
  end if;
end;
$$;

do $$
begin
  if to_regclass('public.distribution_daily_stops_deprecated_20260803') is not null then
    execute 'revoke all on table public.distribution_daily_stops_deprecated_20260803 from public, anon, authenticated';
    execute 'comment on table public.distribution_daily_stops_deprecated_20260803 is ''Deprecated non-authoritative Daily Plan data retained only for traceability. Do not use operationally.''';
  end if;

  if to_regclass('public.distribution_daily_plans_deprecated_20260803') is not null then
    execute 'revoke all on table public.distribution_daily_plans_deprecated_20260803 from public, anon, authenticated';
    execute 'comment on table public.distribution_daily_plans_deprecated_20260803 is ''Deprecated non-authoritative Daily Plan data retained only for traceability. Do not use operationally.''';
  end if;
end;
$$;

-- Daily-only reserved routes are retained for traceability but disabled when
-- they were created by Migration 004. Future route needs will be introduced
-- deliberately with the Distribution Roster.
update public.distribution_routes
set
  active = false,
  updated_at = now(),
  notes = concat_ws(
    ' ',
    nullif(trim(notes), ''),
    'Deprecated with manual Distribution Daily Planning; retained for traceability.'
  )
where route_code in ('COLLECTION', 'AD_HOC', 'SUPPORT')
  and coalesce(metadata ->> 'daily_planning_only', 'false') = 'true';

-- ---------------------------------------------------------------------
-- 4. Capability discovery no longer exposes Daily Plan actions
-- ---------------------------------------------------------------------
create or replace function public.get_customer_read_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_can_manage_schedules boolean;
  v_can_view_distribution boolean;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR',
      'SORTING_OPERATOR', 'FINISH_OPERATOR', 'MOP_OPERATOR',
      'DISTRIBUTION_OPERATOR'
    ]
  );

  v_can_manage_schedules := public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER']
  );
  v_can_view_distribution := public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR', 'AUDITOR']
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
    'can_edit_schedules', v_can_manage_schedules,
    'can_create_schedule_draft', v_can_manage_schedules,
    'can_save_schedule_draft', v_can_manage_schedules,
    'can_compare_schedule_draft', v_can_manage_schedules,
    'can_publish_schedule_draft', v_can_manage_schedules,
    'can_cancel_schedule_draft', v_can_manage_schedules,
    'can_restore_schedule_version', v_can_manage_schedules,
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
    'can_view_distribution', v_can_view_distribution
  );
end;
$$;

comment on function public.get_distribution_weekly_planner(date, smallint, text)
  is 'Protected Distribution Schedule read model. Delivery day is derived from production day and Sunday is skipped.';

comment on function public.get_customer_distribution_overview(uuid, date)
  is 'Protected customer Distribution overview using the automatic next-day delivery rule.';

comment on function public.get_customer_read_capabilities()
  is 'Customer module capability discovery without manual Distribution Daily Planning actions.';

commit;
