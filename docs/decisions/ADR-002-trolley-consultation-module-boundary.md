# ADR-002 — Physical Trolleys is a consultation and master-data module

**Original date:** 2026-08-04  
**Amended:** 2026-08-12  
**Status:** Accepted — amended by Migration 043 history-only exception policy

## Context

Physical trolley movements are created by the operational workflow where the physical event occurs:

- Finish records the physical trolley used for a Clothes customer;
- MOP Production records the physical trolley used for a MOP customer;
- Sorting scans the returned trolley and confirms the originating customer;
- Distribution portable scanning is not available yet.

Duplicating those operational actions on the standalone Trolleys page would create competing workflows and inconsistent custody evidence.

## Decision

The standalone **Trolleys** page is limited to:

1. trolley-code Tracking and lifecycle history;
2. current-location consultation grouped by Elis Laundry/customer/unconfirmed state;
3. complete Trolley Master registry;
4. controlled registration, service-status changes and retirement;
5. Trolley Type Master consultation and ADMIN/MANAGER management;
6. historical lifecycle facts, including missing-outbound/customer-mismatch evidence.

The standalone Trolleys page does **not** own Finish/MOP production assignment or Sorting receipt.

### Exception-policy amendment — 2026-08-12

`MISSING_OUTBOUND_RECORD` and `CUSTOMER_MISMATCH` are historical custody facts, not operational tasks. They remain in stays/events/audit history, but the browser does not expose an exception-review queue or review action.

No missing send date is invented and no old customer is silently rewritten.

Operational bad planning data is handled separately through `operational_data_reports`, for example when a MOP/Finish operator reports that the published trolley quantity/type for a customer is wrong. That report is reviewed by Customer Schedule editors and never directly mutates the published schedule.

## Distribution handoff

The prepared Distribution handoff remains technical history for future portable scanning. It must not evolve into a manual Distribution Daily Plan. Current delivery/custody start remains an explicit next-business-day inference from production until a real Distribution scan can confirm the event.

## Consequences

- Operational entry happens once, in the correct workflow.
- Trolleys remains a reliable consultation/master surface.
- Trolley identity/history is preserved through retirement.
- Historical discrepancies remain visible without creating an unrealistic human review queue.
- Bad Customer Schedule trolley planning has a separate governed report/review workflow.
