-- Sorting customer board: indexes for the per-customer lookups.
--
-- get_sorting_customer_board_v3/v4 run, for every scheduled customer of today and
-- tomorrow (~185 rows), three subqueries on sorting_wash_run_customers filtered by
-- source_schedule_product_id, plus sorting_schedule_product_has_trolley(), which looks up
-- trolley requirements by owner_schedule_product_id or by
-- customer_schedule_trolley_requirement_products.schedule_product_id.
-- None of those columns had a usable index, so each lookup read ~300 rows of the
-- customer's whole wash history (measured 2026-11-04: ~1.8 ms x 185 x 3 subqueries,
-- board total ~1.5 s for the SORTING-PC01 terminal).
--
-- Additive only: no data, function or permission changes.

create index if not exists sorting_wash_run_customers_source_product_idx
  on public.sorting_wash_run_customers (source_schedule_product_id, customer_id)
  where source_schedule_product_id is not null;

create index if not exists customer_schedule_trolley_requirements_owner_product_idx
  on public.customer_schedule_trolley_requirements (owner_schedule_product_id)
  where active = true;

create index if not exists customer_schedule_trolley_requirement_products_product_idx
  on public.customer_schedule_trolley_requirement_products (schedule_product_id);

analyze public.sorting_wash_run_customers;
analyze public.customer_schedule_trolley_requirements;
analyze public.customer_schedule_trolley_requirement_products;
