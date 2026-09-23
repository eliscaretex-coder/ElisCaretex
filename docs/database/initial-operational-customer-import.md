# Initial Operational Customer Import

## Import date

2026-07-30

## Source

`CentralDB(14).xlsx`

## Status rules

The legacy `Active` column was not the final source of truth.

Eleven owner-confirmed inactive customers are imported with:

- `active = false`;
- a deactivation timestamp;
- a deactivation reason;
- no active schedule revision.

They remain available for management history and audit, but are excluded from
active operational views.

## Schedule history

Each active customer receives:

- schedule version number 1;
- source code `LEGACY_IMPORT`;
- status `PUBLISHED`;
- effective date 2026-07-30;
- the source row references in metadata.

Published children become immutable. Future changes must be made through a new
draft revision.

## Trolley ownership

Every trolley requirement has:

- one owner product;
- one structured trolley type;
- a positive quantity;
- an explicit empty-trolley flag;
- one or more served-product mappings.

MILLBROOK and WOODLAWNS are CLOTHES-only. Their legacy MOP-column value is
owned by CLOTHES and does not create a MOP service.

## Shared trolleys

The data model supports a single requirement mapped to CLOTHES and MOP.

The legacy source does not reliably distinguish a shared trolley from a
customer that simply has no separate Mop trolley. Therefore, the initial import
does not create shared mappings unless explicitly confirmed later.
