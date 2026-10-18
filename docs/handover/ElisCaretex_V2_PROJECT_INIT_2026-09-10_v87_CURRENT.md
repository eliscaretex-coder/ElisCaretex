# ElisCaretex V2 - Authoritative AI Project INIT v91

**Handover date:** 2026-10-18

**Purpose:** authoritative AI-to-AI continuation guide for the ElisCaretex V2 laundry operations platform.

**Repository state reviewed through:** commit `296e117` (merged coordination PR #1).
This documentation refresh follows that source baseline.
**Supersedes:** INIT v90 and every older INIT/handover snapshot.

The filename is retained for compatibility with existing links. The content is
v91 and current as of 2026-10-18.

## 1. Read this first

This is a live operational platform, not a UI prototype. Before changing anything, inspect the current source and query the current database state. Preserve the distinction between planned, actual, reported, corrected, approximate, and official facts.

Current Supabase development project:

```text
name: ElisCaretex-dev
project ref: fcimmysqifzxoanmpylh
region: eu-west-1
database access and advisors verified 2026-10-17: available
PostgreSQL: 17.6.1.147
```

Use evidence terms accurately:

- **Applied:** execution was confirmed against the development Supabase project.
- **Validated:** a focused syntax, SQL, permission, or browser check passed.
- **Owner confirmed:** the owner tested the behaviour in the browser.
- **Prepared:** source exists but deployment or operational proof is not confirmed.

Code, database objects, filenames, and UI text stay in English. Conversation with the owner is normally in Portuguese.

## 2. Authoritative source and deployment

Current Codex working repository:

```text
C:/Users/bress/Documents/Codex/2026-10-18/clone-o-reposit-rio-https-github/ElisCaretex
branch: master
remote: https://github.com/eliscaretex-coder/ElisCaretex.git
```

Codex now works on this new computer. This repository was cloned on 2026-10-18;
the path above replaces the previous computer's Codex working path. GitHub
`master` is the source of truth. Do not recreate the deleted `main` branch.
Claude also works here through `claude/*` Pull Requests into `master`.

Owner's OneDrive working copy (previous computer; availability here not verified):

```text
C:/Users/paulob/OneDrive - ELIS/Documents/Paulo/laundry-platform-v2-foundation/laundry-platform-v2
```

GitHub Pages:

```text
https://eliscaretex-coder.github.io/ElisCaretex/
```

Local development normally serves `frontend/`, for example:

```text
http://127.0.0.1:5500/frontend/index.html
```

The workflow `.github/workflows/pages.yml` validates all frontend JavaScript and pinned Supabase browser imports before deploying the `frontend` directory from `master`.

Before work:

```text
git fetch origin
git status
git pull origin master
git log --oneline -15
```

Do not discard a dirty working tree. Existing changes may belong to the owner.
Local copies can diverge; GitHub `master` remains authoritative. Check open Claude
PRs and `claude/*` branches before editing; tell the owner about overlapping files.

Required reading: `AGENTS.md`, then open items and latest entries in
`docs/handover/WORKLOG.md`, this INIT in full and
`docs/handover/REVIEW_2026-10-16.md`. Read the import guide before import work.
After every task add a WORKLOG entry, including every migration applied to
`ElisCaretex-dev` (or none), validation and unfinished work. Follow AGENTS.md for
all subsequent tasks.

Useful first reads:

```text
README.md
docs/README.md
docs/architecture/overview.md
docs/NAVIGATION-ACCESS-MODEL.md
docs/database/APPS_SCRIPT_DATA_IMPORT_GUIDE.md
docs/operations/PRODUCTION_TERMINAL_ROLLOUT.md
supabase/migrations/
```

## 3. Architecture and security model

```text
Static operational frontend
  -> Supabase Auth
  -> PostgreSQL RLS, constraints, controlled RPCs and Edge Functions
  -> append-only/versioned operational evidence and audit history
```

The frontend is not a security boundary. PostgreSQL and server-side functions own authorization and critical validation.

Core rules:

1. Never silently rewrite published schedules, rosters, approvals, or production history.
2. Correct evidence through versioning, replacement, cancellation, or append-only events.
3. Do not expose a `service_role`/secret key in frontend code.
4. A `SECURITY DEFINER` RPC must revoke default `PUBLIC` access and perform an internal identity/permission check.
5. Production terminals are fixed computers; staff attribution comes from Roster/Actual data, not the terminal account.
6. Never present simulation or test activity as real production.
7. Do not infer official production from Sorting estimates.
8. New UI permissions require matching database authorization and negative tests.

`frontend/assets/js/config.js` contains only the Supabase project URL and browser-safe publishable/anon configuration. Never commit SMTP passwords, service-role keys, personal passwords, or private credentials.

## 4. Current workspaces

| Workspace | Current responsibility/status |
| --- | --- |
| Home | Role-aware cards, notification attention badge, personal/management entry points. |
| Customer Workspace | Customer master, versioned weekly planner, product services, routes, trolley requirements and history. |
| Production Roster | Weekly roster planning, publication, staff view, leave/day-off requests, approvals and capacity calendar. |
| My Roster | Personal published roster for linked staff; administrators and production management can inspect published staff rosters. |
| Sorting / Washing | Intake, washers, approximate load KG, staff actuals, no-work and governed area moves. |
| MOP Production | Official MOP production, types, corrections, ABS and reconciliation. It appears under Sorting in navigation, not as a duplicate root item. |
| Finish Production | Table 1/2/3 production, official Clothes KG, Units, batches, trolleys, ReWash, staff actuals and delivery reconciliation. |
| Finish Results | Daily/table/shift performance including unit-to-KG equivalent and ReWash visibility. |
| Production Tracker | Shared route/customer production trace covering washing, MOP, Finish, ABS and trolley evidence. |
| Production Intelligence | Manager analytics for official production, capacity, seasonality, Sorting/trolley flow and forward planning. |
| Distribution | Daily planning, routes/stops, weekly roster publication and printing, driver/fleet master, actuals, driver leave calendar/review and readable history. |
| My Driver Roster | `frontend/pages/driver-roster.html`: published weekly assignments, route stops/customer guides and Holiday/Day Off requests; management can inspect the full published week. |
| Customer Guides | `frontend/pages/driver-guides.html`: management of customer photos/PDFs and pending driver leave decisions; assigned drivers view private guides through published routes. |
| Trolleys | Trolley type/master, physical trolleys, lifecycle, locations and custody history. |
| Staff Master | Staff directory, operational roles, cover capability, onboarding and Accounts & Access. |
| Notifications | Staff inbox plus manager/supervisor notice creation, delivery, read and acknowledgement tracking. |
| Privacy | Employee privacy notice and acknowledgement entry point. |

Customer Service complaints/quality workflow is still not implemented. The expected future scope includes complaints, trace-back to production/table/scanner, assigned actions, resolution status, metrics, and cross-area quality alerts. Do not invent this module without renewed owner direction and the owner's existing form definition.

### Distribution continuation, 2026-10-17

Commits `1f69f2e` through `acfca47` delivered:

- Distribution roster publication: `publish_distribution_roster_week` calls
  `require_distribution_plan_access`, checks row versions and validates the roster.
  Only `PLANNED` entries create route runs and require route, primary driver and
  vehicle. Training, Holiday, Absent and Sick entries do not create runs; existing
  operational runs remain protected. Weekly layouts and print output were refined.
- My Driver Roster: `get_my_driver_roster`, `get_my_driver_route` and
  `submit_my_driver_leave_request` serve published assignments, route stops and
  personal leave requests. `current_distribution_driver_id` resolves an authenticated
  account through an active Staff link and active Distribution driver. Drivers see
  their own assignments; management sees the full published week. Mobile layouts,
  current/next-week switching, search and photo/PDF viewing are implemented.
- Customer Guides: `get_driver_guide_admin`, `save_driver_guide`,
  `update_driver_guide`, `set_driver_guide_active` and `delete_driver_guide` require
  `can_manage_driver_guides`: authenticated identity plus
  `has_account_permission('DISTRIBUTION','MANAGE',null)`. Metadata has RLS enabled
  and direct public/anon/authenticated access revoked. The private
  `customer-driver-guides` bucket accepts JPG/PNG/WebP/PDF up to 15 MB. Four Storage
  policies guard reads/writes: writes require management; reads require an active
  guide and `can_view_driver_guide_object` / `can_view_driver_guide_customer`.
  These allow management or the primary/support driver of a published assignment
  with a matching route-run customer stop. Viewers request 300-second signed URLs.
- `MY_DRIVER_ROSTER` permission templates cover Driver (OWN), Logistics Manager
  (DISTRIBUTION), General Manager and Administrator (ALL). Migration `202610170004`
  grants matching existing accounts access. These navigation permissions do not
  replace the RPC identity/management guards above.
- Driver leave: `get_driver_leave_requests_admin` and `review_driver_leave_request`
  support decisions. The calendar uses `get_distribution_driver_leave_calendar`,
  `save_distribution_driver_leave_admin` and `delete_distribution_driver_leave_admin`.
  All require management access. Pending/approved overlaps and published-roster
  conflicts are checked; changes do not silently rewrite published rosters.
- Driver identity: `get_distribution_driver_master` uses
  `require_distribution_read_access`; `save_distribution_driver` uses
  `require_distribution_master_access`. Database-generated `DRV-xxx` codes use an
  advisory lock and are preserved on edits. Licence categories are recorded.
- Readable history: `get_distribution_activity_history` uses
  `require_distribution_read_access`, with actor names and event summaries.
  The trigger `record_customer_driver_guide_event` appends guide creation, update,
  file replacement, activation/deactivation and deletion to Distribution master
  events; direct trigger-function execution is revoked from all application roles.
  The callable RPCs revoke PUBLIC/anonymous execution and use authenticated grants
  with internal guards. Existing read/plan/master guards require active authenticated
  Staff identity and their allowed operational roles.

Evidence carried forward from the 2026-10-18 WORKLOG review:

- **Applied:** all 11 migrations `202610170002` through `202610170012` were found
  in live migration history by Claude, with spot checks of objects including
  `customer_driver_guides` and `get_my_driver_roster`. No migration was applied or
  live database state rechecked during this documentation refresh.
- **Validated:** original pushes passed Pages validation, as recorded in WORKLOG;
  local repository validation was rerun for this refresh. This proves syntax and
  dependency-pin checks, not operational acceptance.
- **Prepared:** SQL checks exist in
  `supabase/tests/202610170002_fix_distribution_roster_nonworking_publication_validation.sql`
  (DO-block definition/grant checks) and
  `supabase/tests/202610170003_my_driver_roster_and_customer_guides_validation.sql`
  (10 transactional pgTAP checks). Execution is not recorded and they were not run
  in this refresh. They do not prove full action-level authorization coverage.
- **Owner confirmed:** not recorded for this continuation. Browser acceptance,
  focused negative permission tests and owner operational acceptance remain pending.

## 5. Shared UI contract

The application received a cross-page visual refresh based on the owner's Finish reference application:

- teal compact page headers and stronger contrast;
- reduced vertical waste for small notebook screens;
- consistent white cards, borders, typography, controls, status chips and tables;
- duplicate page headings removed;
- the existing customer list/side panel pattern retained where it was better;
- the left sidebar remains compact and opens only while the pointer is inside it;
- clicking navigation must not close/flicker the sidebar while the pointer remains inside;
- page navigation no longer rebuilds the full sidebar, avoiding the previous blackout effect;
- MOP Production exists only inside the Sorting submenu;
- Finish top-right shift/table controls have corrected readable colours.

Preserve this shared shell. Do not introduce a page-specific visual system unless there is a strong operational reason.

Operational master data may be incomplete during rollout. Missing staff defaults,
driver compliance dates and fleet details must be shown as visible warnings in the
relevant screens. They are not hard requirements for saving unrelated operational
work unless a specific workflow rule explicitly requires the value.

## 6. Identity model, jobs, accounts and permissions

Keep these identities separate:

1. **Staff Master record:** operational person used for roster, leave, attendance and production attribution.
2. **Personal system account:** individual Supabase Auth login, optionally linked to one active Staff Master record.
3. **Production terminal account:** fixed shared device/account bound to a station/table; not a person and normally not linked to Staff Master.

Current job-title hierarchy/templates include Administrator, IT Manager, General Manager, Production Manager, Logistics Manager, Maintenance, Production Supervisor, Team Leader, General Operative, Label, Cleaner, Auditor and Customer Service. Team Leader currently has the same operational authority baseline as General Operative unless an explicit grant changes it.

Permissions are flexible per account/module and support:

```text
VIEW
CREATE
EDIT
APPROVE
MANAGE
```

Job title selects relevant defaults, but administrators can adapt grants for real operational changes. General Operatives must not receive approval permissions merely because a generic permission exists.

Accounts & Access now supports:

- cleaner account directory layout;
- create and edit for personal and terminal accounts;
- job title and login method;
- module permissions derived from job-title templates and adjustable grants;
- staff linking;
- disable/delete/reset/invite/resend actions as applicable;
- pending password/account-setup visibility;
- scoped administrator actions enforced server-side.

Staff onboarding now creates the Staff Master record first and automatically generates the next unique `EMP-xxxxx` employee code. Manual employee-code entry is not allowed. If an email is supplied and access is requested, the system sends an invitation so the employee creates their own password. The administrator must not choose the employee's password.

Personal email is acceptable for login only through the consent/onboarding process. A staff record can be created without email and linked/changed later. Login access, Staff Master, permissions and privacy acknowledgement are separate records.

Current Supabase email/redirect behaviour:

- GitHub Pages URLs must be allowed in Supabase Auth Site URL/Redirect URLs;
- local redirect URLs are only for local testing;
- owner confirmed custom Gmail SMTP works as of 2026-09-26;
- branded invite/reset templates exist in project source/guidance, but Supabase templates require custom SMTP to edit;
- never hard-code localhost as the production invitation redirect.

Staff deactivation must remove access. Immediate deactivation disables access; planned leaving dates support scheduled deactivation logic. Re-check session revocation/expiry for strict offboarding because deleting/disabling a record alone does not retroactively invalidate every already-issued JWT.

## 7. Staff and Distribution transfer

The Staff Master interface is intentionally clean:

- Transfer to Driver is inside Edit, not a separate row action;
- internal labels such as `LEG` and `Legacy` are hidden from end users;
- transferred staff no longer remain in active Production Staff lists unless explicitly scoped for Production;
- transfer uses an atomic database operation and must collect/validate driver-specific information;
- an existing driver match must be handled without creating a duplicate.

## 8. Roster, My Roster and leave governance

Implemented behaviour:

- linked employees can view their published roster in My Roster;
- ADM, Production Manager and Supervisor can inspect published rosters to verify planning results;
- My Roster has navigation back to the application;
- employees can request Holiday or Day Off from the staff-facing workflow;
- leave requests appear as notifications and inside the Roster `Leave request control centre`;
- approved/pending requests appear in the planning context so roster planners see conflicts;
- a leave-capacity calendar summarizes pending and approved absence across weeks/months;
- supervisor and Production Manager can approve alternatively;
- requests longer than the configured threshold require General Manager approval and then return to the production approval chain;
- the threshold is configurable in Roster Settings / Leave Approval;
- Team Leader follows General Operative leave authority, not supervisor authority.

Do not bypass the event/review history when importing or correcting leave decisions.

## 9. Notices and notifications

The internal notice system supports:

- targeted Information, Action Required and Training notices;
- optional acknowledgement requirement;
- manager/supervisor creation flow hidden until explicitly opened;
- recipient read/acknowledgement status visible to authorized senders;
- home-page attention indicator;
- clear unread/read/action state in Notifications;
- configurable visibility period/automatic expiry;
- recipient dismissal/hide to reduce clutter;
- sender cleanup of old sent notices;
- leave-request notifications link directly to the Roster control centre.

Avoid permanent unfiltered notification lists. New notification types need a lifecycle, audience, attention rule, expiry/archive behaviour and destination action.

## 10. Finish operational contract

- Finish official Clothes weight is recorded by Table 1/2/3 and shift.
- Terminals remain restricted to their assigned Table when applicable.
- Customer queue uses schedule/flow/trolley evidence and controlled continuation dates.
- Staff actuals support attendance, absence, later arrival, break edits, overtime, early leave and timed table/Sorting moves.
- `SORTING_AREA` cover requires an active capability.
- Evening work crossing the configured 03:00 boundary remains on the originating business date.
- Production lines retain raw `KG` or `UNIT`; Units-to-KG conversion is configurable, initially 6 Units = 1 KG.
- ReWash is a separate audited ledger, visible in Results and not confused with delivery reconciliation.
- Corrections are append-only/superseding, not destructive edits.
- Delivery reconciliation does not enter production metrics unless a real Finish record is later created.

Official Clothes KG for analytics comes only from active Finish production `KG` lines.

## 11. Sorting, MOP and trolley contract

Sorting wash weight is operational and approximate. It must never be treated as official produced KG.

MOP Production is separate and its recorded physical weight is official MOP KG. Late/missed entries use reconciliation paths rather than being disguised as current live entries.

Trolley UI improvements include:

- obsolete `Scan a trolley` screen removed;
- Trolley Master summarizes quantities by trolley size/type;
- cleaner Trolley Master layout;
- Physical Trolley create/edit forms are closed until requested;
- registry/service fields are not permanently exposed;
- trolley lifecycle and custody remain governed operational evidence.

## 12. Production Intelligence

Production Intelligence is implemented for authorized management accounts through:

```text
frontend/pages/production-insights.html
frontend/assets/js/production-insights.js
frontend/assets/css/production-insights.css
```

Canonical official view:

```text
public.production_official_actuals
```

It combines only:

- Clothes: active `finish_production_entries` with `finish_production_lines.unit_code='KG'`;
- MOP: recorded `sorting_mop_production_batches.total_weight_kg`, dated by physical processing date.

Sorting/washing estimates are deliberately excluded from official KG.

Implemented manager views:

- official total, Finish, MOP, production-day and customer KPIs;
- weekly official history and learned customer forecast;
- daily production with recorded Finish attendance/capacity;
- shift and workstation breakdown;
- Sorting intakes, washer runs, approximate KG and exceptions kept visually separate;
- trolley received/sent flow;
- monthly Finish/MOP history;
- customer share, weekly range, variation and learning readiness;
- six-week forward demand versus published Finish roster capacity;
- separate MOP demand, never counted as Finish capacity load;
- states `LEARNING`, `ROSTER_NOT_PUBLISHED`, `COVERED`, `WATCH`, and `AT_RISK`.

Expected KG and forward-capacity learning use the latest three official records
for the same customer, product and production weekday. Fewer than three matching
days remain `LEARNING`; the UI must not report false surplus/shortage. Sorting
and Washing estimates never enter this calculation.

Customer Schedule shows the three source dates and values beside Expected KG.
The `Use` action only updates the editable draft and never silently overwrites
or publishes an approved plan. Production Intelligence provides a `History`
action for each customer, with the official Finish/MOP timeline and independent
Monday-to-Saturday averages by product.

Historical production is present in the development database and drives these
views, but its Apps Script reconciliation is deliberately postponed. Treat
management totals as provisional until source-versus-target counts and KG have
been formally reconciled and accepted by the owner.

Read-only snapshot verified on 2026-10-17:

```text
Finish: 13,201 records, 123 customers, 2026-01-06 to 2026-09-26, 823,581.96 kg
MOP:     1,446 records,  50 customers, 2026-07-13 to 2026-09-26,  49,574.02 kg
Ready customer/product/weekday groups with >=3 official days: 676
```

These figures are validation evidence, not a permanent business baseline.

Applied Production Intelligence migrations:

```text
202609260001_production_intelligence_foundation.sql
202609260002_production_intelligence_operational_breakdown.sql
202609260003_production_intelligence_sorting_trolleys.sql
202609260004_production_intelligence_customer_seasonality.sql
202609260005_production_intelligence_forward_capacity.sql
202610170001_customer_kg_history_and_weekday_suggestions.sql
```

Live Supabase migration history also contains two refinement entries:

```text
production_intelligence_forward_capacity_compact_learning
production_intelligence_forward_capacity_final_states
```

Their final function definition is consolidated in local migration `202609260005_production_intelligence_forward_capacity.sql`. Do not reintroduce the earlier uncompact payload or zero-as-missing capacity behaviour.

## 13. Historical Apps Script data import

The owner has thousands of historical Apps Script records to import after source conversion. The complete contract is:

```text
docs/database/APPS_SCRIPT_DATA_IMPORT_GUIDE.md
```

This guide is mandatory reading. Key rules:

- land raw source in restricted `staging` first;
- retain source files, row IDs, legacy IDs, raw JSON, batch ID and deterministic fingerprint;
- map identities explicitly; never guess UUIDs from names;
- use idempotent transactional promotion;
- do not create Auth accounts while importing historical staff;
- reconcile counts and totals before commit;
- official Clothes/MOP KG rules above are non-negotiable;
- ambiguous records remain blocked for owner review.

Existing staging support already covers legacy customers/schedules and roster/leave. Finish, ReWash, MOP, Sorting, trolley and Distribution source formats require source-specific restricted staging tables and reviewed promotion logic after the actual exports are supplied.

## 14. Supabase state and recorded verification through 2026-10-18

Recent live migration groups include:

```text
20260924: staff-to-driver transfer; flexible account permissions; privacy;
            job titles/login methods; scoped account administration;
            Staff Master and leave permission enforcement; My Roster;
            admin/management published roster access; notification inbox.
20260925: unified staff onboarding; internal notices; notice management;
            notification lifecycle/home badge; ambiguous RPC removal;
            personal sent-notice cleanup.
20260926: Production Intelligence foundation, breakdowns, Sorting/trolleys,
            seasonality and forward capacity.
20261015: Distribution Daily Route Board production-load visibility for the
            current and next delivery dates.
20261016: public-view security hardening, internal RPC grant correction and
            immutable function search paths.
20261017: permission-guarded customer KG history and weekday suggestions;
            forward capacity aligned to the same latest-three-weekdays rule.
```

Distribution migrations, **Applied** according to Claude's live-history review
recorded in WORKLOG on 2026-10-18 (not reapplied in this refresh):

```text
202610170002_fix_distribution_roster_nonworking_publication.sql
202610170003_my_driver_roster_and_customer_guides.sql
202610170004_grant_my_driver_roster_to_existing_accounts.sql
202610170005_harden_driver_guide_storage_access.sql
202610170006_driver_leave_review.sql
202610170007_distribution_driver_roster_management_view.sql
202610170008_manage_customer_driver_guide_files.sql
202610170009_distribution_driver_leave_calendar.sql
202610170010_distribution_driver_identity.sql
202610170011_distribution_history_readable.sql
202610170012_customer_guide_history.sql
```

**Migration-history caveat (verified 2026-10-18, AGENTS.md section 5):** live
`supabase_migrations` history starts at `20260811163258` and lists 94 entries,
while the repository holds 179 files from `202607160001`. The 50 files before
2026-08-11 and 41 later files (including
`202608120008_finish_v2_production_foundation.sql`) were applied outside tracked
history; spot checks confirmed their database objects. Four live entries have names
different from matching files. Two live entries,
`production_intelligence_forward_capacity_compact_learning` and
`production_intelligence_forward_capacity_final_states`, are consolidated in
`202609260005_production_intelligence_forward_capacity.sql`. Query current database
objects to determine whether a change is applied; history and filenames alone are
insufficient. Never edit, rename or rerun historical migrations.

Active Edge Functions:

```text
production-roster-leave-email     active, verify_jwt=true, live version 3
admin-account-management          active, verify_jwt=true, live version 14
```

Local source exists in:

```text
supabase/functions/production-roster-leave-email/index.ts
supabase/functions/admin-account-management/index.ts
```

Seven exposed views were changed to `security_invoker` and anonymous view access
was revoked. Internal privileged RPCs no longer inherit anonymous execution from
`PUBLIC`; only the token-protected public roster endpoints retain anonymous access.
The 13 mutable function search-path warnings were cleared. Run Supabase security
advisors after new database work. Remaining platform-level recommendations include
enabling leaked-password protection in Supabase Auth and reviewing the `btree_gist`
extension location. Do not remove legitimate authenticated RPC execution without
understanding its internal guards.

## 15. Recent Git milestones

Key commits from the current continuation:

```text
5741b21  employee privacy notice and UI improvements
9f056cd  flexible account permissions foundation
511af4f  job titles and flexible account login
9284e47  permission-aware navigation
d8f3b32  authenticated employee My Roster
8f8a665  management published roster view
4156979  unified staff onboarding and account invitation
7b97492  account redirect and branded invite template
71671fb  targeted staff notices and acknowledgements
9082ac0  notification attention and lifecycle controls
18f45e2  leave capacity planning calendar
9ed134f  Production Intelligence foundation
0433ac7  official operational breakdowns
f04f0eb  Sorting and trolley intelligence
cdcf7af  customer seasonality intelligence
13b98f7  forward demand/capacity planning
67b0d93  Apps Script data import contract
d486c40  refreshed authoritative handover
f43ac2c  MOP trolley validation and terminal ABS attribution
345f22a  shared Operational List for Sorting Production Tracker
ffcfc08  clearer not-started and active Production Tracker states
6a31913  real production load on the Distribution Daily Route Board
30699db  current and next delivery load comparison
467735a  security hardening, operational warnings and deployment validation
3bf985c  platform review handover refresh
9e31279  terminal notification access and handover update
785ed39  route creation fix and operational acceptance evidence
91570ef  workspace navigation and customer KG planning improvements
9308683  customer KG history and weekday suggestions committed and deployed
1f69f2e  Distribution publication for non-working entries
0d421e0  My Driver Roster and customer delivery guides
1010b62  Driver Roster management and weekly layout
183c193  customer driver guide management
4183915  mobile driver roster and guide viewer
3838bae  Distribution driver leave calendar
6ee169f  Distribution leave labels and roster printing
d244524  Distribution leave labels and roster printing
66a8832  driver codes, licence types and roster printing
e3d3e39  Distribution roster print layout
e7edb07  readable Distribution history
acfca47  Customer Guide actions in Distribution history
eaf8e7a  shared agent rules and WORKLOG
f7c457b  Graphify removal and Codex action items
296e117  merge coordination PR #1 into master
```

Use Git history for detailed file-level evidence.

## 16. Known constraints and open risks

1. Current-day operational activity remains pre-production/test activity. Imported historical production must retain source provenance and be reconciled before it is treated as authoritative management reporting.
2. Historical Finish/MOP records are visible in Production Intelligence and can support provisional planning suggestions, but their source reconciliation and formal owner acceptance remain pending.
3. Forward capacity needs published future Finish rosters; missing publication is shown explicitly.
4. Historical Apps Script source formats still need to be inventoried and converted source by source.
5. Customer Service/complaints remains future work.
6. Read-only browser acceptance passed for ADMIN, Sorting terminal and Finish terminal on desktop and mobile. Destructive/action-level negative testing is still needed across modules.
7. Controlled Clothes and MOP paths passed Intake -> Washing -> Production -> Tracker -> Distribution on 2026-10-16 and their evidence was removed. MOP ABS posting, append-only correction and the live-trolley cancellation guard also passed. Migration `202610160004` preserves terminal staff attribution on corrected MOP/ABS evidence.
8. Supabase leaked-password protection should be enabled.
9. Strict staff offboarding should continue to verify Auth session revocation/expiry, not only database deactivation.
10. Email templates, allowed redirects and SMTP should be rechecked after changing deployment domains.
11. The older correction register predates several 2026-09-24 to 2026-09-26 features. Current source, Git history, live Supabase state and this INIT override stale register entries.
12. Operational-master review on 2026-10-17 found 3 of 39 active Staff records flagged for setup/import review; all 13 active Drivers still lack their Staff link, phone and licence/CPC details; and all 14 active Fleet records still lack KG/trolley capacity and insurance expiry. The application shows these as non-blocking warnings. Values must be completed from authoritative business records, not inferred.
13. Account promotion is separate from the Staff Master operational role. Controlled tests on 2026-10-17 passed for Production Supervisor, Logistics Manager and Customer Service permission templates, plus a General Operative to Supervisor operational-role change with published roster history preserved. The test account and Staff record were restored to General Operative.

## 17. Recommended next work

Priority order:

1. **Complete operational master data gradually.** Use the non-blocking Staff, Driver and Fleet warnings; do not introduce blanket save requirements.
2. **Inventory and reconcile remaining Apps Script exports.** Compare source and target counts/KG by date, customer, shift, table/product and batch.
3. **Complete platform security settings,** especially leaked-password protection, extension placement review and focused authenticated-RPC review.
4. **Publish representative future rosters** and validate six-week demand/capacity after historical reconciliation.
5. **Expand automated browser coverage** for onboarding, invitation, My Roster, leave approval, notices and production entry/correction.
6. **Resume Customer Service/Quality only with owner-provided form and workflow definitions.**

Do not build advanced analytics on unvalidated legacy data. Data provenance and reconciliation come first.

## 18. Future AI startup checklist

1. Read `AGENTS.md`, `docs/handover/WORKLOG.md`, this INIT,
   `docs/handover/REVIEW_2026-10-16.md` and
   `docs/database/APPS_SCRIPT_DATA_IMPORT_GUIDE.md` fully.
2. Run the AGENTS fetch/status/pull/history checklist, confirm the active working
   copy and check open Claude PRs/branches before editing overlapping files.
3. Query the live Supabase schema/migrations before relying on local assumptions.
4. Preserve the shared visual shell and compact notebook-friendly layout.
5. Keep personal accounts, Staff Master records and terminal accounts separate.
6. Keep Production and Distribution visibility isolated according to permission scope.
7. Preserve official versus approximate KG separation.
8. Add server-side authorization and negative tests for every new protected action.
9. Never import historical data directly into operational tables without staging/reconciliation.
10. [x] Closed 2026-10-18: customer KG frontend and migration
    `202610170001_customer_kg_history_and_weekday_suggestions.sql` are on `master`
    in commit `9308683` and deployed, as verified in the WORKLOG action item.
11. Add a WORKLOG entry after every task, including applied migrations and
    validation; update this INIT for material behaviour, security or database changes.

## 19. Authority statement

This INIT v91 is the handover authority as of 2026-10-18. Current source,
current Git history, current live Supabase state, and explicit owner decisions
override older INIT files, ZIP baselines, screenshots, stale generated reports
and historical assumptions.
