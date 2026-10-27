# Legacy sync: historical Finish import

Status: **Prepared** (2026-10-27). Not applied to `ElisCaretex-dev`. No import has run.

This is the database side of the Legacy Sync: a one-way, incremental, idempotent copy of
legacy Apps Script Finish Area entries into Finish V2. Apps Script stays the sender and holds
no Supabase key. All mapping and business rules live in Postgres.

Migrations:

- `supabase/migrations/202610260002_legacy_sync_identity_foundation.sql`: runs, record
  versions, insert-only legacy links, review queue (schema `integration`).
- `supabase/migrations/202610270001_legacy_sync_finish_historical_import.sql`: switch and
  pilot limit, owner-approved value maps, planner, dry run, importer, narrow Finish trigger
  change.

Validation: `supabase/tests/202610270001_legacy_sync_finish_historical_import_validation.sql`
(55 assertions, transaction rolled back).

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
`HOUSEHOLD_PENDING_DECISION`, `ENTRY_TYPE_NOT_SUPPORTED`, `SOURCE_STATUS_UNMAPPED`,
`SOURCE_NOT_ACTIVE`, `MISSING_WASH_ITEM`, `WASH_ITEM_ID_MISMATCH`, `WASH_ITEM_TYPE_UNMAPPED`,
`PRODUCT_NOT_CLOTHES`, `INVALID_SCHEDULED_DATE`, `CUSTOMER_MISMATCH`, `INVALID_BUSINESS_DATE`,
`BUSINESS_DATE_IN_FUTURE`, `SUNDAY_PRODUCTION_REVIEW`, `BUSINESS_DATE_AFTER_DELIVERY`,
`INVALID_CREATED_AT`, `CREATED_AT_IN_FUTURE`, `SHIFT_UNMAPPED`, `SHIFT_NOT_FOUND`,
`TABLE_UNMAPPED`, `TABLE_NOT_FOUND`, `MISSING_CUSTOMER_ID`, `CUSTOMER_CONFLICT`,
`CUSTOMER_AMBIGUOUS`, `CUSTOMER_DELETED`, `CUSTOMER_NOT_FOUND`,
`CUSTOMER_INACTIVE_PENDING_DECISION`, `STAFF_UNMAPPED`, `MISSING_BATCH_REFERENCE`,
`BATCH_REFERENCE_TOO_LONG`, `INVALID_QUANTITY`, `FRACTIONAL_UNITS`, `TOTAL_KG_MISMATCH`,
`NO_QUANTITY`, `FLOW_CANCELLED`, `SCHEDULE_NOT_PUBLISHED`, `WASH_ITEM_LINKED_TO_OTHER_FLOW`,
`CELL_HAS_ACTIVE_ENTRY`, `BATCH_REFERENCE_IN_USE`. Dry run only: `DUPLICATE_SOURCE_ID_IN_BATCH`,
`CELL_SHARED_IN_BATCH`, `BATCH_REFERENCE_DUPLICATE_IN_BATCH`.

Two legacy entries for the same flow, date, shift and table are never merged: the second is
held (`CELL_SHARED_IN_BATCH` in a dry run, `CELL_HAS_ACTIVE_ENTRY` after the first import)
until the owner decides.

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

1. Read-only on `ElisCaretex-dev`: confirm the live body of
   `finish_enforce_new_entry_current_shift` equals `202610230005` (the migration replaces it),
   list the triggers on `finish_production_entries`, and check that no
   `integration.legacy_sync_*` object already exists.
2. Apply `202610260002`, then `202610270001`, from the committed files. Run the validation file
   (it rolls back). Run the security advisors.
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

- Owner decisions: HOUSEHOLD, two legacy entries in one cell, inactive customers, Sunday
  records, unmapped staff, the raw values of the 3 ambiguous customers and 2 unmapped types.
- Edge Function for Apps Script (HMAC-signed requests; calls only the functions above).
- Repository copy of the live-only `integration.legacy_inbox`,
  `staging.apps_script_incremental_rows` and `legacy-sync-ingest`.
- How the `LOCAL_FINISH_WORKBOOK_20261024` rows passed the Finish trigger.
