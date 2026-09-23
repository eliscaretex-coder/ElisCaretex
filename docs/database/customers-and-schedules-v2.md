# Customers and Schedules V2

## Status

This document describes the database foundation introduced by:

```text
supabase/migrations/202607300002_customers_and_schedules.sql
```

The migration creates the schema only. Legacy customers and schedules are not imported by this migration.

## Confirmed business rules

- Customers without a valid legacy service type are inactive, even if the legacy `Active` column was not updated.
- Inactive customers are excluded from operational views but retained for history and audit.
- Customer service eligibility and the products scheduled on a particular day are separate concepts.
- A `CLOTHES + MOP` customer may have:
  - Clothes trolley requirements only;
  - Mop trolley requirements only;
  - separate trolley requirements for both products;
  - one trolley shared by both products;
  - no planned trolley requirement.
- A trolley shared by Clothes and Mop is stored once, may serve both scheduled products, and has one owner product. The default owner is Clothes.
- The planned trolley total counts each requirement once, including shared requirements.
- Schedule trolley types are restricted to `SMALL`, `MEDIUM`, `LARGE` and `GRAY`.
- An empty trolley is a separate boolean property, not a free-text trolley size.
- Route display name and route color are attributes of the route master record.
- The customer schedule stores a default route reference only.
- Actual daily Distribution assignments, collection routes, ad hoc routes and support routes will be implemented in the Distribution module. They must not rewrite the customer production schedule.
- Distribution-only information is exposed only through a role-protected Distribution view.

## Main structure

```text
customers
  |
  +-- customer_product_services
  |
  +-- customer_schedule_versions
        |
        +-- customer_schedule_days
              |
              +-- customer_schedule_products
              |     |
              |     +-- customer_schedule_product_variants
              |
              +-- customer_schedule_trolley_requirements
                    |
                    +-- customer_schedule_trolley_requirement_products
```

## Trolley ownership and sharing

A trolley requirement has one owner scheduled product.

### Separate Clothes and Mop trolleys

```text
Requirement 1
Owner: CLOTHES
Quantity: 2
Type: MEDIUM
Serves: CLOTHES

Requirement 2
Owner: MOP
Quantity: 1
Type: SMALL
Serves: MOP

Distribution total: 3 trolleys
```

### Shared trolley

```text
Requirement 1
Owner: CLOTHES
Quantity: 1
Type: MEDIUM
Serves: CLOTHES, MOP

Distribution total: 1 trolley
Finish display: 1M
Mop display: no additional trolley
```

The mapping table records all products served. The owner controls which production view displays the requirement.

## Schedule lifecycle

```text
DRAFT
  |
  v
PUBLISHED
  |
  v
SUPERSEDED
```

A version may also be `CANCELLED`.

Published and historical schedule children are immutable. A previous revision is restored by copying it into a new draft.

## Protected views

### `v_active_customers`

Basic active customer information for authenticated operational users.

### `v_finish_current_schedule`

Current Clothes schedule information. Distribution-only fields are not included.

### `v_mop_current_schedule`

Current Mop schedule information. Shared trolleys owned by Clothes are not duplicated in the Mop trolley total.

### `v_distribution_current_schedule`

Current default Distribution schedule for authorized roles. It includes the default route, estimated weight, stops, delivery information and the trolley total counted once.

### `v_customer_management`

General customer management information for authorized management roles. Distribution-only fields are excluded.

### `v_customer_distribution_management`

Distribution-specific customer fields for explicitly authorized Distribution and management roles.

### `v_customer_schedule_history`

Schedule revision history for authorized management and audit roles.

## Next database step

The next migration should add:

- transactional draft content saving from a validated JSON payload;
- staging tables for the legacy Excel import;
- parsing and validation of legacy trolley expressions;
- legacy route normalization;
- Mop product variant import;
- migration review and reconciliation views;
- controlled initial publication of imported schedules.
