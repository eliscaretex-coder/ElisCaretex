# Physical Trolley Lifecycle Management

## Status

Base management migration `202608030006_physical_trolley_lifecycle_management.sql` was applied and its corrected V2 validation passed in Development.

The production/Sorting alignment and trolley registry are prepared in:

```text
202608040001_trolley_production_sorting_flow.sql
202608040001_physical_trolley_registry_import.sql
```

Their real-environment SQL and browser evidence remain pending.

## Core entities reused

```text
trolley_types
trolleys
trolley_customer_stays
trolley_events
```

The one-open-stay guarantee remains:

```text
trolley_one_open_stay_idx
```

## Current status model

```text
LOCATION_UNCONFIRMED
AVAILABLE
IN_PRODUCTION
AT_CUSTOMER
OUT_OF_SERVICE
RETIRED
```

`LOCATION_UNCONFIRMED` is required for registry imports that do not identify current physical location.

## Custody provenance

A trolley stay can originate from:

```text
PRODUCTION_NEXT_DAY_INFERENCE
DISTRIBUTION_CONFIRMED
MANUAL_DELIVERY_CONFIRMATION
SUPERVISOR_CORRECTION
```

The first operational implementation uses `PRODUCTION_NEXT_DAY_INFERENCE` because Distribution has no portable scanner yet.

Production-created stays preserve schedule lineage:

```text
source_schedule_version_id
source_schedule_day_id
source_schedule_product_id
```

This proves which published customer plan was used when the trolley was assigned.

## Effective status

The stored trolley status becomes `IN_PRODUCTION` at production assignment. Read models derive:

```text
open stay and sent_on > current_date  → IN_PRODUCTION
open stay and sent_on <= current_date → AT_CUSTOMER
no open stay after Sorting arrival     → AVAILABLE
```

Out-of-service and retired states always take precedence.

## Days at customer

Current calculation:

```text
received_on - sent_on
```

For production-created stays, `sent_on` initially equals the inferred next Distribution date. Reports must display `custody_start_source` so the inferred nature remains visible.

## Registry import

Batch key:

```text
CENTRALDB_TROLLEY_2026_08_04
```

Expected counts:

```text
633 total
264 SMALL
157 MEDIUM
212 LARGE
631 LOCATION_UNCONFIRMED
2 OUT_OF_SERVICE
```

The seed is idempotent by trolley code and retains source row metadata.

## Security

The browser does not receive direct authenticated table access. Controlled `SECURITY DEFINER` RPC functions enforce role and schedule context.

Finish and Mop production users receive only customers scheduled for their applicable product and selected business date. Generic Customer Master or Distribution-sensitive fields are not exposed through this production selector.

## Audit events

Current events include:

```text
TROLLEY_REGISTERED
ASSIGNED_IN_PRODUCTION
SENT_TO_CUSTOMER
DELIVERY_CONFIRMED
ARRIVED_AT_SORTING
ARRIVED_AT_SORTING_WITHOUT_OUTBOUND
CUSTOMER_MISMATCH
EXCEPTION_REVIEW_STARTED
EXCEPTION_REOPENED
EXCEPTION_REVIEWED
MARKED_OUT_OF_SERVICE
RETURNED_TO_SERVICE
```

## Known limitation

The current delivery date is inferred. A later portable Distribution workflow should append actual delivery/collection evidence and preserve both the original inference and the correction lineage.
