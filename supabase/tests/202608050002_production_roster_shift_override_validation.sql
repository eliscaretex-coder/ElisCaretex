-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608050002_production_roster_shift_override_validation.sql
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
  'test', '202608050002_production_roster_shift_override_validation',
  'cross_shift_staff_pool', true,
  'selected_days_preserved', true,
  'default_shift_snapshot_preserved', true,
  'roster_shift_snapshot_preserved', true,
  'staff_master_unchanged', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
