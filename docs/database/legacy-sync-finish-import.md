# Legacy sync: historical Finish import

Status (2026-10-27): `202610260002` and `202610270001` **Applied** to `ElisCaretex-dev` by the
owner and **Validated** there with the rolled-back test files. `202610270002` (HOUSEHOLD as
ReWash, 2026-10-25 test day skipped) was **Applied** the same day by the owner and **Validated**
there (40/40). Both import switches are OFF. No import has run.

The sync is temporary. When the legacy apps stop, keep the imported production data and remove
the sync scaffolding (owner, 2026-10-27).

This is the database side of the Legacy Sync: a one-way, incremental, idempotent copy of
legacy Apps Script Finish Area entries into Finish V2. Apps Script stays the sender and holds
no Supabase key. All mapping and business rules live in Postgres.

Migrations:

- `supabase/migrations/202610260002_legacy_sync_identity_foundation.sql`: runs, record
  versions, insert-only legacy links, review queue (schema `integration`).
- `supabase/migrations/202610270001_legacy_sync_finish_historical_import.sql`: switch and
  pilot limit, owner-approved value maps, planner, dry run, importer, narrow Finish trigger
  change.
- `supabase/migrations/202610270002_legacy_sync_household_rewash_import.sql`: test-day skip,
  HOUSEHOLD routed to the ReWash ledger, ReWash planner and importer.

Validation (each file is one transaction, rolled back):
`supabase/tests/202610260002_legacy_sync_identity_foundation_validation.sql` (11),
`supabase/tests/202610270001_legacy_sync_finish_historical_import_validation.sql` (57, expects
`202610270002`), `supabase/tests/202610270002_legacy_sync_household_rewash_import_validation.sql` (40).

## Why not the live Finish RPCs

`record_finish_production` and its v2/v3/terminal wrappers derive the business date, shift,
roster, processing staff and edit cutoff from `now()`. They need an authenticated Finish
account and V2 wash evidence, and they change current trolley custody. None of that can
describe a past legacy entry. The importer therefore writes the same tables the RPC writes
(entry, lines, one `FINISH_PRODUCTION_RECORDED` flow event, `audit_log`), with
`source_application = 'LEGACY_SYNC_FINISH'`. It never writes trolley, custody or Sorting
rows, and never fabricates wash events.

## Entry points (service_role only)

| Function | Writes | Use |
| --- | --- | --- |
| `integration.legacy_sync_finish_dry_run(records jsonb)` | nothing (STABLE) | 1–60 records; plans plus batch checks and totals |
| `integration.legacy_sync_plan_finish_entry(record jsonb)` | nothing (STABLE) | one record |
| `integration.legacy_sync_start_run(source, mode, from, to, requested_by)` | one run row | open a `COMMIT` run |
| `integration.legacy_sync_import_finish_entry(run_id, record jsonb)` | see below | one record, one transaction |
| `integration.legacy_sync_finish_run(run_id, status, summary)` | run row | close the run |
| `integration.legacy_sync_plan_household_rewash(records jsonb)` | nothing (STABLE) | 1–60 HOUSEHOLD rows; plans and READY cells |
| `integration.legacy_sync_import_household_rewash(run_id, records jsonb)` | see "HOUSEHOLD as ReWash" | the HOUSEHOLD rows of one Finish cell |

All are `SECURITY DEFINER`, revoked from `public`, `anon` and `authenticated`. The importer
also refuses to run when `auth.uid()` is set.

### Record shape

```json
{
  "source_record_id": "FE-20261026-080542-C042A348",
  "entry": { "EntryID": "...", "CreatedAt": "2026-10-26 08:05:42", "BusinessDate": "2026-10-26",
             "Shift": "...", "TableID": "...", "EntryType": "NORMAL", "WashItemID": "...",
             "WashID": "...", "CustomerID": "...", "CustomerName": "...", "Trolleys": "...",
             "BatchNo": "...", "QtyKg": "45.5", "QtyUnits": "12", "TotalKg": "45.5",
             "Status": "...", "Notes": "...", "StaffUserID": "optional", "StaffName": "optional" },
  "wash_item": { "WashItemID": "...", "CustomerID": "...", "ScheduledDate": "2026-10-27", "Type": "..." }
}
```

`entry` is the FinishEntries row as it is in the sheet. `wash_item` is the CentralDB WashItems
row it references (or `null`). The database computes the fingerprint
(`sha256` of the canonical JSON), so the sender cannot choose it.

- Numbers use a decimal point. A comma (`1,5`) is refused, not guessed.
- `CreatedAt` with `Z` or an offset is taken as given; without an offset it is Dublin local
  time. It becomes `recorded_at`; `created_at` stays the import time.

### Outcomes

| Outcome | Meaning | Rows written |
| --- | --- | --- |
| `READY` | dry run only: would import | none |
| `IMPORTED` | written | entry, lines, flow (if new), event, audit, links, versions |
| `ALREADY_IMPORTED` | same `EntryID`, same fingerprint | versions only (idempotent, normally none) |
| `BLOCKED` | at least one blocker | source versions + one open review item per blocker |
| `SKIPPED` | business date 2026-10-25: owner test day | source version only |
| `REWASH_ROUTE` | HOUSEHOLD: use the ReWash importer | source version only |
| `RUN_LIMIT_REACHED` | run hit `max_entries_per_run` | none |

## Mapping rules

- **Flow:** key `customer_id + 'CLOTHES' + WashItem.ScheduledDate`, through
  `ensure_production_flow_item`. Many WashItems share one flow. A new flow is opened on the
  legacy business date and takes the published schedule snapshot; without a published CLOTHES
  schedule for that date the record is blocked (`SCHEDULE_NOT_PUBLISHED`).
- **Dates:** `production_business_date` = `BusinessDate`; `delivery_date` =
  `next_distribution_business_date(ScheduledDate)`; cutoff = 12:00 Dublin on delivery date.
  Finishing before the scheduled date is allowed (warning `ADVANCE_PRODUCTION`).
- **Customer:** `legacy_metadata->>'legacy_customer_id'`, or exact `customer_code`, or an
  approved `CUSTOMER` link in `integration.legacy_sync_record_links`
  (`source_system='CENTRALDB'`, `source_table='Customers'`). Never by name. Inactive
  customers are held for a decision.
- **Shift / table / WashItem type:** exact canonical codes (`MORNING`, `FINISH_TABLE_1`,
  `CLOTHES`) are accepted. Any other raw value needs a row in
  `integration.legacy_sync_value_maps`. **Finish `Status` always needs an approved map row**
  (`ACTIVE` or `NOT_IMPORTED`).
- **Lines:** `QtyKg` → `KG` line, `QtyUnits` → `UNIT` line (whole number), same `BatchNo`.
  `TotalKg` must equal `QtyKg`. Links per line use `source_line_key` `KG:1`, `UNIT:2`.
- **Staff:** `StaffUserID` (optional) must match `staff_members.legacy_user_id`. Without it the
  entry has no processed-by staff (warning `PROCESSED_BY_NOT_IN_SOURCE`).
- **Trolleys:** the raw `Trolleys` text is kept in the link and the flow event only.
  `trolley_scan_status` stays `UNSPECIFIED`.

## Blockers

`INVALID_RECORD`, `MISSING_SOURCE_ID`, `SOURCE_ID_MISMATCH`, `SOURCE_CHANGED_AFTER_IMPORT`,
`ENTRY_TYPE_NOT_SUPPORTED`, `SOURCE_STATUS_UNMAPPED`,
`SOURCE_NOT_ACTIVE`, `MISSING_WASH_ITEM`, `WASH_ITEM_ID_MISMATCH`, `WASH_ITEM_TYPE_UNMAPPED`,
`PRODUCT_NOT_CLOTHES`, `INVALID_SCHEDULED_DATE`, `CUSTOMER_MISMATCH`, `INVALID_BUSINESS_DATE`,
`BUSINESS_DATE_IN_FUTURE`, `BUSINESS_DATE_AFTER_DELIVERY`,
`INVALID_CREATED_AT`, `CREATED_AT_IN_FUTURE`, `SHIFT_UNMAPPED`, `SHIFT_NOT_FOUND`,
`TABLE_UNMAPPED`, `TABLE_NOT_FOUND`, `MISSING_CUSTOMER_ID`, `CUSTOMER_CONFLICT`,
`CUSTOMER_AMBIGUOUS`, `CUSTOMER_DELETED`, `CUSTOMER_NOT_FOUND`,
`CUSTOMER_INACTIVE_PENDING_DECISION`, `STAFF_UNMAPPED`, `MISSING_BATCH_REFERENCE`,
`BATCH_REFERENCE_TOO_LONG`, `INVALID_QUANTITY`, `FRACTIONAL_UNITS`, `TOTAL_KG_MISMATCH`,
`NO_QUANTITY`, `FLOW_CANCELLED`, `SCHEDULE_NOT_PUBLISHED`, `WASH_ITEM_LINKED_TO_OTHER_FLOW`,
`CELL_HAS_ACTIVE_ENTRY`, `BATCH_REFERENCE_IN_USE`. Dry run only: `DUPLICATE_SOURCE_ID_IN_BATCH`,
`CELL_SHARED_IN_BATCH`, `BATCH_REFERENCE_DUPLICATE_IN_BATCH`.

Two legacy NORMAL entries for the same flow, date, shift and table are never merged: the second is
held (`CELL_SHARED_IN_BATCH` in a dry run, `CELL_HAS_ACTIVE_ENTRY` after the first import)
until the owner decides.

## HOUSEHOLD as ReWash (`202610270002`, Applied)

Owner decision 2026-10-27: a legacy `HOUSEHOLD` Finish entry is ReWash. It goes into the V2
ReWash ledger (`finish_rewash_entries` / `finish_rewash_lines`), the same place as
`record_finish_rewash_v1`. ReWash is production (staff handled it) and is counted separately, per
table and shift; it is not added to a customer's Clothes flow KG and never touches a Production
Flow.

- V2 keeps one ACTIVE ReWash entry per business date, shift and table, with one KG line per
  customer row. The importer takes **all the HOUSEHOLD rows of one cell in one call** and writes
  one new entry (revision 1) with one line per legacy row, in `CreatedAt` order.
  `recorded_at` = the latest `CreatedAt`; processed-by = the common mapped staff, else the common
  `StaffName`, else `Legacy Finish (Apps Script)`; notes = the legacy notes joined.
- A cell is all-or-nothing: one blocked row holds the whole cell (`CELL_HAS_BLOCKED_RECORD`).
- If the cell already has an ACTIVE ReWash entry (typed in V2, or imported earlier), the rows are
  held (`REWASH_CELL_HAS_ACTIVE_ENTRY`). The importer never merges into or supersedes an entry.
- Customer as for NORMAL, then the ReWash eligibility used by V2
  (`finish_rewash_customer_options_v1`: active customer with a published CLOTHES/OTHERS schedule),
  else `REWASH_CUSTOMER_NOT_ELIGIBLE`.
- KG only: `QtyKg` > 0 (max 10 000, 2 decimals); any `QtyUnits` other than 0 is
  `REWASH_UNITS_NOT_SUPPORTED`. `BatchNo` is optional and must be free among the day's ACTIVE
  Finish and ReWash records.
- Provenance: `finish_rewash_entries` has no `source_application`, so it lives in the links
  (`FINISH_ENTRY_TO_REWASH_LINE`, key `KG:1`, metadata holds the entry id) and in
  `audit_log` (`IMPORT_LEGACY_HOUSEHOLD_REWASH`, `source_application='LEGACY_SYNC_FINISH'`).
- Switch `FINISH_REWASH_HISTORICAL_IMPORT` (seeded OFF); its limit counts cells per run.
- Other blockers: `ENTRY_TYPE_NOT_HOUSEHOLD`, `IMPORTED_AS_NORMAL_ENTRY`, and the NORMAL ones
  that apply (status, dates, shift, table, customer, staff, quantity, batch).

## Sunday rows

Owner decision 2026-10-27: every legacy row of **Sunday 2026-10-25** was an owner test. Both
planners return `SKIPPED` (`OWNER_TEST_DAY`) for that date only; the ReWash importer also
records a review item already `REJECTED` by that decision, for traceability.

Other Sundays are real production (occasional catch-up or advance work). They are imported like
any other day, with a `SUNDAY_PRODUCTION` warning; the old `SUNDAY_PRODUCTION_REVIEW` blocker is
gone.

## Safety gates

1. `integration.legacy_sync_settings` row `FINISH_HISTORICAL_IMPORT` is `enabled`
   (seeded `false`).
2. An open run with `mode='COMMIT'`.
3. Fewer than `max_entries_per_run` entries imported in that run (seeded `3`).
4. The planner returns `READY`; cell and batch are checked again under the flow lock.

The Finish trigger `finish_enforce_new_entry_current_shift` accepts a `LEGACY_SYNC_FINISH`
row only when the importer registered that entry id for the current transaction in
`integration.legacy_sync_finish_insert_permits`. Any other row with that label is refused.
Live behaviour and the 2026-10-23 Apps Script exception are unchanged.

## Pilot runbook (after the owner approves each step)

1. Done 2026-10-27: read-only checks, `202610260002` and `202610270001` applied, validation
   files and security advisors run.
2. Done 2026-10-27: `202610270002` applied by the owner and validated (40/40).
3. Insert the owner-approved value maps (at least the Finish `Status` values).
4. Dry run 2026-10-26 from the Edge Function and review the plans with the owner.
5. Owner enables `FINISH_HISTORICAL_IMPORT` (limit 3), opens a `COMMIT` run, imports 1 to 3
   `NORMAL` entries, closes the run, then turns the switch off again.
6. Verify: `production_official_actuals` delta equals the pilot KG; one event per entry; no
   trolley or Sorting change; a second import of the same records returns
   `ALREADY_IMPORTED`.

To withdraw a pilot entry, do not delete it: use a reviewed cancellation (status
`CANCELLED` plus an audit row). The links stay as history.

## Still open

- Owner decisions: two legacy NORMAL entries in one cell, inactive customers, unmapped staff,
  the raw values of the 3 ambiguous customers and 2 unmapped types, the Finish `Status` values.
  (HOUSEHOLD, the 2026-10-25 test day and Sunday production decided 2026-10-27.)
- Edge Function for Apps Script (HMAC-signed requests; calls only the functions above).
- Repository copy of the live-only `integration.legacy_inbox`,
  `staging.apps_script_incremental_rows` and `legacy-sync-ingest`.
- How the `LOCAL_FINISH_WORKBOOK_20261024` rows passed the Finish trigger.
