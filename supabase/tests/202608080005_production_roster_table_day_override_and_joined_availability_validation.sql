-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080005_production_roster_table_day_override_and_joined_availability
--
-- Covered
--   * weekly Table 1 row may preserve day overrides to Table 2 / Table 3;
--   * the weekly display section remains Table 1;
--   * Staff Master joined_on controls staff-pool availability;
--   * save rejects Working before joined_on;
--   * failed pre-join save is atomic;
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
  public.production_roster_week_start(current_date + 728)::text,
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
  join public.operational_roles opr
    on opr.operational_role_id = sm.primary_operational_role_id
   and opr.role_code = 'GENERAL_OPERATIVE'
  where sm.production_staff = true
    and sm.active = true
    and sm.roster_eligible = true
    and sm.deleted_at is null
  order by sm.created_at
  limit 1
) candidate;

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.staff_id', true), '') is null then
    raise exception 'No eligible Morning General Operative staff was found.';
  end if;
end;
$$;

-- Weekly row = Table 1. Individual days intentionally alternate T1/T2/T3.
select set_config(
  'eliscaretex_validation.table_payload',
  (
    select jsonb_agg(jsonb_build_object(
      'staff_id', current_setting('eliscaretex_validation.staff_id')::uuid,
      'work_date', current_setting('eliscaretex_validation.week_start')::date + d,
      'day_status', 'WORKING',
      'assignment_type', 'BASE',
      'operational_role_code', 'GENERAL_OPERATIVE',
      'area_code', 'FINISH',
      'station_code', case mod(d, 3)
        when 0 then 'FINISH_TABLE_1'
        when 1 then 'FINISH_TABLE_2'
        else 'FINISH_TABLE_3'
      end,
      'display_section_code', 'FINISH_TABLE_1',
      'planned_start_time', null,
      'planned_end_time', null,
      'notes', null
    ) order by d)::text
    from generate_series(0, 5) d
  ),
  true
);

set local role authenticated;

select set_config(
  'eliscaretex_validation.saved_table',
  public.save_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'MORNING',
    false,
    'Temporary Table override / Joined date validation.',
    current_setting('eliscaretex_validation.table_payload')::jsonb,
    null,
    'Validate daily Finish Table overrides.',
    'DATABASE_TEST'
  )::text,
  true
);

reset role;

do $$
declare
  v_t1 integer;
  v_t2 integer;
  v_t3 integer;
  v_bad integer;
begin
  select
    count(*) filter (where st.station_code = 'FINISH_TABLE_1'),
    count(*) filter (where st.station_code = 'FINISH_TABLE_2'),
    count(*) filter (where st.station_code = 'FINISH_TABLE_3'),
    count(*) filter (
      where pre.display_section_code <> 'FINISH_TABLE_1'
         or a.area_code <> 'FINISH'
         or r.role_code <> 'GENERAL_OPERATIVE'
    )
  into v_t1, v_t2, v_t3, v_bad
  from public.production_roster_entries pre
  left join public.operational_roles r on r.operational_role_id = pre.operational_role_id
  left join public.areas a on a.area_id = pre.area_id
  left join public.stations st on st.station_id = pre.station_id
  where pre.roster_version_id =
    (current_setting('eliscaretex_validation.saved_table')::jsonb ->> 'roster_version_id')::uuid;

  if v_t1 <> 2 or v_t2 <> 2 or v_t3 <> 2 or v_bad <> 0 then
    raise exception 'Daily Finish Table override persistence is incorrect: T1 %, T2 %, T3 %, bad %.',
      v_t1, v_t2, v_t3, v_bad;
  end if;
end;
$$;

-- Temporarily move the same staff Joined date into the validation week.
update public.staff_members
set joined_on = current_setting('eliscaretex_validation.week_start')::date + 3
where staff_id = current_setting('eliscaretex_validation.staff_id')::uuid;

set local role authenticated;

select set_config(
  'eliscaretex_validation.pool_before',
  public.get_production_roster_staff_pool(
    current_setting('eliscaretex_validation.week_start')::date - 7,
    'MORNING',
    null
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.pool_join_week',
  public.get_production_roster_staff_pool(
    current_setting('eliscaretex_validation.week_start')::date,
    'MORNING',
    null
  )::text,
  true
);

reset role;

do $$
declare
  v_staff_id text := current_setting('eliscaretex_validation.staff_id');
  v_joined_on date := current_setting('eliscaretex_validation.week_start')::date + 3;
  v_before boolean;
  v_join_week boolean;
  v_returned_joined_on text;
begin
  select exists (
    select 1
    from jsonb_array_elements(
      current_setting('eliscaretex_validation.pool_before')::jsonb -> 'staff'
    ) item
    where item ->> 'staff_id' = v_staff_id
  ) into v_before;

  select
    exists (
      select 1
      from jsonb_array_elements(
        current_setting('eliscaretex_validation.pool_join_week')::jsonb -> 'staff'
      ) item
      where item ->> 'staff_id' = v_staff_id
    ),
    (
      select item ->> 'joined_on'
      from jsonb_array_elements(
        current_setting('eliscaretex_validation.pool_join_week')::jsonb -> 'staff'
      ) item
      where item ->> 'staff_id' = v_staff_id
      limit 1
    )
  into v_join_week, v_returned_joined_on;

  if v_before then
    raise exception 'Staff was exposed in the roster pool before Joined date.';
  end if;
  if not v_join_week then
    raise exception 'Staff was not exposed in the roster pool during the Joined week.';
  end if;
  if v_returned_joined_on is distinct from v_joined_on::text then
    raise exception 'Roster pool did not return the Staff Master Joined date.';
  end if;
end;
$$;

-- Re-use the original six Working rows. Days 0-2 are now before Joined date;
-- the save must fail and leave the previously verified draft unchanged.
set local role authenticated;

do $$
begin
  begin
    perform public.save_production_roster_week(
      current_setting('eliscaretex_validation.week_start')::date,
      'MORNING',
      false,
      'Temporary Table override / Joined date validation.',
      current_setting('eliscaretex_validation.table_payload')::jsonb,
      (current_setting('eliscaretex_validation.saved_table')::jsonb ->> 'row_version')::integer,
      'Validate Joined date protection.',
      'DATABASE_TEST'
    );
    raise exception 'Pre-Joined-date Working save unexpectedly succeeded.';
  exception
    when others then
      if sqlerrm = 'Pre-Joined-date Working save unexpectedly succeeded.' then
        raise;
      end if;
      if position('not available before the Staff Master Joined date' in sqlerrm) = 0 then
        raise exception 'Unexpected Joined date error: %', sqlerrm;
      end if;
  end;
end;
$$;

reset role;

do $$
declare
  v_count integer;
  v_row_version integer;
begin
  select count(*) into v_count
  from public.production_roster_entries
  where roster_version_id =
    (current_setting('eliscaretex_validation.saved_table')::jsonb ->> 'roster_version_id')::uuid;

  if v_count <> 6 then
    raise exception 'Failed pre-join save changed draft entries; atomicity was broken.';
  end if;

  select row_version into v_row_version
  from public.production_roster_versions
  where roster_version_id =
    (current_setting('eliscaretex_validation.saved_table')::jsonb ->> 'roster_version_id')::uuid;

  if v_row_version <>
     (current_setting('eliscaretex_validation.saved_table')::jsonb ->> 'row_version')::integer then
    raise exception 'Failed pre-join save changed the draft row_version.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608080005_production_roster_table_day_override_and_joined_availability_validation',
  'table_day_override', true,
  'weekly_table_section_preserved', true,
  'joined_date_pool_gate', true,
  'pre_join_work_rejected', true,
  'failed_save_atomic', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
