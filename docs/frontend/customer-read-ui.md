# Customer Read UI

## Purpose

Provide a permission-aware, read-only interface for the imported Customer and
Production Schedule data.

## Pages

- Home: `frontend/index.html`
- Customer module: `frontend/pages/customers.html`

## Data access

The frontend does not join Customer tables directly.

It uses only the RPC functions created by migration
`202607300007_customer_read_api.sql`.

## Main views

### Customer Directory

Available to management and audit roles.

Includes:

- customer code and name;
- service eligibility;
- current published schedule summary;
- active or inactive status;
- Eircode;
- operational alert.

### Clothes Planner

Available only to roles with Clothes planner permission.

Includes:

- production day and order;
- customer;
- planned trolley requirements;
- Finish instructions;
- operational alert.

### Mop Planner

Available only to roles with Mop planner permission.

Includes:

- production day and order;
- customer;
- Mop products;
- planned trolley requirements;
- Mop instructions;
- operational alert.

### Distribution Planner

Available only to Distribution-authorized roles.

Includes:

- default route;
- delivery day, order and time;
- estimated kilograms and stops;
- planned trolleys;
- Distribution instructions.

The UI explicitly states that the actual daily route may differ from the
customer default route.

## Customer workspace

The available sections depend on role capabilities:

- Overview;
- Weekly Schedule;
- Distribution;
- History.

## Editing

No editing functions are present in this release.

Published schedules remain immutable. Editing will be introduced later through
a controlled draft, compare and publish workflow.
