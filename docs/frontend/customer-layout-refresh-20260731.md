# Customer Layout Refresh — 2026-07-31

## Status

Prepared and statically validated. Browser validation against the live Development Supabase project is still pending.

## Scope

This package changes only the Customer frontend presentation:

- `frontend/pages/customers.html`;
- `frontend/assets/css/customers.css`;
- `frontend/assets/js/customers.js`.

No database migration, RPC signature, permission, RLS policy or business rule is changed.

## Visual objective

The refreshed screen keeps the V2 security and module separation while using a visual structure familiar to users of the legacy Customer Weekly Planner:

- compact teal application header;
- teal planner title bar;
- toolbar order: Add Customer, Reload, Search, service toggle, view toggle and Print;
- denser weekly matrix with production days arranged horizontally;
- production order badge beside the customer name;
- trolley summary beside the customer;
- day-specific header colours;
- horizontal overflow contained inside the planner;
- left and right navigation arrows when the planner overflows;
- compact list and Customer Master tables;
- schedule detail modal presented as a Customer Studio-style day board;
- responsive behaviour for desktop, tablet and smaller screens.

## Behaviour retained

- Schedule Planner remains the first available Customer view.
- Clothes and MOP planners remain separate.
- Planner and List modes remain available.
- Clicking a customer still loads all production days through `get_customer_weekly_schedule()`.
- Customer Master remains a separate view.
- Add, edit, deactivate and reactivate continue to use controlled RPC functions.
- Distribution remains permission-controlled.
- Published schedules remain read-only in this interface.
- No direct table access was introduced.

## Added interaction

The Schedule Planner toolbar now shows `Add Customer` when `can_edit_customers` is true. It opens the existing controlled Customer Master form and does not create or edit schedule rows directly.

## Known visual limitation

The legacy planner colours customer cells using route colours. The current Clothes and MOP planner RPC payloads do not return the default route colour. This layout package therefore does not invent or approximate a route colour.

A future controlled read-API migration may expose the route display data when the permission model and operational meaning are confirmed. Route master data must remain derived from `distribution_routes`.

## Validation completed

- JavaScript syntax check passed with `node --check`.
- Customer page local asset paths passed.
- Direct Supabase table access was not added.
- Existing RPC function names were retained.

## Browser validation checklist

1. Open `frontend/pages/customers.html` through Live Server.
2. Confirm the Schedule Planner opens first.
3. Confirm Clothes and MOP toggles work.
4. Confirm Planner and List toggles work.
5. Confirm Search, Reload and Print work.
6. Confirm `Add Customer` appears only for a role with `can_edit_customers`.
7. Confirm the planner scroll arrows appear only when horizontal overflow exists.
8. Click a customer and confirm all production days load.
9. Open Customer Master and verify the existing lifecycle actions.
10. Confirm no browser console errors are present.
