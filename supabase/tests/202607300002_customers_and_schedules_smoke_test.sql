-- =====================================================================
-- ElisCaretex V2
-- Read-only smoke test for the customer and schedule foundation.
-- Run after the migration and reference seed.
-- =====================================================================

-- Expected counts after the seed:
-- product_types = 2
-- trolley_types = 4
-- customers = 0
-- customer_schedule_versions = 0

select
  'customers' as object_name,
  count(*) as record_count
from public.customers

union all

select
  'product_types' as object_name,
  count(*) as record_count
from public.product_types

union all

select
  'trolley_types' as object_name,
  count(*) as record_count
from public.trolley_types

union all

select
  'distribution_routes' as object_name,
  count(*) as record_count
from public.distribution_routes

union all

select
  'customer_schedule_versions' as object_name,
  count(*) as record_count
from public.customer_schedule_versions

union all

select
  'customer_schedule_days' as object_name,
  count(*) as record_count
from public.customer_schedule_days

union all

select
  'customer_schedule_products' as object_name,
  count(*) as record_count
from public.customer_schedule_products

union all

select
  'customer_schedule_trolley_requirements' as object_name,
  count(*) as record_count
from public.customer_schedule_trolley_requirements

order by object_name;

select
  product_code,
  display_name,
  uses_kg,
  uses_units,
  active
from public.product_types
order by sort_order;

select
  trolley_type_code,
  trolley_type_name,
  display_code,
  trolley_category,
  active
from public.trolley_types
order by sort_order;

select
  table_name
from information_schema.views
where table_schema = 'public'
  and table_name in (
    'v_active_customers',
    'v_customer_management',
    'v_customer_distribution_management',
    'v_finish_current_schedule',
    'v_mop_current_schedule',
    'v_distribution_current_schedule',
    'v_customer_schedule_history'
  )
order by table_name;
