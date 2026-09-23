# Production Roster UI — 2026-08-04

The V2 page intentionally retains the layout direction of the submitted Google Apps Script Roster:

- compact professional toolbar;
- weekly people-by-day grid;
- operational section grouping;
- table subsections;
- colour-coded daily status cells;
- daily assignment editor;
- working totals;
- print and history controls.

Backend and security differ from the legacy project: weekly JSON is replaced by normalized versioned PostgreSQL rows, direct browser writes are prohibited, optimistic concurrency is enforced, and published history is immutable.

`roster-view.html` is a separate mobile-first read-only view for staff.

## Quick status workflow — source update 2026-08-05

The daily status interaction was simplified without changing the database contract or roster governance.

Clicking an editable day cell now opens a compact status menu with the existing supported values:

```text
W  Working
C  Cover
O  Off
S  Sick
H  Holiday
T  Training
QA Quality Analysis
```

The quick menu applies Working, Off, Sick, Holiday, Training and Quality Analysis immediately to the unsaved browser state. The user must still press Save or Publish through the existing versioned workflow.

Cover continues to require an authorised COVER role from Staff Master and therefore opens the detailed daily assignment editor. Cover is unavailable in the menu when the staff member has no authorised cover capabilities.

The detailed editor now uses the same colour-coded status choices instead of a plain status select. Role, area and station fields remain conditional and appear only for working states.

Keyboard shortcuts are available while the quick menu is open:

```text
W Working
C Cover
O Off
S Sick
H Holiday
T Training
Q Quality Analysis
E Edit details
Esc Close
```

This update changes frontend interaction only. It does not change migrations, RPC signatures, published-history rules, staff eligibility, or COVER governance.

Current evidence status:

```text
SOURCE PREPARED
BROWSER VALIDATION PENDING
DATABASE V4 VALIDATION STILL PENDING EVIDENCE
```
## Quick status layout refinement — 2026-08-05

The quick status popover uses a balanced two-column desktop grid with equal-height choices. Quality Analysis spans the full grid width, while narrow screens use one column. The header, choices and footer are visually separated so status selection remains fast and the Save reminder does not compete with the Edit details action.

This is a frontend-only refinement. The supported statuses, keyboard shortcuts, COVER authorisation and versioned Save/Publish workflow are unchanged.



## Area hierarchy, training badges and COVER selection — 2026-08-05

Operational sections now use distinct visual headers for Supervisor, Sorting Area, Label, Finish Area, Cleaner and Support Role. Finish Area is divided into clearly labelled Table 1, Table 2, Table 3 and Other subsections.

Staff rows display EOD, First Aid and Fire badges when those Staff Master flags are true. Team Leaders are placed first within their table and receive a dedicated badge and row emphasis.

The Cover workflow now renders every authorised Cover function as a separate selectable option. The options continue to come only from `cover_role_codes` returned by the controlled Production Roster RPC. The selection is validated again before it is applied to the unsaved roster state.

## Weekly row-section selector — 2026-08-05

The Assignment column includes a **Show row in** selector for each staff member. This selector determines only the weekly visual section in the administrative grid. It does not change daily role, area or station selections.

Changing the selector moves the row immediately in the unsaved view. The staff member remains a single row even when daily assignments are mixed between tables. Save and Publish preserve the selected row section in that Roster version, while Staff Master defaults remain unchanged.
