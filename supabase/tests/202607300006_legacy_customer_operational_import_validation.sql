-- =====================================================================
-- ElisCaretex V2
-- Validation: 202607300006_legacy_customer_operational_import_validation.sql
-- Read-only.
-- =====================================================================

-- Expected core counts.
select
  'customers' as object_name,
  count(*) as record_count
from public.customers

union all
select 'active_customers', count(*)
from public.customers
where active = true

union all
select 'inactive_customers', count(*)
from public.customers
where active = false

union all
select 'customer_product_services', count(*)
from public.customer_product_services

union all
select 'distribution_routes', count(*)
from public.distribution_routes

union all
select 'product_variants', count(*)
from public.product_variants

union all
select 'customer_schedule_versions', count(*)
from public.customer_schedule_versions

union all
select 'customer_schedule_days', count(*)
from public.customer_schedule_days

union all
select 'customer_schedule_products', count(*)
from public.customer_schedule_products

union all
select 'customer_schedule_product_variants', count(*)
from public.customer_schedule_product_variants

union all
select 'customer_schedule_trolley_requirements', count(*)
from public.customer_schedule_trolley_requirements

union all
select 'customer_schedule_trolley_requirement_products', count(*)
from public.customer_schedule_trolley_requirement_products

order by object_name;

-- Expected:
-- customers                                      141
-- active_customers                               130
-- inactive_customers                              11
-- customer_product_services                      156
-- distribution_routes                              9
-- product_variants                                11
-- customer_schedule_versions                     130
-- customer_schedule_days                         417
-- customer_schedule_products                     505
-- customer_schedule_product_variants             207
-- customer_schedule_trolley_requirements         513
-- customer_schedule_trolley_requirement_products 513

-- Expected: all 130 revisions are PUBLISHED.
select
  status,
  source_code,
  count(*) as revision_count
from public.customer_schedule_versions
group by status, source_code
order by status, source_code;

-- Expected trolley quantity total: 852.
select
  count(*) as requirement_rows,
  sum(quantity) as total_planned_trolley_quantity
from public.customer_schedule_trolley_requirements;

-- Confirm MILLBROOK and WOODLAWNS are Clothes-only and have 3M each day.
select
  c.customer_name,
  public.weekday_name(d.production_weekday) as production_day,
  pt.product_code,
  p.production_order,
  sum(req.quantity) as total_trolley_quantity,
  string_agg(
    concat(req.quantity, coalesce(tt.display_code, tt.trolley_type_code)),
    ' + '
    order by tt.sort_order, req.created_at
  ) as trolley_summary
from public.customers c
join public.customer_schedule_versions v
  on v.customer_id = c.customer_id
 and v.status = 'PUBLISHED'
join public.customer_schedule_days d
  on d.schedule_version_id = v.schedule_version_id
join public.customer_schedule_products p
  on p.schedule_day_id = d.schedule_day_id
join public.product_types pt
  on pt.product_type_id = p.product_type_id
left join public.customer_schedule_trolley_requirements req
  on req.schedule_day_id = d.schedule_day_id
 and req.owner_schedule_product_id = p.schedule_product_id
 and req.active = true
left join public.trolley_types tt
  on tt.trolley_type_id = req.trolley_type_id
where c.customer_name in ('MILLBROOK', 'WOODLAWNS')
group by
  c.customer_name,
  d.production_weekday,
  pt.product_code,
  p.production_order
order by c.customer_name, d.production_weekday, pt.product_code;

-- Expected: no MOP services or MOP schedule products for these customers.
select
  c.customer_name,
  pt.product_code,
  count(*) as record_count
from public.customers c
join public.customer_product_services s
  on s.customer_id = c.customer_id
join public.product_types pt
  on pt.product_type_id = s.product_type_id
where c.customer_name in ('MILLBROOK', 'WOODLAWNS')
group by c.customer_name, pt.product_code
order by c.customer_name, pt.product_code;

-- Expected: zero rows. No MOP schedule product was created.
select
  c.customer_name,
  public.weekday_name(d.production_weekday) as production_day,
  pt.product_code
from public.customers c
join public.customer_schedule_versions v
  on v.customer_id = c.customer_id
 and v.status = 'PUBLISHED'
join public.customer_schedule_days d
  on d.schedule_version_id = v.schedule_version_id
join public.customer_schedule_products p
  on p.schedule_day_id = d.schedule_day_id
join public.product_types pt
  on pt.product_type_id = p.product_type_id
where c.customer_name in ('MILLBROOK', 'WOODLAWNS')
  and pt.product_code = 'MOP'
order by c.customer_name, d.production_weekday;

-- Expected: 11 inactive customers; none appears in active customer view.
select
  customer_code,
  customer_name,
  active,
  deactivation_reason
from public.customers
where active = false
order by customer_name;

select
  c.customer_name
from public.customers c
join public.v_active_customers v
  on v.customer_id = c.customer_id
where c.active = false;

-- Expected: zero rows in every integrity query below.

-- A published revision without a day.
select v.schedule_version_id, c.customer_name
from public.customer_schedule_versions v
join public.customers c
  on c.customer_id = v.customer_id
where v.status = 'PUBLISHED'
  and not exists (
    select 1
    from public.customer_schedule_days d
    where d.schedule_version_id = v.schedule_version_id
      and d.active = true
  );

-- A day without a product.
select d.schedule_day_id
from public.customer_schedule_days d
where not exists (
  select 1
  from public.customer_schedule_products p
  where p.schedule_day_id = d.schedule_day_id
    and p.active = true
);

-- A product without an enabled customer service.
select
  c.customer_name,
  public.weekday_name(d.production_weekday) as production_day,
  pt.product_code
from public.customer_schedule_products p
join public.product_types pt
  on pt.product_type_id = p.product_type_id
join public.customer_schedule_days d
  on d.schedule_day_id = p.schedule_day_id
join public.customer_schedule_versions v
  on v.schedule_version_id = d.schedule_version_id
join public.customers c
  on c.customer_id = v.customer_id
left join public.customer_product_services s
  on s.customer_id = c.customer_id
 and s.product_type_id = p.product_type_id
 and s.active = true
 and s.deleted_at is null
where s.customer_product_service_id is null;

-- A trolley without the owner mapped as a served product.
select req.schedule_trolley_requirement_id
from public.customer_schedule_trolley_requirements req
where not exists (
  select 1
  from public.customer_schedule_trolley_requirement_products map
  where map.schedule_trolley_requirement_id =
    req.schedule_trolley_requirement_id
    and map.schedule_product_id = req.owner_schedule_product_id
);

-- Duplicate production orders. Expected: zero rows.
select
  d.production_weekday,
  pt.product_code,
  p.production_order,
  count(*) as duplicate_count
from public.customer_schedule_products p
join public.product_types pt
  on pt.product_type_id = p.product_type_id
join public.customer_schedule_days d
  on d.schedule_day_id = p.schedule_day_id
join public.customer_schedule_versions v
  on v.schedule_version_id = d.schedule_version_id
where v.status = 'PUBLISHED'
  and p.production_order is not null
group by d.production_weekday, pt.product_code, p.production_order
having count(*) > 1
order by d.production_weekday, pt.product_code, p.production_order;

-- Duplicate delivery order by delivery weekday and route. Expected: zero rows.
select
  d.delivery_weekday,
  d.default_route_id,
  d.delivery_order,
  count(*) as duplicate_count
from public.customer_schedule_days d
join public.customer_schedule_versions v
  on v.schedule_version_id = d.schedule_version_id
where v.status = 'PUBLISHED'
  and d.delivery_order is not null
group by d.delivery_weekday, d.default_route_id, d.delivery_order
having count(*) > 1
order by d.delivery_weekday, d.default_route_id, d.delivery_order;

-- Confirm the import audit record.
select
  action,
  entity_id,
  new_data,
  reason,
  source_application,
  occurred_at
from public.audit_log
where action = 'LEGACY_CUSTOMER_OPERATIONAL_IMPORT'
order by occurred_at desc;
