# Distribution Schedule Alignment — 2026-08-03

## Decision

Distribution does not require a manually created daily plan. The published Customer Schedule is the operational default and delivery is deterministically derived from production day.

## Delivery rule

| Production | Delivery |
|---|---|
| Monday | Tuesday |
| Tuesday | Wednesday |
| Wednesday | Thursday |
| Thursday | Friday |
| Friday | Saturday |
| Saturday | Monday |
| Sunday | Monday, but Sunday production is not part of the standard operating week |

The database function `next_distribution_weekday` is the authoritative implementation.

## Separation of concerns

Customer Schedule owns:

- production weekday;
- default Route;
- delivery order;
- delivery window;
- trolley requirements;
- Distribution instructions.

Future Distribution Roster will own:

- business date;
- Route assignment to driver;
- support driver assignment;
- roster status and attendance-related execution context.

The roster must not rewrite Customer Schedule revisions.

## Migration 004 decommissioning

Migration 005 removes the Daily Plan API and preserves any accidental Daily Plan rows in renamed, inaccessible tables for traceability. These rows are not operational source data.
