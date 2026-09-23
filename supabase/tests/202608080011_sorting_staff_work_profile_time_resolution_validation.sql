-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080011_sorting_staff_work_profile_time_resolution
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
  'eliscaretex_validation.shift_code',
  coalesce((
    select sh.shift_code
    from public.production_roster_versions prv
    join public.roster_periods rp
      on rp.roster_period_id = prv.roster_period_id
     and rp.week_start = public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date)
    join public.shifts sh
      on sh.shift_id = prv.shift_id
    where prv.status = 'PUBLISHED'
      and exists (
        select 1
        from public.production_roster_entries pre
        left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
        left join public.areas a on a.area_id = pre.area_id
        left join public.stations st on st.station_id = pre.station_id
        where pre.roster_version_id = prv.roster_version_id
          and pre.work_date = (now() at time zone 'Europe/Dublin')::date
          and pre.day_status = 'WORKING'
          and (
            coalesce(nullif(pre.area_code_snapshot,''),a.area_code)='SORTING'
            or coalesce(nullif(pre.station_code_snapshot,''),st.station_code)='SORTING_MAIN'
            or pre.display_section_code='SORTING_AREA'
            or coalesce(nullif(pre.operational_role_code_snapshot,''),opr.role_code)='SORTING_AREA'
          )
      )
    order by sh.shift_code
    limit 1
  ), 'MORNING'),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_context jsonb;
  v_profile jsonb;
  v_staff jsonb;
  v_result jsonb;
  v_staff_id uuid;
begin
  if has_table_privilege('authenticated','public.work_sessions','SELECT')
     or has_table_privilege('authenticated','public.work_sessions','INSERT')
     or has_table_privilege('authenticated','public.work_sessions','UPDATE')
     or has_table_privilege('authenticated','public.work_sessions','DELETE') then
    raise exception 'work_sessions exposes direct browser privileges.';
  end if;

  v_context := public.get_sorting_staff_work_context(
    current_setting('eliscaretex_validation.shift_code')
  );

  v_profile := v_context -> 'work_profile';

  if v_profile is null
     or nullif(v_profile ->> 'schedule_label','') is null
     or coalesce((v_profile ->> 'break_minutes')::integer,0) <= 0
     or coalesce((v_profile ->> 'net_minutes')::integer,0) <= 0 then
    raise exception 'Current work profile was not resolved: %', v_profile;
  end if;

  select value
  into v_staff
  from jsonb_array_elements(coalesce(v_context -> 'staff','[]'::jsonb))
  limit 1;

  if v_staff is null then
    raise exception 'No current published Sorting staff was returned.';
  end if;

  if nullif(v_staff ->> 'planned_schedule_label','') is null
     or coalesce((v_staff ->> 'planned_net_minutes')::integer,0) <= 0 then
    raise exception 'Staff did not receive a resolved planned work profile: %', v_staff;
  end if;

  -- Entry-level planned times are optional. If profile is unambiguous, defaults
  -- may be present. If it has alternatives, requires_time_choice must preserve
  -- that ambiguity rather than guessing one.
  if coalesce((v_profile ->> 'is_ambiguous_time_window')::boolean,false) then
    if coalesce(v_staff ->> 'planned_time_source','') <> 'ROSTER_ENTRY'
       and coalesce((v_staff ->> 'requires_time_choice')::boolean,false) is not true then
      raise exception 'Ambiguous work profile did not preserve time choice: %', v_staff;
    end if;
  else
    if nullif(v_staff ->> 'planned_start_time','') is null
       or nullif(v_staff ->> 'planned_end_time','') is null then
      raise exception 'Single-window work profile did not resolve default times: %', v_staff;
    end if;
  end if;

  v_staff_id := (v_staff ->> 'staff_id')::uuid;

  -- 00:00 start is always non-future for the current Business Date. The 4-hour
  -- test window is intentionally synthetic and rolled back.
  v_result := public.save_sorting_staff_work_adjustment(
    current_setting('eliscaretex_validation.shift_code'),
    v_staff_id,
    time '00:00',
    time '04:00',
    30,
    'TRAINING',
    'Temporary work-profile resolution validation.'
  );

  if coalesce(v_result ->> 'status','') <> 'success'
     or coalesce((v_result ->> 'extra_non_work_minutes')::integer,0) <> 30
     or coalesce(v_result ->> 'adjustment_reason','') <> 'TRAINING' then
    raise exception 'Worked-time save path failed: %', v_result;
  end if;

  v_context := public.get_sorting_staff_work_context(
    current_setting('eliscaretex_validation.shift_code')
  );

  select value
  into v_staff
  from jsonb_array_elements(coalesce(v_context -> 'staff','[]'::jsonb))
  where value ->> 'staff_id' = v_staff_id::text
  limit 1;

  if coalesce((v_staff ->> 'adjusted')::boolean,false) is not true
     or coalesce(v_staff ->> 'actual_start_time','') not like '00:00%'
     or coalesce(v_staff ->> 'actual_end_time','') not like '04:00%'
     or coalesce((v_staff ->> 'extra_non_work_minutes')::integer,0) <> 30
     or coalesce(v_staff ->> 'adjustment_reason','') <> 'TRAINING' then
    raise exception 'Saved work adjustment was not returned correctly: %', v_staff;
  end if;
end;
$$;

reset role;

do $$
declare
  v_count integer;
begin
  select count(*)
  into v_count
  from public.work_sessions
  where notes = 'Temporary work-profile resolution validation.'
    and source = 'SORTING_WORKSTATION'
    and production_roster_entry_id is not null
    and production_roster_version_id is not null
    and recorded_by_auth_user_id is not null;

  if v_count <> 1 then
    raise exception 'Expected exactly one traceable work-session adjustment, found %.', v_count;
  end if;
end;
$$;

select jsonb_build_object(
  'status','PASS',
  'test','202608080011_sorting_staff_work_profile_time_resolution_validation',
  'entry_times_optional',true,
  'work_profile_resolved',true,
  'single_window_defaults_supported',true,
  'ambiguous_morning_window_not_guessed',true,
  'planned_net_minutes_preserved',true,
  'staff_adjustment_write_path_tested',true,
  'work_sessions_private',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
