# Customer Schedule History Management

Migration: `202608030002_customer_schedule_history_management.sql`

## Objective

Provide a controlled read model for Customer Schedule history and an atomic historical restore path without granting direct browser access to schedule tables.

## Data model change

`public.customer_schedule_versions.restored_from_version_id` records the historical revision copied by a restore operation.

This is intentionally separate from `based_on_version_id`:

- `restored_from_version_id` identifies the source content;
- `based_on_version_id` identifies the current published revision used for comparison and publication lineage.

## Public RPCs

### `get_customer_schedule_history`

Returns:

- customer identity;
- current effective revision ID;
- selected revision ID;
- up to 100 revision metadata records;
- selected and current schedule snapshots;
- normalized current-to-selected comparison;
- restore availability.

History access is available to `ADMIN`, `MANAGER`, `PLANNER`, `SUPERVISOR` and `AUDITOR`.

### `restore_customer_schedule_version_as_update`

Available to `ADMIN`, `MANAGER` and `PLANNER`.

The function:

1. validates the historical source and effective date;
2. copies the historical child model into a new protected working revision;
3. records restore source lineage;
4. uses the currently effective published revision as the comparison base;
5. normalizes production orders;
6. publishes the replacement revision;
7. returns the comparison and new published snapshot.

All steps execute in one database transaction.

## Internal functions

- `require_customer_schedule_history_role`
- `build_customer_schedule_version_comparison`
- `restore_customer_schedule_management_draft`

These functions are not executable directly by `authenticated` browser sessions.

## Immutability

The restore path inserts a new version and new child rows. It does not update or delete the selected historical revision. Publication changes only the lifecycle status of the previously current revision according to the existing versioning model.
