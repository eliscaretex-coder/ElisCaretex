# ElisCaretex V2 - Platform Review and UI System

> Historical review from 2026-08-18. For the current architecture, access model and delivery baseline, use `overview.md` and `../handover/ElisCaretex_V2_PROJECT_INIT_2026-09-10_v87_CURRENT.md`.

## Decision

ElisCaretex should evolve as one governed operational platform, not as a collection of independently styled tools. The application must keep the current model in which the database owns authorization and operational rules, while the browser presents one consistent workspace.

The shared UI foundation is `frontend/assets/css/enterprise-ui.css`. It is loaded after each module stylesheet so it can own common presentation without changing RPC calls, page IDs, data attributes, or business event handlers.

## What is already strong

- Supabase Auth is connected to an active staff record and effective roles.
- Navigation is already role-aware in `app-shell-policy.js` and `operational-page-nav.js`.
- Operational workflows are largely represented as database RPCs, not browser-only writes.
- Planned, actual, published, corrected, and history concepts already exist in key operations.
- RLS appears throughout the migration history and no `auth.role()` use was found in the static migration review.

## Principal risks before company-wide rollout

1. The UI has no enforced component system. Fourteen distinct CSS files make independent choices for hierarchy, radius, spacing, colors, shadows, tab behavior, and control density. Several files are very large, particularly Sorting, Customers, and Roster.
2. The project contains more than 300 public SQL functions and extensive `SECURITY DEFINER` use. This is appropriate only when every function has an explicit caller authorization check, a controlled `search_path`, and narrowly scoped `EXECUTE` grants. It needs a live database audit before expanding access.
3. The browser hides modules by role, but hiding navigation is not authorization. Each read and write RPC must remain responsible for permission checks. The current direction is good, but it must be made auditable as the role matrix grows.
4. Documentation is distributed across many snapshots and migration notes. The project README refers to an older baseline than the supplied current project-init document. A single canonical architecture and release note is required.
5. Validation coverage is broad but uneven. Distribution actuals/history migration `202608170001_distribution_actuals_history.sql` has no matching validation SQL file in the repository snapshot.
6. Compatibility fallbacks are still present in frontend workflows, including Sorting V4 to V3 fallback. These conceal incomplete migrations and should have retirement dates.

## Required operating model

### Roles and permissions

Use a permission catalogue rather than adding page-specific role checks. Every protected action should have a stable permission key, for example:

- `customers.read`, `customers.manage`
- `distribution.plan`, `distribution.dispatch`, `distribution.correct`
- `production.record`, `production.correct`
- `roster.publish`, `roster.view`
- `staff.manage`, `audit.view`

Roles should only bundle permission keys. The database should evaluate the permission key for every RPC; the frontend should use the same catalogue only to decide what to display.

### Product layout

All operational pages use the same hierarchy:

1. Global sidebar: product navigation, current user, sign out.
2. Page header: module name and the small number of immediate actions.
3. Context bar: date, location, shift, route, or selected customer where applicable.
4. Work surface: one primary table, board, or form per view.
5. Side effects: confirmations, errors, and history use standard dialogs and status messages.

Avoid coloured hero sections, decorative gradients, nested cards, and independently invented buttons. Colour has semantic meaning: teal for primary action, blue for information, green for success, amber for warnings, and red for destructive or corrective actions.

### Engineering rules for new modules

- Load `global.css`, `app-shell.css`, module CSS, then `enterprise-ui.css`.
- Keep module CSS for layout and domain states only. Shared components belong in `enterprise-ui.css`.
- Build new data access through named RPCs and add a validation SQL file in the same change.
- Do not release a new `SECURITY DEFINER` function until `PUBLIC` execute access, function search path, caller authorization, and RLS behavior are reviewed.
- Record a migration's corresponding validation test in the release checklist.

## Rollout sequence

1. Validate the shared UI foundation with managers and operational users in Customers, Distribution, Production Tracker, and Sorting.
2. Replace module-local repeated control styles with shared component classes in small, testable changes.
3. Create a permission catalogue and a database query that reports role-to-permission coverage and direct function grants.
4. Run Supabase security and performance advisors against the connected project, then remediate findings before wider onboarding.
5. Publish a single architecture baseline and archive old snapshot notes outside the project root.
