-- =====================================================================
-- ElisCaretex V2
-- Read-only validation for the legacy customer staging import.
-- Run after migration 003 and its staging data seed.
-- =====================================================================

select
  'legacy_customer_master' as object_name,
  count(*) as record_count
from staging.legacy_customer_master

union all

select
  'legacy_customer_schedule',
  count(*)
from staging.legacy_customer_schedule

union all

select
  'customer_status_overrides',
  count(*)
from staging.legacy_customer_status_override

union all

select
  'route_mappings',
  count(*)
from staging.legacy_route_mapping

union all

select
  'mop_variant_mappings',
  count(*)
from staging.legacy_mop_variant_mapping

order by object_name;

-- Customer issue summary.
select
  issue_code,
  count(*) as customer_count
from staging.v_legacy_customer_review
cross join lateral unnest(issue_codes) issue_code
group by issue_code
order by issue_code;

-- Customers without schedules. Review the two rows that still have MOP service.
select
  legacy_customer_id,
  customer_name,
  service_type,
  schedule_row_count,
  proposed_active,
  owner_confirmed,
  issue_codes
from staging.v_legacy_customer_review
where schedule_row_count = 0
order by customer_name;

-- Route source inconsistencies. The proposed values are the route-master values.
select *
from staging.v_legacy_route_review
order by route_code;

-- Trolley values that cannot be converted safely without a decision.
select
  source_row,
  legacy_customer_id,
  customer_name,
  production_day,
  source_field,
  owner_product_code,
  raw_value,
  parsed_value ->> 'status' as parse_status
from staging.v_legacy_trolley_review
where parsed_value ->> 'status' like 'REVIEW%'
order by source_row, source_field;

-- Schedule rows with one or more validation issues.
select
  source_row,
  legacy_customer_id,
  customer_name,
  production_day,
  service_type,
  issue_codes
from staging.v_legacy_schedule_review
where review_required
order by source_row;

-- Mop product normalization review.
select *
from staging.v_legacy_mop_variant_review
order by review_required desc, usage_count desc, legacy_value;

-- Duplicate schedule-day check. Expected: no rows.
select
  legacy_customer_id,
  production_day,
  count(*) as duplicate_count
from staging.legacy_customer_schedule
group by legacy_customer_id, production_day
having count(*) > 1
order by legacy_customer_id, production_day;

-- Duplicate Clothes production order check. Expected: no rows.
select
  production_day,
  clothes_order,
  count(*) as duplicate_count
from staging.legacy_customer_schedule
where clothes_order is not null
group by production_day, clothes_order
having count(*) > 1
order by production_day, clothes_order;

-- Duplicate Mop production order check. Expected: no rows.
select
  production_day,
  mop_order,
  count(*) as duplicate_count
from staging.legacy_customer_schedule
where mop_order is not null
group by production_day, mop_order
having count(*) > 1
order by production_day, mop_order;

-- Duplicate delivery order within delivery day and route. Expected: no rows.
select
  delivery_day,
  route_code,
  delivery_order,
  count(*) as duplicate_count
from staging.legacy_customer_schedule
where delivery_order is not null
group by delivery_day, route_code, delivery_order
having count(*) > 1
order by delivery_day, route_code, delivery_order;
