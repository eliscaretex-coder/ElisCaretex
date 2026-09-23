-- =====================================================================
-- ElisCaretex V2
-- Validation: 202607310001_customer_route_visual_read_api_validation.sql
-- Read-only. The transaction is rolled back at the end.
-- =====================================================================

begin;

-- Resolve the already-linked active ADMIN account before changing to the
-- authenticated database role. No user or role data is modified.
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

-- Expected unchanged totals:
-- Clothes planner rows = 359
-- MOP planner rows = 146
select
  public.get_clothes_weekly_planner(
    date '2026-07-30', null, null
  ) ->> 'total_count' as clothes_planner_rows,
  public.get_mop_weekly_planner(
    date '2026-07-30', null, null
  ) ->> 'total_count' as mop_planner_rows;

-- Expected:
-- - every item contains the route_visual_color key;
-- - coloured rows are greater than zero;
-- - invalid colour values are zero.
with clothes_payload as (
  select public.get_clothes_weekly_planner(
    date '2026-07-30', null, null
  ) as payload
),
clothes_items as (
  select item
  from clothes_payload,
       jsonb_array_elements(payload -> 'items') as item
)
select
  count(*) as total_items,
  count(*) filter (where item ? 'route_visual_color') as items_with_visual_key,
  count(*) filter (
    where nullif(item ->> 'route_visual_color', '') is not null
  ) as items_with_route_colour,
  count(*) filter (
    where nullif(item ->> 'route_visual_color', '') is not null
      and (item ->> 'route_visual_color') !~ '^#[0-9A-Fa-f]{6}$'
  ) as invalid_route_colours
from clothes_items;

with mop_payload as (
  select public.get_mop_weekly_planner(
    date '2026-07-30', null, null
  ) as payload
),
mop_items as (
  select item
  from mop_payload,
       jsonb_array_elements(payload -> 'items') as item
)
select
  count(*) as total_items,
  count(*) filter (where item ? 'route_visual_color') as items_with_visual_key,
  count(*) filter (
    where nullif(item ->> 'route_visual_color', '') is not null
  ) as items_with_route_colour,
  count(*) filter (
    where nullif(item ->> 'route_visual_color', '') is not null
      and (item ->> 'route_visual_color') !~ '^#[0-9A-Fa-f]{6}$'
  ) as invalid_route_colours
from mop_items;

-- Select one customer through the protected planner payload, then verify that
-- every returned weekly day also contains the visual colour key. This avoids
-- direct authenticated SELECT access to public.customers.
with planner_payload as (
  select public.get_clothes_weekly_planner(
    date '2026-07-30', null, null
  ) as payload
),
selected_customer as (
  select (item ->> 'customer_id')::uuid as customer_id
  from planner_payload,
       jsonb_array_elements(payload -> 'items') as item
  order by item ->> 'customer_name'
  limit 1
),
weekly_payload as (
  select public.get_customer_weekly_schedule(
    selected_customer.customer_id,
    date '2026-07-30'
  ) as payload
  from selected_customer
),
weekly_days as (
  select day_item
  from weekly_payload,
       jsonb_array_elements(payload -> 'days') as day_item
)
select
  count(*) as returned_days,
  count(*) filter (where day_item ? 'route_visual_color')
    as days_with_visual_key,
  count(*) filter (
    where nullif(day_item ->> 'route_visual_color', '') is not null
      and (day_item ->> 'route_visual_color') !~ '^#[0-9A-Fa-f]{6}$'
  ) as invalid_route_colours
from weekly_days;

-- Expected: the existing RPCs remain executable by authenticated.
select
  p.proname as function_name,
  has_function_privilege('authenticated', p.oid, 'EXECUTE')
    as authenticated_can_execute
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'get_customer_weekly_schedule',
    'get_clothes_weekly_planner',
    'get_mop_weekly_planner'
  )
order by p.proname;

rollback;
