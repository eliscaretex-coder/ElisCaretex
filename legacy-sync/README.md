# Legacy Sync: Finish Area sender

Temporary. When the legacy Apps Script apps stop, delete this folder, the Edge Functions
`legacy-sync-finish` and `legacy-sync-ingest`, and the `integration.legacy_sync_*` scaffolding.
Keep the imported production data (owner decision, 2026-10-27).

Database rules, outcomes and the live dry run: `docs/database/legacy-sync-finish-import.md`.

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| Sender | `legacy-sync/apps-script/LegacySyncFinish.gs` | Reads `FinishEntries` (+ `FinishEntriesHistory`), `RewashProduction` and CentralDB `WashItems` (+ `WashItemsHistory`) for at most 7 days, normalises cell formats and sends signed requests. Never writes the sheets. |
| Admin page | `legacy-sync/apps-script/Index.html` | Apps Script web app page: status, preview or import a date range, source spreadsheets; the old v3.1 diagnostics are folded under "Old diagnostics". Needs `Code.gs` (v3.1) and `LegacySyncFinish.gs`. |
| Endpoint | `supabase/functions/legacy-sync-finish/index.ts` | Checks the HMAC signature and the timestamp (5 minutes), validates the request shape and calls one `integration.legacy_sync_*` function. No mapping logic. |
| Rules | `integration.legacy_sync_*` (migrations `202610260002` to `202610270005`) | Planner, dry run, importer, switches, run limit, review queue, links, nightly schedule. |
| Control | Finish Results page, "Legacy sheet sync" panel (`frontend/assets/js/legacy-sync-control.js`) | ADMIN only: on/off, "Sync now", last runs. |
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
| `poll` | none | `legacy_sync_claim_run` (returns `{run, reason, dateFrom, dateTo}`) |

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

## Nightly sync (migration `202610270005`)

The Apps Script trigger `legacySyncTick` runs every 5 minutes and sends `poll`. The database
answers `run:false` (OFF, BUSY or IDLE) or claims one run:

- `REQUEST`: an administrator pressed "Sync now" in V2 (picked up within 5 minutes);
- `NIGHTLY`: once per Dublin night between 02:00 and 05:00.

Each run imports the last 3 days (today included). The V2 switch controls everything: ON
enables the schedule and both import switches (limit 300 per run); OFF disables all of them, so
nothing is written, not even by a manual run from the editor.

Setup: apply the migration, redeploy `legacy-sync-finish`, replace `LegacySyncFinish.gs` in the
Apps Script project, run `installLegacySyncTrigger()` once, then turn the sync on in V2.
`removeLegacySyncTrigger()` stops the polling.
