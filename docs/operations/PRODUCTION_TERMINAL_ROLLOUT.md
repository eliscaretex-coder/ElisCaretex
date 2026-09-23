# Production terminal rollout

## Daily use

- Each Finish or Sorting computer remains signed in with its own technical terminal account.
- Production staff do not enter an email, password or PIN on the computer.
- The staff member recorded against the operational work remains the one already selected from the published Roster/Actual workflow.
- A Finish terminal registered to `FINISH_TABLE_1`, `FINISH_TABLE_2` or `FINISH_TABLE_3` cannot record work for another table.

## One-time terminal setup

This setup is performed by IT or a system administrator, not by production staff.

1. In **Staff Master -> Accounts & Access**, create one `Production terminal` account for the physical computer. It may use the assigned technical username and does not need a personal email or a linked Staff Master record.
2. Give it only the matching operational role: `FINISH_OPERATOR` for a Finish Table or `SORTING_OPERATOR` for Sorting. The terminal account is the computer identity, not a person.
3. Set its Computer code and bind it to the correct registered station. The Accounts & Access workflow is preferred; direct database registration is reserved for a controlled administrator deployment:

```sql
insert into public.production_station_devices (
  station_id, device_code, device_name, device_auth_user_id, active
)
select station_id, '<DEVICE_CODE>', '<DEVICE_NAME>', '<AUTH_USER_UUID>'::uuid, true
from public.stations
where station_code = '<STATION_CODE>';
```

4. Sign in once on that physical computer with the terminal account. Supabase preserves this session in that browser. Production staff do not use or need its password.
5. An administrator can reset the terminal password in Accounts & Access if access is lost. Existing passwords cannot be viewed or recovered.

## Required terminal mapping

- `FINISH-T1-PC1` -> `FINISH_TABLE_1`
- `FINISH-T2-PC1` -> `FINISH_TABLE_2`
- `FINISH-T3-PC1` -> `FINISH_TABLE_3`
- `SORTING-PC1` -> `SORTING_MAIN`

The terminal account needs no manager, roster, customer or distribution role. A registered Sorting terminal may enter MOP Production and view MOP Types read-only. Supervisors use their own normal account outside the production terminals.

## Scope in this release

The server enforces the fixed terminal for Finish production/new edits and the primary Sorting workflows: Washing, missed/corrected Washing, trolley reception, no-trolley reception and the approved Sorting terminal MOP path. Advanced MOP corrections, attendance adjustments and exception-maintenance RPCs remain a tracked follow-up in P-014 and should remain with a supervisor until their terminal checks are added.
