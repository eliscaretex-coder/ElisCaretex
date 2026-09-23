# Operational Data Correction Feedback

## Status

Partially implemented. The first implemented report type is **Customer trolley requirement** through Migration 043.

## Purpose

Operational staff must be able to flag protected planning information that appears wrong without directly editing Customer Master or a published Customer Schedule.

Current implemented example:

- planned trolley quantity is wrong;
- planned trolley type is wrong.

Future report types may cover production order/instructions or other protected planning data, but they must reuse the same governance approach rather than giving operators edit permission.

## Current trolley-requirement workflow

```text
MOP Production now
(Finish Production later)
-> Report trolley plan
-> enter believed correct quantities/types
-> required reason
-> scanned trolley evidence is snapshotted server-side
-> PENDING Operational Report
-> ADMIN/MANAGER/PLANNER queue in Customers
-> reviewer corrects official Customer Schedule through normal versioned workflow or rejects the report
-> report marked RESOLVED or REJECTED with required notes
```

## Governance rules

- Operators do not directly edit published Customer Schedule.
- Server derives customer/product/date/Production Flow/schedule lineage.
- Server snapshots the authoritative published trolley requirement.
- Reported trolley types must be active and allowed in Customer Schedule.
- A report identical to the current published plan is rejected.
- Browser roles have no direct table access to `operational_data_reports`.
- Review roles are exactly the existing Customer Schedule edit roles: ADMIN, MANAGER, PLANNER.
- Review does not auto-publish a Schedule change.
- History/audit remains preserved after the schedule changes.

## Current statuses

```text
PENDING
RESOLVED
REJECTED
```

Finish V2 must reuse this mechanism for FINISH/CLOTHES trolley-plan issues.
