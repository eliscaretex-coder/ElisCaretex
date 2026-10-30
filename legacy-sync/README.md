# Legacy Sync: legacy sheets sender

Temporary. When the legacy Apps Script apps stop, delete this folder, the Edge Functions
`legacy-sync-finish` and `legacy-sync-ingest`, and the `integration.legacy_sync_*` scaffolding.
Keep the imported production data (owner decision, 2026-10-27).

Database rules, outcomes and the live dry run: `docs/database/legacy-sync-finish-import.md`.

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| Sender | `legacy-sync/apps-script/LegacySyncFinish.gs` | Reads, for at most 7 days: Sorting `Sorting Area` and `Staff`; Finish Area `FinishEntries` (+ `FinishEntriesHistory`) and `RewashProduction`; CentralDB `WashItems` (+ `WashItemsHistory`) and `User` (name to legacy user ID only; never `UserPrivate`); every row of the CentralDB registers (`User`, `CustomerMaster`, `Trolley`, `Driver`, `Vehicles`) and of `Routes` (name and colour) and `CustomerSchedule` (one record per customer; a change becomes a new published schedule revision). Normalises cell formats and sends signed requests. Never writes the sheets. |
| Admin page | `legacy-sync/apps-script/Index.html` | Apps Script web app page: status, pending records with the owner's choice for each, preview or import a date range, source spreadsheets; the old v3.1 diagnostics are folded under "Old diagnostics". Needs `Code.gs` (v3.1) and `LegacySyncFinish.gs`. |
| Endpoint | `supabase/functions/legacy-sync-finish/index.ts` | Checks the HMAC signature and the timestamp (5 minutes), validates the request shape and calls one `integration.legacy_sync_*` function. No mapping logic. |
| Rules | `integration.legacy_sync_*` (migrations `202610260002` to `202610300002`) | Planner, dry run, importer, switches, run limit, review queue, links, nightly schedule. |
| Old inbox | `supabase/functions/legacy-sync-ingest/index.ts` | Repository copy of the live function (v2). Untouched; the new sender does not use it. |

## Request contract

`POST https://<project-ref>.supabase.co/functions/v1/legacy-sync-finish`

Headers:

- `x-legacy-sync-timestamp`: Unix time in seconds.
- `x-legacy-sync-signature`: lowercase hex HMAC-SHA256 of `<timestamp>.<raw body>`, keyed with
  `LEGACY_SYNC_HMAC_SECRET`.

Bodies (`operation` → database function):

| operation | fields | function |
| --- | --- | --- |
| `finish_dry_run` | `records` (1-60) | `legacy_sync_finish_dry_run` |
| `rewash_dry_run` | `records` (1-40) | `legacy_sync_rewash_dry_run` |
| `start_run` | `mode` (`COMMIT`/`DRY_RUN`), `dateFrom`, `dateTo`, `requestedBy` | `legacy_sync_start_run('FINISH_AREA', ...)` |
| `import_finish` | `runId`, `record` | `legacy_sync_import_finish_entry` |
| `import_rewash` | `runId`, `record` | `legacy_sync_import_rewash_cell` |
| `finish_run` | `runId`, `status` (`COMPLETED`/`FAILED`/`CANCELLED`), `summary` | `legacy_sync_finish_run` |
| `dry_run` | `kind`, `records` (1-60) | `legacy_sync_dispatch_dry_run` (kind `wash`: `legacy_sync_wash_dry_run`) |
| `import` | `kind`, `runId`, `record` | `legacy_sync_dispatch_import` (kind `wash`: `legacy_sync_import_wash`) |
| `poll` | none | `legacy_sync_claim_run` (returns `{run, reason, dateFrom, dateTo}`) |
| `control` | `action` (`STATUS`/`ON`/`OFF`), `changedBy` (required for ON/OFF) | `legacy_sync_control` |
| `review_list` | none | `legacy_sync_review_list` (open items, latest 30 decisions; closes items imported since) |
| `review_decide` | `reviewId`, `action` (`FIX_IN_SOURCE`/`NOT_IMPORTED`), `decidedBy`, `note` (optional, 500) | `legacy_sync_review_decide` |

`dry_run` and `import` take a `kind`; the database dispatcher decides which function runs, so a
new part of the sync needs a migration but no new Edge Function deploy.

Responses: `200 {ok:true, result}`; `200 {ok:false, code, error}` when the database refuses on
purpose (switch OFF `55000`, bad input `22023`, conflicts `23505`, retry `40001`); `400` bad
request; `401` bad signature or clock; `413` body over 512 KB; `500` anything else (details only
in the function log).

Replays inside the 5-minute window are harmless: dry runs write nothing, and a repeated import
returns `ALREADY_IMPORTED`.

## Setup (owner, in this order)

1. Generate a secret of 64 hex characters (for example `openssl rand -hex 32`, or a password
   manager). Do not paste it in chats, issues or commits.
2. Supabase → Edge Functions → Secrets: add `LEGACY_SYNC_HMAC_SECRET` with that value.
3. Deploy the function with JWT verification OFF:
   `supabase functions deploy legacy-sync-finish --no-verify-jwt --project-ref fcimmysqifzxoanmpylh`
   (or create it in the dashboard with the contents of `index.ts` and "Verify JWT" off).
4. Apps Script (the existing Legacy Sync project): add a file `LegacySyncFinish` with the
   contents of `LegacySyncFinish.gs`. It uses `lsConfig_()` from the existing `Code.gs`, so keep
   that file. Project Settings → Script Properties: add `LSF_ENDPOINT` (the function URL) and
   `LSF_SECRET` (the same secret).
5. Run `previewFinishSync('2026-10-24','2026-10-27')` from the editor. It is read-only; the
   summary is in the execution log.
6. Only after the owner reviews the dry run: enable `FINISH_HISTORICAL_IMPORT` (and
   `FINISH_REWASH_HISTORICAL_IMPORT`) with a small `max_entries_per_run`, run
   `importFinishSync(...)`, turn the switches OFF again and check the result.

`importFinishSync` opens one `COMMIT` run, sends `READY` records to be written and `BLOCKED`
records to the review queue, skips the rest, stops at the run limit or after 5 minutes, and
closes the run with a summary. With the switches OFF the database refuses every write.

## Nightly sync (migrations `202610270005` and `202610270006`)

The Apps Script trigger `legacySyncTick` runs every 5 minutes and sends `poll`. The database
answers `run:false` (OFF, BUSY or IDLE) or claims one `NIGHTLY` run per Dublin night between
02:00 and 05:00. Each run imports the last 3 days (today included).

The switch and "Sync now" are on the Apps Script web app page (`Index.html`, owner decision
2026-10-27), through the signed `control` operation. ON enables the schedule and both import
switches (limit 300 per run); OFF disables all of them, so nothing is written, not even by a
manual run from the editor. "Sync now" runs the same 3-day import at once from the page.

Setup: apply the migrations, redeploy `legacy-sync-finish`, replace `LegacySyncFinish.gs` and
`Index.html` in the Apps Script project and publish a new version, run
`installLegacySyncTrigger()` once (or press Install on the page), then press "Turn on".
`removeLegacySyncTrigger()` stops the polling.

## Parts of the sync (owner decision 2026-10-27: everything the legacy apps record)

Each nightly run, `Sync now` or manual import runs the parts in this order. Each part has its own
import switch in `integration.legacy_sync_settings`; the page's ON/OFF switches all of them. A
part whose switch is OFF is refused by the database and skipped; the others still run.

| Part | Legacy sheets | V2 | Switch | Migration |
| --- | --- | --- | --- | --- |
| Registers | CentralDB `User`, `CustomerMaster`, `Trolley`, `Driver`, `Vehicles` (every row) | `staff_members` (+ cover roles), `customers` (+ product services), `trolleys`, `distribution_drivers`, `fleet_vehicles`; only fields changed in the legacy app are written | `MASTER_DATA_IMPORT` | `202610270011` |
| Attendance | Finish `StaffSessions` (+ History) and `RosterNotWorking`, Sorting `Staff` | Finish and Sorting attendance, `work_sessions` with the legacy table, times and break, Finish table segments | `ATTENDANCE_IMPORT` | `202610270010` |
| Washes | Sorting `Sorting Area` + CentralDB `WashItems` + Sorting `Staff` | `sorting_wash_runs`, `sorting_wash_run_customers`, Production Flow `WASH_RECORDED` | `SORTING_WASH_IMPORT` | `202610270007` |
| MOP | CentralDB `MopProduction` (+ History) + `WashItems` | `sorting_mop_production_batches` (lines, trolley references), ABS batch, Production Flow `MOP_PRODUCTION_RECORDED` | `MOP_PRODUCTION_IMPORT` | `202610270008` |
| Finish | Finish Area `FinishEntries` + CentralDB `WashItems` | Finish entries and lines | `FINISH_HISTORICAL_IMPORT` | `202610270001`-`0004` |
| ReWash | Finish Area HOUSEHOLD entries + `RewashProduction` | ReWash entries and lines | `FINISH_REWASH_HISTORICAL_IMPORT` | `202610270003` |
| Schedules | CentralDB `Routes` (name and colour) and `CustomerSchedule` (one record per customer) | `distribution_routes`; a change is a new published `customer_schedule_versions` revision | `SCHEDULE_IMPORT` | `202610280002` |
| Rosters | Weekly Shift Roster `RosterStoreV2` (one record per week and shift) and Distribution `Roster` (one record per week); current and future weeks only | A change is a new published `production_roster_versions` / `distribution_roster_versions` version (previous one SUPERSEDED, history kept) built with the same rules as publishing in V2; Distribution route runs follow. Days before today are never changed. First meeting: the legacy week wins; afterwards only cells changed in the legacy app are written and V2 edits are kept | `ROSTER_IMPORT` | `202610300002` |
| Trolleys | Trolley codes of Finish `FinishEntries` and CentralDB `MopProduction` (out) + CentralDB `TrolleyReturns` (back), in time order | `trolley_customer_stays`, trolley status and events, `sorting_trolley_intakes` with products and Production Flow `TROLLEY_RECEIVED_*`, presence evidence | `TROLLEY_CUSTODY_IMPORT` | `202610270009` |

Rosters need two spreadsheet IDs (not secrets): `sources.roster` and `sources.distribution` in the
Code.gs configuration, or the Script Properties `LSF_ROSTER_SPREADSHEET_ID` (Weekly Shift Roster) and
`LSF_DISTRIBUTION_SPREADSHEET_ID` (Distribution). A week is held for review, never guessed, when V2
rules refuse it: a person, driver or vehicle not in V2 yet (waits for the registers), an open draft
in V2, a cover role the person is not authorised for, Sorting Clothes/MOP undecided, a driver on
approved leave in V2, a blocked vehicle, or a route run that has already started.

Planned next: leave requests (owner decision 2026-10-27: the legacy sheets are still where the team edits them).
