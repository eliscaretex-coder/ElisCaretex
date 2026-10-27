# Legacy sync: Finish import

Status (2026-10-27): `202610260002`, `202610270001` and `202610270002` **Applied** to
`ElisCaretex-dev` by the owner and **Validated** there with the rolled-back test files.
`202610270003` (updates as revisions, adoption of earlier imports, ReWash from
`RewashProduction` lines) is **Prepared**: validated on a local replica (51/51), not yet
applied. Both import switches are OFF. No import has run.

The sync is temporary. When the legacy apps stop, keep the imported production data and remove
the sync scaffolding (owner, 2026-10-27).

This is the database side of the Legacy Sync: a one-way, incremental, idempotent copy of
legacy Apps Script Finish Area entries into Finish V2. Apps Script stays the sender and holds
no Supabase key. All mapping and business rules live in Postgres.

Migrations:

- `202610260002_legacy_sync_identity_foundation.sql`: runs, record versions, insert-only
  legacy links, review queue (schema `integration`).
- `202610270001_legacy_sync_finish_historical_import.sql`: switch and pilot limit, value maps,
  planner, dry run, importer, narrow Finish trigger change.
- `202610270002_legacy_sync_household_rewash_import.sql`: 2026-10-25 test-day skip, Sunday
  warning, HOUSEHOLD routed to ReWash. Its ReWash planner and importer read the customer from
  the HOUSEHOLD row, which is wrong for the real sheets; `202610270003` drops them unused.
- `202610270003_legacy_sync_finish_updates_and_rewash_lines.sql`: everything below.

Validation (each file is one transaction, rolled back):
`supabase/tests/202610260002_legacy_sync_identity_foundation_validation.sql` (11) and
`supabase/tests/202610270003_legacy_sync_finish_updates_and_rewash_lines_validation.sql` (51).
The `202610270001` and `202610270002` test files describe those migrations as applied and no
longer pass once `202610270003` is in place (planner outcomes and ReWash functions changed).

## What the real sheets showed (dry run of 24-27 October, owner decisions 2026-10-27)

- A legacy entry **changes after it is created.** A table may save 0 kg while it still works
  on the customer and fill the real value later, up to dispatch. So the sync applies a changed
  entry as a **new revision** of the V2 entry, and an entry with no quantity yet is
  `PENDING_SOURCE` (not imported, not a review item; the next sync retries it).
- The 24 entries of 2026-10-24 morning are already in V2 from the local workbook import
  (`LOCAL_FINISH_WORKBOOK_20261024`), which names each legacy `EntryID` in its notes
  (`source group FINISH:<EntryID>`). The sync **adopts** them (links, no second copy). Two of
  them differ (KNOCKEEN batch 462: legacy 26.07 kg, V2 21.35; AISLING HOUSE batch 463: legacy
  27.47, V2 22.01): **the legacy value wins**, as a new revision.
- WashItems type `OTHERS` is a washing label only: Finish treats it as `CLOTHES` (value map).
  It may move to MOP later; retire the map row then.
- A legacy `HOUSEHOLD` row is only the **header** of a ReWash cell (one per date, shift and
  table). The customer lines are in the Finish Area sheet `RewashProduction`
  (`RewashLineID` = `EntryID::NNN`). The same customer twice in a cell is **summed** into one
  V2 line.
- Every customer of the period resolves by legacy ID and is active; every `UserName` matches
  exactly one staff display name.

## Why not the live Finish RPCs

`record_finish_production`, `correct_finish_production` and their wrappers derive the business
date, shift, roster, processing staff and edit cutoff from `now()`, need an authenticated Finish
account and V2 wash evidence, and change trolley custody. None of that describes a legacy entry.
The importer writes the same tables (entry, lines, one `FINISH_PRODUCTION_RECORDED` or
`FINISH_PRODUCTION_CORRECTED` flow event, `audit_log`) with
`source_application = 'LEGACY_SYNC_FINISH'`. It never writes trolley custody or Sorting rows and
never fabricates wash events. A revision copies the previous revision's trolley links, as the
live correction does.

## Entry points (service_role only)

| Function | Writes | Use |
| --- | --- | --- |
| `integration.legacy_sync_finish_dry_run(records jsonb)` | nothing (STABLE) | 1–60 NORMAL records |
| `integration.legacy_sync_plan_finish_entry(record jsonb)` | nothing (STABLE) | one NORMAL record |
| `integration.legacy_sync_rewash_dry_run(records jsonb)` | nothing (STABLE) | 1–40 HOUSEHOLD headers with lines |
| `integration.legacy_sync_plan_rewash_cell(record jsonb)` | nothing (STABLE) | one HOUSEHOLD header |
| `integration.legacy_sync_start_run(source, mode, from, to, requested_by)` | one run row | open a `COMMIT` run |
| `integration.legacy_sync_import_finish_entry(run_id, record jsonb)` | see below | one NORMAL record, one transaction |
| `integration.legacy_sync_import_rewash_cell(run_id, record jsonb)` | see below | one ReWash cell, one transaction |
| `integration.legacy_sync_finish_run(run_id, status, summary)` | run row | close the run |

All are `SECURITY DEFINER`, revoked from `public`, `anon` and `authenticated`. The importers
also refuse to run when `auth.uid()` is set.

### NORMAL record

```json
{
  "source_record_id": "FE-20261026-080542-C042A348",
  "entry": { "EntryID": "...", "CreatedAt": "2026-10-26 08:05:42", "BusinessDate": "2026-10-26",
             "Shift": "Morning", "TableID": "Table 2", "EntryType": "NORMAL", "WashItemID": "...",
             "CustomerID": "CID-...", "Trolleys": "...", "BatchNo": "2", "QtyKg": "186.51",
             "QtyUnits": "0", "TotalKg": "186.51", "Status": "DONE", "Notes": "...",
             "StaffName": "Paola Cortez Galvis", "StaffUserID": "optional" },
  "wash_item": { "WashItemID": "...", "CustomerID": "CID-...", "ScheduledDate": "2026-10-26", "Type": "CLOTHES" }
}
```

### ReWash record (one HOUSEHOLD header)

```json
{
  "source_record_id": "FE-20261026-155640-091DF6CA",
  "entry": { "EntryID": "...", "CreatedAt": "...", "BusinessDate": "2026-10-26", "Shift": "Evening",
             "TableID": "Table 2", "EntryType": "HOUSEHOLD", "Status": "DONE", "QtyKg": "14.85",
             "StaffName": "Joyce Soares" },
  "lines": [ { "RewashLineID": "FE-...::001", "EntryID": "FE-...", "LineNo": "1",
               "BusinessDate": "2026-10-26", "Shift": "Evening", "TableID": "Table 2",
               "CustomerID": "CID-...", "BatchNo": null, "QtyKg": "0.8", "QtyUnits": "0", "Status": "DONE" } ]
}
```

The sender normalises the sheet values: dates `YYYY-MM-DD`, times `YYYY-MM-DD HH:MM:SS` (Dublin
local) or ISO with offset, numbers as text with a decimal point and no `.0` on whole batch
numbers, empty cells as `null`. The database computes every fingerprint.

### Outcomes

| Outcome (`action`) | Meaning | Rows written |
| --- | --- | --- |
| `READY` (`CREATE`) | new entry | revision 1, lines, flow if new, event, audit, links |
| `READY` (`UPDATE`) | linked entry whose quantity, batch or staff changed | old revision `SUPERSEDED`, next revision `ACTIVE`, event, audit |
| `READY` (`ADOPT`) | already in V2 from an earlier import, same values | links and audit only |
| `READY` (`ADOPT_AND_UPDATE`) | already in V2, values differ | links, then a revision as `UPDATE` |
| `ALREADY_IMPORTED` | same values as the ACTIVE revision (a notes-only change included) | record version only |
| `PENDING_SOURCE` | no quantity yet | record version only |
| `BLOCKED` | at least one blocker | record version + one open review item per blocker |
| `SKIPPED` | `OWNER_TEST_DAY` (2026-10-25) or `BEFORE_SYNC_WINDOW` (before 2026-10-24, already imported) | record version (test day: an auto-rejected review item) |
| `REWASH_ROUTE` | NORMAL importer got a HOUSEHOLD row | record version only |
| `RUN_LIMIT_REACHED` | the run hit `max_entries_per_run` writes | none |

The importer returns `IMPORTED`, `UPDATED`, `ADOPTED` or `ADOPTED_AND_UPDATED` after a write.
A change of customer, business date, shift, table or scheduled date is never applied: it is
held as `SOURCE_IDENTITY_CHANGED`. An entry that drops to 0 after import is held as
`SOURCE_QUANTITY_REMOVED`. A V2 entry cancelled in V2 is held as `TARGET_NOT_ACTIVE`.

## Mapping rules

- **Target of a legacy entry:** our `FINISH_ENTRY_TO_ENTRY` link; else an entry of
  `APPS_SCRIPT_CENTRALDB_20261023_001` or `LOCAL_FINISH_WORKBOOK_20261024` whose notes name the
  `EntryID`. The ACTIVE revision of that entry group is compared (KG/UNIT lines and processed-by).
- **Flow:** key `customer_id + 'CLOTHES' + WashItem.ScheduledDate`, through
  `ensure_production_flow_item`; without a published CLOTHES schedule a new flow is blocked
  (`SCHEDULE_NOT_PUBLISHED`).
- **Dates:** `production_business_date` = `BusinessDate`; `delivery_date` =
  `next_distribution_business_date(ScheduledDate)`; cutoff = 12:00 Dublin on delivery date.
  Finishing before the scheduled date is a warning (`ADVANCE_PRODUCTION`).
- **Customer:** legacy ID in `legacy_metadata`, else exact `customer_code`, else an approved
  `CUSTOMER` link. Never by name. Inactive customers are held.
- **Value maps** (`integration.legacy_sync_value_maps`, owner-approved 2026-10-27): `DONE` →
  `ACTIVE`; `Morning`/`Evening`; `Table 1-3` → `FINISH_TABLE_1-3`; CentralDB `OTHERS` → `CLOTHES`.
- **Lines:** `QtyKg` → `KG` line, `QtyUnits` → `UNIT` line (whole number), same `BatchNo`.
  `TotalKg` must equal `QtyKg`.
- **Staff:** `StaffUserID` → `staff_members.legacy_user_id`; else exactly one staff member whose
  display name equals `StaffName` (case and outer spaces ignored). Otherwise the name is kept as
  a snapshot with a warning (`PROCESSED_BY_NAME_UNMATCHED` or `_AMBIGUOUS`).
- **Notes:** V2 notes are `Legacy Finish sync; source group FINISH:<EntryID>`; the raw legacy row
  is in `integration.legacy_sync_record_versions`.
- **Trolleys:** the raw `Trolleys` text stays in the link and the flow event.

## ReWash (HOUSEHOLD header + RewashProduction lines)

ReWash is production (staff handled it) counted separately per table and shift; it never touches
a Production Flow or Clothes KG. V2 keeps one ACTIVE ReWash entry per date, shift and table with
one KG line per customer (`finish_rewash_entries` / `finish_rewash_lines`).

- One call = one HOUSEHOLD header with its `RewashProduction` lines. Lines must carry the same
  `EntryID`, date, shift and table.
- Line status `DONE` → included; a line at 0 kg is left out (`ZERO_KG_LINE_WAITING`); a header
  with no kg at all is `PENDING_SOURCE`. Units are refused (`REWASH_UNITS_NOT_SUPPORTED`).
- Customers summed per cell; batches joined (`, `), each must be free among the day's other
  ACTIVE Finish and ReWash records.
- Target: our `HOUSEHOLD_TO_REWASH_ENTRY` link, else the cell's ACTIVE entry when an earlier import
  wrote it (no `recorded_by`), which is adopted. A cell recorded in the V2 app is never taken over
  (`REWASH_CELL_HAS_V2_ENTRY`); a cell already fed by another header is held
  (`REWASH_CELL_LINKED_TO_OTHER_SOURCE`).
- Updates (a line filled in or added during the shift) are new revisions, as
  `record_finish_rewash_v1` does.
- Provenance: links `HOUSEHOLD_TO_REWASH_ENTRY` (header) and `REWASH_LINE_TO_LINE` (each source
  line → its summed V2 line), notes naming the header, and `audit_log`
  (`IMPORT_` / `UPDATE_` / `ADOPT_LEGACY_REWASH`, `source_application='LEGACY_SYNC_FINISH'`).
- Switch `FINISH_REWASH_HISTORICAL_IMPORT` (seeded OFF).

## Sunday rows

Every legacy row of **Sunday 2026-10-25** was an owner test: `SKIPPED` (`OWNER_TEST_DAY`) with
an auto-rejected review item. Other Sundays are real production with a `SUNDAY_PRODUCTION`
warning.

## Safety gates

1. The switch (`FINISH_HISTORICAL_IMPORT` or `FINISH_REWASH_HISTORICAL_IMPORT`) is enabled
   (seeded `false`).
2. An open run with `mode='COMMIT'`.
3. Fewer than `max_entries_per_run` writes (create, update, adopt; audit rows of the run).
4. The planner returns `READY`; cell, batch and target are checked again under locks.

The Finish trigger `finish_enforce_new_entry_current_shift` accepts a `LEGACY_SYNC_FINISH`
row (revision 1 or later) only when the importer registered that entry id for the current
transaction in `integration.legacy_sync_finish_insert_permits`. Any other row with that label is
refused. Live behaviour and the 2026-10-23 Apps Script exception are unchanged.

## Pilot runbook (after the owner approves each step)

1. Done 2026-10-27: `202610260002`, `202610270001`, `202610270002` applied and validated.
2. Apply `202610270003`; run its validation file and the security advisors.
3. Dry run 24-27 October (NORMAL and ReWash) and review it with the owner.
4. Edge Function for Apps Script (HMAC-signed requests; calls only the functions above).
5. Owner enables a switch (limit 3), opens a `COMMIT` run, imports 1 to 3 records, closes the
   run, turns the switch off again, and checks the result.

To withdraw an imported entry, do not delete it: use a reviewed cancellation (status
`CANCELLED` plus an audit row). The links stay as history.

## Still open

- An entry deleted in the legacy sheet cannot be seen by a per-record sync. Needs a periodic
  "still present" check from the sender, or an owner decision.
- Edge Function and the Apps Script sender.
- Repository copy of the live-only `integration.legacy_inbox`,
  `staging.apps_script_incremental_rows` and `legacy-sync-ingest`.
- How the `LOCAL_FINISH_WORKBOOK_20261024` rows passed the Finish trigger.
- 2026-10-23 ReWash cells differ between V2 (CentralDB import) and the current legacy sheet
  (Morning Table 1: 21 lines / 38.90 kg in V2, 11 / 20.96 in the sheet; Morning Table 3:
  14 / 45.30 vs 7 / 26.65). Outside the sync window; owner to decide if it matters.
