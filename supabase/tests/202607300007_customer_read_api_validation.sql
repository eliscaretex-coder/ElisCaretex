-- =====================================================================
-- ElisCaretex V2
-- Validation: 202607300007_customer_read_api_validation.sql
-- Read-only. The transaction is rolled back at the end.
-- =====================================================================

begin;

-- Simulate the already-linked active ADMIN account while testing RPCs from
-- the SQL Editor. This does not change the user or its roles.
select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr
      on sr.staff_id = sm.staff_id
     and sr.active = true
     and sr.effective_from <= current_date
     and (sr.effective_until is null or sr.effective_until >= current_date)
    join public.roles r
      on r.role_id = sr.role_id
     and r.active = true
     and r.role_code = 'ADMIN'
    where sm.active = true
      and sm.deleted_at is null
      and sm.auth_user_id is not null
    order by sm.created_at
    limit 1
  ),
  true
);

set local role authenticated;

-- Expected: all capabilities true for ADMIN.
select public.get_customer_read_capabilities() as capabilities;

-- Expected directory totals:
-- ACTIVE = 130
-- INACTIVE = 11
-- CLOTHES = 110
-- MOP = 46
-- CLOTHES_ONLY = 84
-- MOP_ONLY = 20
-- CLOTHES_AND_MOP = 26
select
  public.get_customer_directory(
    'ACTIVE', 'ALL', null, date '2026-07-30', 200, 0
  ) ->> 'total_count' as active_customers,
  public.get_customer_directory(
    'INACTIVE', 'ALL', null, date '2026-07-30', 200, 0
  ) ->> 'total_count' as inactive_customers,
  public.get_customer_directory(
    'ACTIVE', 'CLOTHES', null, date '2026-07-30', 200, 0
  ) ->> 'total_count' as clothes_customers,
  public.get_customer_directory(
    'ACTIVE', 'MOP', null, date '2026-07-30', 200, 0
  ) ->> 'total_count' as mop_customers,
  public.get_customer_directory(
    'ACTIVE', 'CLOTHES_ONLY', null, date '2026-07-30', 200, 0
  ) ->> 'total_count' as clothes_only_customers,
  public.get_customer_directory(
    'ACTIVE', 'MOP_ONLY', null, date '2026-07-30', 200, 0
  ) ->> 'total_count' as mop_only_customers,
  public.get_customer_directory(
    'ACTIVE', 'CLOTHES_AND_MOP', null, date '2026-07-30', 200, 0
  ) ->> 'total_count' as clothes_and_mop_customers;

-- Expected planner totals:
-- Clothes products = 359
-- Mop products = 146
-- Distribution schedule days = 417
select
  public.get_clothes_weekly_planner(
    date '2026-07-30', null, null
  ) ->> 'total_count' as clothes_planner_rows,
  public.get_mop_weekly_planner(
    date '2026-07-30', null, null
  ) ->> 'total_count' as mop_planner_rows,
  public.get_distribution_weekly_planner(
    date '2026-07-30', null, null
  ) ->> 'total_count' as distribution_planner_rows;

-- Expected: MILLBROOK has three days, only CLOTHES products and a visible
-- trolley total of 3 on every day.
with millbrook as (
  select public.get_customer_weekly_schedule(
    (
      select customer_id
      from public.customers
      where customer_name = 'MILLBROOK'
    ),
    date '2026-07-30'
  ) as payload
)
select
  payload -> 'visible_product_codes' as visible_product_codes,
  jsonb_array_length(payload -> 'days') as schedule_day_count,
  (
    select bool_and((day_item ->> 'visible_trolley_total')::integer = 3)
    from jsonb_array_elements(payload -> 'days') day_item
  ) as every_day_has_three_trolleys,
  (
    select bool_and(
      jsonb_array_length(day_item -> 'products') = 1
      and day_item -> 'products' -> 0 ->> 'product_code' = 'CLOTHES'
    )
    from jsonb_array_elements(payload -> 'days') day_item
  ) as clothes_only_schedule
from millbrook;

-- Expected: one schedule history revision for MILLBROOK.
select jsonb_array_length(
  public.get_customer_schedule_history(
    (
      select customer_id
      from public.customers
      where customer_name = 'MILLBROOK'
    )
  ) -> 'items'
) as millbrook_history_revisions;

-- Expected: three Distribution schedule days for MILLBROOK. The payload is
-- explicitly marked as a default customer route, not an actual daily route.
with distribution_payload as (
  select public.get_customer_distribution_overview(
    (
      select customer_id
      from public.customers
      where customer_name = 'MILLBROOK'
    ),
    date '2026-07-30'
  ) as payload
)
select
  jsonb_array_length(payload -> 'days') as distribution_day_count,
  payload -> 'route_semantics' ->> 'source' as route_source,
  payload -> 'route_semantics' ->> 'actual_daily_route_may_differ'
    as actual_daily_route_may_differ
from distribution_payload;

-- Expected: all nine public RPCs exist and are executable by authenticated.
select
  p.proname as function_name,
  has_function_privilege(
    'authenticated',
    p.oid,
    'EXECUTE'
  ) as authenticated_can_execute
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'get_customer_read_capabilities',
    'get_customer_directory',
    'get_customer_overview',
    'get_customer_weekly_schedule',
    'get_customer_schedule_history',
    'get_clothes_weekly_planner',
    'get_mop_weekly_planner',
    'get_customer_distribution_overview',
    'get_distribution_weekly_planner'
  )
order by p.proname;

rollback;
