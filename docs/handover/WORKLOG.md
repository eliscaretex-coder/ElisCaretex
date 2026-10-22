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
