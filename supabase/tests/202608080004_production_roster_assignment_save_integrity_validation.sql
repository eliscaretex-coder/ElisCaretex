-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080004_production_roster_assignment_save_integrity
--
-- Covered
--   * weekly SORTING_AREA section canonicalises BASE Working assignments;
--   * SUPPORT_ROLE preserves mixed daily BASE assignments;
--   * current Staff Master COVER capability is accepted even when its
--     effective_from is later than Monday of the editable current week;
--   * failed save remains atomic (no partial entry/version change);
--   * optimistic-concurrency save contract remains available;
--   * all validation writes are rolled back.
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
  'eliscaretex_validation.week_start',
  public.production_roster_week_start(current_date + 364)::text,
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
  join public.shifts sh
    on sh.shift_id = sm.default_shift_id
   and sh.shift_code = 'MORNING'
  where sm.production_staff = true
    and sm.active = true
    and sm.roster_eligible = true
    and sm.deleted_at is null
    and not exists (
      select 1
      from public.staff_cover_capabilities scc
      join public.operational_roles cr
        on cr.operational_role_id = scc.operational_role_id
       and cr.role_code = 'SUPERVISOR'
      where scc.staff_id = sm.staff_id
        and scc.active = true
        and scc.deleted_at is null
        and scc.effective_from <= ((now() at time zone 'Europe/Dublin')::date)
        and (scc.effective_until is null or scc.effective_until >= ((now() at time zone 'Europe/Dublin')::date))
    )
  order by sm.created_at
  limit 1
) candidate;

-- Deliberately inconsistent input: weekly row says SORTING_AREA while every
-- BASE assignment says Table 1. The server must canonicalise it.
select set_config(
  'eliscaretex_validation.sorting_payload',
  (
    select jsonb_agg(jsonb_build_object(
      'staff_id', current_setting('eliscaretex_validation.staff_id')::uuid,
      'work_date', current_setting('eliscaretex_validation.week_start')::date + d,
      'day_status', 'WORKING',
      'assignment_type', 'BASE',
      'operational_role_code', 'GENERAL_OPERATIVE',
      'area_code', 'FINISH',
      'station_code', 'FINISH_TABLE_1',
      'display_section_code', 'SORTING_AREA',
      'planned_start_time', null,
      'planned_end_time', null,
      'notes', null
    ) order by d)::text
    from generate_series(0, 5) d
  ),
  true
);

-- SUPPORT_ROLE is the explicit mixed mode: alternate Table 1 and Sorting.
select set_config(
  'eliscaretex_validation.support_payload',
  (
    select jsonb_agg(jsonb_build_object(
      'staff_id', current_setting('eliscaretex_validation.staff_id')::uuid,
      'work_date', current_setting('eliscaretex_validation.week_start')::date + d,
      'day_status', 'WORKING',
      'assignment_type', 'BASE',
      'operational_role_code', case when mod(d, 2) = 0 then 'GENERAL_OPERATIVE' else 'SORTING_AREA' end,
      'area_code', case when mod(d, 2) = 0 then 'FINISH' else 'SORTING' end,
      'station_code', case when mod(d, 2) = 0 then 'FINISH_TABLE_1' else 'SORTING_MAIN' end,
      'display_section_code', 'SUPPORT_ROLE',
      'planned_start_time', null,
      'planned_end_time', null,
      'notes', null
    ) order by d)::text
    from generate_series(0, 5) d
  ),
  true
);

-- Invalid COVER payload for the selected staff (no current Supervisor cover).
select set_config(
  'eliscaretex_validation.invalid_cover_payload',
  (
    select jsonb_agg(
      case when d = 0 then jsonb_build_object(
        'staff_id', current_setting('eliscaretex_validation.staff_id')::uuid,
        'work_date', current_setting('eliscaretex_validation.week_start')::date + d,
        'day_status', 'WORKING',
        'assignment_type', 'COVER',
        'operational_role_code', 'SUPERVISOR',
        'area_code', 'FINISH',
        'station_code', null,
        'display_section_code', 'SUPPORT_ROLE',
        'planned_start_time', null,
        'planned_end_time', null,
        'notes', null
      ) else jsonb_build_object(
        'staff_id', current_setting('eliscaretex_validation.staff_id')::uuid,
        'work_date', current_setting('eliscaretex_validation.week_start')::date + d,
        'day_status', 'WORKING',
        'assignment_type', 'BASE',
        'operational_role_code', 'GENERAL_OPERATIVE',
        'area_code', 'FINISH',
        'station_code', 'FINISH_TABLE_1',
        'display_section_code', 'SUPPORT_ROLE',
        'planned_start_time', null,
        'planned_end_time', null,
        'notes', null
      ) end
      order by d
    )::text
    from generate_series(0, 5) d
  ),
  true
);

do $$
declare
  v_role text;
  v_area text;
  v_station text;
  v_cover_staff uuid;
  v_cover_role uuid;
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.staff_id', true), '') is null then
    raise exception 'No eligible Morning staff without Supervisor COVER capability was found.';
  end if;

  select role_code, area_code, station_code
  into v_role, v_area, v_station
  from public.production_roster_resolve_display_assignment('SORTING_AREA', 'GENERAL_OPERATIVE');

  if v_role <> 'SORTING_AREA' or v_area <> 'SORTING' or v_station <> 'SORTING_MAIN' then
    raise exception 'SORTING_AREA display assignment resolver is incorrect.';
  end if;

  select role_code, area_code, station_code
  into v_role, v_area, v_station
  from public.production_roster_resolve_display_assignment('FINISH_TABLE_2', 'SORTING_AREA');

  if v_role <> 'GENERAL_OPERATIVE' or v_area <> 'FINISH' or v_station <> 'FINISH_TABLE_2' then
    raise exception 'Finish Table display assignment resolver is incorrect.';
  end if;

  -- Reproduce the original current-week mismatch condition: capability was
  -- enabled after Monday, but it is currently active in Staff Master.
  select scc.staff_id, scc.operational_role_id
  into v_cover_staff, v_cover_role
  from public.staff_cover_capabilities scc
  where scc.active = true
    and scc.deleted_at is null
    and scc.effective_from > public.production_roster_week_start(((now() at time zone 'Europe/Dublin')::date))
    and scc.effective_from <= ((now() at time zone 'Europe/Dublin')::date)
    and (scc.effective_until is null or scc.effective_until >= ((now() at time zone 'Europe/Dublin')::date))
  order by scc.effective_from, scc.created_at
  limit 1;

  if v_cover_staff is null then
    raise exception 'No current-week COVER capability fixture was found.';
  end if;

  if public.production_roster_cover_currently_authorised(v_cover_staff, v_cover_role) is not true then
    raise exception 'Current Staff Master COVER capability was not recognised.';
  end if;

  if position(
    'scc.effective_from <= v_work_date'
    in pg_get_functiondef('public.save_production_roster_week(date,text,boolean,text,jsonb,integer,text,text)'::regprocedure)
  ) > 0 then
    raise exception 'Old day-specific COVER validation is still present in save_production_roster_week.';
  end if;
end;
$$;

set local role authenticated;

select set_config(
  'eliscaretex_validation.save_sorting',
  public.save_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'MORNING',
    false,
    'Temporary assignment-integrity validation.',
    current_setting('eliscaretex_validation.sorting_payload')::jsonb,
    null,
    'Validate weekly section canonicalisation.',
    'DATABASE_TEST'
  )::text,
  true
);

reset role;

do $$
declare
  v_bad integer;
begin
  select count(*) into v_bad
  from public.production_roster_entries pre
  left join public.operational_roles r on r.operational_role_id = pre.operational_role_id
  left join public.areas a on a.area_id = pre.area_id
  left join public.stations s on s.station_id = pre.station_id
  where pre.roster_version_id = (current_setting('eliscaretex_validation.save_sorting')::jsonb ->> 'roster_version_id')::uuid
    and (
      pre.display_section_code <> 'SORTING_AREA'
      or r.role_code <> 'SORTING_AREA'
      or a.area_code <> 'SORTING'
      or s.station_code <> 'SORTING_MAIN'
    );

  if v_bad <> 0 then
    raise exception 'Weekly SORTING_AREA did not canonicalise every BASE working assignment.';
  end if;
end;
$$;

set local role authenticated;

select set_config(
  'eliscaretex_validation.save_support',
  public.save_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'MORNING',
    false,
    'Temporary assignment-integrity validation.',
    current_setting('eliscaretex_validation.support_payload')::jsonb,
    (current_setting('eliscaretex_validation.save_sorting')::jsonb ->> 'row_version')::integer,
    'Validate Support Role mixed assignments.',
    'DATABASE_TEST'
  )::text,
  true
);

reset role;

do $$
declare
  v_table integer;
  v_sorting integer;
  v_row_version integer;
begin
  select
    count(*) filter (where s.station_code = 'FINISH_TABLE_1'),
    count(*) filter (where s.station_code = 'SORTING_MAIN')
  into v_table, v_sorting
  from public.production_roster_entries pre
  left join public.stations s on s.station_id = pre.station_id
  where pre.roster_version_id = (current_setting('eliscaretex_validation.save_support')::jsonb ->> 'roster_version_id')::uuid
    and pre.display_section_code = 'SUPPORT_ROLE';

  if v_table <> 3 or v_sorting <> 3 then
    raise exception 'SUPPORT_ROLE did not preserve the expected mixed daily assignments.';
  end if;

  select row_version into v_row_version
  from public.production_roster_versions
  where roster_version_id = (current_setting('eliscaretex_validation.save_support')::jsonb ->> 'roster_version_id')::uuid;

  perform set_config('eliscaretex_validation.before_failed_row_version', v_row_version::text, true);
end;
$$;

set local role authenticated;

do $$
begin
  begin
    perform public.save_production_roster_week(
      current_setting('eliscaretex_validation.week_start')::date,
      'MORNING',
      false,
      'Temporary assignment-integrity validation.',
      current_setting('eliscaretex_validation.invalid_cover_payload')::jsonb,
      (current_setting('eliscaretex_validation.save_support')::jsonb ->> 'row_version')::integer,
      'Validate atomic failed save.',
      'DATABASE_TEST'
    );
    raise exception 'Invalid COVER save unexpectedly succeeded.';
  exception
    when others then
      if sqlerrm = 'Invalid COVER save unexpectedly succeeded.' then
        raise;
      end if;
      if position('not authorised for the selected COVER role' in sqlerrm) = 0 then
        raise exception 'Unexpected invalid COVER error: %', sqlerrm;
      end if;
  end;
end;
$$;

reset role;

do $$
declare
  v_row_version integer;
  v_entry_count integer;
begin
  select row_version into v_row_version
  from public.production_roster_versions
  where roster_version_id = (current_setting('eliscaretex_validation.save_support')::jsonb ->> 'roster_version_id')::uuid;

  if v_row_version <> current_setting('eliscaretex_validation.before_failed_row_version')::integer then
    raise exception 'Failed save changed the draft row_version; atomicity was broken.';
  end if;

  select count(*) into v_entry_count
  from public.production_roster_entries pre
  where pre.roster_version_id = (current_setting('eliscaretex_validation.save_support')::jsonb ->> 'roster_version_id')::uuid
    and pre.display_section_code = 'SUPPORT_ROLE';

  if v_entry_count <> 6 then
    raise exception 'Failed save changed draft entries; atomicity was broken.';
  end if;
end;
$$;

select jsonb_build_object(
  'status','PASS',
  'test','202608080004_production_roster_assignment_save_integrity_validation',
  'weekly_section_drives_base_assignment',true,
  'support_role_preserves_mixed_daily_assignment',true,
  'current_cover_capability_used',true,
  'failed_save_is_atomic',true,
  'optimistic_concurrency_preserved',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
