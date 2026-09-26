# ElisCaretex V2 - Authoritative AI Project INIT v88

**Handover date:** 2026-09-26

**Purpose:** authoritative AI-to-AI continuation guide for the ElisCaretex V2 laundry operations platform.

**Repository state reviewed through:** commit `67b0d93` plus this INIT update.
**Supersedes:** INIT v87 and every older INIT/handover snapshot.

The filename is retained for compatibility with existing links. The content is v88 and current as of 2026-09-26.

## 1. Read this first

This is a live operational platform, not a UI prototype. Before changing anything, inspect the current source and query the current database state. Preserve the distinction between planned, actual, reported, corrected, approximate, and official facts.

Current Supabase development project:

```text
name: ElisCaretex-dev
project ref: fcimmysqifzxoanmpylh
region: eu-west-1
status verified 2026-09-26: ACTIVE_HEALTHY
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
C:/Users/paulob/Documents/Codex/2026-09-23/le/work/laundry-platform-v2-access
branch: master
remote: https://github.com/eliscaretex-coder/ElisCaretex.git
```

Owner's OneDrive working copy:

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

The workflow `.github/workflows/pages.yml` deploys the `frontend` directory from `master`.

Before work:

```text
git status
git pull origin master
```

Do not discard a dirty working tree. Existing changes may belong to the owner. The OneDrive copy and Codex copy can diverge; confirm which one is authoritative before copying or pulling files.

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
| Distribution | Daily planning, routes/stops, weekly roster, driver/fleet master, actuals and history. |
| Trolleys | Trolley type/master, physical trolleys, lifecycle, locations and custody history. |
| Staff Master | Staff directory, operational roles, cover capability, onboarding and Accounts & Access. |
| Notifications | Staff inbox plus manager/supervisor notice creation, delivery, read and acknowledgement tracking. |
| Privacy | Employee privacy notice and acknowledgement entry point. |

Customer Service complaints/quality workflow is still not implemented. The expected future scope includes complaints, trace-back to production/table/scanner, assigned actions, resolution status, metrics, and cross-area quality alerts. Do not invent this module without renewed owner direction and the owner's existing form definition.

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

Forecast learning uses recent official history and requires at least three records per customer/product. Incomplete days remain `LEARNING`; the UI must not report false surplus/shortage. The current test database does not yet contain trustworthy production history, so learning output is expected until real Apps Script history is imported.

Applied Production Intelligence migrations:

```text
202609260001_production_intelligence_foundation.sql
202609260002_production_intelligence_operational_breakdown.sql
202609260003_production_intelligence_sorting_trolleys.sql
202609260004_production_intelligence_customer_seasonality.sql
202609260005_production_intelligence_forward_capacity.sql
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

## 14. Supabase state verified 2026-09-26

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
```

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

The database has many governed `SECURITY DEFINER` RPCs. Run Supabase security advisors after new database work. An existing recommendation remains to enable leaked-password protection in Supabase Auth. Also review advisor warnings methodically; do not remove legitimate authenticated RPC execution without understanding their internal guards.

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
```

Use Git history for detailed file-level evidence.

## 16. Known constraints and open risks

1. Current operational database data is largely test data and must not be treated as real historical performance.
2. Production Intelligence remains in learning state until real official Finish/MOP history is imported.
3. Forward capacity needs published future Finish rosters; missing publication is shown explicitly.
4. Historical Apps Script source formats still need to be inventoried and converted source by source.
5. Customer Service/complaints remains future work.
6. Full role/action negative testing is still needed across modules.
7. Browser acceptance coverage for critical workflows is incomplete.
8. Supabase leaked-password protection should be enabled.
9. Strict staff offboarding should continue to verify Auth session revocation/expiry, not only database deactivation.
10. Email templates, allowed redirects and SMTP should be rechecked after changing deployment domains.
11. The older correction register predates several 2026-09-24 to 2026-09-26 features. Current source, Git history, live Supabase state and this INIT override stale register entries.

## 17. Recommended next work

Priority order:

1. **Inventory Apps Script exports.** List each file/sheet/object, date range, key, row count and data meaning.
2. **Build the import pipeline one domain at a time.** Start with identity/master mappings, then official Finish/MOP history needed by Production Intelligence.
3. **Reconcile official production.** Compare source and target KG by date, customer, shift, table/product and batch.
4. **Publish representative future rosters** and validate six-week demand/capacity once real history exists.
5. **Run role-based acceptance tests** for ADM, managers, supervisors, General Operatives, terminals and Distribution isolation.
6. **Complete security hardening,** including leaked-password protection and focused RPC/permission review.
7. **Expand manager analytics** only after real-data quality is proven: day/shift/table trends, capacity efficiency, customer seasonality, trolley flow and Distribution performance.
8. **Improve automated browser coverage** for onboarding, invitation, My Roster, leave approval, notices and production entry/correction.
9. Resume Customer Service only with owner-provided form/flow definitions.

Do not build advanced analytics on unvalidated legacy data. Data provenance and reconciliation come first.

## 18. Future AI startup checklist

1. Read this INIT and `docs/database/APPS_SCRIPT_DATA_IMPORT_GUIDE.md` fully.
2. Run `git status`, inspect recent history and confirm the active working copy.
3. Query the live Supabase schema/migrations before relying on local assumptions.
4. Preserve the shared visual shell and compact notebook-friendly layout.
5. Keep personal accounts, Staff Master records and terminal accounts separate.
6. Keep Production and Distribution visibility isolated according to permission scope.
7. Preserve official versus approximate KG separation.
8. Add server-side authorization and negative tests for every new protected action.
9. Never import historical data directly into operational tables without staging/reconciliation.
10. Report material behaviour, migrations, validation and unresolved risks back into this INIT at the next handover.

## 19. Authority statement

This INIT v88 is the handover authority as of 2026-09-26. Current source, current Git history, current live Supabase state, and explicit owner decisions override older INIT files, ZIP baselines, screenshots, stale generated reports and historical assumptions.
