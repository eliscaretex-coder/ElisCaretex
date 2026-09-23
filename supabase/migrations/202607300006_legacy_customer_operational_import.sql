-- =====================================================================
-- ElisCaretex V2
-- Migration: 202607300006_legacy_customer_operational_import.sql
-- Purpose:
--   Transform reviewed legacy customer staging data into the operational
--   Customers and Customer Schedule V2 model.
--
-- The import creates:
--   - 141 customer master records;
--   - 130 active customers and 11 inactive customers;
--   - active customer product services;
--   - 9 route-master records;
--   - 11 normalized MOP product variants;
--   - one published LEGACY_IMPORT schedule revision per active customer;
--   - structured production days, products, notes and trolley requirements.
--
-- Historical source values remain available in the private staging schema
-- and in legacy metadata on imported rows.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Safety guards
-- ---------------------------------------------------------------------

do $$
declare
  v_operational_count bigint;
  v_blocker_count integer;
  v_master_count integer;
  v_schedule_count integer;
  v_inactive_count integer;
  v_route_count integer;
  v_variant_mapping_count integer;
begin
  if to_regclass('staging.legacy_customer_master') is null
     or to_regclass('staging.legacy_customer_schedule') is null
     or to_regclass('staging.v_legacy_import_blockers') is null then
    raise exception 'Required legacy staging objects are missing.';
  end if;

  select count(*) into v_master_count
  from staging.legacy_customer_master;

  select count(*) into v_schedule_count
  from staging.legacy_customer_schedule;

  select count(*) into v_inactive_count
  from staging.legacy_customer_status_override
  where proposed_active = false
    and owner_confirmed = true;

  select count(*) into v_route_count
  from staging.legacy_route_mapping
  where owner_confirmed = true;

  select count(*) into v_variant_mapping_count
  from staging.legacy_mop_variant_mapping
  where owner_confirmed = true
    and review_required = false;

  select count(*) into v_blocker_count
  from staging.v_legacy_import_blockers;

  if v_master_count <> 141
     or v_schedule_count <> 417
     or v_inactive_count <> 11
     or v_route_count <> 9
     or v_variant_mapping_count <> 12
     or v_blocker_count <> 0 then
    raise exception using
      message = 'Safety stop: reviewed staging data is not ready for import.',
      detail = format(
        'customers=%s, schedules=%s, inactive=%s, routes=%s, variant_mappings=%s, blockers=%s',
        v_master_count,
        v_schedule_count,
        v_inactive_count,
        v_route_count,
        v_variant_mapping_count,
        v_blocker_count
      ),
      hint = 'Run and verify migration/test 005 before the operational import.';
  end if;

  select
      (select count(*) from public.customers)
    + (select count(*) from public.customer_product_services)
    + (select count(*) from public.distribution_routes)
    + (select count(*) from public.product_variants)
    + (select count(*) from public.customer_schedule_versions)
    + (select count(*) from public.customer_schedule_days)
    + (select count(*) from public.customer_schedule_products)
    + (select count(*) from public.customer_schedule_product_variants)
    + (select count(*) from public.customer_schedule_trolley_requirements)
    + (select count(*) from public.customer_schedule_trolley_requirement_products)
  into v_operational_count;

  if v_operational_count <> 0 then
    raise exception using
      message = 'Safety stop: operational customer tables are not empty.',
      detail = format('Combined operational row count=%s', v_operational_count),
      hint = 'This initial import must never overwrite an existing operational dataset.';
  end if;

  if (
    select count(*)
    from public.product_types
    where product_code in ('CLOTHES', 'MOP')
      and active = true
      and deleted_at is null
  ) <> 2 then
    raise exception 'CLOTHES and MOP product types are missing or inactive.';
  end if;

  if (
    select count(*)
    from public.trolley_types
    where trolley_type_code in ('SMALL', 'MEDIUM', 'LARGE', 'GRAY')
      and active = true
      and allowed_in_customer_schedule = true
      and deleted_at is null
  ) <> 4 then
    raise exception 'The four approved schedule trolley types are missing or inactive.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Route master
-- ---------------------------------------------------------------------

insert into public.distribution_routes (
  route_code,
  display_name,
  route_color,
  route_kind,
  allow_as_default,
  active,
  sort_order,
  notes,
  metadata
)
select
  r.route_code,
  r.proposed_display_name,
  lower(r.proposed_route_color),
  r.route_kind,
  r.allow_as_default,
  true,
  row_number() over (order by r.route_code::integer) * 10,
  nullif(r.decision_note, ''),
  jsonb_build_object(
    'source', 'LEGACY_CENTRALDB',
    'owner_confirmed', r.owner_confirmed,
    'legacy_review_note', r.review_note
  )
from staging.legacy_route_mapping r
where r.owner_confirmed = true
order by r.route_code::integer;

-- ---------------------------------------------------------------------
-- MOP product variants
-- ---------------------------------------------------------------------

with grouped_variants as (
  select
    proposed_variant_code,
    max(proposed_display_name) as proposed_display_name,
    jsonb_agg(legacy_value order by legacy_value) as legacy_values,
    jsonb_agg(
      jsonb_build_object(
        'legacy_value', legacy_value,
        'decision_note', decision_note,
        'review_note', review_note
      )
      order by legacy_value
    ) as review_history
  from staging.legacy_mop_variant_mapping
  where owner_confirmed = true
    and review_required = false
  group by proposed_variant_code
)
insert into public.product_variants (
  product_type_id,
  variant_code,
  display_name,
  active,
  sort_order,
  metadata
)
select
  pt.product_type_id,
  gv.proposed_variant_code,
  gv.proposed_display_name,
  true,
  row_number() over (
    order by gv.proposed_display_name, gv.proposed_variant_code
  ) * 10,
  jsonb_build_object(
    'source', 'LEGACY_CENTRALDB',
    'legacy_values', gv.legacy_values,
    'legacy_review_history', gv.review_history
  )
from grouped_variants gv
cross join public.product_types pt
where pt.product_code = 'MOP'
  and pt.active = true
  and pt.deleted_at is null;

-- ---------------------------------------------------------------------
-- Customer master
-- ---------------------------------------------------------------------

insert into public.customers (
  customer_code,
  customer_name,
  eircode,
  distribution_estimated_kg,
  distribution_stop_count,
  notes,
  operational_alert,
  active,
  deactivated_at,
  deactivation_reason,
  legacy_metadata
)
select
  m.legacy_customer_id,
  trim(m.customer_name),
  nullif(trim(m.eircode), ''),
  m.kg_estimated,
  m.stops,
  nullif(trim(m.information), ''),
  null,
  r.proposed_active,
  case when r.proposed_active then null else now() end,
  case
    when r.proposed_active then null
    else coalesce(r.override_reason, 'Inactive in the legacy operation.')
  end,
  jsonb_build_object(
    'source', 'LEGACY_CENTRALDB',
    'source_file', m.source_file,
    'source_row', m.source_row,
    'legacy_customer_id', m.legacy_customer_id,
    'legacy_service_type', m.service_type,
    'legacy_customer_type', m.customer_type,
    'legacy_active_text', m.legacy_active_text,
    'status_owner_confirmed', coalesce(r.owner_confirmed, false)
  )
from staging.legacy_customer_master m
join staging.v_legacy_customer_review r
  on r.legacy_customer_id = m.legacy_customer_id
order by m.source_row;

-- ---------------------------------------------------------------------
-- Active customer service eligibility
-- ---------------------------------------------------------------------

with service_codes as (
  select
    m.legacy_customer_id,
    'CLOTHES'::text as product_code
  from staging.legacy_customer_master m
  join staging.v_legacy_customer_review r
    on r.legacy_customer_id = m.legacy_customer_id
  where r.proposed_active = true
    and upper(trim(m.service_type)) in ('CLOTHES', 'CLOTHES + MOP')

  union all

  select
    m.legacy_customer_id,
    'MOP'::text as product_code
  from staging.legacy_customer_master m
  join staging.v_legacy_customer_review r
    on r.legacy_customer_id = m.legacy_customer_id
  where r.proposed_active = true
    and upper(trim(m.service_type)) in ('MOP', 'CLOTHES + MOP')
)
insert into public.customer_product_services (
  customer_id,
  product_type_id,
  effective_from,
  active
)
select
  c.customer_id,
  pt.product_type_id,
  date '2026-07-30',
  true
from service_codes s
join public.customers c
  on c.customer_code = s.legacy_customer_id
 and c.active = true
join public.product_types pt
  on pt.product_code = s.product_code
 and pt.active = true
 and pt.deleted_at is null;

-- ---------------------------------------------------------------------
-- Initial schedule revisions
--
-- They remain DRAFT while child rows are inserted. They are published
-- only after all import validations pass.
-- ---------------------------------------------------------------------

insert into public.customer_schedule_versions (
  customer_id,
  version_number,
  status,
  effective_from,
  effective_until,
  source_code,
  change_reason,
  general_instructions
)
select
  c.customer_id,
  1,
  'DRAFT',
  date '2026-07-30',
  null,
  'LEGACY_IMPORT',
  'Initial controlled import from CentralDB(14).xlsx.',
  null
from (
  select distinct legacy_customer_id
  from staging.legacy_customer_schedule
) s
join public.customers c
  on c.customer_code = s.legacy_customer_id
 and c.active = true
order by c.customer_code;

-- ---------------------------------------------------------------------
-- Schedule days and Distribution defaults
-- ---------------------------------------------------------------------

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
  metadata
)
select
  v.schedule_version_id,
  case lower(trim(s.production_day))
    when 'monday' then 1
    when 'tuesday' then 2
    when 'wednesday' then 3
    when 'thursday' then 4
    when 'friday' then 5
    when 'saturday' then 6
    when 'sunday' then 7
  end::smallint,
  case lower(trim(coalesce(s.delivery_day, '')))
    when 'monday' then 1
    when 'tuesday' then 2
    when 'wednesday' then 3
    when 'thursday' then 4
    when 'friday' then 5
    when 'saturday' then 6
    when 'sunday' then 7
    else null
  end::smallint,
  r.route_id,
  case
    when staging.parse_legacy_delivery_window(s.delivery_time_text) ->> 'status' = 'PARSED'
    then (
      staging.parse_legacy_delivery_window(s.delivery_time_text) ->> 'start_time'
    )::time
    else null
  end,
  case
    when staging.parse_legacy_delivery_window(s.delivery_time_text) ->> 'status' = 'PARSED'
    then (
      staging.parse_legacy_delivery_window(s.delivery_time_text) ->> 'end_time'
    )::time
    else null
  end,
  s.delivery_order,
  nullif(trim(s.information), ''),
  nullif(trim(s.delivery_notes), ''),
  true,
  jsonb_build_object(
    'source', 'LEGACY_CENTRALDB',
    'legacy_source_row', s.source_row,
    'legacy_service_type', s.service_type,
    'legacy_route_code', s.route_code,
    'legacy_route_color', s.route_color,
    'legacy_route_display_name', s.display_name,
    'legacy_delivery_time_text', s.delivery_time_text
  )
from staging.legacy_customer_schedule s
join public.customers c
  on c.customer_code = s.legacy_customer_id
 and c.active = true
join public.customer_schedule_versions v
  on v.customer_id = c.customer_id
 and v.version_number = 1
 and v.status = 'DRAFT'
join public.distribution_routes r
  on r.route_code = s.route_code
 and r.active = true
 and r.allow_as_default = true
 and r.deleted_at is null
order by s.source_row;

-- ---------------------------------------------------------------------
-- Scheduled product streams
-- ---------------------------------------------------------------------

insert into public.customer_schedule_products (
  schedule_day_id,
  product_type_id,
  production_order,
  expected_kg,
  expected_units,
  production_instructions,
  active,
  metadata
)
select
  d.schedule_day_id,
  pt.product_type_id,
  s.clothes_order,
  null,
  null,
  nullif(trim(s.clothes_notes), ''),
  true,
  jsonb_build_object(
    'source', 'LEGACY_CENTRALDB',
    'legacy_source_row', s.source_row,
    'legacy_product_code', 'CLOTHES'
  )
from staging.legacy_customer_schedule s
join public.customer_schedule_days d
  on (d.metadata ->> 'legacy_source_row')::integer = s.source_row
join public.product_types pt
  on pt.product_code = 'CLOTHES'
 and pt.active = true
 and pt.deleted_at is null
where s.clothes_order is not null
order by s.source_row;

insert into public.customer_schedule_products (
  schedule_day_id,
  product_type_id,
  production_order,
  expected_kg,
  expected_units,
  production_instructions,
  active,
  metadata
)
select
  d.schedule_day_id,
  pt.product_type_id,
  s.mop_order,
  null,
  null,
  nullif(trim(s.mop_instructions), ''),
  true,
  jsonb_build_object(
    'source', 'LEGACY_CENTRALDB',
    'legacy_source_row', s.source_row,
    'legacy_product_code', 'MOP'
  )
from staging.legacy_customer_schedule s
join public.customer_schedule_days d
  on (d.metadata ->> 'legacy_source_row')::integer = s.source_row
join public.product_types pt
  on pt.product_code = 'MOP'
 and pt.active = true
 and pt.deleted_at is null
where s.mop_order is not null
order by s.source_row;

-- ---------------------------------------------------------------------
-- MOP product variants on each schedule day
-- ---------------------------------------------------------------------

with source_variants as (
  select distinct
    s.source_row,
    trim(value) as legacy_value
  from staging.legacy_customer_schedule s
  cross join lateral regexp_split_to_table(
    coalesce(s.mop_products_text, ''),
    '\s*;\s*'
  ) value
  where nullif(trim(value), '') is not null
)
insert into public.customer_schedule_product_variants (
  schedule_product_id,
  product_variant_id
)
select distinct
  p.schedule_product_id,
  pv.product_variant_id
from source_variants sv
join staging.legacy_mop_variant_mapping m
  on m.legacy_value = sv.legacy_value
 and m.owner_confirmed = true
 and m.review_required = false
join public.customer_schedule_days d
  on (d.metadata ->> 'legacy_source_row')::integer = sv.source_row
join public.customer_schedule_products p
  on p.schedule_day_id = d.schedule_day_id
join public.product_types pt
  on pt.product_type_id = p.product_type_id
 and pt.product_code = 'MOP'
join public.product_variants pv
  on pv.product_type_id = pt.product_type_id
 and pv.variant_code = m.proposed_variant_code
 and pv.active = true
 and pv.deleted_at is null;

-- ---------------------------------------------------------------------
-- Structured trolley requirements
--
-- Every source item creates one requirement and is counted once.
-- Owner and served-product mappings come from the reviewed effective value.
-- The legacy source does not explicitly identify shared trolleys, so no
-- shared relationship is invented during the initial import.
-- ---------------------------------------------------------------------

with effective_items as (
  select
    t.source_row,
    t.source_field,
    t.raw_value,
    t.decision_note,
    t.effective_value,
    item.item_value,
    item.item_ordinality
  from staging.v_legacy_effective_trolley_review t
  cross join lateral jsonb_array_elements(
    coalesce(t.effective_value -> 'items', '[]'::jsonb)
  ) with ordinality as item(item_value, item_ordinality)
  where t.effective_value ->> 'status' in ('PARSED', 'PARSED_OVERRIDE')
)
insert into public.customer_schedule_trolley_requirements (
  schedule_day_id,
  trolley_type_id,
  owner_schedule_product_id,
  quantity,
  empty_trolley,
  notes,
  active,
  metadata
)
select
  d.schedule_day_id,
  tt.trolley_type_id,
  owner_product.schedule_product_id,
  (e.item_value ->> 'quantity')::integer,
  coalesce((e.item_value ->> 'empty_trolley')::boolean, false),
  nullif(trim(e.decision_note), ''),
  true,
  jsonb_build_object(
    'source', 'LEGACY_CENTRALDB',
    'legacy_source_row', e.source_row,
    'legacy_source_field', e.source_field,
    'legacy_raw_value', e.raw_value,
    'legacy_item_ordinal', e.item_ordinality,
    'effective_status', e.effective_value ->> 'status',
    'owner_product_code', e.effective_value ->> 'owner_product_code',
    'serves_product_codes', e.effective_value -> 'serves_product_codes'
  )
from effective_items e
join public.customer_schedule_days d
  on (d.metadata ->> 'legacy_source_row')::integer = e.source_row
join public.trolley_types tt
  on tt.trolley_type_code = e.item_value ->> 'trolley_type_code'
 and tt.active = true
 and tt.allowed_in_customer_schedule = true
 and tt.deleted_at is null
join public.product_types owner_type
  on owner_type.product_code = e.effective_value ->> 'owner_product_code'
 and owner_type.active = true
 and owner_type.deleted_at is null
join public.customer_schedule_products owner_product
  on owner_product.schedule_day_id = d.schedule_day_id
 and owner_product.product_type_id = owner_type.product_type_id
 and owner_product.active = true
order by e.source_row, e.source_field, e.item_ordinality;

with effective_served_products as (
  select
    t.source_row,
    t.source_field,
    item.item_ordinality,
    served.product_code
  from staging.v_legacy_effective_trolley_review t
  cross join lateral jsonb_array_elements(
    coalesce(t.effective_value -> 'items', '[]'::jsonb)
  ) with ordinality as item(item_value, item_ordinality)
  cross join lateral jsonb_array_elements_text(
    coalesce(t.effective_value -> 'serves_product_codes', '[]'::jsonb)
  ) as served(product_code)
  where t.effective_value ->> 'status' in ('PARSED', 'PARSED_OVERRIDE')
)
insert into public.customer_schedule_trolley_requirement_products (
  schedule_trolley_requirement_id,
  schedule_product_id
)
select distinct
  req.schedule_trolley_requirement_id,
  served_product.schedule_product_id
from effective_served_products e
join public.customer_schedule_trolley_requirements req
  on (req.metadata ->> 'legacy_source_row')::integer = e.source_row
 and req.metadata ->> 'legacy_source_field' = e.source_field
 and (req.metadata ->> 'legacy_item_ordinal')::bigint = e.item_ordinality
join public.customer_schedule_days d
  on d.schedule_day_id = req.schedule_day_id
join public.product_types served_type
  on served_type.product_code = e.product_code
 and served_type.active = true
 and served_type.deleted_at is null
join public.customer_schedule_products served_product
  on served_product.schedule_day_id = d.schedule_day_id
 and served_product.product_type_id = served_type.product_type_id
 and served_product.active = true;

-- ---------------------------------------------------------------------
-- Import reconciliation before publication
-- ---------------------------------------------------------------------

do $$
declare
  v_customers integer;
  v_active_customers integer;
  v_inactive_customers integer;
  v_services integer;
  v_routes integer;
  v_variants integer;
  v_versions integer;
  v_days integer;
  v_products integer;
  v_variant_links integer;
  v_trolley_requirements integer;
  v_trolley_quantity integer;
  v_trolley_links integer;
  v_expected_versions integer;
  v_expected_trolley_requirements integer;
  v_expected_trolley_quantity integer;
  v_expected_trolley_links integer;
begin
  select count(*) into v_customers
  from public.customers;

  select count(*) filter (where active),
         count(*) filter (where not active)
  into v_active_customers, v_inactive_customers
  from public.customers;

  select count(*) into v_services
  from public.customer_product_services
  where active = true;

  select count(*) into v_routes
  from public.distribution_routes;

  select count(*) into v_variants
  from public.product_variants;

  select count(*) into v_versions
  from public.customer_schedule_versions
  where status = 'DRAFT';

  select count(*) into v_days
  from public.customer_schedule_days;

  select count(*) into v_products
  from public.customer_schedule_products;

  select count(*) into v_variant_links
  from public.customer_schedule_product_variants;

  select count(*), coalesce(sum(quantity), 0)
  into v_trolley_requirements, v_trolley_quantity
  from public.customer_schedule_trolley_requirements;

  select count(*) into v_trolley_links
  from public.customer_schedule_trolley_requirement_products;

  select count(distinct legacy_customer_id)
  into v_expected_versions
  from staging.legacy_customer_schedule;

  select
    coalesce(sum(jsonb_array_length(effective_value -> 'items')), 0),
    coalesce(sum((effective_value ->> 'total_quantity')::integer), 0),
    coalesce(sum(
      jsonb_array_length(effective_value -> 'items')
      * jsonb_array_length(effective_value -> 'serves_product_codes')
    ), 0)
  into
    v_expected_trolley_requirements,
    v_expected_trolley_quantity,
    v_expected_trolley_links
  from staging.v_legacy_effective_trolley_review
  where effective_value ->> 'status' in ('PARSED', 'PARSED_OVERRIDE');

  if v_customers <> 141
     or v_active_customers <> 130
     or v_inactive_customers <> 11
     or v_services <> 156
     or v_routes <> 9
     or v_variants <> 11
     or v_versions <> v_expected_versions
     or v_versions <> 130
     or v_days <> 417
     or v_products <> 505
     or v_variant_links <> 207
     or v_trolley_requirements <> v_expected_trolley_requirements
     or v_trolley_requirements <> 513
     or v_trolley_quantity <> v_expected_trolley_quantity
     or v_trolley_quantity <> 852
     or v_trolley_links <> v_expected_trolley_links
     or v_trolley_links <> 513 then
    raise exception using
      message = 'Operational import reconciliation failed.',
      detail = format(
        'customers=%s active=%s inactive=%s services=%s routes=%s variants=%s versions=%s days=%s products=%s variant_links=%s trolley_requirements=%s trolley_quantity=%s trolley_links=%s',
        v_customers,
        v_active_customers,
        v_inactive_customers,
        v_services,
        v_routes,
        v_variants,
        v_versions,
        v_days,
        v_products,
        v_variant_links,
        v_trolley_requirements,
        v_trolley_quantity,
        v_trolley_links
      ),
      hint = 'The transaction will roll back. Do not manually correct partial data.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_days d
    where not exists (
      select 1
      from public.customer_schedule_products p
      where p.schedule_day_id = d.schedule_day_id
        and p.active = true
    )
  ) then
    raise exception 'A schedule day was imported without an active product.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    join public.customer_schedule_versions v
      on v.schedule_version_id = d.schedule_version_id
    left join public.customer_product_services s
      on s.customer_id = v.customer_id
     and s.product_type_id = p.product_type_id
     and s.active = true
     and s.deleted_at is null
     and s.effective_from <= v.effective_from
     and (s.effective_until is null or s.effective_until >= v.effective_from)
    where p.active = true
      and s.customer_product_service_id is null
  ) then
    raise exception 'A scheduled product is not enabled for its customer.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_trolley_requirements req
    where not exists (
      select 1
      from public.customer_schedule_trolley_requirement_products map
      where map.schedule_trolley_requirement_id =
        req.schedule_trolley_requirement_id
    )
  ) then
    raise exception 'A trolley requirement has no served-product mapping.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_trolley_requirements req
    where not exists (
      select 1
      from public.customer_schedule_trolley_requirement_products map
      where map.schedule_trolley_requirement_id =
        req.schedule_trolley_requirement_id
        and map.schedule_product_id = req.owner_schedule_product_id
    )
  ) then
    raise exception 'A trolley owner is missing from the products served.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Publish the initial legacy revisions
-- ---------------------------------------------------------------------

update public.customer_schedule_versions
set
  status = 'PUBLISHED',
  change_reason = 'Initial controlled import from CentralDB(14).xlsx.',
  published_at = now(),
  updated_at = now()
where status = 'DRAFT'
  and source_code = 'LEGACY_IMPORT';

do $$
declare
  v_published_count integer;
  v_draft_count integer;
begin
  select count(*) into v_published_count
  from public.customer_schedule_versions
  where status = 'PUBLISHED'
    and source_code = 'LEGACY_IMPORT';

  select count(*) into v_draft_count
  from public.customer_schedule_versions
  where status = 'DRAFT';

  if v_published_count <> 130 or v_draft_count <> 0 then
    raise exception using
      message = 'Schedule publication reconciliation failed.',
      detail = format(
        'published_legacy_revisions=%s, remaining_drafts=%s',
        v_published_count,
        v_draft_count
      ),
      hint = 'The complete transaction will roll back.';
  end if;
end;
$$;

insert into public.audit_log (
  action,
  entity_table,
  entity_id,
  new_data,
  reason,
  source_application,
  correlation_id
)
values (
  'LEGACY_CUSTOMER_OPERATIONAL_IMPORT',
  'customer_schedule_versions',
  'LEGACY_CENTRALDB_20260730',
  jsonb_build_object(
    'source_file', 'CentralDB(14).xlsx',
    'customers', (select count(*) from public.customers),
    'active_customers', (
      select count(*) from public.customers where active = true
    ),
    'inactive_customers', (
      select count(*) from public.customers where active = false
    ),
    'customer_services', (
      select count(*) from public.customer_product_services
    ),
    'routes', (select count(*) from public.distribution_routes),
    'product_variants', (select count(*) from public.product_variants),
    'schedule_versions', (
      select count(*) from public.customer_schedule_versions
    ),
    'schedule_days', (select count(*) from public.customer_schedule_days),
    'schedule_products', (
      select count(*) from public.customer_schedule_products
    ),
    'trolley_requirements', (
      select count(*) from public.customer_schedule_trolley_requirements
    ),
    'trolley_quantity_total', (
      select coalesce(sum(quantity), 0)
      from public.customer_schedule_trolley_requirements
    )
  ),
  'Initial reviewed and controlled legacy customer import.',
  'DATABASE_MIGRATION',
  gen_random_uuid()
);

commit;
