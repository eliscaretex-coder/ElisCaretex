# Apps Script history reconciliation

Status: **Prepared** (read-only review, 2026-10-19). Owner acceptance pending.

The historical import of 2026-09-26 loaded six Apps Script exports into
`staging.apps_script_*` tables and promoted the approved rows into the
operational tables (`source_application = 'APPS_SCRIPT_IMPORT'`). Those staging
tables were created directly in the database; migration
`202610190003_capture_apps_script_history_staging.sql` now records their
definition. The promotion SQL itself was not saved.

Validation: `supabase/tests/202610190003_apps_script_history_reconciliation_validation.sql`.

## Sources and batches

| Batch | Source file / sheets | Dates |
| --- | --- | --- |
| `APPS_SCRIPT_FINISH_20260926_001` | `dados_iniciais-_Elis_2026.xlsx` / Tables_Finish Area | 2026-01-06 to 06-29 |
| `APPS_SCRIPT_FINISH_20260926_002` | `Finish_Area_db_bkp_8_7_26.xlsx` / FinishEntries, FinishEntriesHistory, RewashProduction | 06-29 to 07-08 |
| `APPS_SCRIPT_FINISH_20260926_003` | `CentralDB_3.xlsx` / FinishProduction, FinishProductionHistory | 07-11 to 09-26 |
| `APPS_SCRIPT_FINISH_20260926_004` | `Finish_Area_db_1.xlsx` / FinishEntries, FinishEntriesHistory, RewashProduction | 07-09 to 09-26 |
| `APPS_SCRIPT_MOP_20260926_001` | `CentralDB_3.xlsx` / MopProduction, MopProductionHistory | 07-13 to 09-26 |
| `APPS_SCRIPT_WASH_20260926_001..003` | `dados_iniciais` Sorting Area, `Sorting_Area_-_Elis_2026_db.xlsx` | 2025-12-30 to 09-26 |
| `APPS_SCRIPT_STAFF_20260926_001..004` | Staff sheets of the files above | 2025-12-30 to 09-26 |
| `APPS_SCRIPT_TROLLEY_20260926_001` | `CentralDB_3.xlsx` / TrolleyReturns | — |

Batches 003 and 004 overlap from 07-11: the Finish table app and CentralDB
recorded the same production. Batch 004 was matched against 003 ("option B"):
identical rows kept the CentralDB record, changed rows became a new revision
(the CentralDB row is `SUPERSEDED`), and rows missing from CentralDB were added.
Batch 004 rows for 06-29 to 07-08 were rejected as already covered by batch 002.

## Staging to target: reconciled

Checked 2026-10-19 against `fcimmysqifzxoanmpylh`, read-only.

| Check | Staging | Target | Difference |
| --- | ---: | ---: | ---: |
| Active Finish KG lines | 13,528 | 13,528 | 0 |
| Official Finish KG (`production_official_actuals`) | 823,581.96 | 823,581.96 | 0 |
| Active Finish UNIT lines / units | 664 / 38,032 | 664 / 38,032 | 0 |
| Active ReWash KG | 10,397.05 | 10,397.05 | 0 |
| MOP KG (1,446 recorded batches, 2,127 lines) | 49,574.02 | 49,574.02 | 0 |
| Active imported Finish lines with no staging row | — | 0 | 0 |
| Line quantity or unit differing from staging | — | 0 | 0 |

Every operating day from 2026-01-06 to 2026-09-26 (Monday to Saturday) has
Finish production. Two pairs of identical active UNIT lines exist (same
customer, date, shift, table, batch and quantity); they are probably genuine
repeats and are left as they are.

## Excluded from official totals

| Item | Rows | Quantity | Basis |
| --- | ---: | ---: | --- |
| HOUSEHOLD (small customers grouped + ReWash), Jan to 07-08 | 1,025 | 81,021.49 kg + 1,266 units | Owner decision 2026-09-26 (`apps_script_customer_name_map`) |
| Finish 004 rows covered by batch 002 (06-29 to 07-08) | 533 | 31,144.47 kg + 1,349 units | Duplicate source |
| Zero-quantity or cancelled Finish rows | 139 | 0 kg | Source |
| Finish duplicate-of-previous rows | 7 | 268.25 kg + 39 units | Source flag |
| Fractional UNIT values | 2 | 81.98 units | Units must be whole |
| ReWash recorded in units | 7 | 245 units | ReWash ledger is KG only |
| MOP lines cancelled in source | 64 | 9,315.77 kg | Source status |
| ReWash lines with unmapped customer | 2 | 49.02 kg | **BLOCKED**, needs owner |
| Staff sessions over 13 hours | 33 | — | **BLOCKED**, needs owner |

`production_official_actuals` counts only `KG` lines, so the 38,032 Finish units
(about 6,339 kg at the 6 units = 1 kg rule) are not in Production Intelligence
totals. Finish Results shows the KG equivalent.

## Still open

1. **Source to staging.** The original exports are not in the repository or the
   linked Drive. Sheet row numbers in staging are contiguous (no gaps), but the
   last row of each sheet and the source totals must be confirmed from the
   owner's files or from totals the old system reported.
2. **Owner acceptance** of the exclusions above and of the two BLOCKED groups.
3. **No MOP history before 2026-07-13.** Official totals for January to July
   contain Finish only. The owner should confirm whether MOP was recorded
   elsewhere before CentralDB.
4. **HOUSEHOLD discontinuity.** Until 07-08 small customers were grouped as
   HOUSEHOLD and are excluded; afterwards they appear under their own customer.
   Month-to-month comparisons across July are therefore not like for like.
5. **Imported MOP is marked `entry_mode = 'LIVE'`** and
   `sorting_mop_production_batches` has no source column. Imported MOP can be
   told apart from future live MOP only through `staging.apps_script_mop_lines`.
   A provenance column (as Finish has `source_application`) should be added
   before live MOP recording starts.
6. The promotion SQL of 2026-09-26 was not kept. A repeat import cannot be
   reproduced exactly from the repository.
