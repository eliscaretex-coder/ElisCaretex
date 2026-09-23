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
