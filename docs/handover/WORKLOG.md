# Work log — shared by Codex, Claude and the owner

One entry per finished task, newest at the top. Read the open action items and the
latest entries before starting work: they record changes the INIT handover may not
cover yet.

## Open action items

Whoever completes an item ticks it (`[x]`), adds the date and commit, and records the
work as a normal entry below. Remove ticked items at the next INIT refresh.

### For Codex

Completed 2026-10-18 in c796ff3 (INIT v91); recorded by this WORKLOG entry.
The two recurring checklist items below are adopted ongoing rules, not retired obligations.

- [x] **Refresh the INIT handover to v91** in
      `docs/handover/ElisCaretex_V2_PROJECT_INIT_2026-09-10_v87_CURRENT.md`:
  - [x] Add the Distribution work from the 2026-10-17 entry below (commits `1f69f2e` to
        `acfca47`, migrations `202610170002` to `202610170012`): what each workspace now
        does, which permissions/RPCs protect it, and its validation status using the INIT
        evidence terms (Applied, Validated, Owner confirmed, Prepared).
  - [x] Add My Driver Roster and Customer Guides to section 4 (workspaces), the new
        migrations to section 14 and the commits to section 15.
  - [x] Update "Repository state reviewed through" to the newest commit.
  - [x] Section 2: name `AGENTS.md` and `WORKLOG.md` as required reading and state that
        Claude also works on this repository through `claude/*` Pull Requests.
  - [x] Section 18: close checklist item 10. Verified 2026-10-18: the customer KG change set
        (frontend and `202610170001_customer_kg_history_and_weekday_suggestions.sql`) is
        on `master` in commit `9308683` and deployed.
  - [x] Add the migration-history caveat from `AGENTS.md` section 5 to section 14.
- [x] **From now on, after every task:** add a WORKLOG entry (format above), including
      every migration applied to `ElisCaretex-dev`.
- [x] **Before every task:** `git pull origin master`, read this file, and check open Pull
      Requests from Claude so you do not edit the same files at the same time.

### For the owner

- [ ] Decide whether `.reference-distribution/` is still needed. `README.md` describes it,
      but it is not in the repository. Either commit it or remove the README line.
- [ ] Enable leaked-password protection in Supabase Auth when the project moves to the
      Pro plan. It cannot be enabled on the current Free plan (verified 2026-10-19).

### Database size (Supabase Free plan, 500 MB) — after development is complete

Measured 2026-10-19: database 272 MB after the staging `VACUUM FULL`; application data
(`public`) 146 MB for about 9 months of records (~15 MB/month). Owner decision: stay on
the Free plan for now.

- [ ] Export `staging.apps_script_*` to a backup file (Drive or Storage), then drop it
      once the Apps Script reconciliation is finished (~107 MB). Owner approval required.
- [ ] `VACUUM FULL` the bloated `public` tables, for example `sorting_wash_run_customers`
      (29 MB table, 11 MB live data). Estimated 30–40 MB.
- [ ] Remove the 2026-08-06 simulation data (correction log item P-008).
- [ ] Drop the 3 duplicate indexes on `distribution_roster_entries` and
      `distribution_roster_versions` (Supabase performance advisor), through a migration.
- [ ] Review the 23 unused indexes reported by the performance advisor.
- [ ] Later, owner decision: archive detailed production records older than about two
      years to files and keep daily and per-customer totals in the database.

### Done

- [x] 2026-10-19 — Owner: stronger Supabase Auth password policy (minimum length and
      character requirements) set as the Free-plan alternative to leaked-password protection.
- [x] 2026-10-18 — Owner: Pull Request #1 (coordination setup) merged in `296e117`.
- [x] 2026-10-18 — Owner: set `master` as the GitHub default branch and deleted `main`.
- [x] 2026-10-18 — Owner decision, Claude: Graphify is no longer used. Its references were
      removed from `README.md` and `docs/architecture/overview.md`.

Entry format:

```text
## YYYY-MM-DD — <agent: Codex | Claude | Owner> — <short title>
- Branch / commits: <branch, PR number or commit hashes>
- Changed: <what changed, in one to five lines>
- Database: <migration files applied to ElisCaretex-dev, or "none">
- Validation: <what was checked and how; say "not validated" if nothing was>
- Open / next: <what is unfinished, risks, owner decisions needed>
```

---

## 2026-10-29 — Claude — Production Tracker: no duplicate stream after a same-day schedule change

- Branch / commits: `claude/tracker-duplicate-streams`, Pull Request
- Changed: the Production Tracker showed some customers twice per product (one row with the
  real work, one empty "Not started" row with its planned trolley missing). Cause: when a new
  schedule version is published effective on the production day (Customer Studio edit or a
  legacy-sync delivery-order change), the scheduled row carries the new schedule product id
  while the day's flow item still points to the previous version, and V1 matched only on
  that id. 37 flow items on 28-29/10 were affected (e.g. ST CAMILLUS, ADARE, ST ITAS).
  The Finish "Processed actual" card now also shows the staff who processed the Clothes.
- Database: `202610290004_production_tracker_same_day_schedule_version.sql` **Prepared, not
  applied**. Replaces `get_production_tracker_v1`, `_v2` (lifecycle trolleys through either
  schedule product id) and `_v4` (`finish_processed_by`). Read-only RPCs; no data change.
- Validation: rolled-back run against ElisCaretex-dev, 7/7: no customer/product appears twice
  on any of the last 14 days, every flow item of those days is still on the tracker, ST
  CAMILLUS shows 2 streams with its Finish actual and staff name, anon cannot execute.
  `node scripts/validate-repository.mjs` passes.
- Open / next: owner applies the migration. `get_sorting_customer_board_v3` counts trolley
  scans by schedule product id too, so scan counts may reset after a same-day schedule
  change; not changed here.

## 2026-10-29 — Claude — Delivery day can be chosen per production day

- Branch / commits: `claude/delivery-day-choice`, Pull Request
- Changed: owner decision ("apply everywhere"): Edit Schedule has a Delivery day selector
  per production day (next day by default, later days shown as "+n days", no Sunday unless
  already set). The chosen day is used by the Distribution planner and overview, the
  Finish queue, cutoff, entry lock and delivery reconciliation, MOP Production (due date,
  reconciliation, save) and trolley custody planned delivery.
- Database: `202610290003_customer_delivery_day_choice.sql` **Applied** by the owner on
  2026-10-29 (verified: `schedule_delivery_date` exists and the Finish context is patched).
  New `schedule_delivery_date(day, date)` and `customer_delivery_date(customer, date)`;
  trigger `set_automatic_schedule_delivery_weekday` now only defaults an empty delivery
  day and refuses the production weekday itself; 14 live functions are patched in place
  (each replacement must match its expected count). `integration.legacy_sync_*` and
  `get_trolley_production_customers` keep the next-day rule on purpose.
- Validation: `supabase/tests/202610290003_customer_delivery_day_choice_validation.sql`
  12/12 in a rolled-back run on ElisCaretex-dev: every production item of the last 60
  days keeps its delivery date; BLOOMFIELD Monday delivered Wednesday is stored, shown and
  used after publishing. validate-repository passes; mocked Playwright run of the selector.
- Open / next: PR #130 merged 2026-10-29.

## 2026-10-29 — Claude — Customers search box no longer loses the cursor

- Branch / commits: `claude/customers-search-focus`, Pull Request
- Changed: owner report: typing slowly in the Schedule search box lost the cursor after
  the first letter. Each search rebuilt the view with innerHTML, replacing the box. The
  Customers views now keep focus, caret and the typed text (trailing spaces included) of
  the search box across the reload (Schedule, Customer Master and Distribution lists).
- Database: none
- Validation: validate-repository passes; mocked Playwright run typing "BLO O" with 600 ms
  between keys: before the fix the box held "B" and lost focus, after it holds "BLO O"
  with focus.
- Open / next: none.

## 2026-10-29 — Claude — Choose the unit on each trolley line in Edit Schedule

- Branch / commits: `claude/trolley-unit-select`, Pull Request
- Changed: owner request: in Edit Schedule every planned trolley now has its own line
  ("M #1 [unit]") with a unit selector, visible without opening anything; "customer name
  (no unit)" is the default. Two units on one trolley and the instruction stay in the
  "Two units on a trolley or instruction" details below.
- Database: none
- Validation: validate-repository passes; mocked Playwright run: choosing LAUREL and
  PERSON on Tuesday M #1/#2 saves those plates; a trolley with two units shows "S/BROOK &
  KILAKEE" in its line.
- Open / next: none.

## 2026-10-29 — Claude — Customer Schedule shows the units of every customer

- Branch / commits: `claude/schedule-show-units`, Pull Request
- Changed: owner report (ADARE, 2 units, at most 2 trolleys a day): the units were only
  visible in Customer Master and inside Edit Schedule, because the schedule banner only
  appeared above 2 trolleys. Customer Studio now always shows "Units (n)" with the names
  when the customer has units; the check banner above 2 trolleys is unchanged.
- Database: none
- Validation: validate-repository passes; mocked Playwright run of a schedule with 2
  trolleys a day shows the units strip.
- Open / next: none.

## 2026-10-29 — Claude — Units check for customers with more than 2 trolleys

- Branch / commits: `claude/customer-units-check`, Pull Request
- Changed: owner request: every customer with more than 2 trolleys on a day must have its
  units checked, now and after every trolley change. Customer Schedule shows a "Units to
  check" / "Units checked" banner (who and when) and a "Confirm units checked" button on the
  published schedule; publishing a change of such a customer needs the "Units checked" tick.
  The published day cards list every trolley with its unit (or the customer name) instead of
  the text box. Customer Master list: badge per customer, "N with units to check" button
  and a Units filter. Measured 2026-10-29: 29 of 141 active customers need the check.
- Database: `202610290002_customer_schedule_unit_checks.sql` **Applied** by the owner on
  2026-10-29 (verified: table and RPCs exist on ElisCaretex-dev).
  Append-only `customer_schedule_unit_checks` with a signature of the trolleys, plates and
  units checked; a change of any of them makes the schedule TO_CHECK again, other changes
  (for example Expected KG) keep the check. RPCs `get_customer_schedule_units_check`,
  `confirm_customer_schedule_units` (CUSTOMERS EDIT), `get_customer_units_check_overview`.
- Validation: `supabase/tests/202610290002_customer_schedule_unit_checks_validation.sql`
  15/15 in a rolled-back run on ElisCaretex-dev (BLOOMFIELD); validate-repository passes;
  mocked Playwright run of the Customer Master list, the schedule banner, the confirm
  button and the publish tick (refused without it).
- Open / next: PR #125 merged 2026-10-29. The 29 customers with units to check are
  listed by the Units filter in Customer Master.

## 2026-10-29 — Claude — Customer subunits on trolley plates in Finish and MOP Production

- Branch / commits: `claude/customer-subunit-trolley-plates`, Pull Request
- Changed: Customer Master asks for subunits (create and edit, change history). Customer
  Schedule draft: per planned trolley, choose subunits (two can share a trolley) and an
  instruction; "Copy to all days" copies a day's trolleys and plates. Finish and MOP
  Production show one row per planned trolley with subunit or customer name, instruction
  and Print label. New `frontend/assets/js/trolley-plates.js`. Owner review 2026-10-29: the
  screens say "Units" (database names keep `subunit`); the label shows logo, customer, unit,
  trolley, delivery days, route number and colour (read live from the schedule in force and
  Distribution Routes); it prints on A4 twice, the upper copy upside down, so the sheet
  folded in the middle and hung over the trolley bar reads on both sides.
- Database: `202610290001_customer_subunits_and_trolley_plates.sql` **Applied** by the owner on
  2026-10-29 (final version; verified by querying the new tables and the `delivery_days`
  version of `get_production_flow_trolley_plates`). Security advisor after applying: only the
  expected notices for the new tables (RLS on, no policies, read through RPCs) and the
  authenticated `SECURITY DEFINER` RPCs, which check permissions internally.
  The replaced function bodies were checked identical to the live ones before patching.
- Validation: `supabase/tests/202610290001_customer_subunits_and_trolley_plates_validation.sql`
  inside rolled-back runs on ElisCaretex-dev: 30 checks passed together, the change-history
  check was run and passed separately; the delivery days and route part of
  `get_production_flow_trolley_plates` was checked on BLOOMFIELD (Mon–Fri, Route 616);
  the migration file was revised before being applied; validate-repository passes;
  mocked Playwright runs of Customers, Customer Schedule, Finish (desktop and phone) and MOP
  Production, including the printed label.
- Open / next: PR #123 merged 2026-10-29. QR code on the plate is a separate task.

## 2026-10-29 — Claude — Company Documents: confirmation no longer lost when coming back from the PDF on a phone

- Branch / commits: claude/document-ack-phone-return, Pull Request
- Changed: on phones the PDF opens in the phone's viewer and the page often reloads when
  the person comes back (installed app, iOS), which closed the viewer before they could
  confirm, so the document looked "forgotten". The document being read is now remembered
  for the browser tab and the viewer with the confirmation reopens after the reload. A
  slow "opened" reply can no longer turn a fresh confirmation back into "to read".
  Owner report 2026-10-29: staff confirm, then are asked to read again.
- Database: none. Checked ElisCaretex-dev: every confirmation given is stored and still
  counts (no new versions published). Data finding for the owner: "Environmental Policy
  Statement" (EP101) holds the Health & Safety PDF (HSP101), so staff read the same file
  twice under two titles. Fix by publishing the right file with New version.
- Validation: validate-repository passes; mocked phone run in Playwright (reload after
  opening the PDF reopens the confirmation; slow open reply keeps "Confirmed").
- Open / next: owner to replace the Environmental Policy file.

## 2026-10-28 — Claude — Install ElisCaretex on phones as an app (PWA)

- Branch / commits: `claude/pwa-install`, Pull Request
- Changed: added `frontend/manifest.webmanifest`, `frontend/sw.js`, `frontend/offline.html`,
  `frontend/assets/js/pwa.js` and PNG icons in `frontend/assets/img/icons/` (Elis emblem on white,
  plus a maskable and an Apple touch icon). Every page now links the manifest, icons and `pwa.js`.
  The service worker only handles page navigations and only to show `offline.html` when there
  is no connection; it caches nothing else, so pages, scripts and every Supabase request
  (auth included) always come from the network. No stale data, no change to login.
- Database: none
- Validation: `node scripts/validate-repository.mjs` passed. Local Chromium test served under
  `/ElisCaretex/`: service worker registered with scope `/ElisCaretex/`, Chrome reports no
  installability errors and no manifest errors, offline navigation shows the offline page,
  online navigation is unaffected. Not yet tested on a real Android or iPhone (Owner).
- Open / next: after merge, install from Chrome (Android: menu > Install app) and Safari
  (iPhone: Share > Add to Home Screen) and log in once inside the installed app. On iPhone
  the installed app keeps its own login, separate from Safari. Bump `CACHE_VERSION` in
  `sw.js` only when `offline.html` changes.

## 2026-10-28 — Claude — List version footer on the Cloth + MOP print, same as Print

- Branch / commits: `claude/combined-print-list-version`, Pull Request into `master`.
- Changed: both Cloth + MOP prints (production and delivery) now end each page with the
  same footer as the single-service Print: "List version … · Effective … · Generated …",
  bottom left, 98 mm wide, on a white background. Before, the footer started with the
  planner title, which pushed the list version to the middle. Codes stay `CMP-` (production)
  and `CMD-` (delivery).
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed; both prints rendered to PDF
  in Chromium from live planner data (read-only), footer text present on all 3 pages.
- Open / next: owner to confirm on paper.

## 2026-10-28 — Claude — Customer Master: written reason on every edit and visible change history (Prepared)

- Branch / commits: `claude/customer-master-change-history`, Pull Request into `master`
- Changed: owner renamed a customer and was not asked anything, and saw no history. `update_customer` already wrote `audit_log`, but the page filled the reason in automatically and nothing showed the rows. Edit and Reactivate now require a reason typed by the person (at least 10 characters; Save stays disabled until then). New "Change history" (⏱ on every Customer Master row and "View change history" in the edit window) lists every recorded change of the customer: who, when, the reason and each changed field with old → new values, including imports and legacy sync.
- Database: `202610280008_customer_master_change_history.sql`: replaces `update_customer` (reason of at least 10 characters that is not the old automatic text, refuses an edit that changes nothing, stores `product_services` before/after in the audit row); new `get_customer_master_change_history(uuid)`, CUSTOMERS:VIEW, read-only. **Not applied yet**: waiting for the owner.
- Validation: `supabase/tests/202610280008_customer_master_change_history_validation.sql` (17 assertions) passed against ElisCaretex-dev inside a transaction that was rolled back (verified afterwards: function absent, no renamed customer). Page driven in Chromium at 1366×900 and 390×844 with stub data: Save disabled without a reason, the typed reason is sent, history opens over the edit window and Escape closes it; no page errors. `node scripts/validate-repository.mjs` passed.
- Open / next: apply the migration together with the merge. Until it is applied the History button shows an error, and edits keep working (the old function accepts the typed reason).

## 2026-10-28 — Claude — My Production / Driver Roster: phone menu no longer hidden by the roster banner (Prepared)

- Branch / commits: `claude/roster-mobile-menu-overlap`, Pull Request into `master`
- Changed: inside the shared shell the roster banner (`.rv-header`) kept `z-index: 100` from `roster-view.css`, above the phone navigation drawer (`z-index: 60`). The banner with the Morning/Evening tabs and the leave request button covered the drawer, so its items under the banner could not be tapped. `enterprise-ui.css` now resets that z-index to `auto` for the in-shell banner; both roster pages load the stylesheet with a new version query so phones get the fix.
- Database: none
- Validation: `node scripts/validate-repository.mjs`; Playwright at 390×844 with the drawer open: every point of the drawer is the drawer on all 19 shell pages (before the fix the banner was on top on both roster pages); with the drawer closed the leave request button is still on top.
- Open / next: owner to confirm on a phone after merge.

## 2026-10-28 — Claude — Company Documents: Risk assessment section (Prepared)

- Branch / commits: `claude/company-documents-risk-assessment`, Pull Request into `master`.
- Changed: owner asked for a section to attach Risk assessment documents. New section
  `RISK_ASSESSMENT` ("Risk assessments") next to Company policies and SSOW, with the same rules
  (areas, revision, confirmation, one stored file). Section filter, form option, orange section
  tag; the home card description mentions risk assessments.
- Database: `202610280009_company_document_risk_assessment.sql`: `company_documents_category_check`
  accepts RISK_ASSESSMENT; `create_company_document` and `update_company_document_details`
  (redefined from 0007) accept and log it and refuse unknown sections. **Not applied** yet.
- Validation: `supabase/tests/202610280009_company_document_risk_assessment_validation.sql` and the
  0007 validation passed on the local PostgreSQL 16 replica; pages rendered in Chromium with stub
  data, no console errors; `node scripts/validate-repository.mjs` passed.
- Open / next: owner applies the migration, then merges.

## 2026-10-28 — Claude — Company Documents: confirming on a phone no longer freezes (Prepared)

- Branch / commits: `claude/company-documents-speed`, Pull Request into `master`.
- Changed: owner reported the page slow and the confirmation stuck on a phone with a staff account.
  Cause 1: after opening a document the page recorded the opening only once the file was loaded,
  then redrew the confirmation box, clearing a tick the person had already given and disabling
  Confirm again (reproduced in Chromium with a 900 ms network). The opening is now recorded at the
  same time as the file loads and a refresh never clears an existing tick; Confirm cannot be sent
  twice and shows an error inline. Cause 2: on phones the PDF was still loaded in a hidden frame
  and the viewer used `100vh`, which puts the Confirm button behind the browser bar. Phones now get
  an "Open the document" button (the phone's own PDF viewer) and the viewer uses `100dvh` and the
  safe area.
- Database: none. Live timings checked as a staff account: `get_my_company_documents` 24 ms,
  summary 3 ms, Storage read check 6 ms.
- Validation: iPhone 13 emulation with slow RPCs (tick before the opening is recorded, then
  Confirm) passes and fails on the previous code; desktop screenshots unchanged, no console errors;
  `node scripts/validate-repository.mjs` passed.
- Open / next: none.

## 2026-10-28 — Claude — Company Documents: revision number and date, re-read on every new file (Applied)

- Branch / commits: `claude/company-documents-revision`, Pull Request into `master`.
- Changed: owner asked for the revision number and revision date printed in each document footer,
  so anyone can tell whether a copy is current, and that every new file of a published document
  makes everyone read and confirm it again. Add document and New version now require both (a new
  version needs a different number and a date not earlier than the current one, never in the
  future); Edit details can correct a typo and logs it. The revision shows on staff cards, the
  viewer, the confirmation sentence, Manage documents, Who read, the update log and both CSV
  exports. The "small correction, keep confirmations" option is gone.
- Database: `202610280007_company_document_revisions.sql`: `revision_number`/`revision_date` on
  `company_documents` and `company_document_history`; new internal helpers
  `company_document_check_revision` and `company_document_revision_label`;
  `replace_company_document_file(uuid,jsonb,text,integer)` replaces the 5-argument version (dropped)
  and always moves `acknowledgement_version`; `get_my_company_documents`, `create_company_document`
  and `update_company_document_details` carry the revision. Applied by the owner on 2026-10-28. No documents
  existed live when it was written.
- Validation: `supabase/tests/202610280007_company_document_revisions_validation.sql` passed on the
  local PostgreSQL 16 replica (0001 + 0006 + 0007). The 0001 and 0006 validations call the RPCs
  without a revision, so they now describe the earlier state. Page driven in Chromium with stub
  data, no console errors; `node scripts/validate-repository.mjs` passed.
- Open / next: owner applies the migration together with the merge (the old page calls the
  removed 5-argument RPC, so publish the page and the migration close together).

## 2026-10-28 — Claude — Company Documents by area (Applied)

- Branch / commits: `claude/company-documents-areas`.
- Changed: owner asked to limit SSOW (and any document) to areas: Sorting, Finish, MOP,
  Distribution, Cleaner, Label, Maintenance; one document can be for several areas, none means
  everyone. New table `company_document_areas`; area picker in the add/edit form; area tags on
  cards and rows; area filters on Manage documents and Read status by staff; CSV exports carry
  document and staff areas. Staff see and confirm only their areas' documents (list, Storage
  file, open, confirm and the pending count all check it). Managers and status viewers still see
  every document; one outside their areas shows as "Other area" and is not pending for them.
  "Who read" counts only the people of the document's areas.
- A person's areas: Staff Master default area (SORTING/WASHING -> Sorting, FINISH, MOP,
  DISTRIBUTION), primary operational role (CLEANER, LABEL, MAINTENANCE, SORTING_AREA, DRIVER),
  account job title (CLEANER, LABEL_OPERATIVE, MAINTENANCE, DRIVER, LOGISTICS_MANAGER) and an
  active Distribution driver record (`company_document_person_areas`).
- Database: `202610280006_company_document_areas.sql` applied by the owner on 2026-10-28 (replaces
  `company_document_audience`, which gains an `areas` column, and the staff/manager RPCs).
- Validation: `supabase/tests/202610280006_company_document_areas_validation.sql` and the 0001
  validation both pass on a local PostgreSQL 16 replica with 0001 + 0005 applied. Pages rendered
  in Chromium with stub data (staff of Finish does not see a Sorting SSOW; admin sees it as
  Other area).
- Open / next: owner applies the migration. Live data on 2026-10-28: Staff Master default areas
  are set only for Finish (34) and Sorting (7); nobody has MOP, Distribution, Cleaner or
  Maintenance yet, so documents for those areas reach only people whose job title, role or driver
  record says so.

## 2026-10-28 — Claude — Stock Control: locker key requests, leaving dates, chemical count screen, new overview (Prepared)

- Branch / commits: `claude/stock-improvements`, Pull Request into `master`.
- Changed (owner feedback after trying a staff account): My PPE & Uniform was reorganised (locker key
  and what I hold at the top; tabs Request items / My requests / History; history shows 12 rows
  with Show all). Staff now see their locker key. Without one, or with a problem (lost, wrong
  locker, broken), they send a locker key request; Stock Control answers it with Assign a locker
  (optionally returning the key held now), Mark as solved (note required) or Decline. When Staff
  Master has a last working day (`staff_members.deactivated_on`, also a scheduled one), staff see
  a notice listing every item and key to return, and Stock Control lists them under Returns due
  before they leave. Stock count is now a card per item with large − / + buttons, "Same" for an
  unchanged item, a progress bar, chemicals due first and a draft kept in the browser until saved.
  The Overview now has four tiles (requests, chemicals to count, low stock, returns due), one
  "Needs attention" list and recent activity; quick actions moved to the banner.
- Database: `202610280005_stock_control_locker_requests_and_leavers.sql`: `stock_requests` gets
  `request_kind` (ITEMS / LOCKER_KEY) and `locker_id`; new `submit_my_locker_request(text)` and
  `resolve_locker_request(uuid,text,uuid,text,integer,boolean)`; `decide_stock_request` only
  declines locker requests; `get_my_stock` returns `leaving_on`; `get_stock_workspace` returns
  people leaving or left who still hold items with `leaving_on`. **Not applied** yet.
- Validation: `supabase/tests/202610280005_stock_control_locker_requests_validation.sql` and the
  earlier stock test passed on the local PostgreSQL; both pages driven in Chromium (phone count,
  locker assign with the old key returned, staff report) with no console errors;
  `node scripts/validate-repository.mjs` passed.

## 2026-10-28 — Claude — Stock Control layout matches the platform (Prepared)

- Branch / commits: `claude/stock-control-layout`, Pull Request into `master`.
- Changed: owner asked to keep the same layout as the rest of the platform. `stock.css` now uses
  the standard teal banner (as Company Documents), underlined tabs (as Customer Service and
  Production Intelligence), teal accents instead of blue and the full-width work area. Applies to
  Stock Control and My PPE & Uniform. CSS only; no database change.
- Validation: both pages rendered in Chromium against the local test database;
  `node scripts/validate-repository.mjs` passed.

## 2026-10-28 — Claude — Stock Control: PPE/uniforms, chemicals, miscellaneous, staff requests and locker keys (Applied)

- Branch / commits: `claude/stock-control`.
- Changed: owner asked to bring the "Elis Stock Control" Apps Script into the platform (areas
  PPE & uniforms, chemicals and miscellaneous) and to let every staff member with a roster
  login (production and distribution) request PPE and uniforms. New page
  `pages/stock.html` (Management > Stock Control: Overview, Staff requests, Items, Stock count,
  PPE & keys by person, Locker keys, Usage & forecast, History) and `pages/my-stock.html`
  (My work > My PPE & Uniform: request with size and quantity, follow the answer, see what is
  held). Same rules as the Apps Script: items are booked to a person, to a customer (packing) or
  to nobody (chemicals, usage comes from the count: a drop is CONSUMPTION); immediate low-stock
  and chemicals-due lists; leavers still holding PPE or a locker key are listed as pending
  returns. Requests: REQUESTED -> APPROVED -> ISSUED, or REJECTED (reason required) or
  CANCELLED by the person; handing over takes the items out of stock and registers them in the
  person's name. Sidebar badge and Home card count requests waiting.
- Permissions: module `STOCK` (already in `application_modules`). VIEW = read the workspace;
  EDIT or APPROVE = movements, counts, PPE, keys and requests; MANAGE = catalogue, lockers,
  settings. Templates: Administrator, General Manager, Production Manager MANAGE; Logistics
  Manager and Production Supervisor approve/edit; Auditor VIEW. Requesting needs no STOCK grant:
  an enabled personal account linked to an active Staff Master record with My Roster or My
  Driver Roster access. Tables closed to clients; every RPC checks access.
- Database: `202610280003_stock_control.sql` (tables, RPCs, permissions) and
  `202610280004_stock_control_apps_script_import.sql` (batch `APPS_SCRIPT_STOCK_20261028_001`:
  raw rows landed in `staging.apps_script_stock_rows`, people matched only by legacy ids, 72 of
  73 matched; EMP-0070 "Ryotaro" has no Staff Master record and holds nothing; 33 items, 96
  movements, 15 counts, 8 uniform records, 80 lockers with 24 assigned, 24 key events; CONFIG
  (API key) and CUSTOMERS not imported). **Applied** by the owner in the SQL Editor on
  2026-10-28. The editor ran the script without the outer transaction, so the import's
  `on commit drop` temporary table reported 42P01; checked afterwards that every object and
  every imported row is present (reconciliation counts match). The import now uses a plain
  temporary table so a re-run is safe.
- Validation: `supabase/tests/202610280003_stock_control_validation.sql` passed on a local
  PostgreSQL 16 with stub auth/staff tables (fixtures created and rolled back inside the test);
  the import was run twice locally (idempotent, reconciliation block passed). Both pages were
  driven in Chromium against that local database (request -> hand over -> stock and holdings
  updated, count with chemical usage, locker return, PPE issue) with no console errors.
  `node scripts/validate-repository.mjs` passed. On `ElisCaretex-dev` the owner ran the
  test file (PASSED, rolled back) before applying.
- Open / next: merge the Pull Request to publish the pages. Low-stock emails, the
  daily digest and the weekly chemical reminder from the Apps Script are not ported (no e-mail
  job for this module yet); stock is per item, sizes are recorded on issue and request but not
  stocked per size. INIT handover not refreshed for this module yet (Codex refresh).

## 2026-10-28 — Claude — Legacy Sync: customer schedules and routes join the nightly sync (Prepared)
- Branch / commits: `claude/legacy-sync-schedules`, Pull Request into `master`.
- Changed: sixth part of the full sync, run after the registers. CentralDB `Routes` (one record per
  RouteID; name and colour only, owner decision 2026-10-28: KM and hours stay as edited in V2) and
  `CustomerSchedule` (one record per CustomerID with all its production days). A schedule change is a
  new published revision (source `LEGACY_IMPORT`, effective from the current business date) built
  from the current V2 revision; published revisions are never edited. Same rule as the registers:
  a value the legacy app changed since the baseline is written, every other value keeps V2. First
  baseline is the customer's latest `LEGACY_IMPORT` revision (the 2026-10-23 dist1 import), so
  legacy changes since then are written and hand corrections in V2 (for example Orwell's Friday
  route) are kept and listed as `V2_DIFFERS`. Delivery weekday is not synced (V2 derives it). An
  open draft or a future revision in V2 holds the customer for review. Apps Script page shows a
  Schedules part; review items for V2-side holds say "fix in Customer Studio".
- Database: `202610280002_legacy_sync_customer_schedules.sql` prepared, not applied. New switch
  `SCHEDULE_IMPORT` (seeded OFF, limit 200); link roles `ROUTE_MASTER` and `CUSTOMER_SCHEDULE`;
  `legacy_sync_review_list` also closes items whose record was synced again (states, not only links).
  No Edge Function deploy needed (generic `dry_run` / `import` kinds).
- Validation: `supabase/tests/202610280002_legacy_sync_customer_schedules_validation.sql` 11/11 on
  the local replica; all 146 real records (9 routes, 137 customers, CentralDB of 27/10) planned and
  imported locally without errors, and a second plan finds them all already imported; 0013 and 0014
  tests still pass. Comparison with live on 28/10: same 137 customers and 434 days; 26 customers
  differ (31 delivery orders, 3 routes, 3 trolleys, 2 delivery notes; 3 delivery weekdays are V2's
  automatic rule).
- Open / next: owner applies 0002 and its test, publishes the new `.gs` and `Index.html`, runs
  Preview, then Turn on (switches the new part on with the others). Then production and
  distribution rosters.

## 2026-10-28 — Claude — Production Tracker: Production map is the main view; Operational list removed

- Branch / commits: `claude/tracker-map-default`, Pull Request into `master`
- Changed: owner request. Production Tracker now opens on the Production map (page, side menu
  and the Tracker embedded in Sorting); the Operational list view, its JS and CSS are removed
  (old `?view=list` links open the map). Views are now Production map and Route board.
  "Back to map" on the Route board (after clicking a customer on the map) returns to the exact
  place: same week, same search/status/type filters, same scroll position, and the customer
  that was opened gets a short highlight.
- Database: none
- Validation: `node scripts/validate-repository.mjs`; Playwright with the stubbed Supabase client
  and the 19–24 Oct 2026 flow items, desktop and 390 px mobile: default view is the map, old
  list URL opens the map, Back to map restores scroll (1323 px desktop, 9330 px mobile) and the
  CLOTHES filter, no console errors. Not validated against the live RPC with a signed-in user.
- Open / next: none. Browsers holding a cached `app-shell-policy.js` may show the old
  "Operational list" menu item for a few minutes; it now opens the map.

## 2026-10-28 — Claude — Company Documents: policies and SSOW with read confirmation (Applied)

- Branch / commits: `claude/company-documents`.
- Changed: owner asked for company policies and SSOW (PDF or photo) available to every staff
  member with a login, with a way to confirm each one, managers publishing and replacing them,
  an update log, only one physical file per document and a view of who read what. New page
  `pages/company-documents.html` (My documents / Manage documents / Read status by staff), home
  card and sidebar entry "Company Documents" in My work with a count of documents to confirm.
  Files go to the private Storage bucket `company-documents` (20 MB, PDF/JPG/PNG/WebP; large
  photos are reduced in the browser). A new version uploads the new file, the RPC switches the
  document and returns the old path, and the browser deletes the old file; files left behind are
  listed in `orphan_paths` and removed on the next manager visit. Confirmations are per version:
  the manager chooses "confirm again" (default) or "small correction, keep confirmations".
  Archive hides a document and keeps its file; Delete removes the file and keeps the log and the
  confirmations.
- Permissions: reading and confirming needs no grant (every enabled personal account; never
  production terminals). New module `COMPANY_DOCUMENTS`: VIEW = read status of everyone,
  MANAGE = publish, replace, edit, archive, delete. Templates: Administrator, IT Manager,
  General Manager, Production Manager and Logistics Manager MANAGE; Production Supervisor and
  Auditor VIEW; existing accounts of those titles receive the grant (additions only).
- Also: `.operational-nav-badge[hidden]` now stays hidden when the sidebar is open (a zero
  Notifications count showed as "0"). Cache versions bumped for `app-shell-policy.js`,
  `operational-page-nav.js`, `app.js` and `navigation.css`.
- Database: `202610280001_company_documents.sql` applied by the owner (tables, bucket and 18
  functions verified live on 2026-10-28); PR #109 merged.
- Validation: `supabase/tests/202610280001_company_documents_validation.sql` passes on a local
  PostgreSQL 16 with stub `auth`/`storage` schemas (staff cannot publish, missing file refused,
  open/confirm, wrong version refused, correction keeps confirmations, new version asks again,
  VIEW cannot change, terminal refused, archive/delete, 5 log events, anon and audience closed);
  Storage policies checked as `authenticated` on the same replica. Pages rendered in Chromium
  with stub data at 1440 px and 390 px. PDF preview inside the page is not shown by headless
  Chromium; real browsers show it.
- Open / next: run the validation on `ElisCaretex-dev`; publish a first document and confirm it
  from a staff account.

## 2026-10-27 — Claude — Legacy Sync: pending records and owner choices on the Apps Script page (Prepared)

- Changed: owner asked to see each record the sync holds and keep his choice. New "Pending"
  card on `Index.html`: each open review item with the reason, the detail and where to fix it
  (sheet and tab); items that only wait for another part are shown as waiting. Two choices,
  with an optional note: "Will fix in the sheet" (`FIX_IN_SOURCE`, status APPROVED) and "Do not
  import" (`NOT_IMPORTED`, status REJECTED); kept with who (Apps Script user e-mail), when and the
  record fingerprint. `legacy_sync_hold_for_review` no longer raises the same item for a decided
  version; a changed legacy row is read again. Reading the list closes open items whose record
  was imported later (SUPERSEDED, `IMPORTED_LATER`). Edge Function gains `review_list` and
  `review_decide`; `LegacySyncFinish.gs` gains `getLegacySyncReviews` / `decideLegacySyncReview`.
- Database: `202610270014_legacy_sync_pending_review.sql` prepared, not applied. Migrations
  0012 and 0013 were applied by the owner.
- Validation: `supabase/tests/202610270014_legacy_sync_pending_review_validation.sql` 8/8 on the
  local replica; Edge Function request shapes 8/8 (Node, types stripped); page rendered with
  stub data in Chromium.
- First live sync (owner, 2026-10-27 20:59, SYNC_NOW, 25-27 Oct): registers 930 ADOPTED, washes
  85 IMPORTED, attendance 69 IMPORTED and 1 held (Belen Vas 26/10, `WORK_OVER_13_HOURS`);
  stopped at the 5-minute budget. Open items at 21:50: 10 MOP waiting for 24/10 washes (outside
  the 3-day window), 8 trolleys waiting for MOP, ReWash 0.012 kg, Belen Vas.
- Applied: 0014 by the owner (functions verified live). Edge Function `legacy-sync-finish` v7
  deployed by Claude on owner approval (2026-10-27 22:03, JWT verification off, from this file).
- Open / next: owner publishes the new `.gs` and `Index.html` as a new web app version.

## 2026-10-27 — Claude — Legacy Sync: Ryotaro is one person under legacy users 111 and 112 (Prepared)

- Changed: owner confirmed that legacy user 111 "Ryotaro" (deactivated 2026-10-24) and 112
  "Ryotaro Kawauchi" are the same person, named "Ryotaro Kawauchi". New value map domain
  `STAFF_USER_ALIAS` (append-only, retire to undo) maps 111 -> 112; `legacy_sync_resolve_staff`
  reads it first, so washes, MOP, trolley intakes and attendance under either ID reach the same
  V2 person; the register sync skips 111 (`LEGACY_USER_ALIAS`) instead of creating a second
  person. The V2 person moves from `legacy_user_id` 111 to 112 and is renamed.
- Database: `202610270013_legacy_sync_staff_user_alias.sql` prepared, not applied. Live check
  before: one V2 person "Ryotaro" with legacy 111, none with 112. Migration 0012 was applied by
  the owner.
- Validation: `supabase/tests/202610270013_legacy_sync_staff_user_alias_validation.sql` 8/8 on
  the local replica (with a "Ryotaro" 111 fixture); 0007, 0008, 0009, 0010 and 0012 tests still pass.
- Open / next: owner applies 0013 and its test; the 11 washes and 2 attendance rows held for
  user 112 then import.

## 2026-10-27 — Claude — Legacy Sync: migrations 0007–0011 applied, Edge Function v6 deployed

- Changed: no code. Live state recorded after the owner applied the pending migrations.
- Database: the owner applied `202610270007` (washes), `202610270008` (MOP), re-ran
  `202610270009` and `202610270010` to restore the dispatcher, then `202610270011`
  (registers), each followed by its validation script. Verified by query: the import
  functions for wash, mop, trolley, attendance and master exist, the dispatcher routes all
  five kinds, `integration.legacy_sync_master_states` exists and every new switch
  (SORTING_WASH, MOP_PRODUCTION, TROLLEY_CUSTODY, ATTENDANCE, MASTER_DATA) is still off.
- Deploy: Edge Function `legacy-sync-finish` v6 (generic `dry_run` / `import` operations,
  JWT verification off as before), approved by the owner on 2026-10-27.
- Validation: read-only register dry run on the live database with the 935 CentralDB rows:
  636 trolleys ADOPT with no differences; 153 customers ADOPT (12 active in legacy but
  inactive in V2); staff 107 ADOPT, 1 ADOPT_BY_NAME (113), 1 CREATE (112), 4 SKIPPED;
  17 drivers and 16 vehicles ADOPT; nothing blocked. Differences listed for the owner in the
  Claude Doc "Cadastros: diferenças entre o legado e o V2". Vehicle `legacy_registered_at`
  / `legacy_updated_at` in V2 are one hour ahead (an earlier import read Dublin time as UTC).
- Fix: "Turn on" returned HTTP 500 (`21000 UPDATE requires a WHERE clause`): the Data API
  session runs pg-safeupdate and the `legacy_sync_control` from `202610270007` updates every
  switch without a WHERE. Nothing changed. `202610270012_legacy_sync_control_where_clause.sql`
  (Prepared) recreates it with `where setting_key is not null`; test
  `supabase/tests/202610270012_legacy_sync_control_where_clause_validation.sql` 4/4 locally.
- Preview run by the owner (24-27 Oct) worked: Registers 931 ready; Washes 11 and Attendance 2
  held for legacy user 112 (created by the Registers part first); MOP and Trolleys held until
  Washes / MOP are in V2, as designed; ReWash 0.012 kg still in review.
- Open / next: owner applies 0012 and its test, turns the sync on, then says which listed
  differences the legacy value should win.

## 2026-10-27 — Claude — Legacy Sync: CentralDB registers join the nightly sync (Prepared)
- Branch / commits: `claude/legacy-sync-sorting-washes` (same PR)
- Changed: fifth part of the full sync, run first. Every row of CentralDB `User`, `CustomerMaster`,
  `Trolley`, `Driver` and `Vehicles` is planned each night; only rows that changed are written.
  Owner decision 2026-10-27 ("starting point + list"): a row with no V2 record creates it; the
  first time a row meets an existing V2 record it is only linked and today's differences are
  listed (`V2_DIFFERS`), not applied; afterwards each field the legacy app changes is written and
  the others keep their V2 value. Deactivations follow the V2 screens (customer services ended
  and schedules superseded; trolley service hold; driver unavailable). Page shows a Registers
  part and the list of differences in the Preview.
- Database: `202610270011_legacy_sync_master_data.sql` prepared, not applied (apply after
  0007-0010). New append-only table `integration.legacy_sync_master_states`.
- Validation: `supabase/tests/202610270011_legacy_sync_master_data_validation.sql` 17/17 on the
  local replica; all 935 real rows imported locally without errors, a second plan finds all
  already imported.
- Open / next: send the owner the list of today's differences once 0011 is applied (dry run on
  live); then customer schedules and routes (new versions), then rosters.
- Note: on 2026-10-27 test 0010 passed live, but 0007 and 0008 were still not applied
  (`legacy_sync_import_wash` missing). Order given again: 0007, 0008, then 0009 and 0010 again.

## 2026-10-27 — Claude — Legacy Sync: attendance joins the nightly sync (Prepared)
- Branch / commits: `claude/legacy-sync-sorting-washes` (same PR)
- Changed: fourth part of the full sync, run first. Finish `StaffSessions` become Finish
  attendance + work sessions at the legacy table and times, `RosterNotWorking` becomes Finish
  ABSENT (sessions of the shift cancelled), Sorting `Staff` rows become Sorting attendance + work
  sessions with the legacy times and break. Legacy changes correct, cancellations cancel, V2
  sessions are adopted (legacy value wins). Page shows an Attendance part.
- Database: `202610270010_legacy_sync_attendance.sql` prepared, not applied (apply after 0007-0009).
- Validation: `supabase/tests/202610270010_legacy_sync_attendance_validation.sql` 16/16 on the
  local replica; 0006-0009 tests still pass; collector on the real sheets (80 records 24-27 Oct).
- Note: on 2026-10-27 the owner applied 0009 before 0007/0008; its test failed because the wash
  and MOP functions were missing. Order given: 0007, 0008, then 0009 again (re-runnable), then tests.
- Open / next: master data and rosters; Ryotaro Kawauchi (112) and Alessandra Laura (113) are not
  in V2 yet.

## 2026-10-27 — Claude — Legacy Sync: trolley custody and Sorting intakes join the nightly sync (Prepared)
- Branch / commits: `claude/legacy-sync-sorting-washes` (same PR as the washes and MOP parts)
- Changed: third part of the full sync (owner decision: trolley custody follows the legacy
  sheets). One part `trolley`, in time order and after Finish and MOP: each trolley code typed on
  a legacy Finish entry or MOP save opens the V2 customer stay (as
  `assign_finish_trolley_to_flow`), and each CentralDB `TrolleyReturns` row becomes a V2 Sorting
  intake (as `record_sorting_trolley_intake_v2`: stay closed or MISSING_OUTBOUND, trolley
  AVAILABLE, products and Production Flow events, presence evidence). Legacy corrections write a
  revision, legacy voids cancel; intakes already in V2 (2026-10-24 local import by ClientEventID,
  or the same trolley and shift within 4 hours) are adopted. Stays left open since the 2026-09
  inference are closed as returned before tracking when legacy production fills the trolley
  again. Page shows a Trolleys part and "Turn on Trolleys".
- Database: `202610270009_legacy_sync_trolley_custody.sql` prepared, not applied.
- Validation: `supabase/tests/202610270009_legacy_sync_trolley_custody_validation.sql` 16/16 on
  the local replica; 0006, 0007 and 0008 tests still pass; Apps Script collector on the real
  sheets (413 records 24-27 Oct) and a local dry run of all of them without errors.
- Open / next: owner applies 0009 after 0008 and runs its test. Next parts: attendance, master
  data and rosters.

## 2026-10-27 — Claude — Legacy Sync: MOP production joins the nightly sync (Prepared)
- Branch / commits: `claude/legacy-sync-sorting-washes` (same PR as the washes part)
- Changed: second part of the full sync. CentralDB `MopProduction` (+ History) rows of one
  WashItemID become one V2 MOP production, written like `save_sorting_mop_production`
  (lines, totals, shift, operator, processed time, trolley codes as references, late-entry
  reconciliation, Production Flow event), with corrections, legacy cancellations, adoption of a
  production typed in V2, and the ABS batch once POSTED. Apps Script collects MOP after washes
  and runs it through the generic `dry_run` / `import` operations (no new Edge Function deploy).
  Page shows a MOP part and "Turn on MOP".
- Database: `202610270008_legacy_sync_mop_production.sql` prepared, not applied.
- Validation: `supabase/tests/202610270008_legacy_sync_mop_production_validation.sql` 16/16 on
  the local replica; 0006 and 0007 tests still pass; Apps Script collector on the real CentralDB
  (61 MOP customers 24-27 Oct).
- Open / next: owner applies 0008 after 0007 and runs both tests. Next parts: trolley
  reception/custody, attendance, master data and rosters.

## 2026-10-27 — Claude — Legacy Sync: Sorting washes join the nightly sync (Prepared)
- Branch / commits: `claude/legacy-sync-sorting-washes`
- Changed: owner decisions 2026-10-27 — everything the legacy apps record must reach V2 through
  the sync, as if typed in V2; trolley custody follows the legacy sheets; master data is still
  edited in the legacy sheets, so it will be synced too. First part: Sorting washes
  (`Sorting Area` + CentralDB `WashItems` + Sorting `Staff`), written like
  `save_sorting_wash_run_v2` with schedule snapshot, Production Flow link and corrections.
  Generic `dry_run` / `import` Edge Function operations with a database dispatcher, so later
  parts need no new deploy. Control ON/OFF switches every part. Apps Script page shows Washes.
- Database: `202610270007_legacy_sync_sorting_washes.sql` prepared, not applied.
- Validation: `supabase/tests/202610270007_legacy_sync_sorting_washes_validation.sql` 16/16 on
  the local replica; 0006 control test still 12/12; Deno handler tests; Apps Script collector run
  on the real Sorting workbook (147 loads 24-27 Oct, all shifts from the Staff sheet).
- Open / next: owner applies 0007 and runs the test, approves the Edge Function deploy, replaces
  `LegacySyncFinish.gs` and `Index.html`, enables the `sorting` source, previews, then presses
  "Turn on Washes". Owner to confirm whether "Ryotaro Kawauchi" (legacy 112) is V2 "Ryotaro".
  Next parts: MOP production, trolley reception/custody, attendance, master data and rosters.

## 2026-10-27 — Claude — Legacy Sync: switched ON from the Apps Script page, first Sync now

- Branch / commits: `claude/legacy-sync-live-record` (docs only).
- Database / deploy: the owner applied `202610270006` and published the new `Index.html` and
  `LegacySyncFinish.gs`; Edge Function `legacy-sync-finish` v5 (with `control`) deployed on the
  owner's approval, identical to `master`. The owner pressed "Turn on" (schedule and both import
  switches ON, limit 300, changed_by `Apps Script admin page`) and "Sync now".
- Validation: run `dc2abc81-…` (SYNC_NOW, 25-27 October) COMPLETED: Finish 5 IMPORTED, ReWash
  3 IMPORTED + 1 BLOCKED (the known 0.012 kg record, no duplicate review item); 31 links;
  0 open insert permits.
- Open / next: the sync now runs every night 02:00-05:00 Dublin for the last 3 days. Still open:
  deletions in the legacy sheet are not detected; the 0.012 kg review item waits for the owner.

## 2026-10-27 — Claude — Legacy Sync: on/off and Sync now on the Apps Script page (Applied)

- Branch / commits: `claude/legacy-sync-control-in-apps-script`.
- Why: owner decision, the switch belongs on the Apps Script page, not in V2.
- Changed: migration `202610270006_legacy_sync_control_from_apps_script.sql` (service-role
  `integration.legacy_sync_control`; drops the three V2 RPCs from 202610270005); Edge Function
  `legacy-sync-finish` gains `control`; `LegacySyncFinish.gs` gains `setFinishSyncEnabled`,
  `syncFinishNow` and a V2 status in `getFinishSyncPanel`; `Index.html` gets the "Sync to V2"
  card (ON/OFF, Sync now, last runs); the Finish Results panel and its JS/CSS are removed.
- Database / deploy: nothing applied. Needs the owner: apply the migration, then the Edge
  Function redeploy, then paste `Index.html` and `LegacySyncFinish.gs` and publish a new version.
- Validation: 12/12 SQL checks on the local replica; Edge Function handler tests pass (control
  included); Apps Script harness passes (switch, Sync now window, no poll from the page); page
  checked at 1000 px and 390 px with a mocked `google.script.run`; validate-repository passes.

## 2026-10-27 — Claude — Legacy Sync: cleaner Apps Script admin page

- Branch / commits: `claude/legacy-sync-admin-page`.
- Changed: new `legacy-sync/apps-script/Index.html` replaces the v3.1 page (owner: "too
  cluttered"). It shows the status (sheet reading, 5-minute trigger, V2 connection), a
  preview/import by date range with readable counts, and the source spreadsheets; the v3.1
  diagnostics, the old daily switch and the inbox connection are folded away. `LegacySyncFinish.gs`
  gains `getFinishSyncPanel()`; the trigger functions return it.
- Database / deploy: none. Migration `202610270005` was applied by the owner; Edge Function
  `legacy-sync-finish` v4 (with `poll`) deployed on the owner's approval; the owner installed the
  5-minute trigger.
- Validation: page checked at 1000 px and 390 px with a mocked `google.script.run`, no script
  errors; Apps Script harness passes.
- Validation (live): the owner ran `supabase/tests/202610270005_legacy_sync_schedule_validation.sql`
  in the SQL Editor: all 22 checks passed (rewritten as one DO block; the SQL Editor lost temp
  tables between statements). The Apps Script trigger polls every 5 minutes; sync OFF until the
  owner turns it on in V2.

## 2026-10-27 — Claude — Legacy Sync: nightly sync with V2 switch and "Sync now" (Prepared)

- Branch / commits: `claude/legacy-sync-schedule`.
- Changed: migration `202610270005_legacy_sync_schedule.sql` (schedule row, claim, three ADMIN
  RPCs); Edge Function `legacy-sync-finish` gains `poll`; `LegacySyncFinish.gs` gains
  `legacySyncTick` / `installLegacySyncTrigger` / `removeLegacySyncTrigger` and opens the run
  before reading the sheets; Finish Results gets the ADMIN-only "Legacy sheet sync" panel.
- Database: nothing applied. Needs the owner: apply the migration, approve the redeploy, update
  the Apps Script and install the trigger.
- Validation: 22/22 SQL checks on the local replica; Edge Function handler tests (23) and
  Apps Script harness (tick, window, FAILED recording, trigger install) pass; panel checked at
  1200 px and 390 px with a mocked client; `node scripts/validate-repository.mjs` passes.
- Open / next: run the validation file on the live project after the migration is applied.

## 2026-10-27 — Claude — Legacy Sync: ReWash import of 24-27 October

- Branch / commits: `claude/legacy-sync-rewash-run` (docs only).
- Database: on the owner's approval (keep the 0.012 kg value as is) `FINISH_REWASH_HISTORICAL_IMPORT`
  enabled with limit 20; run `7c2e792b-…` COMPLETED: 11 IMPORTED, 2 ADOPTED_AND_UPDATED, 1 BLOCKED.
  Switch OFF again, limit back to 3.
- Validation: 141 links (13 header, 128 line), 1 OPEN review item
  (`FE-20261026-092636-05587967`, `INVALID_QUANTITY` 0.012 kg), 0 open insert permits, both
  switches OFF.
- Open / next: 3 new Finish entries from the same afternoon are READY (Finish switch was OFF);
  owner decides the catch-up cadence and the 0.012 kg review item.

## 2026-10-27 — Claude — Legacy Sync: full Finish (NORMAL) import of 24-27 October

- Branch / commits: `claude/legacy-sync-finish-full-run` (docs only).
- Database: on the owner's approval `FINISH_HISTORICAL_IMPORT` enabled with limit 150; the owner
  ran `importFinishSync('2026-10-24','2026-10-27')`. Run `9dd77a76-…` COMPLETED: 114 IMPORTED,
  18 ADOPTED, 3 ADOPTED_AND_UPDATED. Switch OFF again, limit back to 3. ReWash switch still OFF
  (refused with `55000`, as intended).
- Validation: 389 links for the run (135 entry, 139 line, 115 wash item), 0 review items, 0 open
  insert permits, both switches OFF.
- Open / next: ReWash import after the 0.012 kg line `FE-20261026-092636-05587967::002` is
  corrected in the sheet; owner decides.

## 2026-10-27 — Claude — Legacy Sync: sender deployed, first signed dry run and 3-record pilot

- Branch / commits: `claude/legacy-sync-sender-fix`.
- Changed: `LegacySyncFinish.gs` no longer calls `Session.getEffectiveUser` (the project lacks the
  userinfo.email scope; the first pilot attempt stopped before opening a run, nothing written).
  Runbook in `docs/database/legacy-sync-finish-import.md` updated.
- Database: Edge Function `legacy-sync-finish` deployed (v2, JWT verification off) on the owner's
  approval; secret `LEGACY_SYNC_HMAC_SECRET` set by the owner. Pilot on the owner's approval:
  `FINISH_HISTORICAL_IMPORT` enabled with limit 3, run `c73c15ac-…`: 3 entries ADOPTED, then
  `RUN_LIMIT_REACHED`; switch OFF again. ReWash switch never enabled.
- Validation: unsigned calls get 401; signed dry run 24-27 October from the Apps Script
  (138 NORMAL READY, ReWash 13 READY + 1 BLOCKED); after the pilot: 1 COMPLETED run, 9 links
  (3 entry, 3 line, 3 wash item), 3 `ADOPT_LEGACY_FINISH_ENTRY` audit rows, 0 new Finish rows,
  0 review items, adopted entries still revision 1 ACTIVE.
- Open / next: owner decides the next run (remaining Finish entries, then ReWash); the 0.012 kg
  ReWash line still needs correcting in the sheet.

## 2026-10-27 — Claude — Legacy Sync: Edge Function and Apps Script sender for Finish (Prepared)

- Branch / commits: `claude/legacy-sync-edge-function`, Pull Request into `master`.
- Changed: new Edge Function `supabase/functions/legacy-sync-finish` (HMAC-SHA256 over
  timestamp + body, 5-minute window, 512 KB limit; maps six operations to the
  `integration.legacy_sync_*` functions through the service role; no mapping logic). New Apps
  Script file `legacy-sync/apps-script/LegacySyncFinish.gs`: `previewFinishSync` (read-only) and
  `importFinishSync` (one COMMIT run; READY written, BLOCKED to review, stops at the run limit).
  Repository copy of the live `legacy-sync-ingest` (v2), unchanged. Setup in `legacy-sync/README.md`.
- Database: none. Nothing deployed; no secret created.
- Validation: Deno tests of the handler (21 checks: signature, clock, sizes, operations, error
  mapping) and `deno check`; Node harness running the `.gs` against the 2026-10-27 sheet exports:
  the 124 NORMAL and 13 HOUSEHOLD records it builds are identical, field by field, to the records
  validated on `ElisCaretex-dev` in the live dry run; signature verified on each call.
- Open / next: owner creates `LEGACY_SYNC_HMAC_SECRET`, deploys with JWT verification off, adds
  the `.gs` and Script Properties, runs `previewFinishSync`; then the pilot import.

## 2026-10-27 — Claude — Legacy Sync: 202610270004 applied and validated

- Branch / commits: `claude/legacy-sync-0004-applied` (docs only).
- Changed: status of `202610270004` in the Finish import doc, INIT and this log.
- Database: `202610270004_legacy_sync_notes_reference_fix.sql` **Applied** by the owner
  2026-10-27 (SQL Editor). Switches OFF, no import has run.
- Validation: its validation checks 8/8 on `ElisCaretex-dev`, rolled back; NORMAL dry run of the
  24 entries of 2026-10-24 morning: 21 ADOPT, 3 ADOPT_AND_UPDATE, no blockers.
- Open / next: the 0.012 kg ReWash line (26 October morning Table 3) needs correcting in the
  sheet; Edge Function for Apps Script; how to see entries deleted in the sheet.

## 2026-10-27 — Claude — Legacy Sync: 202610270003 applied and validated; notes-match fix (Prepared)

- Branch / commits: `claude/legacy-sync-rewash-import` (same Pull Request).
- Changed: the owner applied `202610270003`. Its validation fixture no longer uses
  `session_replication_role` (not allowed on the hosted project); the workbook-like row is
  stored as revision 2 instead. The live dry run found that the 2026-10-24 workbook notes end
  with a full stop, so `legacy_sync_notes_reference` did not find those 24 entries. New
  `202610270004_legacy_sync_notes_reference_fix.sql` matches the whole `EntryID` whatever
  follows it. Results in `docs/database/legacy-sync-finish-import.md` ("Live dry run").
- Database: `202610270003` **Applied** by the owner 2026-10-27 (SQL Editor). `202610270004`
  Prepared, not applied. Both switches OFF, 0 runs, 0 links.
- Validation: `202610270003` validation 51/51 on `ElisCaretex-dev`, rolled back (checked
  afterwards: 0 runs, links, review items or test rows). `202610270004` validation 8/8 on the
  local replica; NORMAL dry run with the fix previewed inside a rolled-back transaction:
  99 CREATE, 21 ADOPT, 3 ADOPT_AND_UPDATE, 1 PENDING_SOURCE. ReWash: 10 CREATE,
  2 ADOPT_AND_UPDATE (staff filled in), 1 BLOCKED (a 0.012 kg line on 26 October morning Table 3).
- Open / next: owner applies `202610270004`; the 0.012 kg ReWash line needs correcting in the
  sheet; Edge Function for Apps Script; how to see entries deleted in the sheet.

## 2026-10-27 — Claude — Legacy Sync: real-sheet dry run, updates as revisions, ReWash from RewashProduction (Prepared)

- Branch / commits: `claude/legacy-sync-rewash-import` (same Pull Request).
- Changed: read-only dry run of the owner's Apps Script exports (24–27 October, 124 NORMAL +
  13 HOUSEHOLD rows) against `ElisCaretex-dev`: 97 ready, 24 = the 2026-10-24 morning entries
  already in V2 from the local workbook (2 with different kg), 3 `OTHERS`, 1 at 0 kg. Owner
  decisions 2026-10-27: legacy entries keep changing after creation (0 kg = still working;
  values change up to dispatch), so changes are applied as new revisions; the legacy value wins
  over the workbook import; `OTHERS` is Clothes; HOUSEHOLD is only a header, its lines live in
  `RewashProduction`, the same customer twice is summed. New
  `202610270003_legacy_sync_finish_updates_and_rewash_lines.sql`: value maps (DONE, shifts,
  tables, OTHERS→CLOTHES), Finish trigger permits importer revisions, sync window from
  2026-10-24, staff by exact display name, NORMAL planner/importer with
  `CREATE`/`UPDATE`/`ADOPT`/`ADOPT_AND_UPDATE` and `PENDING_SOURCE`, new ReWash
  planner/dry run/importer per HOUSEHOLD header with its lines; drops the unused
  `202610270002` HOUSEHOLD functions. Docs: `docs/database/legacy-sync-finish-import.md`
  rewritten.
- Database: none applied. `202610270003` is Prepared; both switches stay OFF.
- Validation: local PostgreSQL 16 copy, `supabase/tests/202610270003_…_validation.sql` 51/51,
  rolled back. The `202610270001` and `202610270002` test files no longer apply once
  `202610270003` is in place.
- Open / next: owner applies `202610270003`; then the validation file and a new dry run on
  `ElisCaretex-dev`; Edge Function for Apps Script; how to see entries deleted in the sheet.

## 2026-10-27 — Claude — Legacy Sync: foundation, Finish importer and HOUSEHOLD-as-ReWash applied

- Branch / commits: `claude/legacy-sync-rewash-import`, Pull Request into `master`.
- Changed: owner decisions 2026-10-27: legacy `HOUSEHOLD` Finish entries are ReWash (production
  counted separately per table and shift); every legacy row of Sunday 2026-10-25 was an owner
  test and is not imported; other Sundays are real (rare catch-up) production; the sync is temporary (once the legacy apps
  stop, keep the production data and remove the sync scaffolding to save space).
  New `202610270002_legacy_sync_household_rewash_import.sql`: link role
  `FINISH_ENTRY_TO_REWASH_LINE`; switch `FINISH_REWASH_HISTORICAL_IMPORT` seeded OFF (limit 3
  cells per run); the NORMAL planner returns `SKIPPED` for 2026-10-25, a `SUNDAY_PRODUCTION`
  warning (instead of a blocker) for other Sundays, and `REWASH_ROUTE` for HOUSEHOLD (rest of
  the body unchanged) and the dry run counts both;
  `legacy_sync_plan_household_rewash` (read-only) and `legacy_sync_import_household_rewash`
  (one Finish cell per call → one new ReWash entry with one KG line per legacy row; a cell that
  already has an ACTIVE ReWash entry is held for review, never merged or superseded). The
  `202610270001` test now expects the routing instead of `HOUSEHOLD_PENDING_DECISION`.
- Database: the owner authorised and applied `202610260002_legacy_sync_identity_foundation.sql`
  and `202610270001_legacy_sync_finish_historical_import.sql` to `ElisCaretex-dev` on 2026-10-27
  through the SQL Editor (the files on `master`, unchanged; therefore not in the
  `supabase_migrations` history). Read-only checks before applying: the live body of
  `finish_enforce_new_entry_current_shift` was byte-identical to `202610230005` (md5
  `b53d4782…`), no `legacy_sync` object existed, every function and column the importer uses
  exists. After applying: both switches OFF, zero runs, links or `LEGACY_SYNC_FINISH` entries.
  The owner then applied `202610270002_legacy_sync_household_rewash_import.sql` the same way
  (version with the 2026-10-25-only skip; checked in the live function bodies). All switches
  still OFF; zero runs, links, review items or value maps.
- Validation: on `ElisCaretex-dev` (rolled back, no residue afterwards): `202610260002` 11/11,
  `202610270001` 55/55 before and 57/57 (updated file) after `202610270002`, `202610270002`
  40/40. Security advisor, after each apply: the only new finding is
  INFO `rls_enabled_no_policy` on the 7 private `integration.legacy_sync_*` tables (by design). On
  the local PostgreSQL 16 copy with all three migrations: `202610260002` 11/11, `202610270001`
  57/57 (updated file), `202610270002` 40/40, all rolled back.
- Open / next: the Finish `Status` value map; the
  remaining owner decisions (two NORMAL entries in one cell, inactive customers, unmapped
  staff, the 3 ambiguous customers and 2 unmapped types); Edge Function for Apps Script.
  FYI: V2 already has 56 `APPS_SCRIPT_IMPORT` Finish entries on Sundays in January–February
  2026 (not touched).

## 2026-10-27 — Claude — Production map: click opens only that customer on the Route board

- Branch / commits: `claude/production-map-customer-focus`, Pull Request into `master`
- Changed: in the Production map, a customer already in Sorting or processed (border or fill)
  opens that day on the Route board showing only that customer (matched by customer id, no
  longer the free-text search, which also matched other customers whose data contained the
  name). A banner shows "Showing only <customer>" with "Back to map" and "Show all customers".
  Grey (not started) customers are not clickable. Filters return to normal when the user leaves
  the customer (banner buttons, another view, another day, History) and on every visit to the
  page (search/status/type reset, including when the browser restores form values on Back).
- Database: none
- Validation: `node scripts/validate-repository.mjs`; Playwright with the stubbed Supabase client
  and the 19–24 Oct 2026 flow items: focus shows 1 customer, Show all / Back to map / day card
  clear it, leaving and coming back with Back resets search and type filters, no console errors.
  Not validated against the live RPC with a signed-in user.
- Open / next: none.

## 2026-10-27 — Claude — Legacy Sync: identity foundation and historical Finish importer (Prepared)

- Branch / commits: `claude/legacy-sync-finish-import`, Pull Request into `master`.
- Changed: owner handed over the Legacy Sync (Apps Script → V2). `202610260002` adds the
  `integration.legacy_sync_*` identity layer (runs, insert-only record versions and links with
  `source_line_key`, review queue). `202610270001` adds the historical Finish importer:
  read-only planner and dry run, `legacy_sync_import_finish_entry` (service_role only, switch
  `FINISH_HISTORICAL_IMPORT` seeded OFF, pilot limit 3 per run), owner-approved value maps, and
  a narrow branch in `finish_enforce_new_entry_current_shift` that accepts a
  `LEGACY_SYNC_FINISH` row only with a per-transaction permit. Contract and pilot runbook:
  `docs/database/legacy-sync-finish-import.md`.
- Database: none. Both migrations are **Prepared**, not applied.
- Validation: both migrations and both test files run on a local PostgreSQL 16 copy rebuilt
  from this repository's migrations and seeds (skipped: the broken `202609160003`, the
  regex rewrite `202610230001` and the data-only `202610250006`; `202610230005` loaded early).
  `202610260002` test 11/11, `202610270001` test 55/55, both rolled back; both migrations
  re-run without changes. Not run against `ElisCaretex-dev`.
- Open / next: owner approval to apply; read-only check that the live body of
  `finish_enforce_new_entry_current_shift` still equals `202610230005` before applying;
  owner decisions (HOUSEHOLD, two entries in one cell, inactive customers, Sunday rows,
  staff, the 3 ambiguous customers and 2 unmapped types, Finish `Status` value map); Edge
  Function for Apps Script; commit the live-only `integration.legacy_inbox`,
  `staging.apps_script_incremental_rows` and `legacy-sync-ingest`; explain how
  `LOCAL_FINISH_WORKBOOK_20261024` rows passed the Finish trigger.

## 2026-10-26 — Claude — Production Tracker: weekly Production map

- Branch / commits: `claude/production-map`, Pull Request into `master`
- Changed: new "Production map" view in Production Tracker (`?view=map`, side menu entry, and the
  view switch on mobile; also in the Tracker embedded in Sorting). It shows the week Monday to
  Saturday like the printed Cloth + MOP production list, customers in production order, one box
  per customer and day: grey = not started, route-colour border = registered in Sorting (Clothes
  trolley intake or any wash), filled with the route colour plus a tick = processed (Finish
  Production for Clothes, MOP Production for MOP). A Clothes customer that also has MOP gets a
  small "M" chip with its own stage. Dashed box = not on the Schedule. Previous / this / next
  week navigation, refresh every 2 minutes while the map is open, and a click on a customer
  opens that day on the Route board filtered to the customer. Read-only: one
  `get_production_tracker_v4` call per day of the week, no new RPC.
  Also fixed: the "Viewing history" banner and the Expand/Collapse buttons ignored `hidden`
  (CSS `display:flex` won), so the banner showed on today's view.
- Database: none
- Validation: `node scripts/validate-repository.mjs`; Playwright with a stubbed Supabase client fed
  with the real flow items of 19–24 Oct 2026 (Finish/MOP/intake evidence from `ElisCaretex-dev`,
  route colours simulated because the snapshots are empty): 352 customer-days rendered, no console
  errors, week navigation and click-through to the Route board work, desktop and 390 px mobile.
  Not validated against the live RPC with a signed-in user.
- Open / next: owner to check with real data. Route 614 is white, so its "In Sorting" border is a
  white frame with a thin dark outline; the tick is what tells "processed" apart for white routes.

## 2026-10-26 — Claude — Distribution: driver infringements with 7-month validity

- Branch / commits: `claude/driver-infringements`, Pull Request into `master`.
- Changed: new "Add Driver Infringement" window (driver, date/time, severity No severity / Minor /
  Serious / Very serious / Most serious, type picked or typed, explanation). Drivers shows a badge
  with the active count and highest severity, an "Infringements" history window per driver and
  "Add infringement"; History lists all infringements (filter by driver and Active / Expired /
  Cancelled / All) and the events; Weekly roster shows a ⚠ badge next to the driver; the daily
  route window adds the active count to the driver options. An infringement counts for 7 months
  after the day it happened (owner rule), then stays as history. Wrong records are edited or
  cancelled with a reason, never deleted.
- Database: `202610260001_distribution_driver_infringements.sql` (adopts the existing table, which held 12
  records imported from CentralDB on 2026-08-17 with no screen: adds the missing columns and backfills
  severity code and expiry; RLS on and grants revoked;
  3 new RPCs, `get_distribution_driver_master` and `get_distribution_activity_history` replaced with
  added keys/labels only). **Applied** by the owner on 2026-10-26 and **Validated** (below).
- Validation: `node scripts/validate-repository.mjs` passed. Browser render with mocked RPC data
  (Drivers, Add window, driver history, History, Weekly roster; desktop and 390 px) and the save
  payload checked. Database: the owner ran `teste-sem-gravar.sql` (rolled back) and every check
  passed; after the apply, Claude ran the RPCs again as a Distribution operator inside a rolled-back
  block (refusals without access, validation, new/edit/stale/cancel, history labels) and read the
  12 imported records (all ACTIVE, `Imported from CentralDB`). Security advisors: only the expected
  `rls_enabled_no_policy` (INFO) and authenticated SECURITY DEFINER (WARN) entries, same as the
  other Distribution RPCs. The pgTAP file was not run (pgTAP is not installed).
  The owner's first run in the SQL editor failed (`p_row.col` instead of `(p_row).col` in a SQL
  function) and was rolled back; that run also revealed the existing imported table. The migration
  was corrected before merge and never applied.
- Open / next: merge the Pull Request to publish the screens. Owner to confirm the 7-month rule (one constant:
  `distribution_infringement_validity_months()`).

## 2026-10-25 — Claude — Finish "Batch / quantity" shows the exact KG (no rounding)

- Branch / commits: `claude/finish-kg-full-value`, Pull Request
- Changed: the Saved today table on Finish showed each batch KG rounded to 1 decimal (1.68 kg appeared as
  1.7 kg), which confused staff checking what they typed. The column now shows the value as saved, up to 2
  decimals (1.68 kg, 15.5 kg, 20 kg), and units as "units" instead of "u". Script cache version bumped.
  Saved data and calculations unchanged.
- Database: none
- Validation: `node scripts/validate-repository.mjs`; column rendered in Chromium with the real CSS and example
  data, before/after, desktop and 390px mobile.
- Open / next: other KG displays on Finish (totals, queue, existing records) still use 1 decimal; owner to decide.

## 2026-10-25 — Claude — Finish warns when staff have no start time (Sunday / free hours)

- Branch / commits: `claude/finish-sunday-planned-hours`, Pull Request
- Changed: on days without a Roster work profile (Sunday) the Finish staff rows have no start/end time, so
  the Produced card counted them but Planned/Target now showed 0 staff hours with no explanation. The Planned
  card now says "N staff without hours", a notice under the cards links to Finish Staff, and Finish Staff
  shows the same warning above the list. Calculation unchanged.
- Database: none
- Validation: `node scripts/validate-repository.mjs`; page rendered in Chromium with stubbed data (5 staff,
  no times → warning; with 15:00-20:00 → 558.1 kg planned, no warning), desktop and 390px mobile.
- Open / next: none.

## 2026-10-25 — Claude — Customer Version History shows the trolley plan reports

- Branch / commits: `claude/customer-trolley-plan-reports-history`, Pull Request into `master`.
- Changed: Customers → Schedule → Version History now ends with a "Trolley plan reports"
  section for that customer: who sent "Report trolley plan" (Finish/MOP), when, the published
  plan vs what was requested, the reason and scanned trolleys, which revision was live (click
  opens it), and who resolved or rejected it, when and with what note. A KPI and a warning
  show pending reports at the top; handlers can review a pending report from there. Before
  this, the reports were only in Customers → Operational Reports (all customers mixed) and in
  the app-wide alert while pending.
- Database: `202610250010_customer_schedule_trolley_plan_reports_history.sql` (new read-only
  RPC `get_customer_trolley_plan_reports(uuid, integer)`, same audience as Version History;
  no table or existing function changed). **Prepared, not applied** — the owner applies it.
- Validation: `node scripts/validate-repository.mjs` passed. The migration was run inside a
  block forced to roll back: an account without the history role was refused (42501), the
  admin account got the one existing report with reporter and reviewer names, and the
  function does not exist afterwards. The pgTAP file was not run as a file. Browser render
  checked with mocked RPC data (desktop, 390 px, and the RPC-missing error state).
- Open / next: apply the migration; until then the section shows an error message and the
  rest of Version History keeps working.

## 2026-10-25 — Claude — Finish marks wrong trolley saves and Results counts them

- Branch / commits: `claude/finish-trolley-errors`, Pull Request into `master`.
- Changed: Finish "Saved today" highlights records saved with "Use with mismatch"
  (`trolley_scan_status = 'MISMATCH'`) with a red "Wrong trolley qty/size" tag and the
  planned trolleys. Finish Results gets a "Trolley errors" section (This day / 7 / 30 days)
  with totals, counts and % by person, Table and Shift, and the list of records with planned
  vs scanned trolleys. The "Customers processed" list also flags those records. Errors are
  attributed to the "Processed by" person of the first MISMATCH revision; a contribution
  with a PENDING/RESOLVED trolley plan report counts as "Plan reported", not as an error.
- Database: `202610250009_finish_trolley_error_results.sql` (new read-only RPC
  `get_finish_trolley_errors_v1(date, date)`; no table or existing function changed).
  **Prepared, not applied** — the owner applies it.
- Validation: `node scripts/validate-repository.mjs` passed. The migration and
  `supabase/tests/202610250009_finish_trolley_error_results_validation.sql` were run inside a
  single block that was forced to roll back (as FINISH-T1-PC01): all checks passed and the
  function does not exist afterwards. Browser render checked with mocked RPC data (desktop
  and 390 px). Not validated with a real save after applying.
- Open / next: apply the migration; Results shows an error message in the new section until
  then (the rest of the page keeps working).

## 2026-10-25 — Claude — Finish Auto Shift no longer fails on days without an Evening work profile

- Branch / commits: `claude/finish-evening-shift-fallback`, Pull Request
- Changed: `get_finish_auto_shift_context` raised "Evening shift start time could not be resolved..." on Sunday
  (no EVENING Roster work profile, `shifts.start_time` empty for EVENING), blocking Finish Table 1 and the
  new-entry current-shift guard. It now falls back to 14:00, the same fallback Sorting/MOP Auto Shift use.
  New reason codes `EVENING_FALLBACK_START` / `BEFORE_EVENING_FALLBACK_START`.
- Database: `202610250008_finish_auto_shift_evening_fallback.sql` — Prepared, not applied (owner applies).
- Validation: migration + `supabase/tests/202610250008_finish_auto_shift_evening_fallback_validation.sql` ran
  in one aborted transaction as FINISH-T1-PC01 (Sunday 18:05 EVENING, Sunday 10:00 MORNING, Monday profile
  15:00 respected, overnight continuation, anon denied); live function confirmed unchanged afterwards.
- Open / next: owner may add a Sunday EVENING Roster work profile or fill the Shift master start time if 14:00
  is not the right Sunday start.

## 2026-10-25 — Claude — MOP Production Trace table no longer cut off

- Branch / commits: `claude/mop-trace-table-fit`, Pull Request into `master`
- Changed: `frontend/assets/css/sorting.css` only. The MOP Production Trace table had a fixed
  minimum width of 1120px, so on normal laptop screens the Actions column (Edit / Cancel) was
  pushed outside the card. The columns now shrink to fit the card; below 700px each record is
  shown as a stacked card with small labels and the Edit / Cancel buttons at the bottom.
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed. Browser screenshots (static copy of
  the page with sample rows, no database access) at 1792px, 1366px and 390px: before, the table
  overflowed at 1366px (1120px table in a 950px card); after, it fits at all three widths.
  Not yet owner confirmed in the live app.
- Open / next: none.

## 2026-10-25 — Claude — Production Roster history shows who saved and who published

- Branch / commits: `claude/roster-history-saved-published-by`, Pull Request into `master`
- Changed: the Production Roster History window now shows, for each version, "Saved by" and
  "Published by" with date and time, plus an "Activity" list (draft created, saved, published,
  replaced, discarded) with the person for each step. Sunday automatic publications say
  "Published automatically" and legacy spreadsheet imports say "Imported from the old spreadsheet".
  The data was already stored (`production_roster_versions.saved_by/published_by` and
  `production_roster_events`); only the history RPC did not return it.
- Database: `202610250007_production_roster_history_saved_and_published_by.sql` — replaces
  `get_production_roster_history` and adds the internal helper `production_roster_actor_name`
  (no direct execute for any client role). No table, column or row changes. **Applied** (confirmed by querying the
  database objects on 2026-10-25, after Pull Request #80 was merged).
- Validation: dry run on `ElisCaretex-dev` inside a transaction that was forced to roll back,
  calling the RPC as a real roster manager for 5 shift-weeks (manual, superseded, legacy import);
  names and sources came back as expected. `node scripts/validate-repository.mjs` passed.
  **Validated** after applying: the assertions of the pgTAP file pass (anon blocked, authenticated
  allowed, permission check present, helper not callable by anon or authenticated, every manual
  publisher resolves to a name). Security advisors: no new finding; the only entry is the usual
  "authenticated can execute SECURITY DEFINER" note for `get_production_roster_history`, which is intended.
- Open / next: none.

## 2026-10-25 — Claude — Customer Service: clearer customer blocks in Settings

- Changed: the owner could not see how to give customers to a Customer Service person.
  Settings → Customer blocks now shows:
  - The three steps.
  - One card per person with their number of customers. Clicking a card shows only those
    customers.
  - A "Give to" list that starts at "Choose a person…" instead of "Nobody (remove)".
    Removing the person is now an explicit option at the end of the list.
  - A button that names the action ("Give 2 customers to Maria", "Remove the person from
    3 customers") and stays disabled until customers are ticked and a person is chosen.
  Frontend only; no database change.
- Validation: `node scripts/validate-repository.mjs` passed. Playwright with a stubbed
  client, desktop and 390 px: no horizontal scroll, button text follows the selection,
  clicking a person's card filters the list.
- Open / next: merge the PR.

## 2026-10-25 — Claude — Supervisors and managers edit Customers and Staff Master

- Branch / commits: `claude/supervisors-managers-edit-customers`, Pull Request into `master`
- Changed: owner request: supervisors, managers and Distribution accounts that already see
  the Customers list, the Schedule Planner and the Customer Master can also edit them, every
  change stays recorded, and the Production Supervisor approves role transfers in Staff
  Master. Permission data only (templates and existing grants, only widened):
  CUSTOMERS view -> create + edit for Production Manager and Production Supervisor
  (General Manager and Logistics Manager already edited); STAFF_MASTER gains create + edit
  for General Manager and create + approve for Production Supervisor. Deactivating a
  customer or a staff member still needs MANAGE. A supervisor approves only transfers into
  a job title ranked below them (unchanged hierarchy rule). Auditor stays read-only. No
  frontend change: the screens follow `get_customer_read_capabilities`,
  `get_staff_master_reference_data` and `get_driver_role_transfers`.
- Recording: the customer, schedule and Staff Master RPCs already write `audit_log` with
  actor, time, old and new data and reason. The migration also writes one `audit_log` row
  per template and account grant it widens. Grant changes made in Accounts & Access are
  not yet written to `audit_log` (follow-up).
- Database: `202610250006_supervisors_managers_edit_customers_and_staff_master.sql`
  **Applied** to `ElisCaretex-dev` on 2026-10-25 after owner approval. Checked afterwards:
  Supervisor Morning has CUSTOMERS and STAFF_MASTER create/edit (+ approve on Staff
  Master), General Manager has STAFF_MASTER create/edit, 7 `audit_log` rows written, and
  the validation re-run (rolled back) passes 15/15 on the live state.
- Validation: migration plus
  `supabase/tests/202610250006_supervisors_managers_edit_customers_and_staff_master_validation.sql`
  run inside a rolled-back transaction on `ElisCaretex-dev`: 17/17 pass, including a real
  `update_customer` by the Production Supervisor recorded in `audit_log` and a Cleaner
  refused. Nothing was kept (checked afterwards).

## 2026-10-25 — Claude — Production Roster opens on each supervisor's own shift

- Branch / commits: `claude/roster-supervisor-home-shift`, Pull Request into `master`
- Changed: owner request: there are two Production Supervisors (Morning and Evening) and
  each one should see their own shift, while still being able to open the other shift's
  roster when covering it. New RPC `get_current_account_home_shift()` returns the default
  shift of the Staff Master record linked to the signed-in account. The Production Roster
  now opens on that shift and marks it "(my shift)" in the Shift selector. On the other
  shift a notice says so, with a "Back to my shift" button. Permissions are unchanged: a
  supervisor can still open and edit both shifts. Accounts without a linked Staff Master
  record (or before the migration is applied) keep today's behaviour (first shift).
- Database: `202610250005_production_roster_home_shift.sql` **Prepared** (not applied).
- Validation: `validate-repository.mjs` passes. The migration was run inside a rolled-back
  transaction on `ElisCaretex-dev`: it compiles, anon cannot execute it, and an admin with
  no linked Staff Master record gets `shift_code: null`. Test:
  `supabase/tests/202610250005_production_roster_home_shift_validation.sql`.
- Open / next: link each supervisor's login to their Staff Master record in Accounts & Access.

## 2026-10-25 — Claude — Production Intelligence read-only for Customer Service

- Branch / commits: `claude/production-intelligence-customer-service` (Pull Request)
- Changed: the Customer Service job title now gets Production Intelligence (PRODUCTION_INSIGHTS)
  with view only, in its permission template and on the existing account. No frontend change: the
  sidebar link and the page already follow the module grant. In the Daily report the Sorting and
  Finish blocks stay hidden for Customer Service (they keep their own SORTING / FINISH checks).
- Database: `202610250004_production_intelligence_view_for_customer_service.sql` (data only).
  **Applied** to ElisCaretex-dev on 2026-10-25 at the owner's request
  (migration name `production_intelligence_view_for_customer_service`).
- Validation: `supabase/tests/202610250004_production_intelligence_view_for_customer_service_validation.sql`
  passed 7/7 (pgTAP created inside the rolled-back transaction). Also checked as the Customer Service
  account: dashboard and forward capacity load; Daily report returns Sorting/Finish as DENIED.
- Open / next: none. Shift-scoped roster access for supervisors is handled in a separate task.

## 2026-10-25 — Claude — Role transfers starting on a Monday switch on Sunday at 12:00

- Branch / commits: `claude/transfer-sunday-noon`, Pull Request #73 (merged)
- Changed: owner request: Sunday is normally not a working day, so a person starting a new
  role on Monday must see the new roster on Sunday. New `role_transfer_switch_at(first_day)`:
  Sunday 12:00 Europe/Dublin when the first day is a Monday, otherwise 00:00 Dublin on the
  first day. Driver -> another job title (`process_driver_role_transfers`) and Staff -> Driver
  (`process_production_roster_exits`) now apply from that moment. Staff -> Driver also gives a
  login with a Production job title up to Team Leader (rank >= 60) the Driver job title and
  its template permissions (My Driver Roster); before, the login had to be changed by hand.
  Helper `apply_account_job_title_template` (internal). The `driver-role-transfers` and
  `production-roster-exits` cron jobs now run hourly (minutes 8 and 7). Help texts in Staff
  Master and Distribution say so.
- Database: `202610250003_role_transfer_sunday_noon_switch.sql` **Applied** 2026-10-25 by the
  owner in the SQL Editor. Cron jobs verified hourly (`7 * * * *`, `8 * * * *`).
- Validation: `validate-repository.mjs` passes. Database test
  `supabase/tests/202610250003_role_transfer_sunday_noon_switch_validation.sql` **Validated**
  as a dry run against ElisCaretex-dev (migration + test in one transaction, rolled back):
  13/13 passed.
- Live check: the 15:08 UTC `driver-role-transfers` run completed Paulo Teste2's transfer
  (Driver -> Cleaner from 26 Oct): login job title CLEANER, My Roster active, My Driver Roster
  inactive, `production_roster_from` cleared. Security advisors: no finding for the new
  functions.
- Open / next: none.

## 2026-10-25 — Claude — Driver moving to Production can be rostered before the first day

- Branch / commits: `claude/transfer-production-start`, Pull Request #71 (merged)
- Changed: owner test: a driver approved to move to Cleaner from 26 Oct was missing from the
  Production Roster of 26 Oct - 1 Nov, because Staff Master only changed on the day. Now,
  when a transfer to a Production job title is approved with a future first day, the Staff
  Master record is prepared at once (Production staff, approved role/area/station/shift,
  new `staff_members.production_roster_from` = the first day; a record is created for a
  driver without one). The driver link, login job title and driver exit still change on the
  day. Cancelling an approved transfer restores the previous values (or soft-deletes a record
  created for it); applying clears `production_roster_from`. The Production Roster pool,
  week, checks and planner offer the person from that week and block the days before.
- Database: `202610250002_driver_role_transfer_production_start.sql` **Applied** 2026-10-25
  by the owner in the SQL Editor. It also prepared the transfer already approved (Paulo
  Teste2: Production staff, CLEANER, `production_roster_from` 2026-10-26).
- Validation: `validate-repository.mjs` passes. Database test
  `supabase/tests/202610250002_driver_role_transfer_production_start_validation.sql`
  **Validated**: 17/17 passed (dry run, rolled back), plus the live check above. Security
  advisors: no new findings for the new functions; the new internal functions are not
  executable by `authenticated`.
- Open / next: none.

## 2026-10-25 — Claude — Staff -> Driver transfer with a first day as Driver

- Branch / commits: `claude/driver-transfer-date`, Pull Request into `master`
- Changed: the Staff Master "Transfer to Driver" form asks for the first day as Driver
  (default next Monday, today or later, at most 90 days ahead). Before, the person stayed
  in Production until Sunday and showed in the Driver Roster at once, so they were in two
  places. Now `production_roster_until` is the day before; from the first day the person
  is OFF in the Production Roster (drafts changed in place; a published week with no
  draft gets a new published version and the previous one stays SUPERSEDED; later weeks
  drop the person). The new Driver gets `joined_on` = the first day, so the Driver Roster
  lists them from that week and blocks the days before ("Not started"). Staff Master moves
  the record to Driver/Distribution on that day (nightly job), or at once when the first
  day is today. The Production Roster check and planner also refuse working days after
  the last Production day.
- Database: `202610250001_staff_to_driver_effective_date.sql` **Applied** by the owner
  (verified 2026-10-25: new 14-argument transfer, internal close function not executable by
  `authenticated`, roster checks in place; security advisors show only the existing categories).
  It replaces `transfer_staff_to_distribution_driver` (new last argument
  `p_effective_on`, optional so the current screen keeps working) and adds the internal
  `production_roster_close_staff_from`; it also replaces
  `production_roster_assert_operational_rules`, `validate_distribution_roster_version`
  and `get_distribution_roster_week`.
- Validation: Staff Master and Distribution roster rendered in Chromium with stubbed RPC
  data (first-day field, past date refused, `p_effective_on` sent, days before the first
  day disabled; no console errors). `validate-repository.mjs` passes. After the owner applied
  the migration, the scenarios of
  `supabase/tests/202610250001_staff_to_driver_effective_date_validation.sql` ran against
  ElisCaretex-dev in a rolled-back transaction: 25 of 25 checks passed, nothing kept (the
  test's setup was corrected to respect the one-draft-per-week index).
- Open / next: none.

## 2026-10-24 — Claude — Driver role transfer (Driver to another job title)

- Branch / commits: `claude/driver-role-transfer`, Pull Request into `master`
- Changed: Distribution Drivers > Remove now asks "Leaving the company" or "Moving to
  another role" (last day as a driver, job title from GO, Label, Team Leader, Supervisor,
  Cleaner, Logistics Manager, Maintenance, Production Manager, reason). Staff Master shows
  "Driver transfers" where a manager with Staff Master APPROVE (only below their own job
  title rank) or an Administrator approves (role, area, station, shift, roster), rejects or
  cancels. The move applies the day after the last driver day (daily job
  `driver-role-transfers`, or at approval when the date has passed): the Staff Master
  record is reused or created, the driver record is unlinked, an existing login gets the
  new job title and its template permissions. Also fixed `apply_staff_production_scope`,
  which turned `production_staff` back to true on every update, so the Staff -> Driver
  transfer never left Production.
- Database: `202610240003_driver_role_transfer.sql` **Applied** by the owner in the SQL
  Editor (verified 2026-10-25: table, `driver-role-transfers` job and the
  `apply_staff_production_scope` fix exist). Security advisors only list the expected
  RLS-without-policy table and authenticated SECURITY DEFINER RPCs with internal checks.
- Validation: the migration plus the scenarios of
  `supabase/tests/202610240003_driver_role_transfer_validation.sql` ran on ElisCaretex-dev
  inside a rolled-back transaction (32 of 32 checks passed, nothing kept). Both screens
  rendered in Chromium with stubbed RPC data (no console errors). `validate-repository.mjs`
  passes.
- Open / next: run the test file and the security advisors after the owner applies the
  migration. A person without a login keeps the chosen job title only on the transfer
  record; choose it again when access is set up.

## 2026-10-24 — Claude — Copy Eircode from the route on My Driver Roster

- Branch / commits: `claude/driver-roster-copy-eircode`, Pull Request into `master`
- Changed: in the route dialog of `frontend/assets/js/driver-roster.js` each customer now shows
  its Eircode in a large box with a "Copy Eircode" button, so the driver can paste it into the
  GPS app they prefer. Uses the Clipboard API with a `execCommand("copy")` fallback; the button
  confirms with "Copied ✓". Customers without an Eircode show "No Eircode registered".
  Styles in `driver-roster.css`; cache-busting versions bumped in `driver-roster.html`.
- Database: none. Data comes from the existing `get_my_driver_route` RPC, which already only
  returns routes assigned to the signed-in driver (or Distribution managers).
- Validation: `node scripts/validate-repository.mjs` passed; route dialog and copy checked in
  Chromium with iPhone 13 emulation and mocked RPC data. Not tested against live data.
- Open / next: the Eircode is the snapshot on the run stop (`eircode_snapshot`).

## 2026-10-24 — Claude — Fix Distribution roster save on imported weeks ("fri" date error)

- Branch / commits: `claude/fix-roster-required-routes-weekday`, Pull Request into `master`.
- Cause: imported roster weeks (e.g. 2026-10-26, PUBLISHED v1) store `required_routes` by
  weekday (`{"mon":10,...,"fri":10}`). Editing such a week sent those keys back to
  `save_distribution_roster_week`, which casts each key to `date` and failed with
  `invalid input syntax for type date: "fri"`. Not caused by PR #61 or #62.
- Changed: `distribution.js` converts weekday keys to the ISO dates of the roster week
  before showing, editing and saving Required routes (date keys win over weekday keys).
  The imported targets now also show in the Required row instead of falling back.
- Database: none (stored rows keep weekday keys; the next save writes date keys).
- Validation: `node --check` and `node scripts/validate-repository.mjs`; conversion checked
  with the live 2026-10-26 `required_routes` value.
- Open / next: owner to confirm the save works on the 2026-10-26 week.

## 2026-10-24 — Claude — "Production" label on the single-service planner print

- Branch / commits: `claude/schedule-print-production-label`, Pull Request into `master`.
- Changed: the existing Schedule Planner Print (Clothes or MOP) shows "PRODUCTION" on the
  right of each black day header, like the new Cloth + MOP print. Layout otherwise unchanged.
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed; print rendered in Chromium
  with live Clothes planner data.
- Open / next: none.

## 2026-10-24 — Claude — Cloth + MOP print by production and by delivery day

- Branch / commits: `claude/schedule-print-cloth-mop`, Pull Request into `master`.
- Changed: new `frontend/assets/js/schedule-combined-print.js` builds a 3-page A4 print
  with Cloth and MOP trolleys side by side. Schedule Planner gets a "Print Cloth + MOP"
  menu next to the unchanged Print button: "By production day" (Clothes + MOP planners,
  Clothes order first, MOP-only customers after with "M" order) and "By delivery day"
  (Distribution planner, grouped by delivery day and route in delivery order).
  Distribution → Route customers gets the same delivery print button.
- Database: none. Uses the existing `get_clothes_weekly_planner`, `get_mop_weekly_planner`
  and `get_distribution_weekly_planner` RPCs.
- Validation: `node scripts/validate-repository.mjs` passed. Both prints rendered in
  Chromium from live RPC data for 24 Oct 2026 (read-only transaction): 3 A4 pages each.
  The buttons inside the logged-in pages were not clicked in a browser.
- Open / next: owner acceptance of the layout.

## 2026-10-24 — Claude — My Driver Roster shows each route in its colour

- Branch / commits: `claude/driver-roster-route-colors`, Pull Request into `master`
- Changed: `frontend/assets/js/driver-roster.js` paints the route button of each day with the
  route colour stored on the published roster entry (`route_color_snapshot`). Text switches
  between dark and white by WCAG luminance; very light colours (white, pale yellow) get a
  thicker slate border so the box stays visible. Entries without a valid colour keep the old look.
- Database: none
- Validation: `node scripts/validate-repository.mjs` passed; rendering checked in Chromium with
  white, yellow, teal, red, navy, black, green and no colour. Not tested against live data.
- Open / next: the colour is the snapshot taken when the roster was published, so a colour
  changed in the route master shows after the next publication.

## 2026-10-24 — Claude — Production Tracker read-only for Distribution and Customer Service
- Branch / commits: `claude/production-tracker-distribution-cs` (Pull Request)
- Changed: the Logistics Manager and Customer Service job titles now get Production Tracker with
  view only, in their permission templates and on the existing accounts. No frontend change: the
  sidebar link and the page already follow the PRODUCTION_TRACKER module grant, and the page only
  reads `get_production_tracker_v4`. Driver is left out (keeps My Driver Roster only).
- Database: `202610240002_production_tracker_view_for_distribution_and_customer_service.sql`
  (data only). **Applied** to ElisCaretex-dev on 2026-10-24 at the owner's request
  (migration name `production_tracker_view_for_distribution_and_customer_service`).
- Validation: assertions of
  `supabase/tests/202610240002_production_tracker_view_for_distribution_and_customer_service_validation.sql`
  run as plain SQL after applying (pgTAP is not installed): 7/7 passed, including Paulo Teste2
  (Logistics Manager) reading the tracker with view but no edit.
- Open / next: there is no Customer Service account yet; new ones get the permission from the template.

## 2026-10-24 — Claude — Production Intelligence for managers and in-app Daily report
- Branch / commits: `claude/production-intelligence-managers` (Pull Request)
- Changed: Production Intelligence rebuilt as tabs (Overview, Daily report, Customers, Shifts & tables,
  Staff, Planning) driven by a Day / Week / Month / Year period that opens on the current month and
  compares with the same days of the previous period. Customers shows KG, average KG and average
  trolleys per production day, and change. Shifts & tables shows Finish/Sorting efficiency per shift
  and per table. Staff shows headcount, leavers, joiners and turnover %. The Daily report replaces the
  Apps Script daily emails: scheduled customers against washed and produced, Sorting/Finish results
  of the day (reusing their Results functions) and MOP. Sidebar links for each tab.
- Database: `202610240001_production_intelligence_manager_views.sql` (new read-only RPCs
  `get_production_intelligence_manager_view`, `get_production_daily_report` and the internal helper
  `production_intelligence_staff_hours`). **Applied** to ElisCaretex-dev on 2026-10-24 after the owner's
  confirmation (migration name `production_intelligence_manager_views`).
- Validation: `node scripts/validate-repository.mjs`; page checked in Chromium with mocked RPC data at
  desktop and phone width. **Validated** after applying: pgTAP is not installed on the project, so the
  assertions of `supabase/tests/202610240001_production_intelligence_manager_views_validation.sql` were
  run as plain SQL (12/12 passed): grants, anonymous refusal, inverted period refusal, Administrator gets
  both RPCs (October: 82,514.8 kg, 22/10: 109 scheduled services), Logistics Manager gets the daily report
  with Sorting/Finish `DENIED`. Security advisors: no new finding beyond the existing project-wide
  "authenticated can execute SECURITY DEFINER" notice, which these permission-guarded RPCs share by design.
- Open / next: joiners are only counted for staff with a start date (`joined_on` is empty for most
  imported staff). Finish efficiency uses imported Apps Script hours until September and the published
  roster (minus sessions/absences) afterwards. Per-person KG ranking was left out because a Finish entry
  records one person while tables work as a team.

## 2026-10-23 — Claude — Module permissions decide access for personal accounts

- Branch / commits: claude/permissions-by-module, Pull Request
- Changed: owner decision 2026-10-23 — for personal (USER) accounts, the ticked module permissions decide access in every module; legacy roles only apply to production terminals and accounts without an access profile. New helpers (`account_module_allowed`, `account_uses_module_permissions`, `legacy_role_allowed`, `legacy_role_modules`, `trolley_action_for_roles`); 55 guards and capability functions rewritten from their live definitions with only the role checks changed; customers / staff_members / staff_roles read policies follow the same rule. Job-title templates completed per the owner-approved matrix (General/Production Manager get Sorting, Finish, MOP, Customers, Trolleys, Tracker; Production Supervisor and Auditor get read access; Logistics Manager gets Customers edit and its Distribution MANAGE now really manages drivers/fleet/routes); existing accounts receive the new rows (additions only). DRIVER no longer carries DISTRIBUTION_OPERATOR, which let a driver account edit customers and publish the Distribution Roster.
- Database: `202610230008_permissions_by_module.sql` — **Applied 2026-10-23** by the owner in the SQL Editor (the MCP apply timed out after the helpers section; the full file was then run in one transaction without errors).
- Validation: SQL and PL/pgSQL parsed with pglast (76 statements, 0 errors); `supabase/tests/202610230008_permissions_by_module_validation.sql` (18 assertions, including a throw-away personal account and the Sorting terminal). After applying, checked live: 53 guards use account_module_allowed/legacy_role_allowed, DRIVER has no legacy role, the 3 policies are updated; Paulo Teste2 (Logistics Manager) can read, plan and manage Distribution and edit Customers, but not deactivate Customers nor use Sorting/Finish despite the DISTRIBUTION_OPERATOR role; SORTING-PC01 and FINISH-T1-PC01 keep their own screen through the role and cannot reach other modules; the admin keeps everything. Security advisor: no new errors (only the usual authenticated SECURITY DEFINER notices for the new helpers, which only answer for the caller).
- Open / next: storage policies for `mop-type-photos` still check ADMIN/MANAGER roles (storage schema owner); the frontend navigation already follows module permissions for personal accounts, so no UI change was needed.

## 2026-10-23 — Claude — Database review follow-up: capture live functions, small fixes, read-only public roster link

- Branch / commits: claude/database-review-capture, Pull Request
- Changed: `202610230005` writes into the repository the live definitions of 38 functions that had drifted from the committed migrations or existed only in the database (includes the working `record_finish_rewash_v1`; `202609160003` referenced the non-existent `finish_workstations`). `202610230006` fixes the mojibake in `record_customer_driver_guide_event`, enables RLS on `staging.dist1_import_rows` and closes two superseded overloads. `202610230007` (owner decision) makes the public roster link read-only: token leave submission and token leave history are revoked; `roster-view.js` sends public-link users to My Production Roster to request leave.
- Database: `202610230005` not re-applied: every body is byte-identical (whitespace-normalised hash) to the live one, so applying it changes nothing. `202610230006` **Applied** 2026-10-23 on the owner's go-ahead; its 6 assertions (plus the new terminal correction overload staying open) returned true against the live project as plain SQL (pgTAP is not installed). `202610230007` **Applied** 2026-10-23 right after Pull Request #56 was merged; its 5 assertions returned true against the live project.
- Validation: function hash comparison now shows the repository matching the live database except the two functions fixed by `202610230004`/`202610230006`; `node scripts/validate-repository.mjs` passes. Tests for `202610230006`/`202610230007` written, to run after applying.
- Open / next: unify authorization on module permission grants (owner decision 2026-10-23: module permission wins), separate Pull Request. `roster_periods` is still used by 21 Production Roster/Sorting functions, so its authenticated read policy stays. `finish_enforce_new_entry_current_shift` keeps the temporary Apps Script import exception until the import is reconciled.

## 2026-10-23 — Claude — Database review: orphan Distribution Roster RPCs and driver reinstatement fix

- Branch / commits: claude/database-review-fixes, Pull Request
- Changed: full review of repository vs live database (report in the project files, `revisao-logica-banco/README.md`). New migration revokes execution of the orphan Distribution Roster RPCs that exist only in the live database (`save_distribution_roster_draft`, `publish_distribution_roster(date,text)`, `get_distribution_roster_context`, `get_distribution_roster_history`, `require_distribution_roster_read_access`, `require_distribution_roster_manage_access`, `distribution_route_valid_on_date`). They let PLANNER and ROSTER_MANAGER publish a Distribution Roster outside the current path and without the 17–20/10 fixes. The same migration applies the `reinstate_distribution_driver` definition from `202610190004`, which was committed but never applied.
- Database: `202610230004_close_orphan_distribution_roster_rpcs_and_apply_driver_reinstate_fix.sql` — **Applied** 2026-10-23 on the owner's go-ahead.
- Validation: function-by-function comparison of all 480 repository functions against the live database; the 11 assertions of `supabase/tests/202610230004_..._validation.sql` (plus the two remaining helpers) all returned true against the live project, run as plain SQL because the pgTAP extension is not installed. Security advisors: no new findings; SECURITY DEFINER functions executable by authenticated went from 317 to 313.
- Open / next: owner decision on one permission model (roles vs module grants); shared staff-portal token allows leave requests for any staff member; `202609160003` redefines `record_finish_rewash_v1` against a non-existent `finish_workstations` table (live version differs and works); capture the live-only functions in a migration so the repository becomes the source of truth again; mojibake in `record_customer_driver_guide_event`.

## 2026-10-23 — Claude — Production Roster exit after a job title change

- Branch / commits: `claude/roster-role-change-exit`, Pull Request into `master`
- Changed: when a linked staff member's account job title moves out of Production
  (department DISTRIBUTION, CUSTOMER_SERVICE, ADMINISTRATION or MANAGEMENT), they stay in the
  current roster week and are left out of every later week. New column
  `staff_members.production_roster_until` (Sunday of the change week), set by triggers on
  `account_access_profiles.job_title_code` and on account linking; cleared when the job title
  returns to Production. Editable drafts of later weeks lose the staff rows; published rosters
  are not changed. Staff pool, new-week list and the save/publish guard respect the date, and
  `roster.js` removes such staff from later-week planners.
- Database: `202610230002_production_roster_exit_after_role_change.sql` and
  `202610230003_driver_transfer_keeps_current_roster_week.sql` applied to ElisCaretex-dev by the
  owner through the SQL Editor on 2026-10-23 (the session's Supabase writes timed out).
- Validation: `node scripts/validate-repository.mjs` passed. Migration run on a local
  PostgreSQL 16 with stub tables: job title change to Logistics Manager set the exit date to
  2026-10-25, removed the staff from the 2026-10-26 draft only, kept the current week and the
  published 2026-11-02 week, staff pool and new-week list excluded the staff from later weeks,
  the guard refused a later-week draft with the staff, and changing back cleared the date.
  After applying: the validation assertions passed on ElisCaretex-dev (run as plain queries);
  as Administrator, Paulo Teste2 (exit 2026-10-25) is in the 2026-10-19 week and absent from the
  2026-10-26 and 2026-11-02 weeks; triggers and the `production-roster-exits` cron job exist; no
  new security advisor finding for the new functions.
- Transfer to Driver aligned (`202610230003_driver_transfer_keeps_current_roster_week.sql`): the
  transfer creates/links the Driver and sets the same exit date; the Staff Master record keeps its
  Production role, shift and eligibility until then, and the new daily cron job
  `production-roster-exits` (00:07 UTC, `process_production_roster_exits()`) completes the move
  to Driver/Distribution afterwards. Only drafts after the exit week lose the staff rows.
  Validated locally the same way. The job title sync does not clear the exit date of a staff
  member linked to a Driver record.
- Open / next: none once both migrations are applied.

## 2026-10-23 — Claude — Distribution manages customers

- Branch / commits: `claude/distribution-customer-access`, Pull Request into `master`
- Changed: `DISTRIBUTION_OPERATOR` now has full view and edit of customers, like `PLANNER`:
  Customer Master (create, edit, deactivate, reactivate), schedule revisions (trolley
  quantities, publish, cancel, restore), planner day order, schedule history, Clothes/MOP
  planners, customer KG history and the trolley plan check list. Navigation: a `DISTRIBUTION`
  account permission now also shows the Customer Workspace
  (`frontend/assets/js/app-shell-policy.js`). No write path added; all of them already insert
  into `audit_log` (actor, old/new data, reason).
- Database: `202610230001_distribution_customer_management_access.sql` — **Applied** to
  `ElisCaretex-dev` on 2026-10-23 (owner approved), from the committed file.
- Validation: `node scripts/validate-repository.mjs` passed. pgTAP is not installed on the
  project, so the 22 assertions of
  `supabase/tests/202610230001_distribution_customer_management_access_validation.sql` were run
  as an equivalent plain-SQL block: all 22 passed (Distribution account allowed, Finish account
  still refused, audit_log inserts present). Security advisors: no new finding for these
  functions.
- Open / next: owner to confirm in the app with the Distribution account.

## 2026-10-22 — Claude — Customer guides as a Distribution tab

- Branch / commits: `claude/driver-guides-distribution-layout`, Pull Request into `master`
- Changed: Customer Driver Guides now opens inside Distribution (`distribution.html#guides`) with
  the same header, KPI cards and tab bar as the other tabs. Markup moved into
  `frontend/pages/distribution.html`; `driver-guides.js` loads the guides only when the tab
  opens; styles scoped in `frontend/assets/css/driver-guides-tab.css` (old
  `driver-guides.css` removed). `driver-guides.html` now redirects to `distribution.html#guides`
  and the navigation link points there.
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed. Checked in headless Chromium with
  a stubbed Supabase client: tab active, KPI cards shown, guides listed, switching back to
  Daily board hides the guides, old URL redirects, no page errors.
- Open / next: owner to confirm with real data.

## 2026-10-22 — Claude — Driver leave requests only in the Distribution Leave calendar

- Branch / commits: `claude/driver-guides-remove-leave-requests`, Pull Request into `master`
- Changed: removed the "Requests · Holiday / Day off" panel from Customer Driver Guides
  (`frontend/pages/driver-guides.html`, `frontend/assets/js/driver-guides.js`). The same pending
  requests, with the same `review_driver_leave_request` approve/reject, are in
  Distribution > Leave calendar > Pending Requests. The page no longer calls
  `get_driver_leave_requests_admin`.
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed. Not checked in a browser.
- Open / next: owner to confirm the page in the browser.

## 2026-10-22 — Claude — Customer KG estimates stored and refreshed weekly

- Branch / commits: `claude/customer-kg-weekly-snapshot`, Pull Request into `master`
- Changed: owner decision: the KG estimate only needs a weekly refresh. The original
  calculation is now `customer_kg_estimates_live`; `customer_kg_estimate_snapshot` stores its
  result, refreshed by pg_cron `customer-kg-estimates-weekly-refresh` every Sunday 05:00 UTC
  (before the roster autopublish). `customer_kg_estimates` keeps its signature: from the
  snapshot date onwards it joins the stored estimates to the published schedule slots (new
  slots show as LEARNING until the next refresh); earlier dates still calculate live.
  ADMIN/MANAGER can refresh on demand with `refresh_customer_kg_estimates_v1()` (no UI button yet).
- Database: `202610220005_customer_kg_estimate_weekly_snapshot.sql`, **Applied** 2026-10-22
  (snapshot 505 rows; cron job present). `202610220004` was never applied and must not be.
  It supersedes `202610220004` (the nested-loop setting now sits on `customer_kg_estimates_live`).
- Validation: on ElisCaretex-dev with a temporary copy of the snapshot, the stored path returned
  the same 505 rows as the live calculation (0 differences) in 22 ms instead of about 1.9 s.
  Test file `supabase/tests/202610220005_customer_kg_estimate_weekly_snapshot_validation.sql`.
- Validated after applying: stored and live estimates match (0 differences); Distribution
  dashboard 220 ms (was about 3.9-4.6 s), weekly planner 42 ms (was about 1.9 s); ADMIN manual
  refresh works.
- Open / next: owner to confirm in the browser; optional refresh button in the UI.

## 2026-10-22 — Claude — Faster Distribution screens (customer KG estimates)

- Branch / commits: `claude/distribution-kg-estimate-speed`, Pull Request into `master`
- Changed: `customer_kg_estimates` took about 1.9 s per call because of a nested-loop plan
  built on very low row estimates. The Distribution dashboard calls it twice (about 3.9 s) and
  the weekly planner once (about 1.9 s). The function now runs with `enable_nestloop = off`.
- Database: `202610220004_customer_kg_estimates_planner_fix.sql` (Prepared, never applied;
  superseded by `202610220005`, do not apply).
- Validation: measured with the same setting for the session on ElisCaretex-dev:
  estimates 163 ms, dashboard 364 ms, weekly planner 189 ms. Test file
  `supabase/tests/202610220004_customer_kg_estimates_planner_fix_validation.sql`.
- Open / next: apply the migration, run the test and confirm the screens in the browser.

## 2026-10-22 — Claude — ADMIN accounts without a staff record can open Distribution and Finish

- Branch / commits: `claude/admin-account-without-staff`, Pull Request into `master`
- Changed: the identity guards of Distribution, Finish, MOP, Customer Schedule editing,
  operational report submit/review, ABS batch entry and the Trolley Type Master required
  `current_staff_id()`. An ADMIN account managed only through `account_roles` (no staff
  record) got "An active authenticated staff account is required.". The guards now require
  `current_account_is_enabled()`; role checks are unchanged.
- Database: `202610220003_account_access_without_staff_record.sql`, **Applied** on 2026-10-22 after the
  owner approved it (verified: no function still checks
  `current_staff_id() is null`).
- Validation: dry run of the guard changes inside a rolled-back transaction on ElisCaretex-dev:
  the staff-less ADMIN account passed all guards; a Sorting terminal and an account with no
  roles were still refused by role. Test file
  `supabase/tests/202610220003_account_access_without_staff_record_validation.sql`.
- Validated after applying: the staff-less ADMIN account passed the Distribution, Finish,
  MOP, Customer Schedule and Trolley Type Master guards; a Sorting terminal was still refused
  by Distribution, Finish, Customer Schedules and Trolley Type Master; anon cannot call the
  guards. Security advisors show the same categories as before (no new kind of finding).
- Open / next: owner to confirm Distribution and Finish open in the browser.

## 2026-10-22 — Claude — Customer Service: cancelling a complaint ends its alerts and tasks

- Changed: the owner cancelled a test complaint and its customer alert stayed active on the
  production screens. `set_customer_service_complaint_status_v1` now, on CANCELLED, ends the
  complaint's open alerts (reason "Complaint cancelled") and cancels its open department
  tasks, logging each in the complaint history. Resolving a complaint keeps its alerts and
  tasks (production may still need to watch the customer). The migration also closes
  alerts and tasks already left open by cancelled complaints (one alert: CS-00001). The
  cancel dialog now says that alerts and open tasks are closed too.
- Database: `202610220006_customer_service_cancel_closes_alerts.sql` — **Applied** to
  ElisCaretex-dev on 2026-10-22 with the owner's approval; afterwards the CS-00001 alert is
  ended, no cancelled complaint keeps an open alert, anon cannot execute the RPC. Ran inside a rolled-back transaction: leftover alert closed; a new
  complaint with an alert and a task, once cancelled, had the alert ENDED, the task
  CANCELLED, both logged, and Finish no longer received the alert. The complaint
  sequence was reset afterwards to continue from the last real code.
- Validation: `node scripts/validate-repository.mjs` passed;
  `supabase/tests/202610220006_customer_service_cancel_closes_alerts_validation.sql`.
- Open / next: merge the PR.

## 2026-10-22 — Claude — Customer Service: Administrator accounts left out of the team list

- Changed: the owner ticked the Customer Service permission on his Administrator account
  (needed: accounts with module permissions get their menu only from those permissions, so
  the Administrator did not see the new menu without it) and then appeared in Settings as
  one of the Customer Service people. `get_customer_service_workspace_v1` now leaves
  accounts with job title `ADMINISTRATOR` out of the `agents` list (who can receive customer
  blocks). Access is unchanged: the Administrator still sees and changes everything.
- Database: `202610220002_customer_service_team_excludes_admins.sql` — **Applied** to
  ElisCaretex-dev on 2026-10-22 with the owner's approval. Replaces only the workspace RPC; same signature,
  so the order of apply and merge does not matter. Checked after applying as the owner's
  account (rolled back): scope ALL, Manage true, agents list empty, anon cannot execute.
- Validation: `supabase/tests/202610220002_customer_service_team_excludes_admins_validation.sql`.
- Open / next: merge the PR.

## 2026-10-22 — Claude — Customer Service: complaints, trace, alerts, tasks and results

- Branch / commits: `claude/customer-service` (Pull Request into `master`).
- Changed: owner asked for a Customer Service screen (about three people, each with a
  block of customers, one of them the manager who sees everything). New page
  `frontend/pages/customer-service.html` with Complaints (pick-from-a-list type, received
  date, delivery, severity, channel), a production trace per complaint (Finish records with
  table, shift, processed-by and the staff on that table; washes with shift, washer,
  operator and Sorting staff) and a link that copies table/shift into the complaint;
  Customer alerts shown at the top of Sorting, Finish, MOP and Distribution
  (`customer-alerts.js`, with a badge on the Finish queue and the washing picker);
  department Tasks followed until done (production areas can mark their tasks done);
  Results (per day/week/month, type, customer, table × shift, washing shift, person,
  department); Settings (customer blocks per person, complaint types). New sidebar group
  "Customer Service"; `app-shell-policy.js` version bumped on every page.
- Database: `202610220001_customer_service_complaints.sql` — **Applied** to ElisCaretex-dev on 2026-10-22
  with the owner's approval (recorded as version `20261022174607`).
  New module `CUSTOMER_SERVICE` (scope Own = own block, All = manager, Manage = settings),
  six RLS-locked tables and SECURITY DEFINER RPCs with internal checks. The full migration
  plus a scripted run (admin, Finish terminal, General Operative) was executed inside a
  transaction that was rolled back on ElisCaretex-dev: all RPCs worked, the terminal saw
  the alert and closed the task, the General Operative was refused.
- Validation: `node scripts/validate-repository.mjs` passed; Playwright screenshots with a
  stubbed client (desktop and 390 px; Finish page with the alert bar). pgTAP file
  `supabase/tests/202610220001_customer_service_complaints_validation.sql` (pgTAP is not
  installed on the remote project, so the same checks ran after applying as a rolled-back
  block: all passed, including admin flow, Finish terminal completing the task and the
  General Operative refused). The complaint sequence was reset afterwards so the first real
  complaint is CS-00001. Security advisors: no new findings beyond the project's existing
  by-design ones (RLS without policies; SECURITY DEFINER executable by authenticated).
- Open / next: merge the PR (the migration is already applied). Then give the three people the Customer Service
  job title in Accounts & access (agents: scope Own; manager: scope All + Manage) and share
  the customers in Settings. Legacy imported washes have no production flow id, so the
  trace shows Finish and washing side by side by date instead of as one flow.

## 2026-10-22 — Claude — Sorting Results: loads and kg per shift, MOP separate from Clothes

- Branch / commits: `claude/sorting-results-shift-loads` (Pull Request into `master`).
- Changed: owner asked to see how many machine loads each shift did, with MOP separate
  from Clothes and the kg of each. Each shift card now shows Clothes, MOP and Total as
  loads + kg (Others only when a day has them); the day totals show Clothes and MOP loads
  first with their kg. Frontend only; the data already came from
  `get_sorting_results_dashboard_v1`.
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed; Playwright screenshots with
  a stubbed client at desktop and 390 px.
- Open / next: none.

## 2026-10-21 — Claude — Staff tabs: "Covering a leader" saved as a note

- Branch / commits: `claude/staff-cover-note` (Pull Request into `master`).
- Changed: owner decision 2026-10-21 ("Só nota por enquanto"): covering as Team Leader or
  Supervisor has no database column yet. The Sorting and Finish Staff tabs get a
  "Covering a leader" choice (Team Leader or Supervisor, whole shift / from now / from a
  time) that saves a standard note on today's work session, for example
  "Covering as Supervisor from 18:30.". The row badge shows it, and later changes from
  the same screen keep the note because the session notes are replaced on each save.
- Database: none. No report reads the cover yet; a migration with its own column is
  needed if the owner wants it reported.
- Validation: `node scripts/validate-repository.mjs` passed. Playwright on Finish with a
  stubbed client: the step renders, saving sends the note, and a later late-start change
  keeps it. Sorting uses the same code path; not run in the browser.
- Open / next: none.

## 2026-10-21 — Claude — Finish table hours count each table worked after a move

- Branch / commits: `claude/finish-table-hours-after-move` (Pull Request into `master`).
- Changed: owner test moved a person from Table 1 to Table 2 at 19:32; Table 1 showed
  31.33 staff hours (only the four who stayed) and Table 2 counted the whole shift. The
  main Finish screen now splits each person by `table_segments`, sharing the break by the
  time on each table (same rule as Finish Results in PR #35 and the Sorting partial move),
  and counts the Finish part of someone who moved to Sorting on their planned table.
  Second fix: a Finish session created from the new Staff tab started with a 0 min break,
  because `upsert_finish_staff_actual` does not set it; the planned break is now saved
  right after.
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed. Playwright with the owner's
  test data: before 31.33 h (Table 1) / 39.67 h (Table 2); after 35.87 h / 35.13 h with the
  saved 0 min break, 35.59 h / 34.91 h with a 30 min break.
- Open / next: Lena Banut's test session of 2026-10-21 has a 0 min break; it goes with the
  test-data cleanup.

## 2026-10-21 — Claude — Sorting Results screen; Finish Results hours follow staff moves

- Branch / commits: `claude/sorting-results` (Pull Request into `master`).
- Changed: new Sorting → Results page (`frontend/pages/sorting-results.html`), same look
  as Finish Results: day totals, Morning/Evening cards, every staff member with status
  (Actual, As planned, Part shift, Moved, Absent, No-show, No hours), hours, Clothes/MOP
  kg, kg/h and efficiency, plus the list of washes. Efficiency = earned hours / worked
  hours, earned = Clothes kg / 160 + MOP kg / 100 (OTHERS use the Clothes target).
  Finish Results now lists the staff hours behind each Table.
- Database: `202610210004_sorting_results_and_finish_results_staff_moves.sql`
  (**Applied** 2026-10-21 18:45 UTC on the owner's approval, after PR #35 merged). Adds
  `get_sorting_results_dashboard_v1(date)` and replaces
  `get_finish_results_dashboard_normal_v1(date)`. The old Finish function read
  `get_finish_staff_context_v2`, which keeps only the latest work session per person and
  drops staff no longer active: on 2026-01-15 Morning Table 1 counted 7.25 staff hours
  instead of 29.00 (efficiency 331%). It also ignored Finish absences and table segments.
- Validation: `node scripts/validate-repository.mjs` passed. Both functions were run
  against live data inside a rolled-back transaction (2026-09-25 Sorting, 2026-01-15 and
  2026-09-25 Finish). Playwright screenshots with a stubbed client (desktop and 390 px).
  After applying: pgTAP is not installed on the project, so the test file's assertions
  were run as plain SQL and all held (function exists, anon refused, authenticated
  granted, access guards present, table segments used, a caller without a role is
  refused). Live call for 2026-10-21 as an admin: Finish Evening Table 1 = 35.87 staff
  hours with Lena Banut split 4h32 Table 1 / 3h48 Table 2 (owner expected ~35h55; the
  difference is her session's 0-minute break, fixed separately in PR #36). Security
  advisors: only the expected "authenticated can execute SECURITY DEFINER" warning for
  the two functions; nothing new otherwise.
- Open / next: the Finish operational screen hours per table are fixed in PR #36.

## 2026-10-21 — Claude — Finish Staff tab: same plan-next-to-actual screen as Sorting

- Branch / commits: `claude/finish-staff-quick-actions` (Pull Request into `master`).
- Changed: the owner asked for the Finish Staff tab to look and work like the Sorting
  one. Each person shows Roster (table and times) next to Today (actual table and times)
  and Worked, with late start, early leave, overtime, absence and table changes
  highlighted. "What changed?" offers Arrived late, Leaving early, Staying later, Did not
  come, Went to another table, Went to Sorting, Different break and Edit all times. Table
  and Sorting moves ask "From what time?" so the hours split between tables. A locked
  table (terminal or `?table=`) still shows only its own staff, plus people who moved
  away from it ("Moved · Table 2 at 18:00") with their hours per table. People who came
  from Sorting show "From Sorting at HH:MM" and, outside terminals, a Back to Sorting
  button. Roster rows nobody confirmed are confirmed with the planned start before a
  move, departure or break change, because those RPCs need a confirmed session.
- Database: none. Uses the existing Finish RPCs (through their `terminal_*` wrappers)
  and `restore_sorting_staff_from_finish_table_v2`.
- Validation: `node scripts/validate-repository.mjs` passed. Playwright against a local
  server with a stubbed Supabase client and the live Finish fixtures: desktop, table-locked
  and 390 px layouts render; move, arrival, Sorting and break choices send the expected
  RPCs and parameters. Not tested against the live database.
- Open / next: the owner's real test on a Finish terminal.

## 2026-10-21 — Claude — Sorting Staff: move to a Finish Table for part of the shift

- Branch / commits: `claude/sorting-partial-move-to-finish` (Pull Request into `master`).
- Changed: owner test found that "Went to a Finish table" saved the move but the Sorting
  Staff list still showed the person in Sorting, and that the time must be split when
  someone works in Sorting first. The move now asks "From what time?" (From now, From a
  time, Whole shift). A partial move closes the Sorting session at that time (break split
  by share of the shift) and opens a Finish session and table segment from that time; the
  row shows "Moved · Finish Table 2 at 17:20" with the Sorting hours and output. Back to
  Sorting cancels the Finish session and reopens the Sorting one.
- Database: `202610210002_sorting_partial_move_to_finish.sql` — new
  `move_sorting_staff_to_finish_table_v2`, `restore_sorting_staff_from_finish_table_v2`;
  `get_sorting_staff_dashboard_context_v2` now recognises `SORTING_TO_FINISH_TRANSFER`
  (pre-existing bug) and returns `partial_area_transfer` / `area_transfer_at`.
  Test: `supabase/tests/202610210002_sorting_partial_move_to_finish_validation.sql`.
  Status: applied 2026-10-21 on owner approval. Fix `202610210003_sorting_restore_partial_move_segment_fix.sql`
  (applied on owner approval): restore v2 tried to close the Finish segment with
  ended_at = started_at, refused by `finish_staff_table_segments_time_check`; the segment now
  stays on the cancelled Finish session as history (every reader joins non-cancelled sessions).
- Validation: `node scripts/validate-repository.mjs` passed; Playwright with a stubbed
  Supabase client renders the partial-move row and sends the v2 call. Against the database
  (pgtap is not installed, so the test assertions were run as plain queries): functions
  exist, anon cannot execute, a caller without Sorting access is refused. Rolled-back run as
  the owner account: Ronaldo (whole-shift move) now shows MOVED; Agostinho moved at 18:00
  showed Sorting 15:00-18:00 (169 min net, break 11) and Finish Table 2 from 18:00 (break 19);
  Back to Sorting reopened the Sorting shift with break 30 and no active Finish session.
  Security advisors: only the expected authenticated SECURITY DEFINER warnings.
- Open / next: owner repeats the real test; owner test data of 2026-10-21 (Ronaldo) to be
  cleaned afterwards.

## 2026-10-21 — Claude — Sorting Staff tab: plan next to actual, one-tap changes

- Branch / commits: `claude/sorting-staff-quick-actions` (Pull Request into `master`).
- Changed: the Sorting Staff tab shows each person as Roster (plan) next to Today (actual),
  with late start, early leave and overtime highlighted. A "What changed?" button opens
  plain choices: Arrived late, Leaving early, Staying later, Did not come, Clothes / MOP,
  Went to a Finish table, Different break, Time away, Edit all times. Each choice is one
  short step with "Now" and preset time chips and no browser prompts. "Add staff
  manually" is now "Add someone to Sorting". The full edit dialog shows planned times.
- Database: none. The new screen calls the existing RPCs (`save_sorting_staff_actual_v3`,
  `set_sorting_staff_attendance`, `set_sorting_staff_work_mode`,
  `move_sorting_staff_to_finish_table_v1`, `set_sorting_staff_break_v1`,
  `restore_sorting_staff_*`, `cancel_sorting_actual_staff`), so Actuals, production per
  person, the two-MOP rule and reports read the same data as before.
- Validation: `node scripts/validate-repository.mjs` passed. Playwright against a local
  server with a stubbed Supabase client: desktop and 390 px layouts render; every choice
  sends the expected RPC and parameters. Not tested against the live database.
- Open / next: covering as Team Leader or Supervisor has no Actual record in the database
  yet; it needs a migration and owner approval.

## 2026-10-21 — Claude — Urgent trolley checks for Managers and Distribution

- Branch / commits: `claude/trolley-check-urgent-alert`, Pull Request into `master`.
- Changed: owner request — a trolley quantity check reported by Production ("Report trolley
  plan" in Finish and MOP, table `operational_data_reports`) is urgent and must not be
  forgotten. Before, only Customer Schedule editors saw it inside the Customers page. Now
  ADMIN, MANAGER, PLANNER and DISTRIBUTION_OPERATOR accounts, accounts with a Distribution edit
  grant and staff whose primary role is Production Manager see a non-dismissable alert at the
  top of every page (`operational-page-nav.js`, refreshed every 5 minutes; amber, red after 4 h,
  pulsing "overdue" after 24 h), an "Needs action" item in Notifications and the count in the
  notification badge. "Review now" opens a dialog with plan vs reported, reason and scans; each
  check closes only with a note as "Plan corrected" (RESOLVED) or "Plan was right" (REJECTED),
  which records who and when (existing columns and audit_log).
- Database: `202610210001_trolley_check_urgent_alert.sql` — **applied 2026-10-21** on the owner's
  approval. New `can_handle_trolley_plan_checks`, `get_open_trolley_checks`;
  replaces `review_operational_schedule_report` (audience widened),
  `get_my_notification_summary` and `get_my_notification_inbox` (repo bodies verified equal to
  live before editing; the inbox's live "Â·" mojibake becomes "·"). No table change.
  Test: `supabase/tests/202610210001_trolley_check_urgent_alert_validation.sql`.
- Validation: `node scripts/validate-repository.mjs` passed. Dry-run on ElisCaretex-dev inside a
  rolled-back transaction: a 30-hour-old test report is listed for the ADMIN account, counted in
  the summary and the inbox, resolved by ADMIN; a Finish operator gets an empty list and is
  refused. Live objects confirmed unchanged afterwards. Playwright with a stubbed client:
  alert on Notifications and Distribution (desktop and 390 px), dialog, required note, resolve
  removes the check, `?trolleyChecks=open` opens the dialog.
- After applying: the 9 static checks of the test file pass (run as plain queries); an unknown
  account gets `can_handle=false` and is refused review (42501), the ADMIN account gets
  `can_handle=true`; the inbox "Â·" mojibake is gone. Security advisors: no new finding
  categories, and none of the new functions is executable by `anon`.
- Open / next: no report has ever been filed (0 rows), so a real check from Finish confirms the flow end to end.

## 2026-10-21 — Claude — My Roster renamed to My Production Roster

- Branch / commits: `claude/my-production-roster-name`, Pull Request into `master`
- Changed: the employee production roster screen is now called "My Production Roster"
  (sidebar, page title, heading) so it reads in parallel with "My Driver Roster". The
  management view heading is "Published Production Roster". The URL
  (`pages/roster-view.html`) and the navigation id `my-roster` are unchanged, so links and
  notification deep links keep working. Cache version of `app-shell-policy.js` bumped on
  every page.
- Database: none. The permission catalogue (`application_modules.module_name` for
  `MY_ROSTER`) and RPC error messages still say "My Roster".
- Validation: `node scripts/validate-repository.mjs` passed. Not tested in a browser.
- Open / next: if the owner wants the Accounts & Access label renamed too, add a migration
  updating `application_modules.module_name` for `MY_ROSTER`.

## 2026-10-20 — Claude — Sorting MOP: up to two staff per day

- Branch / commits: `claude/sorting-mop-two-staff`, Pull Request into `master`.
- Changed: owner request — the Sorting MOP position accepts one or two staff. Roster: the MOP
  coverage row has a second "2nd MOP" selector; the day editor keeps an existing MOP when a
  second is set and refuses a third. Sorting workstation: setting someone to MOP no longer moves
  the other MOP to Clothes (a third is refused); the MOP Production badge becomes a selector when
  two MOP staff are on shift, and the batch is recorded for the chosen one. MOP KG targets stay
  per staff hour, so no capacity formula changed.
- Database: `202610200004_sorting_mop_two_staff.sql` — **applied 2026-10-20** on the owner's
  approval (renumbered from 0003, which PR #25 uses; the two change different functions). Replaces `production_roster_assert_operational_rules`, `get_sorting_staff_work_context_v2`,
  `set_sorting_staff_work_mode`, `get_sorting_staff_dashboard_context_v2` and
  `get_sorting_mop_production_context`; four were rebuilt from the committed bodies, verified equal
  to live by md5 before editing. Test: `supabase/tests/202610200004_sorting_mop_two_staff_validation.sql`.
- Validation: `node scripts/validate-repository.mjs` passed. Playwright with a stubbed client:
  two MOP on one day, swap of the first keeps the second, third MOP refused in the day editor.
  After applying: all five live bodies match the file (md5) and the pgTAP checks pass.
- Open / next: a real check on the Sorting workstation and MOP Production with two MOP staff.

## 2026-10-20 — Claude — Staff Master: primary role is the job function, area is where they work

- Branch / commits: `claude/staff-primary-role-function`, Pull Request into `master`.
- Changed: "Sorting Area" is no longer offered as a Primary role (it was an area used as a role).
  Sorting staff become General Operative with Sorting as default area. New primary roles
  Production Manager and Maintenance; "Label" renamed "Label Operative". The Staff editor hides
  module "areas" (Administration, Reports, Roster), lists only the stations of the chosen area
  and pre-selects the area's only station. Production Roster (`roster.js`, `roster-view.js`) and
  `production_roster_default_display_section` place a General Operative with station
  SORTING_MAIN in the Sorting section, Production Manager with Supervisors and Maintenance in
  Support Role. SORTING_AREA stays as roster position and COVER capability.
- Database: `202610200003_staff_primary_role_separated_from_area.sql` — APPLIED to ElisCaretex-dev
  on 2026-10-20 with the owner's authorisation. Moves the 13 SORTING_AREA staff to GENERAL_OPERATIVE (audit_log rows
  `STAFF_PRIMARY_ROLE_CORRECTED`), updates the primary-role snapshot in current and future
  DRAFT rosters only; published rosters and roster positions are unchanged.
- Validation: migration dry-run inside a rolled-back transaction on ElisCaretex-dev (0 staff left
  on SORTING_AREA, display sections as expected); `node scripts/validate-repository.mjs`.
  Test file `supabase/tests/202610200003_staff_primary_role_separated_from_area_validation.sql`.
  After applying, the 8 checks of the test file passed (run as plain queries); security advisors
  show no new finding.
- Open / next: merge the PR. Support Role (4 inactive staff) kept.

## 2026-10-20 — Claude — Production Roster: Finish capacity of both shifts

- Branch / commits: `claude/roster-both-shifts-capacity`, Pull Request into `master`.
- Changed: new "Both shifts" row in the Roster Finish capacity block (this shift with its live,
  unsaved edits + the other shift's saved roster, approved leave applied, same simulation %).
  "Customers scheduled" is now red only when Clothes + other is above the both-shifts capacity,
  as requested by the owner. Frontend only (`roster.js`, `roster.css`, cache versions).
- Database: none (reuses `get_production_roster_week` and `get_production_roster_approved_leave`).
- Validation: `node scripts/validate-repository.mjs` passed. Playwright with a stubbed client and
  two shifts (10 staff each, 7.5 h and 8 h): Both shifts 3,643 kg, 4,371 kg at 120%; red only on
  the days above it.
- Open / next: owner acceptance after merge. The other shift counts only what is saved.

## 2026-10-20 — Claude — Production Roster: scheduled customer KG per day

- Branch / commits: `claude/roster-daily-customer-kg`, Pull Request into `master`.
- Changed: new "Customers scheduled" row under Finish total in the Roster Finish capacity block:
  per production day, the sum of the automatic Expected KG of all scheduled customers, Clothes +
  other products in bold and MOP below, with the customer count and slots without KG. The value
  is for the whole day (both shifts), so it is not coloured against the single-shift capacity.
  New RPC `get_production_roster_customer_kg(date,date)` (roster read access).
- Database: `202610200002_production_roster_customer_kg.sql` — **applied 2026-10-20** on the owner's
  approval; live body matches the file (md5); runs as ADMIN, refused without an account, anon blocked. Test: `supabase/tests/202610200002_production_roster_customer_kg_validation.sql`.
- Validation: the RPC query ran read-only on live data for week 2026-10-19 (Mon 3,076 + 654 MOP kg,
  Tue 5,712 + 1,050 ...). `node scripts/validate-repository.mjs` passed. Playwright with a stubbed
  Supabase client at 1440 px. The page shows "No KG data" until the migration is applied.
- Open / next: owner acceptance after merge.

## 2026-10-20 — Claude — Customer Expected KG calculated from production history

- Branch / commits: `claude/customer-kg-history-estimates`, Pull Request into `master`.
- Changed: Expected KG per customer, product and weekday is now calculated from official
  production (latest 8 valid services with no date limit, owner decision, finished-next-day production credited to the scheduled day,
  outliers capped at 0.4x-2x the median, ready after 3 services). Manual KG stays only as a
  fallback while learning. Customer Weekly Planner and list show the value with an Auto/Manual/
  Stale tag and a tooltip with the evidence; the schedule editor shows the automatic value
  instead of a "Use" button; Distribution Route customers, route stops, Forward capacity and the
  leave capacity calendar use the same model. Customer form label is now "Fallback KG per delivery".
- Database: `202610200001_customer_kg_history_estimates.sql` — **applied 2026-10-20** on the owner's
  approval (live history name `customer_kg_history_estimates`). Live function bodies match the file
  (md5 compared for all 8 functions). Test: `supabase/tests/202610200001_customer_kg_history_estimates_validation.sql`.
- Validation: after applying, the test assertions passed when run as SQL (grants, weekday
  attribution, minimum 3 services, average within observed range, max 8 services); every changed
  RPC ran as an ADMIN identity; a call without an account was refused (42501). Security advisors:
  no new anon exposure. Live: 461 of 505 slots ready, 22 stale, 22 learning; ~29,450 kg per week;
  Wednesday 2026-10-21 Distribution stops 87 / 6,762 kg. Backtest on
  3,643 Jul-Sep services: slot WAPE 28.0% -> 25.2%, total bias -7.4% -> -1.5%, daily total
  error 7.4%. `node scripts/validate-repository.mjs` passed. Playwright with a stubbed Supabase
  client: planner, list and Route customers at 1440 px. Not checked with real accounts.
- Open / next: owner acceptance on the live site after merge. Official production data
  in the database ends 2026-09-26; if no newer data arrives, slots turn STALE from early November.

---

## 2026-10-20 — Claude — Shared page standard for every workspace

- Branch / commits: `claude/ui-visual-standard`, Pull Request stacked on the sidebar PR.
- Changed: one page frame for all workspaces (12/16 px gutters, header banner in the same
  position and size on every page; before, each page used its own 0-18 px padding);
  page-level errors and warnings shown as the same red/amber box, confirmations as a
  short green line, empty messages take no space; My Roster, My Driver Roster,
  Notifications and Customer guides use the same banner shape (shift colours kept) and
  drop their Back links and duplicate logo; Distribution's Customer guides link looks like
  the other tabs. Removed unused `enterprise-ui_old.css`, `enterprise-ui_old2.css` and
  `finish-production.css.before-visual-refresh-20260923.bak`. CSS only, no logic changed.
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed. Playwright with a stubbed
  Supabase client measured the header box on 13 pages (all at the same x/y/width) and
  screenshots at 1440 px and 390 px. Not checked with real data.
- Open / next: owner acceptance on the live site.

## 2026-10-20 — Claude — Sidebar navigation: full coverage, sections, mobile drawer, one Home

- Branch / commits: `claude/ui-consistency-sidebar`, Pull Request into `master`.
- Changed: the sidebar now appears on every signed-in page, including Home (the separate
  administrative Home without sidebar is gone), My Roster, My Driver Roster, Notifications
  and Customer guides. New sections (Home, My work, Planning, Production, Logistics,
  Management) with distinct icons; Distribution lists Leave calendar and Customer guides;
  the current sub-page follows in-page tab changes; Notifications shows an attention badge.
  Mobile (<= 700 px) uses a top bar and a navigation drawer instead of the icon strip.
  Sidebar CSS moved to `frontend/assets/css/navigation.css`; `app-shell-policy.js` gained
  `NAVIGATION_GROUPS` and `PAGE_MODULES`. Home shows `?access=denied` as a message.
  Removed the unused `sorting-area-navigation.js`. Docs: `docs/NAVIGATION-ACCESS-MODEL.md`.
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed. Browser check with Playwright
  against a local server and a stubbed Supabase client (no real login, no data): every
  page at 1440 px and 390 px, sidebar collapsed, hover-open and mobile drawer, ADMIN and
  FINISH_OPERATOR navigation, roster token link without session (sidebar removed).
  Not checked with real accounts or data.
- Open / next: owner acceptance on the live site. Permissions are unchanged (navigation
  is guidance only; RPCs still enforce access).

## 2026-10-19 — Claude — Distribution review after the Fleet and roster changes

- Branch / commits: `claude/roster-review-fixes`, Pull Request.
- Owner asked for a full review after PRs #13 to #16. Smoke-tested every Distribution tab,
  the route, roster, defect, maintenance, history and temporary-vehicle dialogs in Chromium
  on the live site with every write blocked: no page or console errors.
- Found and fixed:
  - Republishing a week (now possible) left daily routes the new version no longer plans
    as READY with the old driver and vehicle, so a driver set to Off still showed on the
    Daily board. `202610190008_roster_publish_clears_removed_runs.sql` (**Applied
    2026-10-20** on the owner's request; test file 3/3, no new advisor finding) returns such DRAFT/READY routes from today onwards to DRAFT with no driver
    or vehicle and logs `ROSTER_REMOVED`; dispatched or finished routes are untouched.
    Reproduced as the owner's account (Alex Off on Wed 21 Oct: route 612 stayed READY with
    Alex) and verified the fix in a rolled-back transaction (612 back to DRAFT, 42 READY
    routes = 42 planned entries, today's 9 routes unchanged).
  - The Edit route dialog disabled the route's own vehicle when it is off road today, so
    the dialog could not be saved without changing it. The current vehicle stays
    selectable (with `202610190007` the server accepts keeping it).
- Still open: the 231D45366 Engine defect (off road since 15 Jul) is probably stale: Return to service
  clears it if the truck is running.

## 2026-10-19 — Claude — Roster: Edit roster on a published week

- Branch / commits: `claude/roster-edit-published-week`, Pull Request.
- Problem (owner report): once a week was published, every roster cell was disabled and
  there was no way to change it; the page offered no action to start a new version.
- Changed: a published, current or future week is editable directly (the owner clicked the
  cells and expected the dialog; an **Edit roster** button first was missed, so it was
  removed). Save creates a new draft version (the published one is not changed) and
  Publish replaces the published version, as the database already supported.
- Validation: in Chromium on the live site with the changed file served locally and every
  write blocked, cells went from 0 to 65 clickable after Edit roster and the entry dialog
  opened. `node scripts/validate-repository.mjs` passed. No database change.
- Open / next: saving this week also needs `202610190007` applied (route 612 today keeps
  231D45366, which is off road).

## 2026-10-19 — Claude — Roster: keep a published vehicle that went off road

- Branch / commits: `claude/roster-keep-published-vehicle`, Pull Request.
- Problem (owner report): after `202610190005` the weekly roster could not be saved at all.
  Saving re-validates the whole week, and one published day (route 612 today, 231D45366,
  off road since 15 Jul) failed the new vehicle rule, so every edit was refused.
- Changed: a blocked vehicle still cannot be newly chosen, but a day already published with
  it is kept and only flagged (⚠) in the roster; the same applies to the vehicle a daily
  route already has. The roster dialog lets a cell keep its current vehicle.
- Database: `202610190007_roster_keeps_published_vehicle.sql`, **Applied 2026-10-20** on the
  owner's explicit request.
  Replaces `validate_distribution_roster_version` and `save_distribution_route_run`.
- Validation: reproduced the failure as the owner's account (saving the published week
  unchanged returned "Vehicle 231D45366 cannot be used on Mon 19 Oct"); with the new
  function, inside a rolled-back transaction, the same save succeeded and moving 231D45366
  to another route was still refused. `node scripts/validate-repository.mjs` passed.
- After applying (2026-10-20): the test file passed 3/3, saving the published week
  2026-10-19 unchanged as the owner's account succeeded (rolled back), and the security
  advisors showed no new finding.

## 2026-10-19 — Claude — Fleet: temporary (short hire) vehicles

- Branch / commits: `claude/fleet-vehicle-off-road-periods` (same Pull Request).
- Changed: owner request. Most trucks are hired and temporary ones come and go, so Fleet
  has **Add temporary vehicle** and a "Kind" choice (Fleet vehicle / Temporary hire) in the
  vehicle form. A temporary vehicle asks only for registration, type, capacity, hire company
  and "Available until"; documents and the other registration details are hidden and do not
  count as missing (only trolley capacity does). After its available-until date the vehicle
  is blocked in the roster and on daily routes ("Temporary vehicle, hire ended DD Mon") and
  Fleet shows "Hire ended — edit to extend or set Inactive".
- Database: `202610190006_fleet_temporary_vehicles.sql`, **Applied 2026-10-19** on the
  owner's explicit request. Adds
  `fleet_vehicles.is_temporary`, `available_until`, `hire_company`; replaces
  `distribution_vehicle_block_reason` and `save_fleet_vehicle` (which now also saves the
  three fields and returns `roster_conflicts`).
- Validation: migration and saves run as the owner's account inside a rolled-back
  transaction on `ElisCaretex-dev` (free on the last day, blocked the day after, existing
  vehicle fields kept on a partial save). Form checked in Chromium, nothing saved.
  `node scripts/validate-repository.mjs` passed. After applying, the test file
  `supabase/tests/202610190006_fleet_temporary_vehicles_validation.sql` passed 8/8 and the
  security advisors showed no new finding.
- Open / next: the frontend reaches production when the Pull Request is merged.

## 2026-10-19 — Claude — Fleet: vehicle off road until its expected return

- Branch / commits: `claude/fleet-vehicle-off-road-periods`, Pull Request.
- Changed: owner request after the Distribution review. A defect now records whether the
  vehicle can be used (Roadworthy / Restricted use / Off road) and a required expected
  return date; a maintenance has a required expected return date. Off-road defects and
  planned or in-progress maintenance block the vehicle in the roster picker, on the daily
  route plan and in roster save/publish from the start date until the day before the
  expected return; an overdue return blocks today until someone presses **Return to
  service** in Fleet (or closes the defect / completes the maintenance). Expired documents
  only warn (owner decision). Fleet rows show status, the most urgent document by name and
  12-month defects / days off road; **History** opens metrics (defects, days off road,
  maintenance, days rostered, KM) and every past item. Board cards flag the vehicle, the
  roster marks published days whose vehicle is now blocked, and saving a defect or
  maintenance lists the published roster days to reassign. HIGH/CRITICAL severity no longer
  silently sets the vehicle Out of service.
- Database: `202610190005_fleet_vehicle_off_road_periods.sql`, **Applied 2026-10-19** on the
  owner's request.
  It declares the CentralDB-imported columns `expected_return_on`, `repair_date` and
  `vehicle_status_snapshot`, and backfills `vehicle_condition` from the imported snapshot:
  231D45366 (Out Of Service since 15 Jul, still open) becomes off road and blocks today
  until it is returned to service.
- Validation: the block rule, defect save, roster conflicts and return to service were run
  against `ElisCaretex-dev` inside a transaction that was rolled back (nothing kept).
  `node scripts/validate-repository.mjs` passed. UI checked in Chromium on the live site
  with the changed files served locally and the new RPC fields stubbed; nothing was saved.
  After applying: the pgTAP file `supabase/tests/202610190005_..._validation.sql` passed
  20/20 (pgTAP created and dropped inside the rolled-back transaction); as the owner's
  account, the fleet master, roster week, vehicle history and a maintenance save (rolled
  back) returned the expected blocks and conflicts. Security advisors: the new RPCs appear
  only in the usual `authenticated_security_definer_function_executable` warning (they
  check Distribution access inside); the internal helpers are not executable by any client
  role.
- Open / next: 231D45366 stays blocked on today's roster (route 612) until someone records
  its return in Fleet. The frontend reaches production when the Pull Request is merged.

## 2026-10-19 — Claude — Distribution alerts and weekly actuals history

- Branch / commits: `claude/distribution-alerts-actuals-history`, Pull Request.
- Changed: Distribution shows compact alert chips under the summary cards, one per area
  and only when needed: Drivers (expired or 30-day-due licence/CPC, exit within 14 days,
  missing details), Fleet (expired or due road tax/insurance/test/service, open defects,
  missing details) and last week's actuals still missing. A chip opens its tab (with the
  "incomplete only" filter when that is the only issue). The "Fleet attention" card was
  removed. The Actuals tab now lists the last 8 closed weeks (up to 52 with "Show older
  weeks") with actual/planned totals and a Recorded / Missing / Not recorded / No plan
  status; the entry form stays closed until a week is opened. Fixed `weekInputValue`,
  which showed the previous ISO week (and W00 in early January) in the roster and
  actuals week pickers.
- Database: none. The history calls `get_distribution_actuals_week` once per week.
- Validation: `node scripts/validate-repository.mjs` passed. Exercised in Chromium against
  a stubbed Supabase client (alerts, opening a week from the alert, saving, older weeks,
  week picker, mobile width); not run against `ElisCaretex-dev`.
- Open / next: owner check on live data. The history lists only drivers and vehicles that
  are active today, because the existing RPC filters them; a former driver's past hours
  are still stored but not shown.

## 2026-10-19 — Claude — Apps Script history reconciliation (staging to target)

- Branch / commits: `claude/apps-script-history-reconciliation` (Pull Request #3).
- Changed: added `docs/database/apps-script-history-reconciliation.md` (what the
  2026-09-26 import loaded, excluded and still needs), migration
  `202610190003_capture_apps_script_history_staging.sql` (records the six
  `staging.apps_script_*` tables that were created without a migration) and read-only
  validation `supabase/tests/202610190003_apps_script_history_reconciliation_validation.sql`.
- Database: none applied. The migration is idempotent and would change nothing on
  `ElisCaretex-dev`; the owner decides whether to apply it.
- Validation: the test queries were run read-only against `ElisCaretex-dev` and all
  eight checks hold (Finish KG 823,581.96 = staging; MOP KG 49,574.02 = staging; no
  orphan or altered lines).
- Open / next: source-file totals versus staging, owner acceptance of the exclusions,
  the two BLOCKED groups, MOP before 2026-07-13, and a provenance column for MOP
  batches. See section "Still open" of the new document.

## 2026-10-19 — Claude — Review fixes: cancel a scheduled driver exit, migration guard

- Branch / commits: `claude/review-fixes`, Pull Request.
- Changed: review of PRs #2 and #5 to #8 found two fixes. (1) Distribution > Drivers now
  offers **Cancel exit** on a driver with a scheduled (future) exit; before, a scheduled
  exit could only be moved, not cancelled. Migration `202610190004` makes
  `reinstate_distribution_driver` keep the current employment and availability when it
  cancels a scheduled exit (before, it always set ACTIVE/AVAILABLE, so a SUSPENDED
  driver became active). A driver who has left is still made ACTIVE/AVAILABLE.
  (2) `.claude/hooks/guard-repository-rules.mjs` now blocks edits only to committed
  migrations, so a new migration can be corrected before its first commit.
- Database: `202610190004_driver_reinstate_keeps_scheduled_status.sql` **applied** to
  `ElisCaretex-dev` by the owner through the SQL Editor on 2026-10-19 (Owner confirmed).
- Validation: `node scripts/validate-repository.mjs` passed. Hook tested with a committed
  migration (blocked) and a new staged one (allowed). Migration and UI not run live.
- Open / next: run the `202610190004` test file against the database (not yet run). Schema drift: live
  `distribution_drivers` also has `legacy_driver_id` and `import_source`, which no
  migration declares.

## 2026-10-19 — Claude — Sorting Washing: Reception exception unlocks Save

- Branch / commits: `claude/wash-reception-exception-save`, Pull Request.
- Changed: in `frontend/assets/js/sorting.js` the Save washing button now also accepts a
  customer covered by a staged Reception exception with a reason. Before, the button
  only accepted a CONTENTS trolley scan, so the exception flow (already sent by
  `washPayload()` and validated by `sorting_assert_wash_reception_gate_v2`) could never
  be saved. The button tooltip now mentions the exception.
- Database: none.
- Validation: `node scripts/validate-repository.mjs` passed. In a browser against the live
  site with the Sorting terminal account and the changed `sorting.js` served locally:
  staging an exception enables Save washing, removing the customer disables it again.
  Nothing was saved. Found during the browser test recorded in the project folder
  (`teste-aplicacao/teste-navegador.md`).
- Open / next: a real wash with an exception has not been saved yet; test it after merge
  and cancel the wash through the app.

## 2026-10-19 — Claude — Database back under the Free plan size limit

- Branch / commits: `claude/staging-vacuum-worklog`, Pull Request (this entry only).
- Changed: the Supabase dashboard showed "Exceeding usage limits" (database 0.574 of
  0.5 GB). 368 MB of the 533 MB were the `staging.apps_script_*` import tables, mostly
  empty space left by repeated imports. On owner request, ran `VACUUM FULL` on
  `apps_script_finish_lines`, `apps_script_wash_lines`, `apps_script_staff_sessions`,
  `apps_script_mop_lines` and `apps_script_trolley_returns`. No data was changed.
- Database: maintenance only, no migration. Database 533 MB → 272 MB; staging 368 MB
  → 107 MB (finish lines 166 → 49 MB, wash lines 146 → 42 MB).
- Validation: row counts identical before and after (finish 28285, wash 34557, staff
  sessions 8258, MOP 2191, trolley returns 1451).
- Open / next: if staging is re-imported again, run `VACUUM FULL` on the reloaded tables
  afterwards, or the space returns.

## 2026-10-19 — Claude — Claude Code hooks and skills for the repository rules

- Branch / commits: `claude/claude-code-automations`, Pull Request.
- Changed: added `.claude/settings.json` with two hooks. A PreToolUse hook
  (`.claude/hooks/guard-repository-rules.mjs`) blocks Claude from editing an existing
  file in `supabase/migrations/` and from pushing to `master`. A PostToolUse hook
  (`.claude/hooks/validate-frontend.mjs`) runs `scripts/validate-repository.mjs` after
  every edit under `frontend/`. Added the skills `new-migration` (file naming, SECURITY
  DEFINER pattern, pgTAP test, WORKLOG) and `finish-task` (AGENTS.md section 6).
  These files affect Claude Code only; Codex and the deploy are unchanged.
- Database: none.
- Validation: both hooks tested locally with allowed and blocked inputs (push of a
  `claude/*` branch allowed; `git push origin master`, `HEAD:master` and a bare push
  from `master` blocked; editing an existing migration blocked, creating a new one
  allowed; a JavaScript syntax error reported). `node scripts/validate-repository.mjs`
  passes.
- Open / next: none.

## 2026-10-19 — Claude — Driver exit workflow (Remove replaces Leave)

- Branch / commits: `claude/driver-offboarding`, Pull Request.
- Changed: in Distribution > Drivers the **Leave** button (a duplicate of the
  Leave calendar) is replaced by **Remove**: last working day plus a mandatory
  reason, like Staff Master deactivation. Future dates are scheduled and applied
  by a daily cron job; a linked non-production Staff record follows the same exit;
  pending leave after the exit is cancelled; published roster assignments after
  the exit are listed for reassignment, never changed. Former drivers can be
  shown and **Reinstated** with a reason. The driver form no longer offers
  "Inactive". INIT sections 4, 7 and 14 updated.
- Database: `202610190002_distribution_driver_exit_workflow.sql` **applied**
  2026-10-19 by Claude on owner request (live history name
  `distribution_driver_exit_workflow`). Verified live: the three new functions are
  SECURITY DEFINER; anon cannot execute them; `process_scheduled_driver_exits` is not
  executable by authenticated; cron job `distribution-driver-scheduled-exit`
  (`6 0 * * *`) active; the six exit columns exist; `save_distribution_driver` has
  the INACTIVE guard; driver counts unchanged (13 ACTIVE, 3 INACTIVE). Security
  advisors: only the existing project-wide warning about authenticated SECURITY
  DEFINER functions, as expected for these RPCs.
- Validation: local PostgreSQL 16 with stubbed auth/staff/roster/cron objects:
  migration applies twice cleanly; auditor blocked; reason, self-removal, stale
  row_version, double exit and Edit-to/from-INACTIVE rejected; scheduled exit keeps
  the driver active and schedules the Staff record; pending leave after the exit
  cancelled; published conflict returned; cron job deactivates after the date;
  reinstate restores driver and Staff; three audit_log rows written. Browser check
  of Drivers (Remove, Change exit, former drivers, Reinstate) with a mocked
  Supabase client, no console errors. `node scripts/validate-repository.mjs` passed.
- Open / next: the weekly planner does not yet warn when a driver with a scheduled
  exit is assigned after the last working day (the remove action lists published
  conflicts instead). The 3 live INACTIVE drivers already have `deactivated_on`
  but no reason; they show as former drivers.

## 2026-10-19 — Claude — Driver and fleet master completion

- Branch / commits: `claude/driver-fleet-master`, Pull Request #2.
- Changed: Distribution Drivers can be linked to a non-production Staff Master
  record from the driver form (production staff still use Transfer to Driver).
  Driver and vehicle saves now merge into the stored row, fixing two data-loss
  bugs: editing a driver cleared its Staff link, and editing a vehicle cleared
  capacity m3, odometer and notes (the Fleet tab read the dashboard, which omits
  them). Fleet now reads full rows via `get_fleet_vehicle_master`, vehicles can
  be marked inactive, open defects and maintenance can be updated or closed, and
  Drivers/Fleet show which details are missing with an "incomplete only" filter.
  Optional `row_version` checks reject stale edits.
- Database: `202610190001_distribution_driver_fleet_master_completion.sql`
  **applied** to `ElisCaretex-dev` on 2026-10-19 at the owner's request (live
  history name `distribution_driver_fleet_master_completion`). Checked live: the
  five functions are SECURITY DEFINER, not executable by anon, executable by
  authenticated; as an ADMIN (read-only transaction) the fleet master returned 18
  full vehicle rows, the driver master 16 drivers, Staff link options 2 records.
  Security advisors show no new finding for these functions beyond the existing
  project-wide "authenticated SECURITY DEFINER executable" warning.
- Validation: migration and behaviour (permission guards, Staff link rules,
  partial-edit preservation, stale row_version, duplicate registration) checked
  on a local PostgreSQL 16 with stubbed auth/staff objects; browser check of the
  Drivers and Fleet tabs with a mocked Supabase client (desktop and mobile, no
  console errors); `node scripts/validate-repository.mjs` passed. pgTAP file
  `supabase/tests/202610190001_distribution_driver_fleet_master_completion_validation.sql`
  not yet run against the development project.
- Open / next: merge the PR (the frontend now matches the database); fill the real
  driver/fleet data. Only 2 non-production Staff records exist to link drivers to;
  INIT section 4 can mention the Staff link and fleet master RPCs at the next refresh.

## 2026-10-19 — Owner, documented by Claude — Supabase Auth password policy

- Branch / commits: `claude/auth-password-policy` (Pull Request into `master`).
- Changed: the owner tried to enable leaked-password protection (HaveIBeenPwned) in
  `ElisCaretex-dev`. Supabase refused it: "available on Pro Plans and up", so the
  project is on the Free plan. As the Free-plan alternative, the owner raised
  **Minimum password length** and set **Password requirements** in Supabase Auth
  (dashboard setting, not a migration). The exact values were not recorded here.
- Database: none. Auth configuration changed in the dashboard only.
- Validation: owner confirmed in the dashboard. Not validated by an agent (the
  Supabase connector was unavailable in this session). The new rules apply only to
  passwords created or changed from now on; existing passwords keep working.
- Open / next: enable leaked-password protection after an upgrade to Pro. Check that
  the invitation, forgot-password and update-password pages show the Auth error
  message clearly when a password breaks the new rules.

## 2026-10-18 — Codex — Git identity and completed push correction

- Branch / commits: `master`; new documentation commit, preserving all previous
  commits, including `c796ff3` and `5c2ce7a`.
- Changed: corrected the earlier entry to record the completed push and both
  commits on `origin/master`. Configured this computer's global Git identity as
  Paulo Bressan with the email explicitly supplied by the owner. Existing global
  settings were preserved. No old commits were amended, rebased or rewritten.
- Database: none.
- Validation: fetched/pulled `master`; both commits are ancestors of
  `origin/master`. No open PRs found; checked the remaining Claude branch.
  Verified global `user.name` and `user.email`. Repository validation passed
  (24 JavaScript files, 20 HTML files); `git diff --check` passed.
- Open / next: existing operational acceptance and owner action items remain.

## 2026-10-18 — Codex — INIT v91 and working copy on the new computer

- Branch / commits: `master`, `c796ff3` (INIT refresh); this accompanying WORKLOG
  completion commit records the checklist and validation.
- Changed: refreshed INIT to v91, documenting Distribution publication/printing,
  My Driver Roster, Customer Guides, leave calendar/review, driver identity and
  readable history, with actual permission/RPC guards and honest evidence status.
  Added migrations `202610170002`–`202610170012`, all 12 Distribution commits,
  coordination milestones and the migration-history caveat. Closed startup item 10:
  customer KG frontend/migration reached master and deployment in `9308683`, per
  the existing verified action item. Added AGENTS/WORKLOG reading, Claude PR
  coordination and per-task logging as ongoing requirements.
- Working copy: Codex now works on this new computer at
  `C:/Users/bress/Documents/Codex/2026-10-18/clone-o-reposit-rio-https-github/ElisCaretex`,
  cloned from GitHub `master`; the INIT replaces the previous Codex computer path.
  GitHub master remains authoritative. Follow `AGENTS.md` on every future task.
- Database: none. No migrations applied, no operational records changed and no
  live database revalidation. Applied evidence is attributed to Claude's prior
  2026-10-18 review; SQL tests and Distribution owner acceptance remain unconfirmed.
- Validation: read AGENTS, WORKLOG, full INIT, review and import guide; fetched,
  checked clean status, pulled master and inspected recent history. GitHub open-PR
  search returned no open PRs; remote `claude/coordination-setup` still exists but
  PR #1 is already merged in `296e117`. Reviewed migration definitions and frontend
  RPC/Storage usage. `node scripts/validate-repository.mjs` passed (24 JavaScript
  files, 20 HTML files); `git diff --check` passed. No browser or SQL tests run.
- Push completed: commits `c796ff3` and `5c2ce7a` are on `origin/master`, verified
  on 2026-10-18. The earlier credential error was resolved by the owner's push
  from their Windows session.
- Open / next:
  Recurring start/end checklists continue on every task. Distribution
  browser/negative permission tests and owner acceptance remain pending. Owner
  items concerning `.reference-distribution/` and leaked-password protection are
  unchanged; the old owner PR #1 action is already satisfied by merge `296e117`.

## 2026-10-18 — Claude — Repository and database review; coordination files

- Branch / commits: `claude/coordination-setup` (Pull Request into `master`).
- Changed: added `AGENTS.md`, `CLAUDE.md` and this work log; linked them from `README.md`
  and `docs/README.md`; removed the unused Graphify references (owner decision). No code
  or database change.
- Database: none. Read-only checks only.
- Validation, against `master` at `acfca47`:
  - `node scripts/validate-repository.mjs` passed (24 JavaScript files, 20 HTML files).
  - No service-role key, secret key or password found in tracked files.
    `frontend/assets/js/config.js` contains only the project URL, the publishable key and the public app URL.
  - Every file and commit hash cited in the INIT exists. `README.md` also mentioned
    `.reference-distribution/` and `graphify-out/`, which are not in the repository.
  - All 11 migrations added after INIT v90 (`202610170002` to `202610170012`) appear in the
    live migration history. Spot checks found their objects (for example
    `customer_driver_guides`, `get_my_driver_roster`) in the database.
  - Edge Functions match the INIT: `production-roster-leave-email` v3 and
    `admin-account-management` v14, both active with `verify_jwt=true`.
  - Security advisors match INIT section 14: leaked-password protection disabled;
    `btree_gist` in the `public` schema; anonymous `SECURITY DEFINER` execution limited
    to the six token-based production roster endpoints; 281 authenticated
    `SECURITY DEFINER` functions (expected design, internal guards); 103 tables with RLS
    enabled and no policies (INFO; access goes through RPCs).
- Open / next: see "Open action items" at the top. The INIT handover (last updated in
  `9308683`, 2026-10-17 17:48) does not yet describe the Distribution work below.

## 2026-10-17 — Codex (recorded from Git history) — Distribution driver roster and customer guides

Not covered by INIT v90. Reconstructed by Claude on 2026-10-18 from Git history; commit
author recorded as Paulo Bressan.

- Commits: `1f69f2e` … `acfca47` (12 commits, 18:08–21:13).
- Changed: Distribution roster publication for non-working entries; new My Driver Roster
  (`frontend/pages/driver-roster.html`) and customer delivery guides
  (`frontend/pages/driver-guides.html`) with a private storage bucket; driver leave review
  and leave calendar; driver identity, codes and licence types; roster printing; readable
  Distribution history for administrators, including Customer Guide actions.
- Database: `202610170002` to `202610170012`, all present in the live migration history.
  New validation SQL: `supabase/tests/202610170002_…_validation.sql` and
  `supabase/tests/202610170003_…_validation.sql`.
- Validation: each push passed the GitHub Pages workflow. Browser and owner confirmation
  are not recorded.
- Open / next: document this work in the next INIT refresh.
