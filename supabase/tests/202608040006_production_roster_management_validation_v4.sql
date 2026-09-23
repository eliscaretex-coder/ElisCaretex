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
