-- =====================================================================
-- ElisCaretex V2
-- Validation: 202607300005_final_legacy_trolley_decisions_validation.sql
-- Read-only.
-- =====================================================================

-- Expected: 11 total confirmed trolley overrides.
select
  count(*) as confirmed_trolley_overrides
from staging.legacy_trolley_override
where owner_confirmed = true;

-- Expected: six rows, all owned by CLOTHES and serving CLOTHES.
select
  o.source_row,
  s.customer_name,
  s.production_day,
  o.source_field,
  o.trolley_type_code,
  o.quantity,
  o.owner_product_code,
  o.serves_product_codes,
  o.decision_note
from staging.legacy_trolley_override o
join staging.legacy_customer_schedule s
  on s.source_row = o.source_row
where o.source_row in (40, 181, 309, 131, 269, 400)
order by s.customer_name, s.production_day;

-- Expected: zero rows.
select *
from staging.v_legacy_import_blockers
order by blocker_code, source_row;

-- Expected: all zero.
select
  'customers' as table_name,
  count(*) as record_count
from public.customers

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

order by table_name;
