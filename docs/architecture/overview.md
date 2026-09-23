# Laundry Platform V2 Architecture Overview

> **Canonical architecture summary** - updated 2026-09-10 from the current source. The checked-in Graphify report is dated 2026-08-26 and awaits regeneration after a local Windows access-denied failure.
> Detailed delivery risks and unfinished work remain in `PLATFORM_CORRECTION_REGISTER_20260818.md`.

## Platform shape

```text
Browser
  |
  +-- Static operational frontend (Cloudflare Pages)
  |     |
  |     +-- shared shell, navigation and role-aware visibility
  |     +-- Customer, Distribution, Roster, Sorting, MOP, Finish,
  |         Finish Results, Tracker, Trolleys and Staff workspaces
  |
  +-- Supabase JavaScript client
          |
          +-- Supabase Auth
          +-- controlled PostgreSQL RPCs, views and constraints
          +-- Edge Functions where an integration is required
          +-- audit/history and governed correction flows
```

The browser is an operational interface. It may decide which workspace or control is visible, but it does not own authorization or critical operational validation. PostgreSQL functions and policies remain the source of truth for protected reads and writes.

## Application shell and workspaces

`frontend/assets/js/app-shell-policy.js` is the navigation registry. It defines each sidebar workspace, its stable navigation permission and the roles that may see it. `operational-page-nav.js` keeps internal tabs consistent within each workspace.

| Area | Primary responsibility |
| --- | --- |
| Customer Workspace | Customer master data and versioned weekly schedules. Schedule-only users receive a read-only customer view. |
| Distribution | Daily board, weekly route schedule, route customers in delivery order, drivers, fleet, routes, actuals and history. |
| Production Roster | Planned operational staffing, published roster history and governed operational targets, including Finish Units-to-KG conversion. |
| Sorting / Washing | Trolley intake, washing preparation, Sorting actual work and controlled Finish cover transfer. |
| MOP Production | Standalone MOP workflow with its own scoped access; a MOP operator does not gain broad Sorting access. |
| Finish | Table- and shift-based Finish production, ReWash, delivery reconciliation and staff attribution supplied by the Roster/Actual workflow. |
| Finish Results | Daily Finish performance, ReWash and Units-to-KG equivalent result rows. |
| Production Tracker | Cross-area, route-centric production trace with detailed Route board and compact Operational list views. |
| Trolleys | Trolley master, location, custody and movement history. |
| Staff Master | Operational staff records, roster context, and administrator-only Accounts & Access management. |

Each workspace can contain internal views, but related views remain grouped rather than becoming duplicate sidebar entries.

## Identity and access model

Supabase Auth proves that an account is signed in. Application access is derived from the account's roles and direct grants, exposed to the frontend through controlled access functions such as `get_current_account_access()`.

There are three separate identity concepts:

1. **Staff Master** represents operational people used by the roster and production attribution. It does not automatically grant a system login.
2. **System user** represents a person who signs in to administer or use permitted workspaces. A Staff Master link is optional.
3. **Production terminal** represents a fixed shared computer, such as a Finish table or a Sorting station. It has a low-privilege terminal account and is bound to a registered production station/device. A Staff Master link is not required. Staff do not individually sign in or use a PIN on that computer; their attribution comes from the published Roster or Actual selection.

Administrators manage active accounts, account type, terminal binding, direct roles and workspace visibility through the Accounts & Access view. The navigation registry improves usability, but every RPC must enforce the corresponding access server-side.

## Operational data model

The platform is built around shared operational facts rather than copied data between separate applications:

- Customer schedules and route planning provide the planned work.
- The published roster provides the planned operational staffing context.
- Production Flow provides shared production identity and event history.
- Sorting, Washing, MOP and Finish record area-specific activity through governed workflows.
- Trolley identity, custody and location remain shared across those flows.
- Distribution receives scheduled route/customer work and records delivery execution, drivers, fleet and history.
- Production Tracker reads the shared operational picture rather than owning a second set of production facts.
- Corrections, cancellations, reports and audit data remain traceable; planned, actual, reported and corrected facts are not silently merged.

## Backend boundaries

The `supabase/migrations` directory is the database change history. It defines tables, constraints, row-level protections, views and RPCs. Frontend modules call RPCs through the Supabase client rather than writing protected operational tables directly.

Notable current access boundaries include:

- account roles and account identity separation;
- administrator-only account-access directory and maintenance actions;
- terminal/device context for shared production computers;
- terminal-checked Finish production writes, corrections and table scope;
- scoped MOP access; and
- role-aware Customer and Production Tracker reads.

Supabase Edge Functions are used only when an external service or server-side integration is required. They are not a substitute for PostgreSQL authorization.

## Architecture rules

1. One shared platform: do not duplicate business rules across pages or separate tools.
2. PostgreSQL owns authorization, validation, immutable publication and operational consistency.
3. Browser navigation is a usability layer, never the security boundary.
4. Keep planned, actual, reported and corrected facts distinct and auditable.
5. A roster assignment or operational cover role does not itself grant application permissions.
6. Shared production computers are fixed terminals; personal administrator accounts must not become production terminals.
7. Remove simulated operational data rather than presenting it as live work.
8. New workspaces and protected actions must add matching server-side authorization and targeted validation.

## Graphify reference

The checked-in code graph was generated on 2026-08-26 and contains frontend and Supabase SQL migration relationships from that point in time. It is stored in `graphify-out/`:

- `graph.html` is the interactive visual map.
- `GRAPH_REPORT.md` is the generated technical report.
- `graph.json` is queried by Graphify before cross-module changes.

Refresh it after meaningful changes with Graphify's update command. A 2026-09-10 refresh attempt failed with a local Windows access-denied error, so use the current source and `docs/handover/ElisCaretex_V2_PROJECT_INIT_2026-09-10_v87_CURRENT.md` until it is regenerated. Treat the graph as a map of source relationships; this document remains the concise operational interpretation and the correction register remains the backlog of known risks.
