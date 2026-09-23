# Staff Master UI — 2026-08-04

## Page

```text
frontend/pages/staff.html
```

## Main directory

The directory provides:

- total, active, inactive, roster-eligible and review-required counts;
- Active, Inactive, All and Import Review filters;
- Morning and Evening filters;
- search by name, employee code, role or table;
- primary work assignment;
- COVER capability;
- training indicators;
- joined and deactivated dates;
- controlled Edit, Deactivate and Reactivate actions.

## Editor

The editor keeps the primary role separate from COVER capability. The confirmed COVER options are:

```text
Team Leader
Sorting Area
Supervisor
```

Training controls are explicit Yes/No checkboxes. Empty legacy values have already been imported as No.

## Lifecycle

There is no Delete action. Deactivate and Reactivate use separate confirmation flows with audit reasons.

## Roster relationship

This screen defines who exists and their normal work context. It does not assign staff to a specific business date. Daily and weekly assignments belong to the future Production Roster.
