# Navigation Access Model

The application has one sidebar entry per workspace. A workspace may contain
several internal views, but those views must not become duplicate sidebar items.

## Workspaces

| Sidebar section | Workspace | Internal views |
| --- | --- | --- |
| Home | Home | Start page with the same workspaces as cards |
| My work | My Production Roster | Published production schedule and leave requests |
| My work | My Driver Roster | Routes, customers and leave requests |
| My work | Notifications | Inbox and sent notices (attention count shown as a badge) |
| Planning | Customer Workspace | Schedule Planner, Customer Master, Operational Reports |
| Planning | Production Roster | Roster planning and published history |
| Production | Sorting | Washing, Trolley Intake, MOP Production, Staff |
| Production | Finish | Production and Staff views |
| Production | Finish Results | Daily Finish performance |
| Production | Production Tracker | Route board and operational list |
| Logistics | Distribution | Daily board, Route customers, Weekly roster, Leave calendar, Actuals, Drivers, Fleet, Routes, History, Customer guides |
| Logistics | Trolleys | Locations, Trolley Master, Trolley Types |
| Management | Production Intelligence | Official production history and indicators |
| Management | Staff Master | Staff directory, Accounts & access |

MOP Production has its own permission but no separate sidebar entry: it opens
from Sorting (accounts with MOP only see Sorting → MOP Production).

## Permission Source

`frontend/assets/js/app-shell-policy.js` is the single navigation registry.

- `NAVIGATION_MODULES` defines the sidebar workspaces and their sub-pages (`children`).
- `NAVIGATION_GROUPS` defines the sidebar sections and their order.
- `PAGE_MODULES` maps each HTML page to the workspace it highlights.
- `NAVIGATION_PERMISSIONS` defines stable permission names.
- `ROLE_NAVIGATION_PERMISSIONS` maps an application role to workspaces.
- `navigationAccess()` combines all active roles and supports future explicit
  per-person grants or denials.

Navigation visibility is guidance only. Supabase RPC authorization remains the
source of truth for data access and must be updated whenever a new permission
is introduced.

## Rendering

`frontend/assets/js/operational-page-nav.js` renders the sidebar on every signed-in
page, including Home (which mounts it after sign-in). Styles live only in
`frontend/assets/css/navigation.css`. A page joins the shell by wrapping its
content in an element with `data-operational-shell-root` and loading
`app-shell-policy.js`, `operational-page-nav.js` and `navigation.css`.

- Desktop: a 72 px icon rail that opens on hover or focus and can be pinned open.
  Sections are separated by thin dividers on the rail and titled when open.
- Mobile (700 px and below): a top bar with a menu button opens a drawer with all
  labels, sections and sub-pages. Escape, the close button or the backdrop close it.
- Without a session (public roster token links) the sidebar is removed.

## Adding a Workspace

1. Add its stable permission name to `NAVIGATION_PERMISSIONS`.
2. Add exactly one workspace entry to `NAVIGATION_MODULES`, with a `group` from
   `NAVIGATION_GROUPS`, and map its page in `PAGE_MODULES`.
3. Grant that permission to the relevant application roles in
   `ROLE_NAVIGATION_PERMISSIONS`.
4. Ensure the destination RPCs enforce the same access on the server.
5. Keep related subviews inside the workspace unless they are genuinely
   independent operational destinations.
