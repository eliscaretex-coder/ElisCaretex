-- =====================================================================
-- ElisCaretex V2
-- Migration: 202607310002_customer_schedule_management_api.sql
-- Purpose:
--   Add the controlled API used by the future Customer Studio workflow:
--
--     PUBLISHED -> CREATE DRAFT -> EDIT DRAFT -> COMPARE -> PUBLISH
--
-- Security and history principles:
--   - Published and historical schedule children remain immutable.
--   - Only ADMIN, MANAGER and PLANNER may change schedule drafts.
--   - Draft writes are transactional and protected by row_version.
--   - The frontend supplies one complete weekly draft document.
--   - Every saved draft revision stores before/after snapshots in audit_log.
--   - Product, route, variant and trolley reference values are validated in
--     PostgreSQL; the browser is not trusted to enforce business rules.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Safety guard
-- ---------------------------------------------------------------------

do $$
begin
  if to_regprocedure(
       'public.create_customer_schedule_draft(uuid,date,uuid,text,text)'
     ) is null
     or to_regprocedure(
       'public.publish_customer_schedule(uuid,text,text)'
     ) is null
     or to_regprocedure(
       'public.get_customer_read_capabilities()'
     ) is null then
    raise exception using
      message = 'Safety stop: prerequisite Customer Schedule functions are missing.',
      hint = 'Apply migrations 202607300002, 202607300007 and 202607310001 before this migration.';
  end if;

  if (select count(*) from public.product_types
      where active and deleted_at is null
        and product_code in ('CLOTHES', 'MOP')) <> 2 then
    raise exception using
      message = 'Safety stop: CLOTHES and MOP product types are not both active.';
  end if;

  if (select count(*) from public.trolley_types
      where active
        and deleted_at is null
        and allowed_in_customer_schedule
        and trolley_type_code in ('SMALL', 'MEDIUM', 'LARGE', 'GRAY')) <> 4 then
    raise exception using
      message = 'Safety stop: standard Customer Schedule trolley types are incomplete.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Internal permission guard
-- ---------------------------------------------------------------------

create or replace function public.require_customer_schedule_edit_role()
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

  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to manage Customer Schedules.';
  end if;
end;
$$;

revoke all on function public.require_customer_schedule_edit_role()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Internal complete snapshot
--
-- The returned structure is deliberately suitable for round-tripping through
-- save_customer_schedule_draft(). Technical IDs are included for diagnostics,
-- but the save API resolves business references again from controlled codes.
-- ---------------------------------------------------------------------

create or replace function public.build_customer_schedule_version_snapshot(
  p_schedule_version_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'schedule_version_id', v.schedule_version_id,
    'customer_id', v.customer_id,
    'customer_code', c.customer_code,
    'customer_name', c.customer_name,
    'version_number', v.version_number,
    'status', v.status,
    'effective_from', v.effective_from,
    'effective_until', v.effective_until,
    'based_on_version_id', v.based_on_version_id,
    'source_code', v.source_code,
    'change_reason', v.change_reason,
    'general_instructions', v.general_instructions,
    'created_at', v.created_at,
    'updated_at', v.updated_at,
    'published_at', v.published_at,
    'superseded_at', v.superseded_at,
    'cancelled_at', v.cancelled_at,
    'row_version', v.row_version,
    'days', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'schedule_day_id', d.schedule_day_id,
            'production_weekday', d.production_weekday,
            'production_day', public.weekday_name(d.production_weekday),
            'delivery_weekday', d.delivery_weekday,
            'delivery_day', case
              when d.delivery_weekday is null then null
              else public.weekday_name(d.delivery_weekday)
            end,
            'default_route_id', d.default_route_id,
            'default_route', case
              when r.route_id is null then null
              else jsonb_build_object(
                'route_id', r.route_id,
                'route_code', r.route_code,
                'display_name', r.display_name,
                'route_color', r.route_color,
                'route_kind', r.route_kind
              )
            end,
            'delivery_window_start', d.delivery_window_start,
            'delivery_window_end', d.delivery_window_end,
            'delivery_order', d.delivery_order,
            'day_alert', d.day_alert,
            'distribution_instructions', d.distribution_instructions,
            'active', d.active,
            'row_version', d.row_version,
            'products', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'schedule_product_id', p.schedule_product_id,
                    'product_type_id', p.product_type_id,
                    'product_code', pt.product_code,
                    'display_name', pt.display_name,
                    'production_order', p.production_order,
                    'expected_kg', p.expected_kg,
                    'expected_units', p.expected_units,
                    'production_instructions', p.production_instructions,
                    'active', p.active,
                    'row_version', p.row_version,
                    'variant_codes', coalesce(
                      (
                        select jsonb_agg(
                          pv.variant_code
                          order by pv.sort_order, pv.variant_code
                        )
                        from public.customer_schedule_product_variants spv
                        join public.product_variants pv
                          on pv.product_variant_id = spv.product_variant_id
                        where spv.schedule_product_id = p.schedule_product_id
                      ),
                      '[]'::jsonb
                    ),
                    'variants', coalesce(
                      (
                        select jsonb_agg(
                          jsonb_build_object(
                            'product_variant_id', pv.product_variant_id,
                            'variant_code', pv.variant_code,
                            'display_name', pv.display_name
                          )
                          order by pv.sort_order, pv.variant_code
                        )
                        from public.customer_schedule_product_variants spv
                        join public.product_variants pv
                          on pv.product_variant_id = spv.product_variant_id
                        where spv.schedule_product_id = p.schedule_product_id
                      ),
                      '[]'::jsonb
                    )
                  )
                  order by pt.sort_order, p.production_order nulls last,
                           pt.product_code
                )
                from public.customer_schedule_products p
                join public.product_types pt
                  on pt.product_type_id = p.product_type_id
                where p.schedule_day_id = d.schedule_day_id
                  and p.active = true
              ),
              '[]'::jsonb
            ),
            'trolley_requirements', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'schedule_trolley_requirement_id',
                      req.schedule_trolley_requirement_id,
                    'trolley_type_id', req.trolley_type_id,
                    'trolley_type_code', tt.trolley_type_code,
                    'trolley_type_name', tt.trolley_type_name,
                    'display_code', coalesce(
                      tt.display_code,
                      tt.trolley_type_code
                    ),
                    'owner_product_code', owner_pt.product_code,
                    'quantity', req.quantity,
                    'empty_trolley', req.empty_trolley,
                    'notes', req.notes,
                    'active', req.active,
                    'row_version', req.row_version,
                    'serves_product_codes', coalesce(
                      (
                        select jsonb_agg(
                          served_pt.product_code
                          order by served_pt.sort_order,
                                   served_pt.product_code
                        )
                        from public.customer_schedule_trolley_requirement_products map
                        join public.customer_schedule_products served_product
                          on served_product.schedule_product_id =
                             map.schedule_product_id
                        join public.product_types served_pt
                          on served_pt.product_type_id =
                             served_product.product_type_id
                        where map.schedule_trolley_requirement_id =
                          req.schedule_trolley_requirement_id
                      ),
                      '[]'::jsonb
                    )
                  )
                  order by tt.sort_order,
                           owner_pt.sort_order,
                           req.created_at,
                           req.schedule_trolley_requirement_id
                )
                from public.customer_schedule_trolley_requirements req
                join public.trolley_types tt
                  on tt.trolley_type_id = req.trolley_type_id
                join public.customer_schedule_products owner_product
                  on owner_product.schedule_product_id =
                     req.owner_schedule_product_id
                join public.product_types owner_pt
                  on owner_pt.product_type_id = owner_product.product_type_id
                where req.schedule_day_id = d.schedule_day_id
                  and req.active = true
              ),
              '[]'::jsonb
            )
          )
          order by d.production_weekday
        )
        from public.customer_schedule_days d
        left join public.distribution_routes r
          on r.route_id = d.default_route_id
        where d.schedule_version_id = v.schedule_version_id
          and d.active = true
      ),
      '[]'::jsonb
    )
  )
  into v_result
  from public.customer_schedule_versions v
  join public.customers c
    on c.customer_id = v.customer_id
  where v.schedule_version_id = p_schedule_version_id
    and c.deleted_at is null;

  return v_result;
end;
$$;

revoke all on function public.build_customer_schedule_version_snapshot(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Internal normalized snapshot for comparisons
-- ---------------------------------------------------------------------

create or replace function public.build_customer_schedule_comparable_snapshot(
  p_schedule_version_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_full jsonb;
  v_result jsonb;
begin
  v_full := public.build_customer_schedule_version_snapshot(
    p_schedule_version_id
  );

  if v_full is null then
    return null;
  end if;

  select jsonb_build_object(
    'effective_from', v_full -> 'effective_from',
    'effective_until', v_full -> 'effective_until',
    'general_instructions', v_full -> 'general_instructions',
    'days', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'production_weekday', day_row -> 'production_weekday',
            'delivery_weekday', day_row -> 'delivery_weekday',
            'default_route_id', day_row -> 'default_route_id',
            'delivery_window_start', day_row -> 'delivery_window_start',
            'delivery_window_end', day_row -> 'delivery_window_end',
            'delivery_order', day_row -> 'delivery_order',
            'day_alert', day_row -> 'day_alert',
            'distribution_instructions',
              day_row -> 'distribution_instructions',
            'products', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'product_code', product_row -> 'product_code',
                    'production_order', product_row -> 'production_order',
                    'expected_kg', product_row -> 'expected_kg',
                    'expected_units', product_row -> 'expected_units',
                    'production_instructions',
                      product_row -> 'production_instructions',
                    'variant_codes', product_row -> 'variant_codes'
                  )
                  order by product_row ->> 'product_code'
                )
                from jsonb_array_elements(
                  coalesce(day_row -> 'products', '[]'::jsonb)
                ) as product_items(product_row)
              ),
              '[]'::jsonb
            ),
            'trolley_requirements', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'trolley_type_code',
                      requirement_row -> 'trolley_type_code',
                    'owner_product_code',
                      requirement_row -> 'owner_product_code',
                    'quantity', requirement_row -> 'quantity',
                    'empty_trolley',
                      requirement_row -> 'empty_trolley',
                    'notes', requirement_row -> 'notes',
                    'serves_product_codes',
                      requirement_row -> 'serves_product_codes'
                  )
                  order by requirement_row ->> 'trolley_type_code',
                           requirement_row ->> 'owner_product_code',
                           requirement_row ->> 'quantity',
                           requirement_row ->> 'notes'
                )
                from jsonb_array_elements(
                  coalesce(
                    day_row -> 'trolley_requirements',
                    '[]'::jsonb
                  )
                ) as requirement_items(requirement_row)
              ),
              '[]'::jsonb
            )
          )
          order by (day_row ->> 'production_weekday')::integer
        )
        from jsonb_array_elements(
          coalesce(v_full -> 'days', '[]'::jsonb)
        ) as day_items(day_row)
      ),
      '[]'::jsonb
    )
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.build_customer_schedule_comparable_snapshot(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Reference data for the Customer Studio editor
-- ---------------------------------------------------------------------

create or replace function public.get_customer_schedule_reference_data(
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
  perform public.require_customer_schedule_edit_role();

  if not exists (
    select 1
    from public.customers c
    where c.customer_id = p_customer_id
      and c.deleted_at is null
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Customer not found.';
  end if;

  select jsonb_build_object(
    'business_date', public.current_business_date(),
    'effective_date', p_effective_date,
    'weekdays', jsonb_build_array(
      jsonb_build_object('weekday', 1, 'name', 'Monday'),
      jsonb_build_object('weekday', 2, 'name', 'Tuesday'),
      jsonb_build_object('weekday', 3, 'name', 'Wednesday'),
      jsonb_build_object('weekday', 4, 'name', 'Thursday'),
      jsonb_build_object('weekday', 5, 'name', 'Friday'),
      jsonb_build_object('weekday', 6, 'name', 'Saturday'),
      jsonb_build_object('weekday', 7, 'name', 'Sunday')
    ),
    'product_types', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'product_type_id', pt.product_type_id,
            'product_code', pt.product_code,
            'display_name', pt.display_name,
            'uses_kg', pt.uses_kg,
            'uses_units', pt.uses_units,
            'variants', coalesce(
              (
                select jsonb_agg(
                  jsonb_build_object(
                    'product_variant_id', pv.product_variant_id,
                    'variant_code', pv.variant_code,
                    'display_name', pv.display_name
                  )
                  order by pv.sort_order, pv.variant_code
                )
                from public.product_variants pv
                where pv.product_type_id = pt.product_type_id
                  and pv.active = true
                  and pv.deleted_at is null
              ),
              '[]'::jsonb
            )
          )
          order by pt.sort_order, pt.product_code
        )
        from public.customer_product_services service
        join public.product_types pt
          on pt.product_type_id = service.product_type_id
        where service.customer_id = p_customer_id
          and service.active = true
          and service.deleted_at is null
          and service.effective_from <= p_effective_date
          and (
            service.effective_until is null
            or service.effective_until >= p_effective_date
          )
          and pt.active = true
          and pt.deleted_at is null
          and coalesce(
            (pt.metadata ->> 'schedule_enabled')::boolean,
            true
          )
      ),
      '[]'::jsonb
    ),
    'routes', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'route_id', r.route_id,
            'route_code', r.route_code,
            'display_name', r.display_name,
            'route_color', r.route_color,
            'route_kind', r.route_kind
          )
          order by r.sort_order, r.route_code
        )
        from public.distribution_routes r
        where r.active = true
          and r.deleted_at is null
          and r.allow_as_default = true
      ),
      '[]'::jsonb
    ),
    'trolley_types', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'trolley_type_id', tt.trolley_type_id,
            'trolley_type_code', tt.trolley_type_code,
            'trolley_type_name', tt.trolley_type_name,
            'display_code', coalesce(
              tt.display_code,
              tt.trolley_type_code
            ),
            'trolley_category', tt.trolley_category
          )
          order by tt.sort_order, tt.trolley_type_code
        )
        from public.trolley_types tt
        where tt.active = true
          and tt.deleted_at is null
          and tt.allowed_in_customer_schedule = true
      ),
      '[]'::jsonb
    )
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Current Customer Schedule management state
-- ---------------------------------------------------------------------

create or replace function public.get_customer_schedule_management_state(
  p_customer_id uuid,
  p_selected_version_id uuid default null,
  p_effective_date date default public.current_business_date()
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_customer record;
  v_published_version_id uuid;
  v_draft_version_id uuid;
  v_selected_version_id uuid;
  v_result jsonb;
begin
  perform public.require_customer_schedule_edit_role();

  select
    c.customer_id,
    c.customer_code,
    c.customer_name,
    c.eircode,
    c.active,
    c.operational_alert,
    c.row_version
  into v_customer
  from public.customers c
  where c.customer_id = p_customer_id
    and c.deleted_at is null;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Customer not found.';
  end if;

  select v.schedule_version_id
  into v_published_version_id
  from public.customer_schedule_versions v
  where v.customer_id = p_customer_id
    and v.status = 'PUBLISHED'
    and p_effective_date >= v.effective_from
    and (
      v.effective_until is null
      or p_effective_date <= v.effective_until
    )
  order by v.effective_from desc, v.version_number desc
  limit 1;

  select v.schedule_version_id
  into v_draft_version_id
  from public.customer_schedule_versions v
  where v.customer_id = p_customer_id
    and v.status = 'DRAFT'
  order by v.created_at desc
  limit 1;

  if p_selected_version_id is not null then
    select v.schedule_version_id
    into v_selected_version_id
    from public.customer_schedule_versions v
    where v.schedule_version_id = p_selected_version_id
      and v.customer_id = p_customer_id;

    if v_selected_version_id is null then
      raise exception using
        errcode = '22023',
        message = 'The selected schedule version does not belong to this customer.';
    end if;
  else
    v_selected_version_id := coalesce(
      v_draft_version_id,
      v_published_version_id
    );
  end if;

  v_result := jsonb_build_object(
    'business_date', public.current_business_date(),
    'effective_date', p_effective_date,
    'customer', jsonb_build_object(
      'customer_id', v_customer.customer_id,
      'customer_code', v_customer.customer_code,
      'customer_name', v_customer.customer_name,
      'eircode', v_customer.eircode,
      'active', v_customer.active,
      'operational_alert', v_customer.operational_alert,
      'row_version', v_customer.row_version
    ),
    'permissions', jsonb_build_object(
      'can_create_draft', v_customer.active,
      'can_save_draft', true,
      'can_compare_draft', true,
      'can_publish_draft', true,
      'can_cancel_draft', true,
      'can_restore_version', v_customer.active
    ),
    'published_schedule', case
      when v_published_version_id is null then null
      else public.build_customer_schedule_version_snapshot(
        v_published_version_id
      )
    end,
    'draft_schedule', case
      when v_draft_version_id is null then null
      else public.build_customer_schedule_version_snapshot(
        v_draft_version_id
      )
    end,
    'selected_schedule', case
      when v_selected_version_id is null then null
      else public.build_customer_schedule_version_snapshot(
        v_selected_version_id
      )
    end,
    'reference_data', public.get_customer_schedule_reference_data(
      p_customer_id,
      coalesce(
        (
          select effective_from
          from public.customer_schedule_versions
          where schedule_version_id = v_draft_version_id
        ),
        p_effective_date
      )
    )
  );

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Frontend-friendly draft creation
-- ---------------------------------------------------------------------

create or replace function public.create_customer_schedule_management_draft(
  p_customer_id uuid,
  p_effective_from date,
  p_based_on_version_id uuid default null,
  p_change_reason text default null,
  p_source_application text default 'CUSTOMER_STUDIO'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_schedule_version_id uuid;
begin
  perform public.require_customer_schedule_edit_role();

  if nullif(trim(p_change_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'A reason is required to create a schedule draft.';
  end if;

  if p_effective_from < public.current_business_date() then
    raise exception using
      errcode = '22023',
      message = 'A new schedule draft cannot start before the current business date.';
  end if;

  v_schedule_version_id := public.create_customer_schedule_draft(
    p_customer_id,
    p_effective_from,
    p_based_on_version_id,
    trim(p_change_reason),
    p_source_application
  );

  return jsonb_build_object(
    'schedule_version_id', v_schedule_version_id,
    'draft', public.build_customer_schedule_version_snapshot(
      v_schedule_version_id
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Transactional full-document draft save
-- ---------------------------------------------------------------------

create or replace function public.save_customer_schedule_draft(
  p_schedule_version_id uuid,
  p_expected_row_version integer,
  p_draft jsonb,
  p_change_reason text,
  p_source_application text default 'CUSTOMER_STUDIO'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_version public.customer_schedule_versions%rowtype;
  v_effective_from date;
  v_effective_until date;
  v_old_snapshot jsonb;
  v_new_snapshot jsonb;
  v_day jsonb;
  v_product jsonb;
  v_requirement jsonb;
  v_variant_code text;
  v_served_code text;
  v_weekday smallint;
  v_delivery_weekday smallint;
  v_route_id uuid;
  v_delivery_window_start time;
  v_delivery_window_end time;
  v_delivery_order integer;
  v_day_id uuid;
  v_product_id uuid;
  v_product_type_id uuid;
  v_variant_id uuid;
  v_requirement_id uuid;
  v_trolley_type_id uuid;
  v_owner_product_id uuid;
  v_served_product_id uuid;
  v_product_code text;
  v_owner_product_code text;
  v_trolley_type_code text;
  v_quantity integer;
  v_empty_trolley boolean;
  v_seen_weekdays smallint[] := array[]::smallint[];
  v_seen_product_codes text[];
  v_seen_variant_codes text[];
  v_seen_served_codes text[];
  v_product_map jsonb;
  v_product_count integer;
  v_day_count integer;
begin
  perform public.require_customer_schedule_edit_role();

  if nullif(trim(p_change_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'A reason is required to save schedule changes.';
  end if;

  if p_expected_row_version is null then
    raise exception using
      errcode = '22023',
      message = 'The expected draft row version is required.';
  end if;

  if p_draft is null or jsonb_typeof(p_draft) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'The draft payload must be a JSON object.';
  end if;

  if jsonb_typeof(coalesce(p_draft -> 'days', 'null'::jsonb))
     is distinct from 'array' then
    raise exception using
      errcode = '22023',
      message = 'The draft payload must contain a days array.';
  end if;

  select *
  into v_version
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Schedule draft not found.';
  end if;

  if v_version.status <> 'DRAFT' then
    raise exception using
      errcode = '55000',
      message = 'Only a DRAFT schedule revision can be saved.';
  end if;

  if v_version.row_version <> p_expected_row_version then
    raise exception using
      errcode = '40001',
      message = 'The schedule draft was changed by another user.',
      detail = format(
        'Expected row_version %s but current row_version is %s.',
        p_expected_row_version,
        v_version.row_version
      ),
      hint = 'Reload the draft before applying your changes again.';
  end if;

  if not exists (
    select 1
    from public.customers c
    where c.customer_id = v_version.customer_id
      and c.active = true
      and c.deleted_at is null
  ) then
    raise exception using
      errcode = '55000',
      message = 'The customer is inactive or does not exist.';
  end if;

  begin
    v_effective_from := nullif(
      trim(p_draft ->> 'effective_from'),
      ''
    )::date;
  exception when others then
    raise exception using
      errcode = '22023',
      message = 'The draft effective_from value is invalid.';
  end;

  if v_effective_from is null then
    raise exception using
      errcode = '22023',
      message = 'The draft effective date is required.';
  end if;

  if v_effective_from < public.current_business_date() then
    raise exception using
      errcode = '22023',
      message = 'The draft effective date cannot be before the current business date.';
  end if;

  begin
    v_effective_until := nullif(
      trim(p_draft ->> 'effective_until'),
      ''
    )::date;
  exception when others then
    raise exception using
      errcode = '22023',
      message = 'The draft effective_until value is invalid.';
  end;

  if v_effective_until is not null
     and v_effective_until < v_effective_from then
    raise exception using
      errcode = '22023',
      message = 'The schedule end date cannot be before its effective date.';
  end if;

  v_day_count := jsonb_array_length(p_draft -> 'days');

  if v_day_count = 0 then
    raise exception using
      errcode = '22023',
      message = 'The schedule must contain at least one production day.';
  end if;

  if v_day_count > 7 then
    raise exception using
      errcode = '22023',
      message = 'The weekly schedule cannot contain more than seven days.';
  end if;

  -- Validate the entire submitted document before deleting the current draft
  -- children. Any error aborts the transaction and leaves the draft unchanged.
  for v_day in
    select value
    from jsonb_array_elements(p_draft -> 'days')
  loop
    if jsonb_typeof(v_day) <> 'object' then
      raise exception using
        errcode = '22023',
        message = 'Every days item must be a JSON object.';
    end if;

    begin
      v_weekday := nullif(
        trim(v_day ->> 'production_weekday'),
        ''
      )::smallint;
    exception when others then
      raise exception using
        errcode = '22023',
        message = 'A production_weekday value is invalid.';
    end;

    if v_weekday is null or v_weekday not between 1 and 7 then
      raise exception using
        errcode = '22023',
        message = 'production_weekday must be between 1 and 7.';
    end if;

    if v_weekday = any(v_seen_weekdays) then
      raise exception using
        errcode = '22023',
        message = format(
          'Production weekday %s appears more than once.',
          v_weekday
        );
    end if;

    v_seen_weekdays := array_append(v_seen_weekdays, v_weekday);

    if jsonb_typeof(coalesce(v_day -> 'products', 'null'::jsonb))
       is distinct from 'array' then
      raise exception using
        errcode = '22023',
        message = format(
          'The products value for %s must be an array.',
          public.weekday_name(v_weekday)
        );
    end if;

    v_product_count := jsonb_array_length(v_day -> 'products');

    if v_product_count = 0 then
      raise exception using
        errcode = '22023',
        message = format(
          '%s must contain at least one product.',
          public.weekday_name(v_weekday)
        );
    end if;

    v_seen_product_codes := array[]::text[];

    for v_product in
      select value
      from jsonb_array_elements(v_day -> 'products')
    loop
      v_product_code := upper(trim(coalesce(
        v_product ->> 'product_code',
        ''
      )));

      if v_product_code = '' then
        raise exception using
          errcode = '22023',
          message = format(
            'A product code is missing for %s.',
            public.weekday_name(v_weekday)
          );
      end if;

      if v_product_code = any(v_seen_product_codes) then
        raise exception using
          errcode = '22023',
          message = format(
            'Product %s appears more than once on %s.',
            v_product_code,
            public.weekday_name(v_weekday)
          );
      end if;

      v_seen_product_codes := array_append(
        v_seen_product_codes,
        v_product_code
      );

      if not exists (
        select 1
        from public.customer_product_services service
        join public.product_types pt
          on pt.product_type_id = service.product_type_id
        where service.customer_id = v_version.customer_id
          and service.active = true
          and service.deleted_at is null
          and service.effective_from <= v_effective_from
          and (
            service.effective_until is null
            or service.effective_until >= v_effective_from
          )
          and pt.product_code = v_product_code
          and pt.active = true
          and pt.deleted_at is null
          and coalesce(
            (pt.metadata ->> 'schedule_enabled')::boolean,
            true
          )
      ) then
        raise exception using
          errcode = '22023',
          message = format(
            'Product %s is not enabled for this customer on %s.',
            v_product_code,
            v_effective_from
          );
      end if;

      if jsonb_typeof(
           coalesce(v_product -> 'variant_codes', '[]'::jsonb)
         ) <> 'array' then
        raise exception using
          errcode = '22023',
          message = format(
            'variant_codes for %s must be an array.',
            v_product_code
          );
      end if;

      v_seen_variant_codes := array[]::text[];

      for v_variant_code in
        select upper(trim(value))
        from jsonb_array_elements_text(
          coalesce(v_product -> 'variant_codes', '[]'::jsonb)
        )
      loop
        if v_variant_code = '' then
          raise exception using
            errcode = '22023',
            message = format(
              'An empty product variant was submitted for %s.',
              v_product_code
            );
        end if;

        if v_variant_code = any(v_seen_variant_codes) then
          raise exception using
            errcode = '22023',
            message = format(
              'Variant %s appears more than once for %s.',
              v_variant_code,
              v_product_code
            );
        end if;

        v_seen_variant_codes := array_append(
          v_seen_variant_codes,
          v_variant_code
        );

        if not exists (
          select 1
          from public.product_variants pv
          join public.product_types pt
            on pt.product_type_id = pv.product_type_id
          where pt.product_code = v_product_code
            and pv.variant_code = v_variant_code
            and pv.active = true
            and pv.deleted_at is null
        ) then
          raise exception using
            errcode = '22023',
            message = format(
              'Variant %s is not active for product %s.',
              v_variant_code,
              v_product_code
            );
        end if;
      end loop;
    end loop;

    if jsonb_typeof(
         coalesce(v_day -> 'trolley_requirements', '[]'::jsonb)
       ) <> 'array' then
      raise exception using
        errcode = '22023',
        message = format(
          'The trolley requirements value for %s must be an array.',
          public.weekday_name(v_weekday)
        );
    end if;

    for v_requirement in
      select value
      from jsonb_array_elements(
        coalesce(v_day -> 'trolley_requirements', '[]'::jsonb)
      )
    loop
      v_trolley_type_code := upper(trim(coalesce(
        v_requirement ->> 'trolley_type_code',
        ''
      )));
      v_owner_product_code := upper(trim(coalesce(
        v_requirement ->> 'owner_product_code',
        ''
      )));

      if not exists (
        select 1
        from public.trolley_types tt
        where tt.trolley_type_code = v_trolley_type_code
          and tt.active = true
          and tt.deleted_at is null
          and tt.allowed_in_customer_schedule = true
      ) then
        raise exception using
          errcode = '22023',
          message = format(
            'Trolley type %s is not allowed in Customer Schedules.',
            coalesce(nullif(v_trolley_type_code, ''), '[missing]')
          );
      end if;

      if not (v_owner_product_code = any(v_seen_product_codes)) then
        raise exception using
          errcode = '22023',
          message = format(
            'Trolley owner product %s is not scheduled on %s.',
            coalesce(nullif(v_owner_product_code, ''), '[missing]'),
            public.weekday_name(v_weekday)
          );
      end if;

      begin
        v_quantity := nullif(
          trim(v_requirement ->> 'quantity'),
          ''
        )::integer;
      exception when others then
        raise exception using
          errcode = '22023',
          message = 'A trolley quantity value is invalid.';
      end;

      if v_quantity is null or v_quantity <= 0 then
        raise exception using
          errcode = '22023',
          message = 'Every trolley requirement quantity must be greater than zero.';
      end if;

      if jsonb_typeof(
           coalesce(
             v_requirement -> 'serves_product_codes',
             'null'::jsonb
           )
         ) is distinct from 'array' then
        raise exception using
          errcode = '22023',
          message = 'serves_product_codes must be an array.';
      end if;

      if jsonb_array_length(
           v_requirement -> 'serves_product_codes'
         ) = 0 then
        raise exception using
          errcode = '22023',
          message = 'Every trolley requirement must serve at least one product.';
      end if;

      v_seen_served_codes := array[]::text[];

      for v_served_code in
        select upper(trim(value))
        from jsonb_array_elements_text(
          v_requirement -> 'serves_product_codes'
        )
      loop
        if not (v_served_code = any(v_seen_product_codes)) then
          raise exception using
            errcode = '22023',
            message = format(
              'Trolley served product %s is not scheduled on %s.',
              v_served_code,
              public.weekday_name(v_weekday)
            );
        end if;

        if v_served_code = any(v_seen_served_codes) then
          raise exception using
            errcode = '22023',
            message = format(
              'Trolley served product %s appears more than once.',
              v_served_code
            );
        end if;

        v_seen_served_codes := array_append(
          v_seen_served_codes,
          v_served_code
        );
      end loop;

      if not (v_owner_product_code = any(v_seen_served_codes)) then
        raise exception using
          errcode = '22023',
          message = 'The trolley owner product must also be included in serves_product_codes.';
      end if;
    end loop;

    begin
      v_delivery_weekday := nullif(
        trim(v_day ->> 'delivery_weekday'),
        ''
      )::smallint;
    exception when others then
      raise exception using
        errcode = '22023',
        message = format(
          'The delivery weekday for %s is invalid.',
          public.weekday_name(v_weekday)
        );
    end;

    if v_delivery_weekday is not null
       and v_delivery_weekday not between 1 and 7 then
      raise exception using
        errcode = '22023',
        message = 'delivery_weekday must be between 1 and 7.';
    end if;

    begin
      v_route_id := nullif(
        trim(v_day ->> 'default_route_id'),
        ''
      )::uuid;
    exception when others then
      raise exception using
        errcode = '22023',
        message = format(
          'The default route for %s is invalid.',
          public.weekday_name(v_weekday)
        );
    end;

    if v_route_id is not null
       and not exists (
         select 1
         from public.distribution_routes r
         where r.route_id = v_route_id
           and r.active = true
           and r.deleted_at is null
           and r.allow_as_default = true
       ) then
      raise exception using
        errcode = '22023',
        message = format(
          'The selected default route for %s is inactive or unavailable.',
          public.weekday_name(v_weekday)
        );
    end if;

    begin
      v_delivery_window_start := nullif(
        trim(v_day ->> 'delivery_window_start'),
        ''
      )::time;
      v_delivery_window_end := nullif(
        trim(v_day ->> 'delivery_window_end'),
        ''
      )::time;
      v_delivery_order := nullif(
        trim(v_day ->> 'delivery_order'),
        ''
      )::integer;
    exception when others then
      raise exception using
        errcode = '22023',
        message = format(
          'A delivery planning value for %s is invalid.',
          public.weekday_name(v_weekday)
        );
    end;

    if v_delivery_window_start is not null
       and v_delivery_window_end is not null
       and v_delivery_window_end <= v_delivery_window_start then
      raise exception using
        errcode = '22023',
        message = format(
          'The delivery window for %s must end after it starts.',
          public.weekday_name(v_weekday)
        );
    end if;

    if v_delivery_order is not null and v_delivery_order <= 0 then
      raise exception using
        errcode = '22023',
        message = 'delivery_order must be greater than zero.';
    end if;
  end loop;

  v_old_snapshot := public.build_customer_schedule_version_snapshot(
    p_schedule_version_id
  );

  -- Delete only the mutable DRAFT child records, in dependency order.
  delete from public.customer_schedule_trolley_requirement_products map
  where map.schedule_trolley_requirement_id in (
    select req.schedule_trolley_requirement_id
    from public.customer_schedule_trolley_requirements req
    join public.customer_schedule_days d
      on d.schedule_day_id = req.schedule_day_id
    where d.schedule_version_id = p_schedule_version_id
  );

  delete from public.customer_schedule_trolley_requirements req
  where req.schedule_day_id in (
    select d.schedule_day_id
    from public.customer_schedule_days d
    where d.schedule_version_id = p_schedule_version_id
  );

  delete from public.customer_schedule_product_variants spv
  where spv.schedule_product_id in (
    select p.schedule_product_id
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    where d.schedule_version_id = p_schedule_version_id
  );

  delete from public.customer_schedule_products p
  where p.schedule_day_id in (
    select d.schedule_day_id
    from public.customer_schedule_days d
    where d.schedule_version_id = p_schedule_version_id
  );

  delete from public.customer_schedule_days d
  where d.schedule_version_id = p_schedule_version_id;

  -- Insert the validated replacement document.
  for v_day in
    select value
    from jsonb_array_elements(p_draft -> 'days')
    order by (value ->> 'production_weekday')::integer
  loop
    v_weekday := (v_day ->> 'production_weekday')::smallint;
    v_delivery_weekday := nullif(
      trim(v_day ->> 'delivery_weekday'),
      ''
    )::smallint;
    v_route_id := nullif(
      trim(v_day ->> 'default_route_id'),
      ''
    )::uuid;
    v_delivery_window_start := nullif(
      trim(v_day ->> 'delivery_window_start'),
      ''
    )::time;
    v_delivery_window_end := nullif(
      trim(v_day ->> 'delivery_window_end'),
      ''
    )::time;
    v_delivery_order := nullif(
      trim(v_day ->> 'delivery_order'),
      ''
    )::integer;

    insert into public.customer_schedule_days (
      schedule_version_id,
      production_weekday,
      delivery_weekday,
      default_route_id,
      delivery_window_start,
      delivery_window_end,
      delivery_order,
      day_alert,
      distribution_instructions,
      active,
      metadata,
      created_by,
      updated_by
    )
    values (
      p_schedule_version_id,
      v_weekday,
      v_delivery_weekday,
      v_route_id,
      v_delivery_window_start,
      v_delivery_window_end,
      v_delivery_order,
      nullif(trim(v_day ->> 'day_alert'), ''),
      nullif(trim(v_day ->> 'distribution_instructions'), ''),
      true,
      '{}'::jsonb,
      auth.uid(),
      auth.uid()
    )
    returning schedule_day_id into v_day_id;

    v_product_map := '{}'::jsonb;

    for v_product in
      select value
      from jsonb_array_elements(v_day -> 'products')
    loop
      v_product_code := upper(trim(v_product ->> 'product_code'));

      select pt.product_type_id
      into v_product_type_id
      from public.product_types pt
      where pt.product_code = v_product_code
        and pt.active = true
        and pt.deleted_at is null;

      insert into public.customer_schedule_products (
        schedule_day_id,
        product_type_id,
        production_order,
        expected_kg,
        expected_units,
        production_instructions,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        v_day_id,
        v_product_type_id,
        nullif(trim(v_product ->> 'production_order'), '')::integer,
        nullif(trim(v_product ->> 'expected_kg'), '')::numeric,
        nullif(trim(v_product ->> 'expected_units'), '')::integer,
        nullif(trim(v_product ->> 'production_instructions'), ''),
        true,
        '{}'::jsonb,
        auth.uid(),
        auth.uid()
      )
      returning schedule_product_id into v_product_id;

      v_product_map := jsonb_set(
        v_product_map,
        array[v_product_code],
        to_jsonb(v_product_id::text),
        true
      );

      for v_variant_code in
        select upper(trim(value))
        from jsonb_array_elements_text(
          coalesce(v_product -> 'variant_codes', '[]'::jsonb)
        )
      loop
        select pv.product_variant_id
        into v_variant_id
        from public.product_variants pv
        where pv.product_type_id = v_product_type_id
          and pv.variant_code = v_variant_code
          and pv.active = true
          and pv.deleted_at is null;

        insert into public.customer_schedule_product_variants (
          schedule_product_id,
          product_variant_id,
          created_by
        )
        values (
          v_product_id,
          v_variant_id,
          auth.uid()
        );
      end loop;
    end loop;

    for v_requirement in
      select value
      from jsonb_array_elements(
        coalesce(v_day -> 'trolley_requirements', '[]'::jsonb)
      )
    loop
      v_trolley_type_code := upper(trim(
        v_requirement ->> 'trolley_type_code'
      ));
      v_owner_product_code := upper(trim(
        v_requirement ->> 'owner_product_code'
      ));
      v_quantity := (v_requirement ->> 'quantity')::integer;
      v_empty_trolley := coalesce(
        (v_requirement ->> 'empty_trolley')::boolean,
        false
      );

      select tt.trolley_type_id
      into v_trolley_type_id
      from public.trolley_types tt
      where tt.trolley_type_code = v_trolley_type_code
        and tt.active = true
        and tt.deleted_at is null
        and tt.allowed_in_customer_schedule = true;

      v_owner_product_id := (
        v_product_map ->> v_owner_product_code
      )::uuid;

      insert into public.customer_schedule_trolley_requirements (
        schedule_day_id,
        trolley_type_id,
        owner_schedule_product_id,
        quantity,
        empty_trolley,
        notes,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        v_day_id,
        v_trolley_type_id,
        v_owner_product_id,
        v_quantity,
        v_empty_trolley,
        nullif(trim(v_requirement ->> 'notes'), ''),
        true,
        '{}'::jsonb,
        auth.uid(),
        auth.uid()
      )
      returning schedule_trolley_requirement_id
      into v_requirement_id;

      for v_served_code in
        select upper(trim(value))
        from jsonb_array_elements_text(
          v_requirement -> 'serves_product_codes'
        )
      loop
        v_served_product_id := (
          v_product_map ->> v_served_code
        )::uuid;

        insert into public.customer_schedule_trolley_requirement_products (
          schedule_trolley_requirement_id,
          schedule_product_id,
          created_by
        )
        values (
          v_requirement_id,
          v_served_product_id,
          auth.uid()
        );
      end loop;
    end loop;
  end loop;

  update public.customer_schedule_versions
  set
    effective_from = v_effective_from,
    effective_until = v_effective_until,
    general_instructions = nullif(
      trim(p_draft ->> 'general_instructions'),
      ''
    ),
    change_reason = trim(p_change_reason),
    updated_by = auth.uid()
  where schedule_version_id = p_schedule_version_id;

  v_new_snapshot := public.build_customer_schedule_version_snapshot(
    p_schedule_version_id
  );

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'SAVE_CUSTOMER_SCHEDULE_DRAFT',
    'customer_schedule_versions',
    p_schedule_version_id::text,
    v_old_snapshot,
    v_new_snapshot,
    trim(p_change_reason),
    p_source_application
  );

  return v_new_snapshot;
end;
$$;

-- ---------------------------------------------------------------------
-- Draft comparison
-- ---------------------------------------------------------------------

create or replace function public.compare_customer_schedule_draft(
  p_schedule_version_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_draft_record record;
  v_before jsonb;
  v_after jsonb;
  v_before_day jsonb;
  v_after_day jsonb;
  v_changed_weekdays jsonb := '[]'::jsonb;
  v_weekday integer;
  v_before_day_count integer;
  v_after_day_count integer;
  v_before_product_count integer;
  v_after_product_count integer;
  v_before_trolley_count integer;
  v_after_trolley_count integer;
  v_before_trolley_quantity integer;
  v_after_trolley_quantity integer;
begin
  perform public.require_customer_schedule_edit_role();

  select
    v.schedule_version_id,
    v.customer_id,
    v.version_number,
    v.based_on_version_id,
    v.status
  into v_draft_record
  from public.customer_schedule_versions v
  where v.schedule_version_id = p_schedule_version_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Schedule draft not found.';
  end if;

  if v_draft_record.status <> 'DRAFT' then
    raise exception using
      errcode = '55000',
      message = 'Only a DRAFT schedule revision can be compared.';
  end if;

  v_after := public.build_customer_schedule_comparable_snapshot(
    p_schedule_version_id
  );

  if v_draft_record.based_on_version_id is null then
    v_before := jsonb_build_object(
      'effective_from', null,
      'effective_until', null,
      'general_instructions', null,
      'days', '[]'::jsonb
    );
  else
    v_before := public.build_customer_schedule_comparable_snapshot(
      v_draft_record.based_on_version_id
    );
  end if;

  for v_weekday in 1..7 loop
    select value
    into v_before_day
    from jsonb_array_elements(
      coalesce(v_before -> 'days', '[]'::jsonb)
    )
    where (value ->> 'production_weekday')::integer = v_weekday
    limit 1;

    select value
    into v_after_day
    from jsonb_array_elements(
      coalesce(v_after -> 'days', '[]'::jsonb)
    )
    where (value ->> 'production_weekday')::integer = v_weekday
    limit 1;

    if v_before_day is distinct from v_after_day then
      v_changed_weekdays := v_changed_weekdays || jsonb_build_array(
        jsonb_build_object(
          'weekday', v_weekday,
          'day_name', public.weekday_name(v_weekday::smallint),
          'change_type', case
            when v_before_day is null then 'ADDED'
            when v_after_day is null then 'REMOVED'
            else 'CHANGED'
          end
        )
      );
    end if;

    v_before_day := null;
    v_after_day := null;
  end loop;

  v_before_day_count := jsonb_array_length(
    coalesce(v_before -> 'days', '[]'::jsonb)
  );
  v_after_day_count := jsonb_array_length(
    coalesce(v_after -> 'days', '[]'::jsonb)
  );

  select coalesce(sum(jsonb_array_length(
           coalesce(value -> 'products', '[]'::jsonb)
         )), 0)::integer,
         coalesce(sum(jsonb_array_length(
           coalesce(value -> 'trolley_requirements', '[]'::jsonb)
         )), 0)::integer
  into v_before_product_count, v_before_trolley_count
  from jsonb_array_elements(
    coalesce(v_before -> 'days', '[]'::jsonb)
  );

  select coalesce(sum(jsonb_array_length(
           coalesce(value -> 'products', '[]'::jsonb)
         )), 0)::integer,
         coalesce(sum(jsonb_array_length(
           coalesce(value -> 'trolley_requirements', '[]'::jsonb)
         )), 0)::integer
  into v_after_product_count, v_after_trolley_count
  from jsonb_array_elements(
    coalesce(v_after -> 'days', '[]'::jsonb)
  );

  select coalesce(sum((requirement ->> 'quantity')::integer), 0)::integer
  into v_before_trolley_quantity
  from jsonb_array_elements(
    coalesce(v_before -> 'days', '[]'::jsonb)
  ) as before_days(day_row)
  cross join lateral jsonb_array_elements(
    coalesce(day_row -> 'trolley_requirements', '[]'::jsonb)
  ) as before_requirements(requirement);

  select coalesce(sum((requirement ->> 'quantity')::integer), 0)::integer
  into v_after_trolley_quantity
  from jsonb_array_elements(
    coalesce(v_after -> 'days', '[]'::jsonb)
  ) as after_days(day_row)
  cross join lateral jsonb_array_elements(
    coalesce(day_row -> 'trolley_requirements', '[]'::jsonb)
  ) as after_requirements(requirement);

  return jsonb_build_object(
    'schedule_version_id', p_schedule_version_id,
    'version_number', v_draft_record.version_number,
    'based_on_version_id', v_draft_record.based_on_version_id,
    'has_changes', v_before is distinct from v_after,
    'effective_period_changed',
      (v_before -> 'effective_from') is distinct from
        (v_after -> 'effective_from')
      or (v_before -> 'effective_until') is distinct from
        (v_after -> 'effective_until'),
    'general_instructions_changed',
      (v_before -> 'general_instructions') is distinct from
        (v_after -> 'general_instructions'),
    'changed_weekdays', v_changed_weekdays,
    'summary', jsonb_build_object(
      'before', jsonb_build_object(
        'days', v_before_day_count,
        'products', v_before_product_count,
        'trolley_requirements', v_before_trolley_count,
        'trolley_quantity', v_before_trolley_quantity
      ),
      'after', jsonb_build_object(
        'days', v_after_day_count,
        'products', v_after_product_count,
        'trolley_requirements', v_after_trolley_count,
        'trolley_quantity', v_after_trolley_quantity
      )
    ),
    'before', v_before,
    'after', v_after
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Controlled publication wrapper with optimistic concurrency
-- ---------------------------------------------------------------------

create or replace function public.publish_customer_schedule_draft(
  p_schedule_version_id uuid,
  p_expected_row_version integer,
  p_change_reason text,
  p_source_application text default 'CUSTOMER_STUDIO'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_version public.customer_schedule_versions%rowtype;
  v_comparison jsonb;
  v_published public.customer_schedule_versions%rowtype;
begin
  perform public.require_customer_schedule_edit_role();

  if nullif(trim(p_change_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'A publication reason is required.';
  end if;

  select *
  into v_version
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Schedule draft not found.';
  end if;

  if v_version.status <> 'DRAFT' then
    raise exception using
      errcode = '55000',
      message = 'Only a DRAFT schedule revision can be published.';
  end if;

  if v_version.row_version <> p_expected_row_version then
    raise exception using
      errcode = '40001',
      message = 'The schedule draft was changed by another user.',
      hint = 'Reload and compare the current draft before publishing.';
  end if;

  v_comparison := public.compare_customer_schedule_draft(
    p_schedule_version_id
  );

  v_published := public.publish_customer_schedule(
    p_schedule_version_id,
    trim(p_change_reason),
    p_source_application
  );

  return jsonb_build_object(
    'published_schedule',
      public.build_customer_schedule_version_snapshot(
        v_published.schedule_version_id
      ),
    'comparison', v_comparison
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Controlled draft cancellation wrapper with optimistic concurrency
-- ---------------------------------------------------------------------

create or replace function public.cancel_customer_schedule_draft(
  p_schedule_version_id uuid,
  p_expected_row_version integer,
  p_reason text,
  p_source_application text default 'CUSTOMER_STUDIO'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_version public.customer_schedule_versions%rowtype;
  v_cancelled public.customer_schedule_versions%rowtype;
begin
  perform public.require_customer_schedule_edit_role();

  if nullif(trim(p_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'A cancellation reason is required.';
  end if;

  select *
  into v_version
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Schedule draft not found.';
  end if;

  if v_version.status <> 'DRAFT' then
    raise exception using
      errcode = '55000',
      message = 'Only a DRAFT schedule revision can be cancelled through this function.';
  end if;

  if v_version.row_version <> p_expected_row_version then
    raise exception using
      errcode = '40001',
      message = 'The schedule draft was changed by another user.',
      hint = 'Reload the draft before cancelling it.';
  end if;

  v_cancelled := public.cancel_customer_schedule_version(
    p_schedule_version_id,
    trim(p_reason),
    p_source_application
  );

  return public.build_customer_schedule_version_snapshot(
    v_cancelled.schedule_version_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Controlled historical restore wrapper
-- ---------------------------------------------------------------------

create or replace function public.restore_customer_schedule_management_draft(
  p_source_version_id uuid,
  p_effective_from date,
  p_reason text,
  p_source_application text default 'CUSTOMER_STUDIO'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_schedule_version_id uuid;
begin
  perform public.require_customer_schedule_edit_role();

  if p_effective_from < public.current_business_date() then
    raise exception using
      errcode = '22023',
      message = 'A restored schedule cannot start before the current business date.';
  end if;

  v_schedule_version_id := public.restore_customer_schedule_version(
    p_source_version_id,
    p_effective_from,
    p_reason,
    p_source_application
  );

  return jsonb_build_object(
    'schedule_version_id', v_schedule_version_id,
    'draft', public.build_customer_schedule_version_snapshot(
      v_schedule_version_id
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Add explicit Schedule Management capabilities to the existing discovery
-- RPC without removing any previously returned fields.
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
-- Function privileges
--
-- The older low-level schedule write functions are no longer executable by
-- authenticated browser clients. The new wrappers are the only public write
-- path and enforce required reasons plus optimistic concurrency.
-- ---------------------------------------------------------------------

revoke all on function public.create_customer_schedule_draft(
  uuid, date, uuid, text, text
) from public, anon, authenticated;
revoke all on function public.restore_customer_schedule_version(
  uuid, date, text, text
) from public, anon, authenticated;
revoke all on function public.cancel_customer_schedule_version(
  uuid, text, text
) from public, anon, authenticated;
revoke all on function public.publish_customer_schedule(
  uuid, text, text
) from public, anon, authenticated;

revoke all on function public.get_customer_schedule_reference_data(uuid, date)
  from public, anon, authenticated;
revoke all on function public.get_customer_schedule_management_state(uuid, uuid, date)
  from public, anon, authenticated;
revoke all on function public.create_customer_schedule_management_draft(uuid, date, uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.save_customer_schedule_draft(uuid, integer, jsonb, text, text)
  from public, anon, authenticated;
revoke all on function public.compare_customer_schedule_draft(uuid)
  from public, anon, authenticated;
revoke all on function public.publish_customer_schedule_draft(uuid, integer, text, text)
  from public, anon, authenticated;
revoke all on function public.cancel_customer_schedule_draft(uuid, integer, text, text)
  from public, anon, authenticated;
revoke all on function public.restore_customer_schedule_management_draft(uuid, date, text, text)
  from public, anon, authenticated;

revoke all on function public.get_customer_read_capabilities()
  from public, anon, authenticated;

grant execute on function public.get_customer_schedule_reference_data(uuid, date)
  to authenticated;
grant execute on function public.get_customer_schedule_management_state(uuid, uuid, date)
  to authenticated;
grant execute on function public.create_customer_schedule_management_draft(uuid, date, uuid, text, text)
  to authenticated;
grant execute on function public.save_customer_schedule_draft(uuid, integer, jsonb, text, text)
  to authenticated;
grant execute on function public.compare_customer_schedule_draft(uuid)
  to authenticated;
grant execute on function public.publish_customer_schedule_draft(uuid, integer, text, text)
  to authenticated;
grant execute on function public.cancel_customer_schedule_draft(uuid, integer, text, text)
  to authenticated;
grant execute on function public.restore_customer_schedule_management_draft(uuid, date, text, text)
  to authenticated;
grant execute on function public.get_customer_read_capabilities()
  to authenticated;

comment on function public.save_customer_schedule_draft(uuid, integer, jsonb, text, text)
is 'Replaces the complete child model of one DRAFT Customer Schedule in a transaction. Published revisions remain immutable.';

comment on function public.compare_customer_schedule_draft(uuid)
is 'Returns a normalized before/after comparison between a DRAFT Customer Schedule and its base revision.';

commit;
