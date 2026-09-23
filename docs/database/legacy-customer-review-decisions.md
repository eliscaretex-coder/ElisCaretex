# Legacy Customer Review Decisions

## Confirmed decisions recorded

- 11 customers are inactive, including SKIBBEREEN and ST GABRIEL.
- ST JOSEPHS / Tuesday: `TrolleyMop = 5` means 5 Small Mop trolleys.
- OUR LADY OF LOURDES / Wednesday: `QtyClothes = 1` means 1 Medium Clothes trolley.
- ST CATHERINES / Tuesday, Thursday and Saturday: legacy value `74` in `TrolleyMop` is ignored because the customer has no Mop service.
- All proposed Mop variant mappings were accepted, including BAG, MANORHAMILTON and SCRUB SUITS.
- Route display names and colours come from the route master.

## Remaining blocker

MILLBROOK and WOODLAWNS are CLOTHES-only customers, but each of their schedule rows contains:

- `QtyClothes = 2M`
- `TrolleyMop = 1M`

The import must not guess whether the extra `1M` is:

1. an additional Clothes trolley;
2. an incorrect legacy value that must be ignored; or
3. evidence that the customer should also have a Mop service.

The operational import remains blocked until this is confirmed.

## Shared trolley policy

The legacy import does not infer that a Clothes trolley also serves Mop merely because the Mop trolley field is empty. Explicit requirements are imported with their source owner. A shared mapping can be added later through the controlled Customer Schedule interface without changing the total trolley count.
