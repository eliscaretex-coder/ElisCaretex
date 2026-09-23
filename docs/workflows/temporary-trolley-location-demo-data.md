# Temporary Physical Trolley Location Demo Data

**Status:** TEMPORARY / DEVELOPMENT ONLY  
**Source:** `CentralDB (1)(4).xlsx`, sheet `WashItems`  
**Marker:** `TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1`

## Decision

The Physical Trolleys module is a consultation and master-data surface. To
review the current-location presentation before Finish, Mop Production and
Sorting are implemented, temporary data may be loaded into Development.

The demo uses real trolley codes and trolley/customer associations observed in
`WashItems`. It does not claim that those records represent the current
physical custody state.

## Synthetic fields

The following are deliberately generated for presentation testing:

- current location;
- location start date;
- days at location;
- warning and overdue examples.

## Removal requirement

The demo must be removed before real operational trolley testing. Use the
paired removal script. Do not convert this seed into a migration.
