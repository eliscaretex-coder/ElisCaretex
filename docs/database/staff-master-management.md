# Staff Master Management

## Boundary

Staff Master owns operational people and their normal work context. It does not own application permissions, weekly roster assignments, actual work sessions or private HR data.

## Separation of concepts

```text
staff_roles
→ application permissions such as ADMIN or ROSTER_MANAGER

operational_roles
→ work functions such as GENERAL_OPERATIVE or TEAM_LEADER

staff_cover_capabilities
→ temporary alternative work functions allowed during a roster assignment
```

A COVER capability never changes `primary_operational_role_id`.

## Staff lifecycle

Physical deletion is not supported. The controlled lifecycle is:

```text
Active
→ Deactivate with date and reason
→ historical records remain queryable
→ Reactivate with reason when required
```

Deactivation sets `roster_eligible = false`. Reactivation explicitly decides whether roster eligibility is restored.

## Legacy dates and training

Missing `joined_on` and `deactivated_on` values are preserved as `NULL`. They are expected because those legacy fields were introduced later.

Training fields are non-null booleans. Legacy blank values are imported as `false`.

## Controlled API

```text
get_staff_master_reference_data()
get_staff_directory(status, shift, search)
get_staff_master_record(staff_id)
create_staff_master(...)
update_staff_master(...)
deactivate_staff_member(...)
reactivate_staff_member(...)
```

All multi-field writes are transactional, audited and protected by role checks. Updates require `row_version`.

## Roles

May view Staff Master:

```text
ADMIN
MANAGER
ROSTER_MANAGER
SUPERVISOR
AUDITOR
```

May create, edit, deactivate and reactivate:

```text
ADMIN
MANAGER
```

## Roster dependency

The future Production Roster will reference the immutable staff identity plus the effective operational role, area, station and COVER assignment selected for each day. Historical roster publications must use snapshots so later Staff Master changes do not rewrite past rosters.
