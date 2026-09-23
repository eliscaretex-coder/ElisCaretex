# Customer Schedule Management API

**Migration:** `202607310002_customer_schedule_management_api.sql`  
**Environment:** Development  
**Status after package creation:** Prepared — pending Supabase execution and validation

## Purpose

This migration introduces the controlled backend workflow required by the Customer Studio interface:

```text
Published Revision
        |
        v
Create Draft
        |
        v
Edit complete weekly draft
        |
        v
Compare with base revision
        |
        v
Publish with change reason
```

Published and historical schedule children remain immutable. Only a `DRAFT` revision can be changed.

## Roles

Schedule management is available only to active authenticated staff with one of these roles:

```text
ADMIN
MANAGER
PLANNER
```

Operational users may continue to read only the planners allowed by their Customer Read API capabilities.

## Public RPC functions

```text
get_customer_schedule_reference_data()
get_customer_schedule_management_state()
create_customer_schedule_management_draft()
save_customer_schedule_draft()
compare_customer_schedule_draft()
publish_customer_schedule_draft()
cancel_customer_schedule_draft()
restore_customer_schedule_management_draft()
```

The existing `get_customer_read_capabilities()` result is extended with explicit draft, compare, publish, cancel and restore capabilities.

The older low-level schedule write functions are revoked from browser-authenticated callers. They remain internal building blocks used by the new `SECURITY DEFINER` wrappers, so the UI cannot bypass required reasons or optimistic concurrency.

## Draft save model

`save_customer_schedule_draft()` accepts one complete weekly JSON document. It replaces only the children of the selected `DRAFT` revision inside one transaction.

The function validates in PostgreSQL:

- authenticated staff and management role;
- draft status;
- optimistic concurrency through `row_version`;
- active customer;
- valid effective period;
- unique weekdays;
- at least one product per active day;
- customer service eligibility;
- active product types and product variants;
- active default routes allowed in Customer Schedules;
- approved trolley types;
- positive trolley quantities;
- trolley owner and served-product relationships;
- shared trolley mapping to scheduled products on the same day.

The browser cannot bypass these rules by changing JavaScript or request data.

## Audit

Every successful draft save writes:

```text
action = SAVE_CUSTOMER_SCHEDULE_DRAFT
entity_table = customer_schedule_versions
old_data = complete draft snapshot before the save
new_data = complete draft snapshot after the save
reason = required user reason
source_application = caller-provided source
```

Draft creation, publication and cancellation continue to use the existing audited transactional functions.

## Optimistic concurrency

The frontend must send the current schedule version `row_version` when saving, publishing or cancelling a draft.

When another user has changed the draft, the API raises a concurrency error and instructs the caller to reload instead of silently overwriting newer work.

## Effective-date protection

The new Customer Studio API does not allow a manually created or restored draft to start before the current business date. This prevents the UI from rewriting a historical effective period.

Historical versions remain available for review and may be restored only into a new current or future draft.

## Validation

Run:

```text
supabase/tests/202607310002_customer_schedule_management_api_validation.sql
```

The validation performs:

```text
capability read
reference-data read
draft creation
complete document round-trip save
comparison
publication
second draft creation
second draft cancellation
function privilege validation
rollback
```

The test does not leave a customer revision, draft, child records or audit rows in the database.

## Frontend status

This migration prepares the backend. It does not yet activate editing controls in `customers.js`.

The next frontend package should connect the existing Customer Studio visual fields to these RPCs and must preserve the sequence:

```text
Create Draft -> Save Draft -> Compare -> Publish
```
