# Production Roster management

The Production Roster uses `roster_periods` as the weekly container and adds shift-specific immutable versions through:

- `production_roster_versions`;
- `production_roster_entries`;
- `production_roster_events`;
- `production_roster_view_links`.

A saved draft is mutable only through controlled RPC functions. A published or superseded version is immutable. Daily entries store staff, role, area, station, training and shift snapshots so historical views do not change when Staff Master is edited later.

Current daily statuses are `WORKING`, `OFF`, `SICK`, `HOLIDAY`, `TRAINING` and `QUALITY_ANALYSIS`. COVER is represented by `assignment_type = COVER` with `day_status = WORKING`.

The candidate scope is always:

```sql
production_staff = true
and active = true
and roster_eligible = true
and deleted_at is null
```

The mobile view is served by `get_published_production_roster(token)`. Browser roles do not receive direct table access.

## Weekly visual row section — migration 202608050001

`production_roster_entries.display_section_code` stores the single visual section used to place a staff row in one Roster version. Supported values are:

```text
SUPERVISOR
SORTING_AREA
LABEL
FINISH_TABLE_1
FINISH_TABLE_2
FINISH_TABLE_3
FINISH_OTHER
CLEANER
SUPPORT_ROLE
```

The value is intentionally independent from `area_id` and `station_id`, which continue to describe each day's planned work. The Save RPC enforces one consistent display section across all visible-day entries for the same staff member. Existing versions are backfilled from their stored primary-role and default-station snapshots. Published immutability remains in force after the controlled migration backfill.


## Temporary shift override — migration 202608050002

A roster version may include an eligible production staff member whose Staff Master default shift differs from the roster shift. The assignment is temporary and versioned. `shift_code_snapshot` / `shift_name_snapshot` record the roster shift, while `staff_default_shift_code_snapshot` / `staff_default_shift_name_snapshot` preserve the Staff Master default shift at save time.

The controlled RPC `get_production_roster_staff_pool(date, text, uuid)` exposes eligible staff across active production shifts without granting direct browser access to Staff Master or roster tables.
