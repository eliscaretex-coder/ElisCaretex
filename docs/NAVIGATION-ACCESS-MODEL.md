# Navigation Access Model

The application has one sidebar entry per workspace. A workspace may contain
several internal views, but those views must not become duplicate sidebar items.

## Workspaces

| Workspace | Internal views |
| --- | --- |
| Customer Workspace | Customer Master, Customer Weekly Planner, Distribution Routes, Operational Reports |
| Distribution | Daily dispatch, route runs, drivers and fleet |
| Production Roster | Roster planning and published history |
| Sorting | Washing, trolley intake, MOP work, tracker and staff views |
| Finish | Production and staff views |
| Finish Results | Daily Finish performance |
| MOP Production | Standalone MOP production |
| Production Tracker | Shared production trace |
| Trolleys | Trolley location and custody history |
| Staff Master | Staff records and operational roles |

## Permission Source

`frontend/assets/js/app-shell-policy.js` is the single navigation registry.

- `NAVIGATION_MODULES` defines the sidebar workspaces.
- `NAVIGATION_PERMISSIONS` defines stable permission names.
- `ROLE_NAVIGATION_PERMISSIONS` maps an application role to workspaces.
- `navigationAccess()` combines all active roles and supports future explicit
  per-person grants or denials.

Navigation visibility is guidance only. Supabase RPC authorization remains the
source of truth for data access and must be updated whenever a new permission
is introduced.

## Adding a Workspace

1. Add its stable permission name to `NAVIGATION_PERMISSIONS`.
2. Add exactly one workspace entry to `NAVIGATION_MODULES`.
3. Grant that permission to the relevant application roles in
   `ROLE_NAVIGATION_PERMISSIONS`.
4. Ensure the destination RPCs enforce the same access on the server.
5. Keep related subviews inside the workspace unless they are genuinely
   independent operational destinations.
