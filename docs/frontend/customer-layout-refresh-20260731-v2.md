# Customer Layout Refresh v2 — 2026-07-31

## Status

Prepared and statically validated. Database execution and browser validation against `ElisCaretex-dev` remain pending.

## Objective

Make the ElisCaretex V2 Customer screen visually familiar to users of the legacy Customer Weekly Planner without weakening the V2 security, audit or schedule-versioning design.

The legacy application is used as a visual and interaction reference only. The V2 database remains authoritative.

## Included files

```text
frontend/pages/customers.html
frontend/assets/css/customers.css
frontend/assets/js/customers.js
supabase/migrations/202607310001_customer_route_visual_read_api.sql
supabase/tests/202607310001_customer_route_visual_read_api_validation.sql
```

## Planner changes

- Customer cells use the route master colour as a soft background tint.
- A route-colour dot appears beside each customer.
- The colour is also shown in List view.
- Day header colours remain separate from route colours.
- Production order remains beside the customer name.
- Trolley summary remains beside the customer.
- Operational alerts remain visible.
- No colour is invented when the route master has no valid colour.

The frontend accepts only a valid six-digit hexadecimal value before applying an inline colour.

## Customer Studio changes

Clicking a customer opens a weekly studio closer to the legacy editing layout:

- Monday through Saturday are always visible;
- Sunday is included when a published schedule uses it;
- scheduled days show `ON LIST`;
- unscheduled days show `OFF`;
- each active day shows its route colour;
- product rows show service, production order, quantity plan, trolley plan, variants and instructions;
- route and delivery fields are displayed only when the current role already has Distribution permission;
- non-Distribution roles see permission-controlled placeholders instead of protected route details;
- Customer and revision information remains separate from per-day schedule fields.

All controls are currently read-only. They are a visual preparation for future controlled schedule editing.

## Protected revision behaviour

The screen explicitly states that the selected schedule is a published revision.

This package does not save schedule changes. The future workflow remains:

```text
Published revision
→ Create Draft
→ Edit days, products and trolleys
→ Compare changes
→ Enter reason
→ Publish new revision
```

The previous published revision must remain historical and must not be overwritten.

## Route-colour Read API migration

Migration `202607310001_customer_route_visual_read_api.sql` replaces the existing definitions of:

```text
get_customer_weekly_schedule()
get_clothes_weekly_planner()
get_mop_weekly_planner()
```

Their signatures and role checks remain unchanged.

The only new non-Distribution visual field is:

```text
route_visual_color
```

It is derived from:

```text
distribution_routes.route_color
```

through the schedule day's existing `default_route_id`.

The migration does not return route IDs, route codes, route names, delivery order, delivery windows or Distribution instructions through the Clothes/MOP RPCs.

For users who already have `can_view_distribution`, the modal uses the existing protected `get_customer_distribution_overview()` RPC to show route code/name and delivery day.

## Static validation completed

- `customers.js` passed `node --check`.
- HTML contains no duplicate IDs.
- Existing RPC names and Customer Master write parameters were retained.
- No frontend `.from("table")` access was introduced.
- Route colours are validated before use in inline CSS.
- Migration contains three balanced `CREATE OR REPLACE FUNCTION` definitions.
- Validation test uses protected RPC payloads and does not read `public.customers` after switching to `authenticated`.

## Database validation checklist

1. Confirm Migration 008 final validation status before applying new development migrations.
2. Run `202607310001_customer_route_visual_read_api.sql` in the Development project.
3. Run `202607310001_customer_route_visual_read_api_validation.sql`.
4. Confirm Clothes rows remain `359` for effective date `2026-07-30`.
5. Confirm MOP rows remain `146` for effective date `2026-07-30`.
6. Confirm `items_with_visual_key = total_items`.
7. Confirm `items_with_route_colour > 0`.
8. Confirm `invalid_route_colours = 0`.
9. Confirm all three RPCs remain executable by `authenticated`.
10. Do not add direct table grants.

## Browser validation checklist

1. Open `frontend/pages/customers.html` through Live Server.
2. Confirm Schedule Planner opens first.
3. Confirm customer rows use route-colour shading.
4. Compare several route colours with the legacy planner.
5. Confirm white or missing colours remain readable.
6. Confirm Clothes and MOP toggles work.
7. Confirm Planner and List toggles work.
8. Confirm Search, Reload and Print work.
9. Click a Clothes-only customer and inspect the six-day studio.
10. Click a Clothes + MOP customer and confirm both product sections appear on applicable days.
11. Confirm unscheduled days are visible as `OFF` and cannot be changed.
12. Confirm all fields are read-only.
13. Confirm the protected-revision message is visible.
14. Confirm an ADMIN can see authorized route/delivery details.
15. Confirm an operational non-Distribution role receives no route code/name or delivery details.
16. Confirm no browser console errors are present.
17. Confirm MILLBROOK and WOODLAWNS still show Clothes only.

## Pending future work

This package does not implement schedule saving. The next controlled backend work must still provide draft creation, draft updates, comparison, publication, cancellation and restoration with audit records and optimistic concurrency.
