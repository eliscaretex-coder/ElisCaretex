# Data Model V2 — Foundation

## Staff

Operational staff/authentication are separated through governed master and role records:

```text
auth.users
    |
    v
staff_members
    |
    +-- staff_roles
```

`production_staff` is explicit. System-only accounts are not inferred into the production workforce.

## Customer schedules

Current versioned schedule structure includes:

```text
customers
    |
    +-- customer_schedule_versions
            |
            +-- customer_schedule_days
                    |
                    +-- customer_schedule_products
                    +-- customer_schedule_trolley_requirements
```

Published schedule history is versioned; operational operators do not directly rewrite it.

## Production Roster / Actual work

```text
production_roster_versions
    |
    +-- production_roster_entries   planned/versioned

work_sessions                       actual operational work
```

Planned and Actual evidence are intentionally separate.

## Production Flow

```text
production_flow_items
    |
    +-- production_flow_events
    +-- production_flow_external_batches (ABS etc.)
```

Production Flow is the shared cross-module identity/trace spine. Source operational rows remain authoritative.

## Trolleys

```text
trolley_types
    |
    +-- trolleys
            |
            +-- trolley_customer_stays
            |       |
            |       +-- sent_on
            |       +-- received_on
            |       +-- outbound_customer_id
            |       +-- received_from_customer_id
            |       +-- exception_type
            |
            +-- trolley_events
```

### Normal receipt

```text
sent_on = known/inferred custody start
received_on = actual Sorting receipt date
exception_type = NULL
review_status = NOT_REQUIRED
```

### Receipt without outbound record

```text
sent_on = NULL
received_on = actual receipt date
exception_type = MISSING_OUTBOUND_RECORD
review_status = NOT_REQUIRED
```

The missing send date is never invented. The trolley may be physically available while the history preserves that outbound evidence was missing.

### Customer mismatch

The database preserves both values:

```text
outbound_customer_id = Customer A
received_from_customer_id = Customer B
status = RECEIVED
exception_type = CUSTOMER_MISMATCH
review_status = NOT_REQUIRED
```

The mismatch is history/audit evidence, not a review task.

## Operational planning reports

```text
operational_data_reports
```

Current implemented type:

```text
CUSTOMER_TROLLEY_REQUIREMENT
```

The report stores published-plan snapshot, operator-reported expectation, observed trolley evidence and review outcome. It never directly edits Customer Schedule.
