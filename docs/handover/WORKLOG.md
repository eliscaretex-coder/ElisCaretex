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
- Database: `202610190004_driver_reinstate_keeps_scheduled_status.sql` **Prepared, not
  applied**. Until it is applied, Cancel exit works but sets the driver ACTIVE/AVAILABLE.
- Validation: `node scripts/validate-repository.mjs` passed. Hook tested with a committed
  migration (blocked) and a new staged one (allowed). Migration and UI not run live.
- Open / next: apply `202610190004` and run its test file. Schema drift: live
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
