-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608040004_legacy_staff_import_validation.sql
-- Purpose:
--   Validate the authoritative 99-record Staff Master import.
-- This validation is read-only and does not roll back the imported data.
-- =====================================================================

do $$
declare
  v_invalid_cover_count integer;
begin
  if not exists (
    select 1 from public.app_config
    where config_key = 'legacy_staff_import_20260804_v1'
  ) then
    raise exception 'Legacy staff import marker is missing.';
  end if;

  if (select count(*) from public.staff_members where legacy_user_id between 1 and 99) <> 99 then
    raise exception 'Expected 99 imported legacy staff records.';
  end if;

  if (select count(*) from public.staff_members where legacy_user_id between 1 and 99 and active = true) <> 40 then
    raise exception 'Expected 40 active imported staff records.';
  end if;

  if (select count(*) from public.staff_members where legacy_user_id between 1 and 99 and active = false) <> 59 then
    raise exception 'Expected 59 inactive imported staff records.';
  end if;

  if (select count(*) from public.staff_members where legacy_user_id between 1 and 99 and roster_eligible = true) <> 40 then
    raise exception 'Expected 40 roster-eligible imported staff records.';
  end if;

  if (
    select count(*)
    from public.staff_members sm
    join public.shifts sh on sh.shift_id = sm.default_shift_id
    where sm.legacy_user_id between 1 and 99
      and sh.shift_code = 'MORNING'
  ) <> 58 then
    raise exception 'Expected 58 Morning Shift records.';
  end if;

  if (
    select count(*)
    from public.staff_members sm
    join public.shifts sh on sh.shift_id = sm.default_shift_id
    where sm.legacy_user_id between 1 and 99
      and sh.shift_code = 'EVENING'
  ) <> 41 then
    raise exception 'Expected 41 Evening Shift records.';
  end if;

  if (
    select count(*)
    from public.staff_cover_capabilities scc
    join public.staff_members sm on sm.staff_id = scc.staff_id
    where sm.legacy_user_id between 1 and 99
      and scc.active = true
      and scc.deleted_at is null
  ) <> 24 then
    raise exception 'Expected 24 imported COVER capabilities.';
  end if;

  select count(*) into v_invalid_cover_count
  from public.staff_cover_capabilities scc
  join public.staff_members sm on sm.staff_id = scc.staff_id
  join public.operational_roles opr on opr.operational_role_id = scc.operational_role_id
  where sm.legacy_user_id between 1 and 99
    and opr.role_code not in ('TEAM_LEADER', 'SORTING_AREA', 'SUPERVISOR');

  if v_invalid_cover_count <> 0 then
    raise exception 'An unapproved legacy COVER role was imported.';
  end if;

  if (select count(*) from public.staff_members where legacy_user_id between 1 and 99 and import_review_required = true) <> 3 then
    raise exception 'Expected 3 import-review records.';
  end if;

  if exists (
    select 1
    from public.staff_members sm
    where sm.legacy_user_id between 1 and 99
      and (
        sm.fire_training is null
        or sm.first_aid_training is null
        or sm.eod_capable is null
      )
  ) then
    raise exception 'Training values must be imported as explicit Yes/No booleans.';
  end if;

  if exists (
    select 1
    from public.staff_members sm
    where sm.legacy_user_id between 1 and 99
      and sm.joined_on is not null
      and sm.legacy_user_id not in (40, 68, 98, 99)
  ) then
    raise exception 'JoinedAt dates were invented for records that had no legacy date.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608040004_legacy_staff_import_validation',
  'staff_records', 99,
  'active', 40,
  'inactive', 59,
  'roster_eligible', 40,
  'morning_shift', 58,
  'evening_shift', 41,
  'cover_capabilities', 24,
  'review_required', 3,
  'empty_training_values_imported_as_no', true,
  'missing_dates_preserved_as_null', true
) as result;
