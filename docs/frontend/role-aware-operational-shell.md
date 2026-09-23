# Role-aware Administrative and Operational Shells

**Status:** Historical design note; current terminal/access model updated 2026-09-10.
**Current authority:** `docs/handover/ElisCaretex_V2_PROJECT_INIT_2026-09-10_v87_CURRENT.md` and `docs/operations/PRODUCTION_TERMINAL_ROLLOUT.md`.

## Decision

ElisCaretex V2 uses two different authenticated Home experiences.

### Administrative shell

The administrative shell supports management, planning, audit and platform navigation. It retains the current profile summary and module-card layout.

### Operational shell

The operational shell supports fixed production and distribution workstations. It uses a compact retractable sidebar and exposes only operationally relevant entry points.

## Role policy

The frontend policy is defined in:

```text
frontend/assets/js/app-shell-policy.js
```

Administrative shell roles:

```text
ADMIN
MANAGER
PLANNER
ROSTER_MANAGER
AUDITOR
```

Operational-only roles:

```text
SUPERVISOR
SORTING_OPERATOR
FINISH_OPERATOR
MOP_OPERATOR
DISTRIBUTION_OPERATOR
```

An effective administrative role takes precedence when a staff member has mixed roles.

Role assignment is evaluated using:

```text
active
effective_from
effective_until
```

## Historical operational navigation

The first implementation exposes existing read-only operational views where the backend already supports them:

```text
SORTING_OPERATOR / FINISH_OPERATOR
→ Clothes Schedule

MOP_OPERATOR
→ MOP Schedule

DISTRIBUTION_OPERATOR
→ Distribution Routes

SUPERVISOR
→ Clothes Schedule and MOP Schedule
```

This section records the original role-only proposal. It is not the current terminal routing model.

## Current operational navigation

- A Finish terminal opens Finish Production for its bound Table, the read-only Customer Schedule and Production Tracker.
- A Sorting terminal opens Sorting/Washing, Trolley Intake, MOP Production and read-only MOP Types.
- A personal MOP Operator account remains scoped to MOP Production by backend permission.
- A Distribution Operator account opens its permitted Distribution operational views.

The exact visible module list is usability guidance only. Every destination RPC remains independently authorized.

## Direct Customer view routing

The Customer module now accepts optional query parameters:

```text
view=schedule
distribution.html
service=clothes
service=mop
```

These parameters select only views already authorized by the result of:

```text
get_customer_read_capabilities()
```

They do not override database permissions.

## Security

The operational shell is not treated as security enforcement. Hiding a module does not grant or revoke access.

Authorization remains the responsibility of database policies and controlled RPC functions. Every future operational page must independently verify authentication and capabilities.

## Device-aware production state

Fixed production terminal identity is implemented. A terminal account is bound to a registered station and does not require a linked Staff Master record.

Current routing uses:

```text
Terminal identity
+
Authenticated account roles
+
Roster/Actual staff attribution
```

Examples:

```text
FINISH-T1-PC1 → Finish Table 1
SORTING-PC1   → Sorting Area
```

A production terminal must not receive administrative permissions. Staff do not log in individually or use a PIN on that computer.
