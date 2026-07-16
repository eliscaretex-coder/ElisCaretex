# Data Model V2 — Foundation

## Staff

Only operational information is stored:

```text
auth.users
    |
    v
staff_members
    |
    +-- staff_roles
```

No UserPrivate or DriverPrivate equivalent is created.

## Customer schedules

```text
customers
    |
    +-- customer_schedule_versions
            |
            +-- customer_schedule_items
                    |
                    +-- product_types
```

A schedule is effective for a date range. Overlapping active versions for the
same customer and production weekday are blocked by the database.

## Roster

```text
roster_periods
    |
    +-- roster_assignments     planned work
             |
             +-- work_sessions actual work
```

## Trolleys

```text
trolleys
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
sent_on = 2026-07-01
received_on = 2026-07-08
days_out = 7
```

### Receipt without outbound record

```text
sent_on = null
received_on = 2026-07-08
exception_type = MISSING_OUTBOUND_RECORD
```

The missing send date is never invented.

### Customer mismatch

The database preserves both values:

```text
outbound_customer_id = Customer A
received_from_customer_id = Customer B
status = REVIEW_REQUIRED
exception_type = CUSTOMER_MISMATCH
```
