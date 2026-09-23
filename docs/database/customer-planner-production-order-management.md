# Customer Planner Production Order Management

**Implemented:** 2026-08-03  
**Migration:** `202608030001_customer_planner_production_order_management.sql`

## Problem

`customer_schedule_products.production_order` is stored inside each customer schedule revision, but its operational meaning is cross-customer: it defines the position of one customer relative to every other customer for the same product service and production weekday.

The original Customer Studio allowed the field to remain null, and the weekly planner had no controlled cross-customer reorder operation.

## Controlled APIs

### `save_customer_schedule_draft_with_auto_orders`

This function wraps the complete-document schedule save API.

After the normal draft validation and save, it assigns `max(current production order) + 1` to every active draft product whose order is null. Assignment is serialized by product, weekday and effective date.

The revision `row_version` is advanced after child assignment so the frontend receives the correct optimistic concurrency token.

### `publish_customer_schedule_draft_with_order_normalization`

This function performs a final conflict check immediately before publication.

If the draft order is null or is already occupied by another effective published customer, the function appends the customer to the current sequence. This closes the concurrency gap between draft save and final confirmation.

### `reorder_customer_planner_day`

The browser submits the complete ordered day as customer IDs plus the schedule version ID currently displayed for each customer.

The function:

1. validates role, product, weekday, effective date and reason;
2. locks the product/day/effective-date reorder operation;
3. confirms that browser item count equals the database item count;
4. confirms every customer and expected schedule version;
5. rejects duplicate customer IDs and open schedule edits;
6. creates a replacement draft only for a customer whose order changes;
7. updates only the target product order in that draft;
8. publishes the replacement schedule revision;
9. records one batch audit entry;
10. returns the refreshed complete planner.

All changed customer revisions are committed or rolled back together.

## Security

The new APIs use `SECURITY DEFINER`, an explicit search path and the existing `require_customer_schedule_edit_role()` guard.

Only `authenticated` may execute the new browser-facing functions, and the functions internally require one of:

- `ADMIN`
- `MANAGER`
- `PLANNER`

The older browser save and publish wrappers are revoked from `authenticated` so the order controls cannot be bypassed.

## Published immutability

The reorder API never updates a published `customer_schedule_products` row. It clones the effective published customer schedule into a working revision, updates the cloned product order, and publishes that replacement revision through the existing controlled publication function.

## Frontend safeguards

Drag-and-drop requires the complete unfiltered day. The frontend disables reorder when search is active and on historical effective dates. It sends all items for the selected service and weekday, updates optimistically, then replaces the browser state with the authoritative planner returned by PostgreSQL.
