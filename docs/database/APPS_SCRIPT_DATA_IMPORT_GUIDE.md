# Apps Script Data Import Guide

## Purpose

This document is the import contract for moving historical Google Apps Script data into Laundry Platform V2.

It is intentionally written for an engineer or AI that has no prior knowledge of this application. Read the entire document before generating SQL, migrations, CSV files, or import scripts.

The production database is Supabase PostgreSQL. The target Supabase project currently used by the application is `fcimmysqifzxoanmpylh`.

## Non-negotiable rules

1. Never write converted data directly into production tables before it has been loaded, reconciled, and approved in a `staging` table.
2. Never overwrite existing operational records. Historical corrections are append-only, versioned, superseded, or cancelled according to the target table's rules.
3. Never create UUID relationships by guessing names. Resolve every customer, staff member, product, shift, area, station, trolley, route, and vehicle to its real database ID.
4. Preserve the original source filename, sheet/table name, source row/key, legacy ID, raw value, import batch, and conversion notes.
5. Import scripts must be idempotent. Running the same approved batch twice must not create duplicates.
6. Use one database transaction per logical batch. Any failed validation must roll back the whole batch.
7. Do not create, invite, or modify Supabase Auth users during historical-data import.
8. Do not import personal email addresses into Auth without the employee's explicit onboarding/consent process. Historical staff records and login accounts are separate concepts.
9. Do not use `auth.users`, account roles, permissions, privacy acknowledgements, or passwords as import targets.
10. Use `Europe/Dublin` for local operational timestamps. Preserve the source timezone and offset whenever the source provides them.
11. Empty text is `null`, not zero, `false`, or an invented value.
12. Do not silently repair ambiguous data. Put it in a review queue with the raw value and a clear reason.

## The most important production rule

Official production weight comes from only two sources:

- Clothes: active records in `public.finish_production_entries` with `KG` lines in `public.finish_production_lines`.
- MOP: recorded batches in `public.sorting_mop_production_batches`, using `total_weight_kg` and `physical_processed_on`.

`public.production_official_actuals` is the canonical read model combining those two sources.

Sorting and washing weights are approximate operational measures. Values from `public.sorting_wash_runs.total_weight_kg`, trolley estimates, customer plan estimates, or old Sorting screens must never be imported as official Finish/MOP production KG.

If the legacy source does not prove whether a weight is Finish, MOP, or approximate Sorting weight, stop and classify the row for review.

## Import workflow

Every import must follow these phases:

1. **Inventory** — identify every Apps Script file, sheet, object, key, date range, timezone, and row count.
2. **Extract** — export source data without changing values, preferably as UTF-8 CSV or JSON.
3. **Land** — load the untouched records into a restricted `staging` table.
4. **Profile** — count duplicates, null keys, invalid dates, invalid numbers, unknown codes, and broken relationships.
5. **Map** — create explicit legacy-to-current ID maps.
6. **Review** — do not continue while unresolved blockers exist.
7. **Transform** — convert approved rows into the current model in dependency order.
8. **Validate** — reconcile source totals, target totals, dates, customers, staff, weights, units, and statuses.
9. **Promote** — write the approved batch to operational tables in one transaction.
10. **Audit** — save the batch manifest, validation result, rejected rows, and SQL/migration used.

Recommended batch identifier format:

```text
APPS_SCRIPT_<DOMAIN>_<YYYYMMDD>_<SEQUENCE>
```

Example: `APPS_SCRIPT_FINISH_20261002_001`.

## Required manifest for each source

Before conversion, produce a manifest containing:

```json
{
  "import_batch": "APPS_SCRIPT_FINISH_20261002_001",
  "source_file": "Finish_DB.xlsx",
  "source_sheet": "Production",
  "source_system": "GOOGLE_APPS_SCRIPT",
  "extracted_at": "2026-10-02T10:30:00+01:00",
  "source_timezone": "Europe/Dublin",
  "row_count": 12500,
  "minimum_business_date": "2023-01-01",
  "maximum_business_date": "2026-09-30",
  "source_primary_key": "recordId",
  "sha256": "<file hash>",
  "notes": "<known limitations>"
}
```

If the source has no stable primary key, create a deterministic source fingerprint from the original fields. Do not use a random UUID as the only deduplication key.

## Target selection matrix

| Apps Script data | First landing location | Operational destination | Important rule |
| --- | --- | --- | --- |
| Customer master | `staging.legacy_customer_master` | `public.customers`, `public.customer_product_services` | Match by approved legacy ID/customer code, never name alone. |
| Customer weekly schedule | `staging.legacy_customer_schedule` | Schedule version hierarchy described below | Publish one immutable version after all children are validated. |
| Staff directory | New restricted staging table for the batch | `public.staff_members`, `public.staff_cover_capabilities` | Generate `employee_code`; do not import/create login access. |
| Production roster | `staging.legacy_production_roster_source` | `public.roster_periods`, `public.production_roster_versions`, `public.production_roster_entries` | Requires `staff_members.legacy_user_id` mapping first. |
| Leave/day-off requests | `staging.legacy_leave_request_source` | `public.production_roster_leave_requests` and event/review tables | Preserve the complete decision history and evidence. |
| Finish Clothes production | New restricted Finish-history staging table | Finish entries, lines, trolleys, and flow references | This is official Clothes KG only when source evidence is Finish. |
| ReWash | New restricted ReWash-history staging table | `public.finish_rewash_entries`, `public.finish_rewash_lines` | Keep separate from ordinary Finish entries. |
| MOP production | New restricted MOP-history staging table | MOP batches, lines, trolleys, and flow references | This is official MOP KG. Use physical processing date. |
| Sorting trolley intake | New restricted Sorting-history staging table | `public.sorting_trolley_intakes`, `public.sorting_trolley_intake_products` | Operational trace, not official KG. |
| Sorting wash/load records | New restricted Sorting-history staging table | `public.sorting_wash_runs`, `public.sorting_wash_run_customers` | Weight is approximate; never promote to official production KG. |
| Physical trolley master | New restricted trolley staging table | `public.trolley_types`, `public.trolleys` | `trolley_code` must be unique. |
| Trolley movements/custody | New restricted trolley-event staging table | `public.trolley_customer_stays`, `public.trolley_events` | Preserve chronological event order. |
| Drivers | New restricted Distribution staging table | `public.distribution_drivers` | Link to staff only through a confirmed identity mapping. |
| Vehicles | New restricted Distribution staging table | `public.fleet_vehicles` | Registration/vehicle identity must be deduplicated first. |
| Routes and stops | New restricted Distribution staging table | `public.distribution_routes`, route run and stop tables | Historical run data must not rewrite customer schedules. |
| Driver hours / vehicle mileage | New restricted Distribution staging table | Weekly actual tables | Week start must be Monday. |
| Accounts, passwords, emails, permissions | Do not import | None | Use the application's onboarding and consent workflow later. |

## Core identity mappings

Create and validate these maps before importing dependent history:

| Legacy value | Current identifier | Resolution rule |
| --- | --- | --- |
| legacy customer ID | `customers.customer_id` | Prefer preserved legacy ID in `legacy_metadata`; otherwise approved unique customer code. |
| legacy staff/user ID | `staff_members.staff_id` | Use `staff_members.legacy_user_id`; a display name alone is insufficient. |
| product/service label | `product_types.product_type_id` | Current main codes are `CLOTHES` and `MOP`. |
| MOP item label | `product_variants.product_variant_id` | Use an explicit reviewed legacy variant map. |
| shift label | `shifts.shift_id` | Resolve canonical `MORNING` or `EVENING`; retain snapshot code. |
| Finish table | `stations.station_id` | Resolve `FINISH_TABLE_1`, `FINISH_TABLE_2`, or `FINISH_TABLE_3`. |
| role/position | `operational_roles.operational_role_id` | Use approved role-code mapping. |
| area/station | `areas.area_id`, `stations.station_id` | Resolve canonical codes, not labels. |
| trolley code | `trolleys.trolley_id` | Normalize whitespace/case, then match exact canonical code. |
| trolley size/type | `trolley_types.trolley_type_id` | Use the approved type mapping; do not infer from trolley number. |
| route | `distribution_routes.route_id` | Resolve canonical route code. |
| driver | `distribution_drivers.driver_id` | Prefer legacy driver ID; confirm staff link separately. |
| vehicle | `fleet_vehicles.vehicle_id` | Resolve approved unique registration/legacy vehicle ID. |

Store rejected or unresolved mappings with `raw_value`, `reason_code`, and `review_note`. Never convert unknowns to the closest-looking record.

## Customers and schedules

Existing source landing tables:

- `staging.legacy_customer_master`
- `staging.legacy_customer_schedule`
- `staging.legacy_customer_status_override`
- `staging.legacy_route_mapping`
- `staging.legacy_mop_variant_mapping`
- `staging.legacy_trolley_override`

Existing review views:

- `staging.v_legacy_customer_review`
- `staging.v_legacy_schedule_review`
- `staging.v_legacy_route_review`
- `staging.v_legacy_mop_variant_review`
- `staging.v_legacy_effective_trolley_review`
- `staging.v_legacy_import_blockers`

The operational schedule hierarchy is:

```text
customers
└── customer_schedule_versions
    └── customer_schedule_days
        ├── customer_schedule_products
        │   └── customer_schedule_product_variants
        └── customer_schedule_trolley_requirements
            └── customer_schedule_trolley_requirement_products
```

Rules:

- ISO weekdays are integers: Monday `1` through Sunday `7`.
- A customer schedule is versioned. Do not edit a historical published version.
- Only publish after all days, services, routes, product variants, and trolley requirements validate.
- Imported schedule versions use a clear source such as `LEGACY_IMPORT` or `APPS_SCRIPT_IMPORT`.
- Historical `expected_kg` is not the official production result and must not feed Production Intelligence as an actual.
- Current forecasting learns from real Finish/MOP production history rather than static customer estimates.
- Daily Distribution changes do not rewrite the customer's production schedule.

## Staff directory and accounts

Staff master data belongs in `public.staff_members` and related operational tables. Login identity belongs in Supabase Auth and account-access tables. They must not be conflated.

For a new current staff record, the application uses `public.create_staff_master_auto_code(...)`; employee codes are generated by the database. An importer must not invent or manually reuse `EMP-xxxxx` values.

Historical import rules:

- Preserve a real numeric Apps Script user ID in `legacy_user_id` when available.
- Set `auth_user_id` to `null` unless an already approved, exact account link exists.
- Do not use personal email as an identity key.
- Mark ambiguous roles, shifts, areas, or duplicated names with `import_review_required=true`.
- Deactivated staff remain historical records. Use `active=false`, `deactivated_on`, and a reason; do not delete them.
- Staff transferred to Distribution should not remain active Production staff unless their confirmed employment scope requires both.
- Login invitation, privacy notice acceptance, permissions, and password creation happen after import through the application.

## Production roster and leave history

Use the existing landing tables:

- `staging.legacy_production_roster_source`
- `staging.legacy_leave_request_source`

Roster source is stored by week and shift. `week_start` must be Monday. `source_payload` preserves the complete original JSON.

Required order:

1. Import and validate Staff Master with `legacy_user_id`.
2. Load roster source payloads into staging.
3. Validate staff, shift, weekday, status, role, area, and station mappings.
4. Create or resolve `roster_periods`.
5. Create the appropriate `production_roster_versions`.
6. Insert `production_roster_entries` using resolved IDs plus source snapshots.
7. Reconcile staff/day counts before marking a version published.
8. Import leave requests and their complete event/review history.

Do not infer that a leave request was approved merely because it exists. Preserve explicit decisions. If approval was historically inferred from a saved roster, label the decision basis as inferred and retain the evidence.

## Finish Clothes production history

Operational target:

```text
production_flow_items
└── finish_production_entries
    ├── finish_production_lines
    └── finish_production_trolleys
```

Minimum information required for a trustworthy Finish import:

- stable legacy record/batch ID;
- customer mapping;
- production business date;
- delivery date when known;
- Morning/Evening shift;
- Finish Table 1, 2, or 3;
- batch reference;
- quantity and unit (`KG` or `UNIT`);
- original recorded timestamp;
- recorder/staff mapping when available;
- trolley codes when present;
- cancellation/correction state.

Rules:

- Only `finish_production_lines.unit_code='KG'` contributes to official Clothes KG.
- `UNIT` must be a whole number and is not converted to KG without an approved conversion rule.
- One Finish entry may have multiple lines and batches.
- Corrections must retain the original and use the revision/supersession model. Never update historical quantity in place.
- Active entries use `status='ACTIVE'`; replaced/cancelled rows must not remain active.
- Preserve `shift_code_snapshot`, `table_code_snapshot`, customer identity, and source metadata as they were at the time.
- Do not fabricate trolley, staff, delivery date, table, or production-flow links. Unresolved rows remain in staging.

Because Finish records require valid flow, schedule, staff, station, and audit relationships, do not bulk-insert them directly from CSV. Build a dedicated restricted staging table and a reviewed promotion function/migration for the actual Apps Script format.

## ReWash history

ReWash is stored separately in:

- `public.finish_rewash_entries`
- `public.finish_rewash_lines`

Do not merge ReWash rows into ordinary Finish production. Preserve customer, business date, shift, table, batches, KG/UNIT, recorder, and notes. Use append-only correction behaviour.

## MOP production history

Operational target:

```text
production_flow_items
└── sorting_mop_production_batches
    ├── sorting_mop_production_lines
    ├── sorting_mop_production_trolleys
    └── sorting_mop_reconciliations
```

Minimum information:

- customer;
- business/scheduled/delivery dates when available;
- physical processing date and time precision;
- shift;
- operator mapping;
- total weight and/or units;
- MOP variant details;
- trolley references;
- late-entry/reconciliation evidence;
- cancellation status.

Rules:

- `physical_processed_on` is the official date used by Production Intelligence.
- Recorded batches use `status='RECORDED'`; cancelled batches are excluded.
- `total_weight_kg` is official MOP KG when greater than zero.
- Line totals, variant unit weights, and batch totals must reconcile or be flagged.
- A missed historical entry should be represented as a late reconciliation, not disguised as a live current entry.

## Sorting and washing history

Relevant targets include:

- `public.sorting_trolley_intakes`
- `public.sorting_trolley_intake_products`
- `public.sorting_non_trolley_arrivals`
- `public.sorting_wash_runs`
- `public.sorting_wash_run_customers`
- `public.sorting_wash_reception_exceptions`

Sorting data describes intake, washing, operational trace, and estimated load. It does not establish official produced KG.

For each wash run preserve washer, capacity snapshot, date, shift, operator, start time, wash type, customer allocation, approximate weight, entry mode, correction/cancellation information, and raw source key.

If a single legacy load contains multiple customers and the source has no exact split, preserve the allocation method and uncertainty. Do not invent exact customer KG.

## Trolleys

Master records:

- `public.trolley_types`
- `public.trolleys`

Lifecycle records:

- `public.trolley_customer_stays`
- `public.trolley_events`

Rules:

- `trolley_code` is the physical identity and must be unique.
- Trolley type/size is a foreign key, not free text.
- Do not create a trolley merely because a malformed code appears in a historic note.
- Process movement events chronologically.
- Customer custody must keep sent/received dates, customer IDs, source, exception state, and operator evidence.
- A trolley used by Finish/MOP should link to the correct historical stay when this can be proven.
- If lifecycle continuity cannot be reconstructed, import the validated master trolley first and hold uncertain events for review.

## Distribution

Relevant destinations:

- `public.distribution_drivers`
- `public.fleet_vehicles`
- `public.distribution_routes`
- `public.distribution_route_runs`
- `public.distribution_route_run_stops`
- `public.distribution_run_events`
- `public.distribution_driver_weekly_actuals`
- `public.distribution_vehicle_weekly_mileage`

Rules:

- Production and Distribution access/scopes are separate.
- A route run is historical execution; it must not mutate the customer's recurring production schedule.
- Preserve driver, vehicle, route, run date/status, ordered stops, customer snapshots, planned and actual times, mileage, and exceptions.
- Driver licences, phone numbers, personal emails, and absence details are personal data. Import only fields with a confirmed operational/legal purpose and restrict access.
- Weekly records use Monday as `week_start`.

## Dates, time, numbers, and codes

- Business dates use PostgreSQL `date` in ISO format `YYYY-MM-DD`.
- Exact instants use `timestamptz` with the source offset. If a source time is Dublin local time, resolve it with `Europe/Dublin`, including daylight-saving rules.
- A time with no known date must not be converted to an instant.
- Decimal separators must be normalized explicitly. For example, confirm whether `1,234` means one thousand two hundred thirty-four or `1.234` kilograms.
- KG must be non-negative and normally positive for a recorded production line.
- Units must be integers where required.
- Trim text and normalize comparison case, but preserve the raw source value.
- Canonical application codes are uppercase. Do not translate codes into Portuguese.
- Store user-facing names separately from stable codes.

## Required staging design for sources without an existing staging table

Create a source-specific table in the `staging` schema. It must be inaccessible to `anon` and `authenticated`, have RLS enabled as defense in depth, and contain at least:

```sql
import_batch text not null,
source_file text not null,
source_sheet text,
source_row text not null,
source_record_id text,
source_payload jsonb not null,
source_fingerprint text not null,
import_status text not null default 'LOADED',
blocker_codes text[] not null default '{}',
target_record_id uuid,
import_note text,
loaded_at timestamptz not null default now(),
promoted_at timestamptz
```

Add a uniqueness rule for `(import_batch, source_fingerprint)` and an index for `import_status`. The exact typed columns needed for validation should be added alongside `source_payload`; raw JSON is evidence, not a substitute for typed validation.

Allowed staging status flow:

```text
LOADED -> VALIDATED -> APPROVED -> IMPORTED
                    -> BLOCKED
                    -> REJECTED
```

## Deduplication

Use this priority:

1. stable legacy primary key plus source system;
2. approved legacy-to-current mapping;
3. deterministic fingerprint of immutable source fields;
4. manual review.

Do not deduplicate production solely by customer + date + weight. The same customer can legitimately have multiple batches, tables, shifts, or entries with identical weights.

Recommended import metadata/fingerprint fields:

```json
{
  "source_system": "GOOGLE_APPS_SCRIPT",
  "source_file": "...",
  "source_sheet": "...",
  "source_record_id": "...",
  "source_row": "...",
  "import_batch": "...",
  "source_fingerprint": "sha256:..."
}
```

## Validation gates

No batch may be promoted unless all applicable gates pass:

- source row count equals loaded + explicitly rejected rows;
- no duplicate source key/fingerprint;
- every required customer/staff/product/shift/station/trolley/route mapping resolves exactly once;
- no invalid dates, timezones, negative quantities, or fractional unit counts;
- no overlapping active customer schedule versions;
- roster weeks begin on Monday;
- roster entries reference the correct version and staff;
- Finish active revision uniqueness is preserved;
- Finish KG totals reconcile by date, shift, table, customer, and batch;
- MOP totals reconcile by physical processing date, shift, customer, and batch;
- Sorting approximate KG is excluded from official production totals;
- cancelled/superseded records are excluded from active totals;
- trolley event order and custody are internally consistent;
- target counts and totals are documented before commit.

## Mandatory post-import reconciliation

At minimum, generate a report with:

| Check | Source | Target |
| --- | ---: | ---: |
| total source rows | count | count by imported/rejected/blocked status |
| unique customers | count | mapped customer count |
| unique staff | count | mapped staff count |
| Finish KG | by date/shift/table/customer | `production_official_actuals` where source is `FINISH` |
| MOP KG | by physical date/shift/customer | `production_official_actuals` where source is `MOP` |
| Sorting approximate KG | by date/washer | Sorting tables only |
| roster entries | by week/shift/status | production roster entries |
| leave requests | by type/status | requests plus event history |
| trolley events | by event/date | trolley event ledger |
| route runs/stops | by date/route | Distribution run tables |

Differences must be zero or listed individually with an approved explanation.

## Security and privacy

- Historical files may contain employee and customer personal data. Use only the fields needed for the application's stated operational purpose.
- Keep raw imports in restricted staging tables; do not expose them through the Data API.
- Never place Supabase service-role keys, passwords, SMTP credentials, or personal data in this repository.
- Do not grant `anon` or ordinary `authenticated` access to staging.
- Operational tables are protected by RLS and governed RPCs. A bulk importer must run as a controlled administrative migration/process, not from browser JavaScript.
- Preserve audit evidence without copying unnecessary personal email, phone, complaint, health, or leave-detail data into general-purpose metadata.
- Staff account creation and privacy acknowledgement happen separately through the application.

## What the importing AI must produce

For each supplied Apps Script export, the importing AI must deliver:

1. source inventory and manifest;
2. field-by-field source-to-target mapping;
3. list of assumptions and unresolved values;
4. staging-table migration when no approved staging table exists;
5. deterministic load script;
6. validation/blocker queries;
7. promotion migration or controlled import function;
8. rollback/cleanup procedure for that batch only;
9. reconciliation report;
10. final counts and totals.

The AI must stop before promotion when source meaning is ambiguous, a required relationship cannot be mapped, totals do not reconcile, or the source would violate the official-weight rules.

## Repository references

Read these before implementing an import:

- `docs/database/data-model-v2-foundation.md`
- `docs/database/legacy-customer-import-staging.md`
- `docs/database/legacy-customer-review-decisions.md`
- `docs/database/initial-operational-customer-import.md`
- `docs/database/customers-and-schedules-v2.md`
- `docs/database/staff-master-management.md`
- `docs/database/production-roster-management.md`
- `supabase/migrations/202607300003_legacy_customer_staging.sql`
- `supabase/migrations/202607300006_legacy_customer_operational_import.sql`
- `supabase/migrations/202608080003_legacy_production_roster_and_leave_history_import.sql`
- `supabase/migrations/202608120008_finish_v2_production_foundation.sql`
- `supabase/migrations/202608110010_sorting_mop_production_and_no_trolley_arrival.sql`
- `supabase/migrations/202609260001_production_intelligence_foundation.sql`

The migrations are the final authority for current columns, constraints, and function signatures. Verify the live database schema immediately before creating an import migration because the application is still evolving.
