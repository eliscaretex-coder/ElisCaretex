-- =====================================================================
-- ElisCaretex V2
-- Acceptance Suite: 202608050005_production_roster_acceptance_suite.sql
--
-- Purpose:
--   Run the current authoritative Production Roster SQL validations in
--   one Supabase SQL Editor execution while preserving each original test
--   verbatim. Every section manages its own transaction and ends with
--   ROLLBACK, so test writes do not persist.
--
-- Expected output:
--   Four validation_result rows with status = PASS, one for each test.
--
-- This file is a test suite, not a migration.
-- =====================================================================

-- =====================================================================
-- BEGIN INCLUDED AUTHORITATIVE TEST: 202608040006_production_roster_management_validation_v4.sql
-- =====================================================================
-- =====================================================================
-- ElisCaretex V2
-- Validation V4: 202608040006_production_roster_management_validation_v4.sql
--
-- V4 corrections:
--   - retains the protected-table and portable JSON corrections;
--   - validates the compatibility replacement for unavailable
--     gen_random_bytes() through the revocable link lifecycle;
--   - does not query protected reference/master tables while running as
--     authenticated;
--   - prepares validation payloads under the SQL test owner;
--   - exercises browser-facing behaviour only through controlled RPCs;
--   - keeps operational_roles, areas, stations, staff_members and roster
--     tables private from browser roles.
--
-- Covered:
--   - production-staff-only candidate scope;
--   - controlled RPC access and protected tables;
--   - save and publish lifecycle;
--   - immutable published entries;
--   - second publication supersedes but preserves the first;
--   - revocable anonymous RosterView read;
--   - all test writes are rolled back.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Test identity and deterministic input preparation.
-- These queries intentionally run before SET ROLE authenticated because
-- the referenced tables are protected implementation details.
-- ---------------------------------------------------------------------

select set_config(
  'request.jwt.claim.sub',
  admin_user.auth_user_id::text,
  true
)
from (
  select sm.auth_user_id
  from public.staff_members sm
  join public.staff_roles sr
    on sr.staff_id = sm.staff_id
   and sr.active = true
   and sr.effective_from <= current_date
   and (sr.effective_until is null or sr.effective_until >= current_date)
  join public.roles r
    on r.role_id = sr.role_id
   and r.active = true
   and r.role_code = 'ADMIN'
  where sm.active = true
    and sm.deleted_at is null
    and sm.auth_user_id is not null
  order by sm.created_at
  limit 1
) admin_user;

select set_config(
  'eliscaretex_validation.week_start',
  (public.production_roster_week_start(current_date) + 7)::text,
  true
);

select set_config(
  'eliscaretex_validation.staff_id',
  candidate.staff_id::text,
  true
)
from (
  select sm.staff_id
  from public.staff_members sm
  join public.shifts s
    on s.shift_id = sm.default_shift_id
   and s.shift_code = 'MORNING'
  join public.operational_roles opr
    on opr.operational_role_id = sm.primary_operational_role_id
  join public.areas a
    on a.area_id = sm.default_area_id
  where sm.production_staff = true
    and sm.active = true
    and sm.roster_eligible = true
    and sm.deleted_at is null
  order by sm.created_at
  limit 1
) candidate;

-- Expected Morning candidate scope. The authenticated check below compares
-- the controlled RPC result with this precomputed protected-table snapshot.
select set_config(
  'eliscaretex_validation.expected_staff_ids',
  coalesce((
    select jsonb_object_agg(sm.staff_id::text, true)
    from public.staff_members sm
    join public.shifts s on s.shift_id = sm.default_shift_id
    where sm.production_staff = true
      and sm.active = true
      and sm.roster_eligible = true
      and sm.deleted_at is null
      and s.shift_code = 'MORNING'
  ), '{}'::jsonb)::text,
  true
);

-- Build both payloads before assuming the browser role. This preserves the
-- intended denial of direct SELECT on operational_roles/areas/stations.
select set_config(
  'eliscaretex_validation.entries_v1',
  (
    select jsonb_agg(jsonb_build_object(
      'staff_id', sm.staff_id,
      'work_date', current_setting('eliscaretex_validation.week_start')::date + day_offset,
      'day_status', 'WORKING',
      'assignment_type', 'BASE',
      'operational_role_code', opr.role_code,
      'area_code', a.area_code,
      'station_code', st.station_code,
      'notes', null
    ) order by day_offset)::text
    from public.staff_members sm
    join public.operational_roles opr
      on opr.operational_role_id = sm.primary_operational_role_id
    join public.areas a
      on a.area_id = sm.default_area_id
    left join public.stations st
      on st.station_id = sm.default_station_id
    cross join generate_series(0, 5) day_offset
    where sm.staff_id = current_setting('eliscaretex_validation.staff_id')::uuid
  ),
  true
);

select set_config(
  'eliscaretex_validation.entries_v2',
  (
    select jsonb_agg(
      case when day_offset = 0 then jsonb_build_object(
        'staff_id', sm.staff_id,
        'work_date', current_setting('eliscaretex_validation.week_start')::date + day_offset,
        'day_status', 'OFF',
        'assignment_type', 'BASE',
        'operational_role_code', null,
        'area_code', null,
        'station_code', null,
        'notes', 'Temporary validation day off.'
      ) else jsonb_build_object(
        'staff_id', sm.staff_id,
        'work_date', current_setting('eliscaretex_validation.week_start')::date + day_offset,
        'day_status', 'WORKING',
        'assignment_type', 'BASE',
        'operational_role_code', opr.role_code,
        'area_code', a.area_code,
        'station_code', st.station_code,
        'notes', null
      ) end
      order by day_offset
    )::text
    from public.staff_members sm
    join public.operational_roles opr
      on opr.operational_role_id = sm.primary_operational_role_id
    join public.areas a
      on a.area_id = sm.default_area_id
    left join public.stations st
      on st.station_id = sm.default_station_id
    cross join generate_series(0, 5) day_offset
    where sm.staff_id = current_setting('eliscaretex_validation.staff_id')::uuid
  ),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;

  if nullif(current_setting('eliscaretex_validation.staff_id', true), '') is null then
    raise exception 'No eligible Morning production staff with a complete default assignment was found.';
  end if;

  if current_setting('eliscaretex_validation.expected_staff_ids')::jsonb = '{}'::jsonb then
    raise exception 'No eligible Morning production staff was found.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Browser-facing read and write lifecycle through controlled RPCs only.
-- ---------------------------------------------------------------------

set local role authenticated;

do $$
declare
  v_reference jsonb := public.get_production_roster_reference_data();
  v_week jsonb := public.get_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'MORNING',
    null
  );
  v_expected jsonb := current_setting('eliscaretex_validation.expected_staff_ids')::jsonb;
  v_actual_count integer;
  v_expected_count integer;
begin
  select count(*)
  into v_expected_count
  from jsonb_each(v_expected);
  if coalesce((v_reference ->> 'can_manage')::boolean, false) is not true then
    raise exception 'ADMIN did not receive Production Roster management capability.';
  end if;

  if jsonb_array_length(coalesce(v_reference -> 'operational_roles', '[]'::jsonb)) = 0
     or jsonb_array_length(coalesce(v_reference -> 'areas', '[]'::jsonb)) = 0 then
    raise exception 'Controlled Production Roster reference data is incomplete.';
  end if;

  select count(*) into v_actual_count
  from jsonb_array_elements(coalesce(v_week -> 'staff', '[]'::jsonb));

  if v_actual_count <> v_expected_count then
    raise exception 'Production Roster candidate count differs from the protected eligible staff scope.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_week -> 'staff', '[]'::jsonb)) item
    where not (v_expected ? (item ->> 'staff_id'))
  ) then
    raise exception 'Production Roster candidate scope contains an ineligible or non-production profile.';
  end if;
end;
$$;

-- Save and publish version 1.
select set_config(
  'eliscaretex_validation.save_v1',
  public.save_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'MORNING',
    false,
    'Temporary validation week.',
    current_setting('eliscaretex_validation.entries_v1')::jsonb,
    null,
    'Validate Production Roster version 1.',
    'DATABASE_TEST'
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.publish_v1',
  public.publish_production_roster_week(
    (current_setting('eliscaretex_validation.save_v1')::jsonb ->> 'roster_version_id')::uuid,
    (current_setting('eliscaretex_validation.save_v1')::jsonb ->> 'row_version')::integer,
    'Publish temporary Production Roster version 1.',
    'DATABASE_TEST'
  )::text,
  true
);

reset role;

-- Published entries must remain immutable even for the migration/test owner.
do $$
begin
  begin
    update public.production_roster_entries
    set notes = 'This update must be blocked.'
    where roster_version_id = (
      current_setting('eliscaretex_validation.publish_v1')::jsonb ->> 'roster_version_id'
    )::uuid;

    raise exception 'Published Production Roster entries were mutable.';
  exception
    when sqlstate '55000' then
      null;
  end;
end;
$$;

set local role authenticated;

-- Save and publish version 2 with Monday Off.
select set_config(
  'eliscaretex_validation.save_v2',
  public.save_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'MORNING',
    false,
    'Temporary validation week version 2.',
    current_setting('eliscaretex_validation.entries_v2')::jsonb,
    null,
    'Validate Production Roster version 2.',
    'DATABASE_TEST'
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.publish_v2',
  public.publish_production_roster_week(
    (current_setting('eliscaretex_validation.save_v2')::jsonb ->> 'roster_version_id')::uuid,
    (current_setting('eliscaretex_validation.save_v2')::jsonb ->> 'row_version')::integer,
    'Publish temporary Production Roster version 2.',
    'DATABASE_TEST'
  )::text,
  true
);

-- Create a revocable mobile link through the authenticated management RPC.
select set_config(
  'eliscaretex_validation.view_link',
  public.rotate_production_roster_view_link('MORNING')::text,
  true
);

reset role;
set local role anon;

-- Anonymous RosterView reads only the published document through its token.
do $$
declare
  v_public jsonb := public.get_published_production_roster(
    current_setting('eliscaretex_validation.view_link')::jsonb ->> 'token'
  );
  v_test_week jsonb;
begin
  select item into v_test_week
  from jsonb_array_elements(coalesce(v_public -> 'weeks', '[]'::jsonb)) item
  where (item ->> 'week_start')::date = current_setting('eliscaretex_validation.week_start')::date
  limit 1;

  if v_test_week is null then
    raise exception 'Anonymous RosterView did not return the published validation week.';
  end if;

  if (v_test_week ->> 'version_number')::integer <> 2 then
    raise exception 'RosterView did not return the current published validation version.';
  end if;
end;
$$;

reset role;

-- ---------------------------------------------------------------------
-- Internal lifecycle and privilege checks under the SQL test owner.
-- ---------------------------------------------------------------------

do $$
declare
  v_week date := current_setting('eliscaretex_validation.week_start')::date;
  v_v1 uuid := (
    current_setting('eliscaretex_validation.publish_v1')::jsonb ->> 'roster_version_id'
  )::uuid;
  v_v2 uuid := (
    current_setting('eliscaretex_validation.publish_v2')::jsonb ->> 'roster_version_id'
  )::uuid;
  v_history_count integer;
begin
  if not exists (
    select 1
    from public.production_roster_versions
    where roster_version_id = v_v1
      and status = 'SUPERSEDED'
  ) then
    raise exception 'First published version was not preserved as SUPERSEDED.';
  end if;

  if not exists (
    select 1
    from public.production_roster_versions
    where roster_version_id = v_v2
      and status = 'PUBLISHED'
  ) then
    raise exception 'Second version is not the current PUBLISHED roster.';
  end if;

  select count(*) into v_history_count
  from public.production_roster_versions prv
  join public.roster_periods rp
    on rp.roster_period_id = prv.roster_period_id
  join public.shifts s
    on s.shift_id = prv.shift_id
  where rp.week_start = v_week
    and s.shift_code = 'MORNING';

  if v_history_count < 2 then
    raise exception 'Production Roster history did not preserve both validation versions.';
  end if;

  if has_table_privilege('authenticated', 'public.operational_roles', 'SELECT')
     or has_table_privilege('authenticated', 'public.production_roster_versions', 'SELECT')
     or has_table_privilege('authenticated', 'public.production_roster_entries', 'SELECT')
     or has_table_privilege('anon', 'public.production_roster_entries', 'SELECT') then
    raise exception 'Protected Production Roster/reference tables have direct browser SELECT privileges.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608040006_production_roster_management_validation_v4',
  'production_staff_only', true,
  'controlled_rpc_access', true,
  'protected_reference_data', true,
  'published_history_preserved', true,
  'published_entries_immutable', true,
  'shift_publication_versioned', true,
  'mobile_roster_view', true,
  'protected_tables_remain_private', true,
  'writes_rolled_back', true
) as validation_result;

rollback;

-- =====================================================================
-- END INCLUDED AUTHORITATIVE TEST: 202608040006_production_roster_management_validation_v4.sql
-- =====================================================================

-- =====================================================================
-- BEGIN INCLUDED AUTHORITATIVE TEST: 202608050001_production_roster_display_section_validation.sql
-- =====================================================================
-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608050001_production_roster_display_section_validation.sql
--
-- Confirms that the weekly visual row section is independent from daily
-- assignments, persists through Save and Publish, preserves history, and
-- does not modify the Staff Master default station.
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  admin_user.auth_user_id::text,
  true
)
from (
  select sm.auth_user_id
  from public.staff_members sm
  join public.staff_roles sr
    on sr.staff_id = sm.staff_id
   and sr.active = true
   and sr.effective_from <= current_date
   and (sr.effective_until is null or sr.effective_until >= current_date)
  join public.roles r
    on r.role_id = sr.role_id
   and r.active = true
   and r.role_code = 'ADMIN'
  where sm.active = true
    and sm.deleted_at is null
    and sm.auth_user_id is not null
  order by sm.created_at
  limit 1
) admin_user;

select set_config(
  'eliscaretex_display_validation.week_start',
  candidate.week_start::text,
  true
)
from (
  select public.production_roster_week_start(current_date) + (series.week_offset * 7) as week_start
  from generate_series(8, 104) as series(week_offset)
  where not exists (
    select 1
    from public.roster_periods rp
    join public.production_roster_versions prv on prv.roster_period_id = rp.roster_period_id
    join public.shifts s on s.shift_id = prv.shift_id
    where rp.week_start = public.production_roster_week_start(current_date) + (series.week_offset * 7)
      and s.shift_code = 'MORNING'
  )
  order by series.week_offset
  limit 1
) candidate;

select set_config(
  'eliscaretex_display_validation.staff_id',
  candidate.staff_id::text,
  true
)
from (
  select sm.staff_id
  from public.staff_members sm
  join public.shifts s on s.shift_id = sm.default_shift_id and s.shift_code = 'MORNING'
  join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
  join public.areas a on a.area_id = sm.default_area_id and a.area_code = 'FINISH'
  where sm.production_staff = true
    and sm.active = true
    and sm.roster_eligible = true
    and sm.deleted_at is null
  order by sm.created_at
  limit 1
) candidate;

select set_config(
  'eliscaretex_display_validation.master_station_before',
  coalesce(st.station_code, ''),
  true
)
from public.staff_members sm
left join public.stations st on st.station_id = sm.default_station_id
where sm.staff_id = current_setting('eliscaretex_display_validation.staff_id')::uuid;

select set_config(
  'eliscaretex_display_validation.entries',
  (
    select jsonb_agg(jsonb_build_object(
      'staff_id', sm.staff_id,
      'work_date', current_setting('eliscaretex_display_validation.week_start')::date + day_offset,
      'day_status', 'WORKING',
      'assignment_type', 'BASE',
      'operational_role_code', opr.role_code,
      'area_code', a.area_code,
      'station_code', case when day_offset in (0, 2) then 'FINISH_TABLE_1' else 'FINISH_TABLE_3' end,
      'display_section_code', 'FINISH_TABLE_3',
      'notes', null
    ) order by day_offset)::text
    from public.staff_members sm
    join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
    join public.areas a on a.area_id = sm.default_area_id
    cross join generate_series(0, 5) day_offset
    where sm.staff_id = current_setting('eliscaretex_display_validation.staff_id')::uuid
  ),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;

  if nullif(current_setting('eliscaretex_display_validation.week_start', true), '') is null then
    raise exception 'No unused future Morning roster week was available for validation.';
  end if;

  if nullif(current_setting('eliscaretex_display_validation.staff_id', true), '') is null then
    raise exception 'No eligible Morning Finish Area production staff was found.';
  end if;
end;
$$;

set local role authenticated;

select set_config(
  'eliscaretex_display_validation.save_result',
  public.save_production_roster_week(
    current_setting('eliscaretex_display_validation.week_start')::date,
    'MORNING',
    false,
    'Temporary display-section validation roster.',
    current_setting('eliscaretex_display_validation.entries')::jsonb,
    null,
    'Validate independent weekly row section',
    'PRODUCTION_ROSTER_DISPLAY_SECTION_VALIDATION'
  )::text,
  true
);

do $$
declare
  v_week jsonb := public.get_production_roster_week(
    current_setting('eliscaretex_display_validation.week_start')::date,
    'MORNING',
    (current_setting('eliscaretex_display_validation.save_result')::jsonb ->> 'roster_version_id')::uuid
  );
  v_staff_id text := current_setting('eliscaretex_display_validation.staff_id');
  v_staff jsonb;
  v_table_1_count integer;
  v_table_3_count integer;
begin
  select item into v_staff
  from jsonb_array_elements(coalesce(v_week -> 'staff', '[]'::jsonb)) item
  where item ->> 'staff_id' = v_staff_id;

  if v_staff is null or v_staff ->> 'display_section_code' <> 'FINISH_TABLE_3' then
    raise exception 'The saved weekly row section was not returned as FINISH_TABLE_3.';
  end if;

  select count(*) filter (where item ->> 'station_code' = 'FINISH_TABLE_1'),
         count(*) filter (where item ->> 'station_code' = 'FINISH_TABLE_3')
  into v_table_1_count, v_table_3_count
  from jsonb_array_elements(coalesce(v_week -> 'entries', '[]'::jsonb)) item
  where item ->> 'staff_id' = v_staff_id;

  if v_table_1_count <> 2 or v_table_3_count <> 4 then
    raise exception 'Daily Table 1/Table 3 assignments were not preserved independently from the row section.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_week -> 'entries', '[]'::jsonb)) item
    where item ->> 'staff_id' = v_staff_id
      and item ->> 'display_section_code' <> 'FINISH_TABLE_3'
  ) then
    raise exception 'A saved entry returned an inconsistent weekly display section.';
  end if;
end;
$$;

select set_config(
  'eliscaretex_display_validation.publish_result',
  public.publish_production_roster_week(
    (current_setting('eliscaretex_display_validation.save_result')::jsonb ->> 'roster_version_id')::uuid,
    (current_setting('eliscaretex_display_validation.save_result')::jsonb ->> 'row_version')::integer,
    'Publish temporary display-section validation roster',
    'PRODUCTION_ROSTER_DISPLAY_SECTION_VALIDATION'
  )::text,
  true
);

do $$
declare
  v_version_id uuid := (current_setting('eliscaretex_display_validation.publish_result')::jsonb ->> 'roster_version_id')::uuid;
  v_week jsonb := public.get_production_roster_week(
    current_setting('eliscaretex_display_validation.week_start')::date,
    'MORNING',
    v_version_id
  );
  v_staff_id text := current_setting('eliscaretex_display_validation.staff_id');
begin
  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_week -> 'staff', '[]'::jsonb)) item
    where item ->> 'staff_id' = v_staff_id
      and item ->> 'display_section_code' = 'FINISH_TABLE_3'
  ) then
    raise exception 'Published historical read did not preserve the selected weekly row section.';
  end if;
end;
$$;

reset role;

do $$
declare
  v_staff_id uuid := current_setting('eliscaretex_display_validation.staff_id')::uuid;
  v_version_id uuid := (current_setting('eliscaretex_display_validation.publish_result')::jsonb ->> 'roster_version_id')::uuid;
  v_master_station_after text;
begin
  select coalesce(st.station_code, '')
  into v_master_station_after
  from public.staff_members sm
  left join public.stations st on st.station_id = sm.default_station_id
  where sm.staff_id = v_staff_id;

  if v_master_station_after <> current_setting('eliscaretex_display_validation.master_station_before') then
    raise exception 'Changing the weekly row section modified the Staff Master default station.';
  end if;

  if exists (
    select 1
    from public.production_roster_entries pre
    where pre.roster_version_id = v_version_id
      and pre.staff_id = v_staff_id
      and pre.display_section_code <> 'FINISH_TABLE_3'
  ) then
    raise exception 'Published entries do not contain one consistent weekly display section.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608050001_production_roster_display_section_validation',
  'daily_assignments_independent', true,
  'weekly_row_section_selectable', true,
  'published_history_preserved', true,
  'staff_master_unchanged', true,
  'writes_rolled_back', true
) as validation_result;

rollback;

-- =====================================================================
-- END INCLUDED AUTHORITATIVE TEST: 202608050001_production_roster_display_section_validation.sql
-- =====================================================================

-- =====================================================================
-- BEGIN INCLUDED AUTHORITATIVE TEST: 202608050003_production_roster_shift_override_safe_repair_validation.sql
-- =====================================================================
-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608050003_production_roster_shift_override_safe_repair_validation.sql
--
-- Confirms that an eligible Evening staff member can be included in a
-- Morning roster for selected days without changing Staff Master, and that
-- both the roster shift and default shift snapshots remain traceable.
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  admin_user.auth_user_id::text,
  true
)
from (
  select sm.auth_user_id
  from public.staff_members sm
  join public.staff_roles sr
    on sr.staff_id = sm.staff_id
   and sr.active = true
   and sr.effective_from <= current_date
   and (sr.effective_until is null or sr.effective_until >= current_date)
  join public.roles r
    on r.role_id = sr.role_id
   and r.active = true
   and r.role_code = 'ADMIN'
  where sm.active = true
    and sm.deleted_at is null
    and sm.auth_user_id is not null
  order by sm.created_at
  limit 1
) admin_user;

select set_config(
  'eliscaretex_shift_override_validation.week_start',
  candidate.week_start::text,
  true
)
from (
  select public.production_roster_week_start(current_date) + (series.week_offset * 7) as week_start
  from generate_series(10, 104) as series(week_offset)
  where not exists (
    select 1
    from public.roster_periods rp
    join public.production_roster_versions prv on prv.roster_period_id = rp.roster_period_id
    join public.shifts s on s.shift_id = prv.shift_id
    where rp.week_start = public.production_roster_week_start(current_date) + (series.week_offset * 7)
      and s.shift_code = 'MORNING'
  )
  order by series.week_offset
  limit 1
) candidate;

select set_config(
  'eliscaretex_shift_override_validation.staff_id',
  candidate.staff_id::text,
  true
)
from (
  select sm.staff_id
  from public.staff_members sm
  join public.shifts sh on sh.shift_id = sm.default_shift_id and sh.shift_code = 'EVENING'
  join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
  join public.areas a on a.area_id = sm.default_area_id
  where sm.production_staff = true
    and sm.active = true
    and sm.roster_eligible = true
    and sm.deleted_at is null
    and opr.role_code is not null
    and a.area_code is not null
  order by sm.created_at
  limit 1
) candidate;

select set_config(
  'eliscaretex_shift_override_validation.entries',
  (
    select jsonb_agg(jsonb_build_object(
      'staff_id', sm.staff_id,
      'work_date', current_setting('eliscaretex_shift_override_validation.week_start')::date + day_offset,
      'day_status', case when day_offset in (0, 2, 4) then 'WORKING' else 'OFF' end,
      'assignment_type', 'BASE',
      'operational_role_code', case when day_offset in (0, 2, 4) then opr.role_code else null end,
      'area_code', case when day_offset in (0, 2, 4) then a.area_code else null end,
      'station_code', case when day_offset in (0, 2, 4) then st.station_code else null end,
      'display_section_code', public.production_roster_default_display_section(opr.role_code, st.station_code),
      'notes', null
    ) order by day_offset)::text
    from public.staff_members sm
    join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
    join public.areas a on a.area_id = sm.default_area_id
    left join public.stations st on st.station_id = sm.default_station_id
    cross join generate_series(0, 5) day_offset
    where sm.staff_id = current_setting('eliscaretex_shift_override_validation.staff_id')::uuid
  ),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;

  if nullif(current_setting('eliscaretex_shift_override_validation.week_start', true), '') is null then
    raise exception 'No unused future Morning roster week was available for validation.';
  end if;

  if nullif(current_setting('eliscaretex_shift_override_validation.staff_id', true), '') is null then
    raise exception 'No eligible Evening production staff was found.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_pool jsonb := public.get_production_roster_staff_pool(
    current_setting('eliscaretex_shift_override_validation.week_start')::date,
    'MORNING',
    null
  );
  v_staff_id text := current_setting('eliscaretex_shift_override_validation.staff_id');
begin
  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_pool -> 'staff', '[]'::jsonb)) item
    where item ->> 'staff_id' = v_staff_id
      and item ->> 'default_shift_code' = 'EVENING'
      and (item ->> 'shift_override')::boolean = true
  ) then
    raise exception 'The controlled staff pool did not expose the Evening staff member as a Morning shift override candidate.';
  end if;
end;
$$;

select set_config(
  'eliscaretex_shift_override_validation.save_result',
  public.save_production_roster_week(
    current_setting('eliscaretex_shift_override_validation.week_start')::date,
    'MORNING',
    false,
    'Temporary shift override validation roster.',
    current_setting('eliscaretex_shift_override_validation.entries')::jsonb,
    null,
    'Validate temporary Evening to Morning assignment',
    'PRODUCTION_ROSTER_SHIFT_OVERRIDE_VALIDATION'
  )::text,
  true
);

select set_config(
  'eliscaretex_shift_override_validation.publish_result',
  public.publish_production_roster_week(
    (current_setting('eliscaretex_shift_override_validation.save_result')::jsonb ->> 'roster_version_id')::uuid,
    (current_setting('eliscaretex_shift_override_validation.save_result')::jsonb ->> 'row_version')::integer,
    'Publish temporary shift override validation roster',
    'PRODUCTION_ROSTER_SHIFT_OVERRIDE_VALIDATION'
  )::text,
  true
);

do $$
declare
  v_pool jsonb := public.get_production_roster_staff_pool(
    current_setting('eliscaretex_shift_override_validation.week_start')::date,
    'MORNING',
    (current_setting('eliscaretex_shift_override_validation.publish_result')::jsonb ->> 'roster_version_id')::uuid
  );
  v_staff_id text := current_setting('eliscaretex_shift_override_validation.staff_id');
begin
  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_pool -> 'staff', '[]'::jsonb)) item
    where item ->> 'staff_id' = v_staff_id
      and item ->> 'default_shift_code' = 'EVENING'
      and item ->> 'roster_shift_code' = 'MORNING'
      and (item ->> 'included_in_roster')::boolean = true
      and (item ->> 'shift_override')::boolean = true
  ) then
    raise exception 'Published shift override history did not preserve both the default and roster shifts.';
  end if;
end;
$$;

reset role;

do $$
declare
  v_staff_id uuid := current_setting('eliscaretex_shift_override_validation.staff_id')::uuid;
  v_version_id uuid := (current_setting('eliscaretex_shift_override_validation.publish_result')::jsonb ->> 'roster_version_id')::uuid;
  v_default_shift text;
begin
  select sh.shift_code
  into v_default_shift
  from public.staff_members sm
  join public.shifts sh on sh.shift_id = sm.default_shift_id
  where sm.staff_id = v_staff_id;

  if v_default_shift <> 'EVENING' then
    raise exception 'The temporary Morning roster assignment changed the Staff Master default shift.';
  end if;

  if not exists (
    select 1
    from public.production_roster_entries pre
    where pre.roster_version_id = v_version_id
      and pre.staff_id = v_staff_id
      and pre.shift_code_snapshot = 'MORNING'
      and pre.staff_default_shift_code_snapshot = 'EVENING'
  ) then
    raise exception 'Roster entry snapshots did not preserve Morning roster shift and Evening Staff Master shift independently.';
  end if;

  if (
    select count(*)
    from public.production_roster_entries pre
    where pre.roster_version_id = v_version_id
      and pre.staff_id = v_staff_id
      and pre.day_status = 'WORKING'
  ) <> 3 then
    raise exception 'Selected-day shift override did not preserve the expected three working days.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608050003_production_roster_shift_override_safe_repair_validation',
  'cross_shift_staff_pool', true,
  'selected_days_preserved', true,
  'default_shift_snapshot_preserved', true,
  'roster_shift_snapshot_preserved', true,
  'staff_master_unchanged', true,
  'writes_rolled_back', true
) as validation_result;

rollback;

-- =====================================================================
-- END INCLUDED AUTHORITATIVE TEST: 202608050003_production_roster_shift_override_safe_repair_validation.sql
-- =====================================================================

-- =====================================================================
-- BEGIN INCLUDED AUTHORITATIVE TEST: 202608050004_production_roster_staff_view_layout_validation.sql
-- =====================================================================
-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608050004_production_roster_staff_view_layout_validation.sql
--
-- Validates the enriched anonymous RosterView payload while proving that
-- published Production Roster entries are not modified. All writes roll back.
-- =====================================================================

begin;

select set_config(
  'eliscaretex_validation.entry_fingerprint_before',
  coalesce((
    select md5(string_agg(to_jsonb(pre)::text, '|' order by pre.roster_entry_id))
    from public.production_roster_entries pre
    join public.production_roster_versions prv
      on prv.roster_version_id = pre.roster_version_id
    where prv.status in ('PUBLISHED', 'SUPERSEDED')
  ), md5('')),
  true
);

select set_config(
  'eliscaretex_validation.shift_id',
  candidate.shift_id::text,
  true
)
from (
  select prv.shift_id
  from public.production_roster_versions prv
  join public.roster_periods rp
    on rp.roster_period_id = prv.roster_period_id
  where prv.status = 'PUBLISHED'
    and rp.week_start in (
      public.production_roster_week_start(current_date),
      public.production_roster_week_start(current_date) + 7
    )
    and exists (
      select 1
      from public.production_roster_entries pre
      where pre.roster_version_id = prv.roster_version_id
    )
  order by rp.week_start, prv.version_number desc
  limit 1
) candidate;

do $$
begin
  if nullif(current_setting('eliscaretex_validation.shift_id', true), '') is null then
    raise exception 'A published current- or next-week Production Roster with entries is required for this validation.';
  end if;
end;
$$;

update public.production_roster_view_links
set active = false,
    revoked_at = coalesce(revoked_at, now())
where shift_id = current_setting('eliscaretex_validation.shift_id')::uuid
  and active = true;

select set_config(
  'eliscaretex_validation.token',
  replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  true
);

insert into public.production_roster_view_links (
  shift_id,
  token_hash,
  token_hint,
  active
)
values (
  current_setting('eliscaretex_validation.shift_id')::uuid,
  public.production_roster_view_token_hash(current_setting('eliscaretex_validation.token')),
  right(current_setting('eliscaretex_validation.token'), 6),
  true
);

set local role anon;

select set_config(
  'eliscaretex_validation.payload',
  public.get_published_production_roster(
    current_setting('eliscaretex_validation.token')
  )::text,
  true
);

reset role;

do $$
declare
  v_payload jsonb := current_setting('eliscaretex_validation.payload')::jsonb;
  v_entry jsonb;
  v_fingerprint_after text;
begin
  if jsonb_array_length(coalesce(v_payload -> 'weeks', '[]'::jsonb)) = 0 then
    raise exception 'RosterView returned no published week.';
  end if;

  select entry
  into v_entry
  from jsonb_array_elements(v_payload -> 'weeks') week_item
  cross join lateral jsonb_array_elements(coalesce(week_item -> 'entries', '[]'::jsonb)) entry
  limit 1;

  if v_entry is null then
    raise exception 'RosterView returned no published entry.';
  end if;

  if not (
    v_entry ? 'display_section_code'
    and v_entry ? 'staff_primary_role_code'
    and v_entry ? 'staff_default_station_code'
    and v_entry ? 'staff_default_shift_code'
    and v_entry ? 'roster_shift_code'
    and v_entry ? 'fire_training'
    and v_entry ? 'first_aid_training'
    and v_entry ? 'eod_capable'
    and v_entry ? 'notes'
  ) then
    raise exception 'RosterView entry is missing one or more layout snapshot fields.';
  end if;

  if v_entry ? 'employee_code' then
    raise exception 'Anonymous RosterView payload still exposes employee_code.';
  end if;

  if jsonb_typeof(v_entry -> 'fire_training') <> 'boolean'
     or jsonb_typeof(v_entry -> 'first_aid_training') <> 'boolean'
     or jsonb_typeof(v_entry -> 'eod_capable') <> 'boolean' then
    raise exception 'RosterView qualification flags are not booleans.';
  end if;

  select coalesce(md5(string_agg(to_jsonb(pre)::text, '|' order by pre.roster_entry_id)), md5(''))
  into v_fingerprint_after
  from public.production_roster_entries pre
  join public.production_roster_versions prv
    on prv.roster_version_id = pre.roster_version_id
  where prv.status in ('PUBLISHED', 'SUPERSEDED');

  if v_fingerprint_after <> current_setting('eliscaretex_validation.entry_fingerprint_before') then
    raise exception 'Published Production Roster entries changed during staff-view validation.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608050004_production_roster_staff_view_layout_validation',
  'anonymous_token_access', true,
  'current_next_weeks_only', true,
  'layout_snapshots_present', true,
  'qualification_flags_present', true,
  'employee_code_omitted', true,
  'published_entries_unchanged', true,
  'writes_rolled_back', true
) as validation_result;

rollback;

-- =====================================================================
-- END INCLUDED AUTHORITATIVE TEST: 202608050004_production_roster_staff_view_layout_validation.sql
-- =====================================================================

