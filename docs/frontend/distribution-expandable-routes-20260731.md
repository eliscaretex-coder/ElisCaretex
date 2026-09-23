# Distribution Expandable Routes — 2026-07-31

## Status

Prepared and statically validated. Browser validation against `ElisCaretex-dev`
is pending.

## Purpose

Replace the flat Distribution schedule list with a route-centred operational
view that is familiar to users of the legacy Distribution application.

## Visual model

Each group represents:

```text
Delivery day + Default Customer Schedule route
```

The collapsed route header shows:

```text
Route display name
Route code
Delivery day
Route colour
Customer count
Stop units
Estimated KG
Planned trolley total
```

Expanding the group shows:

```text
Delivery order
Customer and customer code
Production day
Delivery time window
Eircode
Scheduled products
Estimated KG
Stop units
Trolley quantity and summary
Operational alerts
Day alerts
Distribution instructions
```

## Important semantics

This screen still represents the default route stored in the published Customer
Schedule. It is not an actual daily run.

Future daily Distribution runs may use routes such as:

```text
COLLECTION
AD_HOC
SUPPORT
```

Those actual assignments must not rewrite the Customer Schedule default route.

## Security

Data continues to be returned by the protected RPC:

```text
get_distribution_weekly_planner()
```

No direct table access was added.
No write function was added.
No published revision is changed.

## Browser validation checklist

1. Sign in with an ADMIN or authorized Distribution role.
2. Open Customers → Distribution.
3. Confirm that route/day bars are shown instead of one flat table.
4. Confirm that all groups start collapsed.
5. Expand route 610 and confirm the stops appear in delivery order.
6. Confirm that each route uses its master-data colour.
7. Test Search with a customer name and route code.
8. Test Delivery day filtering.
9. Test Route filtering.
10. Test Expand all and Collapse all.
11. Click a customer and confirm the weekly schedule modal opens.
12. Confirm that no editing or save action is offered in Distribution.
13. Test at a narrower browser width and confirm route metrics wrap correctly.
14. Confirm that the existing Schedule Planner and Customer Master tabs still work.
