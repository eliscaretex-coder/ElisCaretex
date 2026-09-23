# Physical Trolley Workflow

## Current confirmed flow

```text
Finish / MOP Production
-> physical trolley assigned to processed customer
-> next Distribution business date inferred
-> trolley moves through inferred production/customer custody state
-> Sorting scans trolley code and confirms customer
-> customer stay closes
-> trolley becomes AVAILABLE at Elis Laundry
```

Current delivery timing is an explicit inference until Distribution receives portable scanning equipment.

## Initial registry state

The imported trolley master contains identity/type/service status but no reliable current location.

```text
Source Available -> LOCATION_UNCONFIRMED
Source Out of Service -> OUT_OF_SERVICE
```

The first reliable operational action establishes location/custody evidence.

## Production assignment

Production assignment is owned by Finish or MOP Production. The database validates trolley identity/status, open stays, active customer and the published customer/product/date schedule lineage.

Current inferred custody fields include:

```text
production_business_date
planned_delivery_on = next Distribution business date
sent_on = planned_delivery_on
custody_start_source = PRODUCTION_NEXT_DAY_INFERENCE
production_area_code = FINISH or MOP
```

The inference provenance must remain visible and must not later be rewritten as if a Distribution scan had occurred.

## Distribution without portable scanning

Distribution continues to follow the published Default Schedule. The current project does not use a manual Distribution Daily Plan.

Until portable scanning exists:

- no Distribution action falsely confirms delivery;
- next-business-day custody start is inferred from production;
- Sunday is skipped;
- future actual scans may supersede the inference while preserving original provenance.

## Sorting arrival with open stay

Sorting scans the trolley and confirms the actual customer represented by the dirty contents.

When customer matches:

```text
received_on = Sorting Business Date
status = RECEIVED
exception_type = NULL
review_status = NOT_REQUIRED
trolley status = AVAILABLE
```

## Sorting arrival without outbound

If there is no open stay:

```text
sent_on = NULL
outbound_customer_id = NULL
received_from_customer_id = confirmed customer
exception_type = MISSING_OUTBOUND_RECORD
status = RECEIVED
review_status = NOT_REQUIRED
```

No outbound/send date is fabricated. The fact is visible in Tracking/history only.

## Customer mismatch

If the confirmed Sorting customer differs from the stored outbound customer:

```text
outbound_customer_id is preserved
received_from_customer_id is preserved
exception_type = CUSTOMER_MISMATCH
status = RECEIVED
review_status = NOT_REQUIRED
```

This is a historical custody discrepancy, not an operational review queue. Migration 043 revoked browser access to the old trolley reconciliation queue/actions.

## Bad planned trolley requirement

A different workflow handles the case where an operator knows the published customer trolley quantity/type is wrong.

```text
MOP/Finish production screen
-> Report trolley plan
-> server snapshots published requirement + scanned trolley evidence
-> operational_data_reports status PENDING
-> ADMIN/MANAGER/PLANNER review in Customers
-> official schedule correction uses normal versioned Customer Studio workflow
-> report marked RESOLVED or REJECTED with notes
```

The report itself never changes the published schedule.

## Standalone Trolleys module boundary

The Trolleys page owns consultation/master tasks:

- Tracking;
- Locations;
- Trolley Master;
- Trolley Types;
- historical lifecycle facts.

It does not duplicate Finish/MOP assignment or Sorting receipt.
