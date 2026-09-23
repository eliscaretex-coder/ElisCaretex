# ElisCaretex V2 - Authoritative AI Project INIT v87

**Date:** 2026-09-10
**Purpose:** current AI-to-AI handover for the ElisCaretex V2 laundry operations platform.
**Current source authority:** the working tree containing this file.
**Supersedes:** `ElisCaretex_V2_PROJECT_INIT_2026-08-18_v86_DISTRIBUTION_CURRENT.md` and older INIT handovers.

**Continuation update:** 2026-09-23. The owner now keeps the publishable Git repository in OneDrive and uses this Codex workspace as the editable AI working copy when needed. See section 2 before doing any work.

## 1. Read First

This is a live operational platform, not a UI prototype. Read the current source before changing it and preserve the distinction between planned, actual, reported and corrected facts.

Current Supabase development project:

```text
ElisCaretex-dev
project ref: fcimmysqifzxoanmpylh
```

Use these evidence terms accurately:

- **Applied**: migration execution was confirmed against the development project.
- **Validated**: a focused syntax, SQL or operational check passed.
- **Owner confirmed**: the owner tested the behaviour in the browser.
- **Prepared**: source exists but deployment or operational proof is not confirmed.

Do not apply Supabase writes unless the owner explicitly requests that action. Do not treat a local migration file as proof that it was applied.

Code, database/schema names, filenames and UI text remain in English. Conversation with the owner is in Portuguese.

## 2. Source and Startup

Current working source:

```text
C:/Users/paulob/Documents/Codex/2026-09-10/an/work/laundry-platform-v2-analysis/laundry-platform-v2
```

Owner's Git/GitHub working folder:

```text
C:/Users/paulob/OneDrive - ELIS/Documents/Paulo/laundry-platform-v2-foundation/laundry-platform-v2
```

GitHub repository:

```text
https://github.com/eliscaretex-coder/ElisCaretex.git
branch: master
```

Local application URL normally used by the owner:

```text
http://127.0.0.1:5500/frontend/index.html
```

Useful first reads:

```text
README.md
docs/architecture/overview.md
docs/architecture/PLATFORM_CORRECTION_REGISTER_20260818.md
docs/NAVIGATION-ACCESS-MODEL.md
docs/operations/PRODUCTION_TERMINAL_ROLLOUT.md
supabase/migrations/
```

The correction register is the active backlog and implementation record. Its current entries reach **P-041**.

Current collaboration/deployment workflow:

1. Codex may edit the Codex working copy listed above.
2. The owner copies changed files into the OneDrive Git working folder.
3. The owner commits and pushes from the OneDrive folder:

```text
git status
git add -A
git commit -m "Describe the change"
git push origin master
```

4. GitHub Pages deploys automatically from `master` using:

```text
.github/workflows/pages.yml
```

GitHub Pages publishes only the `frontend` folder. The live Pages URL is expected to be:

```text
https://eliscaretex-coder.github.io/ElisCaretex/
```

Supabase Auth should allow that URL in Site URL / Redirect URLs for login and password recovery. Do not put private credentials into frontend files. `frontend/assets/js/config.js` intentionally contains only the Supabase project URL and publishable key.

Security note from 2026-09-23: no `.env`, private key, service-role key or obvious private credential was found in the tracked source. The old `.reference-distribution` folder contained a Google Apps Script URL reference; if that endpoint is still active, disable/rotate it or remove the reference before making the repository broadly public.

## 3. Platform Architecture

```text
Static operational frontend
  -> Supabase Auth
  -> PostgreSQL RLS, constraints and controlled RPCs
  -> append-only operational evidence, corrections and audit/history
```

The frontend is an operational workflow surface, never the security boundary. PostgreSQL owns authorization and critical validation.

Core rules:

1. Preserve published schedules and rosters; never silently rewrite history.
2. Keep planned, actual, reported and corrected data separate.
3. Correct operational evidence through controlled replacement/correction flows, not destructive edits.
4. Production terminals are fixed computers; production people do not sign in individually on them.
5. New workspaces and actions need matching server-side authorization and targeted validation.
6. Never present simulation/test activity as real production data.

## 4. Current Workspaces

| Workspace | Current status and responsibility |
| --- | --- |
| Customer Workspace | Customer master, versioned schedules, schedule planner, routes and operational reports. Schedule-only access is read-only. |
| Distribution | Daily board, route customers by day/order, weekly roster, actuals, drivers, fleet, routes and history. |
| Production Roster | Planned staffing, shifts, leave governance, publication and history. `FINISH_UNITS_PER_KG` is maintained in Roster Settings, initially 6 units per kg. |
| Sorting / Washing | Washing, trolley intake, staff actuals, no-work, timed moves and controlled Finish cover transfer. |
| MOP Production | Standalone MOP production, corrections, ABS and MOP Types. A registered Sorting terminal can enter MOP Production; MOP Types are read-only to that terminal. |
| Finish Production | Table-based Finish production, scanned trolley control, KG/Units lines, ReWash ledger, staff actuals and delivery reconciliation. |
| Finish Results | Daily/Table/Shift performance, including ReWash and Units-to-KG equivalent treatment. |
| Production Tracker | Shared route-centric production trace with the Route board and an Operational list. |
| Trolleys | Trolley master/types, locations, custody and history. |
| Staff Master | Staff master, roles, COVER capabilities, roster context and administrator-only Accounts & Access. |

Customer Service is **not implemented yet**. The owner has defined its expected scope: customer complaints, trace back to likely production/table/scanner, directed resolution tasks, metrics, and quality alerts visible in Sorting/MOP/Finish/Distribution. Revisit this only after the owner requests it again.

## 5. Identity, Accounts and Terminals

There are three different identities:

1. **Staff Master**: operational people used in roster, attendance and production attribution. It does not imply a system login.
2. **System user**: a person with an individual login and assigned access. A Staff Master link is optional.
3. **Production terminal account**: a shared account bound to a physical station/computer. It has no required Staff Master link and is not a person.

Administrators manage accounts through **Staff Master -> Accounts & Access**. They can create, edit, disable and reset passwords for active system/terminal accounts, inspect roles, terminal binding and module access. Existing passwords cannot be read back; the recovery workflow sets and confirms a new password.

Finish terminals are tied to their own Table. Sorting terminals are tied to Sorting and can access MOP Production as configured. Production staff attribution comes from Roster/Actual records, not from the terminal login and not from a PIN.

## 6. Finish Operational Contract

Finish is under active refinement and has the following implemented behaviour:

- Each terminal is restricted to its assigned Table when applicable.
- The terminal shows the customer schedule read-only and can view the shared Tracker.
- A future customer is acceptable when delivery is today or later; a past delivery customer is blocked except for the governed late/reconciliation path.
- Medium trolley requirements accept an unreserved Medium or Large trolley; other type rules remain exact.
- Finish staff uses the Roster as a pre-fill, then records Actual staffing. Manual staff confirmation proposes the Ireland-local current time and requires explicit confirmation.
- Staff Actual supports absence, later arrival, edited break, overtime, early leaving and timed moves between Finish Tables. Eligible `SORTING_AREA` COVER staff can move to Sorting. The maximum recorded daily span is 13 hours.
- Worked time deducts the recorded break. Evening work through the configured 03:00 boundary remains on the originating workday.
- Before saving a staff-time edit, the UI shows the effective time/break/net-work preview and requests confirmation.
- Customer production keeps raw KG and Units. Roster Settings controls the Units-to-KG conversion, currently 6 Units = 1 KG. Table metrics and Results use the equivalent KG while retaining raw quantities.
- Each Table/Shift has a separate audited ReWash ledger. ReWash is visible in Results and never confused with delivery reconciliation.
- Washed Clothes due by delivery-day midday without Finish evidence trigger a blocking reconciliation decision. A processed confirmation requires only a positive quantity in KG or Units and stays outside production metrics. `NOT_PROCESSED` re-prompts after two hours; a later real Finish record is the only path into production metrics.
- The Finish queue shows the current complete day and controlled delayed/advanced continuation days, with receipt/wash/Finish state, scheduled day/date, route and customer colour.

## 7. Sorting and MOP Staffing Contract

Sorting Staff intentionally matches the Finish staff layout and editing model as closely as possible. It records Actual Position (`MOP` or `Clothes`), time, break, worked time and status.

- `No Work` and `Move` must stay operationally limited. Sorting whole-shift Move offers only Finish Table 1, 2 or 3.
- Timed staff moves preserve worked time against the correct origin/destination area.
- Only an active Staff Master `SORTING_AREA` COVER capability permits the relevant Finish-to-Sorting cover move.
- MOP Type Management is visible read-only to the registered Sorting terminal. Create/edit remains restricted to ADMIN or MANAGER.

## 8. Production Tracker Contract

`get_production_tracker_v4(date)` is the shared production read model. It consolidates schedule, washing, MOP, Finish, ABS and trolley evidence. It must not infer completed work from washing estimates.

Two views are available in Production Tracker:

- **Route board**: detailed route blocks, washed estimate versus processed actual, ABS and trolley capacity/evidence.
- **Operational list**: fast route-coloured scan by priority, showing status, production/washing quantity, batch and trolley codes.

The list shows every `production_flow_item` for the selected date, including Clothes and MOP when the schedule contains both. A date with only Clothes scheduled correctly shows only Clothes.

Finish batch references are returned from active `finish_production_lines` by migration `202609090032_tracker_finish_batch_references.sql`. MOP continues to show its existing batch/external evidence when present.

## 9. Recent Applied Migrations

The latest source migrations are:

```text
202609090024_staff_primary_role_current_roster_choice.sql
202609090025_staff_primary_role_stale_draft_repair.sql
202609090026_staff_primary_role_future_roster_drafts.sql
202609090027_finish_overdue_reconciliation_backlog.sql
202609090028_finish_reconciliation_exclude_simulated_washes.sql
202609090029_finish_manual_staff_start_time_guard.sql
202609090030_finish_unit_to_kg_conversion.sql
202609090031_finish_staff_metrics_unit_conversion.sql
202609090032_tracker_finish_batch_references.sql
```

These were applied to `fcimmysqifzxoanmpylh` during the current work, with focused validation recorded in the correction register. Re-query the live schema before depending on any migration in a new environment.

## 10. Known Follow-ups and Constraints

Consult the correction register before planning work. High-value follow-ups include:

- complete the Customer Service workspace only when restarted by the owner;
- resolve or formally accept remaining Supabase security-advisor findings;
- finish role/action authorization tests across all modules;
- preserve evidence that simulated operational records have been removed;
- add broader browser acceptance coverage for critical operational workflows;
- keep advanced terminal actions constrained until their terminal checks are explicitly implemented and tested.

Do not remove historical migrations, generated legacy references or audit evidence merely because they look old. Remove only temporary artifacts whose lack of use has been verified.

## 11. Graphify

The checked-in `graphify-out/` report was generated on 2026-08-26 and is useful as a relationship map, but is stale after the recent Finish/Tracker changes. A refresh was attempted on 2026-09-10 and Graphify returned Windows `Access denied` during AST extraction. Re-run `graphify update .` after releasing any process that holds the generated output or source file lock. Do not treat its older report date as the current architecture authority; this INIT, the current source and the correction register win.

## 12. Future AI Startup Checklist

1. Read this INIT, `README.md`, the architecture overview and correction register.
2. Inspect current source before proposing a change. Do not assume historical screenshots or old INITs represent current behaviour.
3. Preserve shared navigation and shell conventions; use one consistent internal-tab/submenu pattern.
4. For database work, read Supabase guidance, query read-only state first and apply a migration only with owner approval.
5. Add targeted validation for every protected cross-area change.
6. Keep updates to the owner in Portuguese and code/UI text in English.
7. Record material new behaviour or unresolved risk in the correction register and refresh this INIT at the next handover.

## 13. Authority Statement

This `INIT v87` is the project handover authority as of 2026-09-10. The active source folder, latest applied migration state and correction register override older INIT files, ZIP-only baselines and historic screenshots.
