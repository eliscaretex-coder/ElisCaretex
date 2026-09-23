# Legacy Customer Import Staging

## Purpose

This stage separates source loading from operational publication.

The legacy Excel data is preserved first, validated, and reviewed before it is
allowed to create active customers or published schedules.

## Source

`CentralDB(14).xlsx`

- `CustomerMaster`: 141 records
- `CustomerSchedule`: 417 records

## Confirmed rules

- Customers without `ServiceType` are inactive even when the legacy `Active`
  field still says `Yes`.
- Trolley requirements are optional.
- Approved customer-schedule trolley types are Small, Medium, Large and Gray.
- Empty trolley is a separate flag.
- A Clothes + Mop customer may have separate trolleys or one shared trolley.
- A shared trolley is counted once and has one owner product.
- Route name and route colour come from the route master.
- Distribution-only data must not be exposed to unauthorized operational roles.
- A daily Distribution route may differ from the customer default route and
  must not rewrite the production schedule.

## Why staging is required

The source contains information that cannot be converted safely without review:

- customer status conflicts;
- customers without schedules;
- route display-name and colour inconsistencies;
- trolley quantities without a trolley size;
- unusual Mop product descriptions.

No source value is discarded.
