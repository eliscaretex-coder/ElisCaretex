-- =====================================================================
-- ElisCaretex V2
-- Validation: reviewed legacy customer decisions
-- Run after migration 202607300004_legacy_customer_review_decisions.sql
-- This file is read-only.
-- =====================================================================

-- 1. Decision counts.
select
  'confirmed_inactive_customers' as item,
  count(*) as record_count
from staging.legacy_customer_status_override
where proposed_active = false
  and owner_confirmed = true

union all

select
  'confirmed_trolley_overrides',
  count(*)
from staging.legacy_trolley_override
where owner_confirmed = true

union all

select
  'confirmed_route_mappings',
  count(*)
from staging.legacy_route_mapping
where owner_confirmed = true

union all

select
  'confirmed_mop_variant_mappings',
  count(*)
from staging.legacy_mop_variant_mapping
where owner_confirmed = true

order by item;

-- Expected:
-- confirmed_inactive_customers    11
-- confirmed_trolley_overrides      5
-- confirmed_route_mappings         9
-- confirmed_mop_variant_mappings  12

-- 2. Confirm the five applied trolley decisions.
select
  source_row,
  source_field,
  decision_code,
  trolley_type_code,
  quantity,
  owner_product_code,
  serves_product_codes,
  decision_note
from staging.legacy_trolley_override
order by source_row, source_field;

-- 3. Trolley parser errors after applying overrides. Expected: zero rows.
select
  source_row,
  customer_name,
  production_day,
  source_field,
  raw_value,
  effective_value ->> 'status' as effective_status
from staging.v_legacy_effective_trolley_review
where effective_value ->> 'status' like 'REVIEW%'
order by source_row, source_field;

-- 4. Final blockers. Expected at this stage: six rows.
select
  blocker_code,
  source_row,
  customer_name,
  production_day,
  source_field,
  raw_value,
  blocker_detail
from staging.v_legacy_import_blockers
order by blocker_code, source_row;

-- The six expected blockers are:
-- MILLBROOK   Monday, Wednesday, Friday
-- WOODLAWNS   Tuesday, Thursday, Saturday
-- Each source row contains QtyClothes=2M and TrolleyMop=1M while the
-- customer ServiceType is CLOTHES.

-- 5. Mop variants. No row should have review_required=true.
select *
from staging.v_legacy_mop_variant_review
order by review_required desc, usage_count desc, legacy_value;

-- 6. Operational tables must still be empty.
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
