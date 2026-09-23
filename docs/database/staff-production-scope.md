# Staff production scope

The `staff_members` table contains both authentication-linked identity profiles and productive staff records. Staff Master and Production Roster must never infer productive workforce membership from the existence of an auth account.

`staff_members.production_staff` is the authoritative distinction.

## Rules

- Staff Master read and write APIs operate only on `production_staff = true`.
- Staff created through Staff Master are production staff.
- Authentication-only records default to `production_staff = false`.
- Non-production profiles are forced to `roster_eligible = false`.
- Future Production Roster candidates require production scope, active status and roster eligibility.
- System roles in `staff_roles` do not make a person production staff.
- Linking `auth_user_id` to a production staff member does not remove production scope.
