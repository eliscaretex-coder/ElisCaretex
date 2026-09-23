-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608100003_production_roster_mop_decision_and_sorting_selection_clarity
--
-- Roster rule:
--   Every Working Sorting day requires an explicit MOP coverage decision:
--     A) DEDICATED: exactly one Sorting staff row = MOP; remaining rows = CLOTHES
--     B) NO_DEDICATED_MOP: every Working Sorting row has sorting_work_mode = NULL
--
-- This prevents forgetting the MOP decision without forcing a dedicated person.
-- Published history remains immutable.
-- =====================================================================

begin;

create or replace function public.production_roster_assert_operational_rules(
  p_roster_version_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_version public.production_roster_versions%rowtype;
  v_period public.roster_periods%rowtype;
  v_bad record;
begin
  select * into v_version
  from public.production_roster_versions prv
  where prv.roster_version_id = p_roster_version_id;

  if not found then
    raise exception using errcode='P0002', message='Production Roster version not found.';
  end if;

  select * into v_period
  from public.roster_periods rp
  where rp.roster_period_id = v_version.roster_period_id;

  select sm.display_name, sm.joined_on, sm.deactivated_on
  into v_bad
  from public.production_roster_entries pre
  join public.staff_members sm on sm.staff_id = pre.staff_id
  where pre.roster_version_id = p_roster_version_id
  group by sm.staff_id, sm.display_name, sm.joined_on, sm.deactivated_on, sm.production_staff, sm.deleted_at
  having sm.production_staff is not true
      or sm.deleted_at is not null
      or (sm.joined_on is not null and sm.joined_on > v_period.week_start + 6)
      or (sm.deactivated_on is not null and sm.deactivated_on < v_period.week_start)
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        '%s is outside the Staff Master employment dates for this roster week. Remove the staff row before saving or publishing.',
        v_bad.display_name
      );
  end if;

  select sm.display_name, pre.work_date, sm.joined_on, sm.deactivated_on
  into v_bad
  from public.production_roster_entries pre
  join public.staff_members sm on sm.staff_id = pre.staff_id
  where pre.roster_version_id = p_roster_version_id
    and pre.day_status in ('WORKING','TRAINING','QUALITY_ANALYSIS')
    and (
      (sm.joined_on is not null and pre.work_date < sm.joined_on)
      or (sm.deactivated_on is not null and pre.work_date > sm.deactivated_on)
      or (
        sm.deactivated_on is null
        and (sm.active is not true or sm.roster_eligible is not true)
      )
    )
  order by pre.work_date, sm.display_name
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        '%s cannot be planned as working on %s because Staff Master employment/eligibility does not allow that date.',
        v_bad.display_name,
        to_char(v_bad.work_date,'YYYY-MM-DD')
      );
  end if;

  -- Valid Sorting daily decisions:
  -- 1) exactly one MOP, with all other Working Sorting rows explicitly CLOTHES;
  -- 2) zero MOP and every Working Sorting row NULL = explicit No dedicated MOP.
  select
    pre.work_date,
    count(*) as sorting_count,
    count(*) filter (where pre.sorting_work_mode = 'MOP') as mop_count,
    count(*) filter (where pre.sorting_work_mode = 'CLOTHES') as clothes_count,
    count(*) filter (where pre.sorting_work_mode is null) as null_count
  into v_bad
  from public.production_roster_entries pre
  where pre.roster_version_id = p_roster_version_id
    and pre.day_status = 'WORKING'
    and (
      pre.area_code_snapshot = 'SORTING'
      or pre.operational_role_code_snapshot = 'SORTING_AREA'
    )
  group by pre.work_date
  having not (
    (
      count(*) filter (where pre.sorting_work_mode = 'MOP') = 1
      and count(*) filter (where pre.sorting_work_mode is null) = 0
    )
    or
    (
      count(*) filter (where pre.sorting_work_mode = 'MOP') = 0
      and count(*) filter (where pre.sorting_work_mode is null) = count(*)
    )
  )
  order by pre.work_date
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        'Choose the Sorting MOP coverage for %s: select exactly one dedicated MOP staff member, or explicitly choose No dedicated MOP. Sorting staff=%s, MOP=%s, Clothes=%s, undecided=%s.',
        to_char(v_bad.work_date,'YYYY-MM-DD'),
        v_bad.sorting_count,
        v_bad.mop_count,
        v_bad.clothes_count,
        v_bad.null_count
      );
  end if;
end;
$$;

create or replace function public.save_production_roster_week(
  p_week_start date,
  p_shift_code text,
  p_include_sunday boolean,
  p_week_note text,
  p_entries jsonb,
  p_base_row_version integer default null,
  p_change_reason text default null,
  p_source_application text default 'PRODUCTION_ROSTER'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift public.shifts%rowtype;
  v_period_id uuid;
  v_draft public.production_roster_versions%rowtype;
  v_published public.production_roster_versions%rowtype;
  v_item jsonb;
  v_staff public.staff_members%rowtype;
  v_role public.operational_roles%rowtype;
  v_area public.areas%rowtype;
  v_station public.stations%rowtype;
  v_resolved_base record;
  v_work_date date;
  v_day_status text;
  v_assignment_type text;
  v_role_code text;
  v_area_code text;
  v_station_code text;
  v_requested_station_code text;
  v_display_section_code text;
  v_sorting_work_mode text;
  v_expected_days integer := case when p_include_sunday then 7 else 6 end;
  v_entry_count integer;
  v_staff_count integer;
  v_actor_staff uuid := public.current_staff_id();
  v_next_version integer;
  v_staff_default_shift public.shifts%rowtype;
  v_cross_shift boolean;
  v_shift_override_confirmed boolean;
  v_conflict_shift_name text;
  v_shift_override_staff_count integer := 0;
begin
  perform public.require_production_roster_manage_role();

  if v_week_start < public.production_roster_week_start(current_date) then
    raise exception using errcode = '55000', message = 'Past Production Roster weeks are read-only.';
  end if;

  if p_entries is null or jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) = 0 then
    raise exception using errcode = '22023', message = 'The Production Roster must contain staff entries.';
  end if;

  select * into v_shift
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code)) and s.active = true and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid or inactive shift.';
  end if;

  insert into public.roster_periods (week_start, status, created_by)
  values (v_week_start, 'DRAFT', auth.uid())
  on conflict (week_start) do nothing;

  select rp.roster_period_id into v_period_id
  from public.roster_periods rp
  where rp.week_start = v_week_start
  for update;

  select * into v_draft
  from public.production_roster_versions prv
  where prv.roster_period_id = v_period_id
    and prv.shift_id = v_shift.shift_id
    and prv.status = 'DRAFT'
  for update;

  if v_draft.roster_version_id is not null then
    if p_base_row_version is null or p_base_row_version <> v_draft.row_version then
      raise exception using errcode = '40001', message = 'The Production Roster was changed by another user. Reload before saving.';
    end if;
  else
    select * into v_published
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id
      and prv.shift_id = v_shift.shift_id
      and prv.status = 'PUBLISHED'
    limit 1;

    select coalesce(max(prv.version_number), 0) + 1 into v_next_version
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id and prv.shift_id = v_shift.shift_id;

    insert into public.production_roster_versions (
      roster_period_id, shift_id, version_number, status, include_sunday,
      week_note, based_on_version_id, saved_at, saved_by, created_by, updated_by
    ) values (
      v_period_id, v_shift.shift_id, v_next_version, 'DRAFT', p_include_sunday,
      nullif(trim(p_week_note), ''), v_published.roster_version_id,
      now(), auth.uid(), auth.uid(), auth.uid()
    ) returning * into v_draft;

    insert into public.production_roster_events (
      roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason, metadata
    ) values (
      v_draft.roster_version_id, 'DRAFT_CREATED', auth.uid(), v_actor_staff,
      nullif(trim(p_change_reason), ''),
      jsonb_build_object('week_start', v_week_start, 'shift_code', v_shift.shift_code)
    );
  end if;

  delete from public.production_roster_shift_overrides pro
  where pro.roster_version_id = v_draft.roster_version_id;

  delete from public.production_roster_entries pre
  where pre.roster_version_id = v_draft.roster_version_id;

  for v_item in select value from jsonb_array_elements(p_entries)
  loop
    v_work_date := (v_item ->> 'work_date')::date;
    v_day_status := upper(coalesce(nullif(trim(v_item ->> 'day_status'), ''), 'WORKING'));
    v_assignment_type := upper(coalesce(nullif(trim(v_item ->> 'assignment_type'), ''), 'BASE'));
    v_role_code := upper(nullif(trim(v_item ->> 'operational_role_code'), ''));
    v_area_code := upper(nullif(trim(v_item ->> 'area_code'), ''));
    v_requested_station_code := upper(nullif(trim(v_item ->> 'station_code'), ''));
    v_station_code := v_requested_station_code;
    v_display_section_code := upper(nullif(trim(v_item ->> 'display_section_code'), ''));
    v_sorting_work_mode := upper(nullif(trim(v_item ->> 'sorting_work_mode'), ''));

    if v_work_date < v_week_start
       or v_work_date > v_week_start + (v_expected_days - 1) then
      raise exception using errcode = '22023', message = 'A roster entry is outside the selected week.';
    end if;

    if v_day_status not in ('WORKING', 'OFF', 'SICK', 'HOLIDAY', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using errcode = '22023', message = 'Invalid Production Roster day status.';
    end if;

    if v_assignment_type not in ('BASE', 'COVER') then
      raise exception using errcode = '22023', message = 'Invalid Production Roster assignment type.';
    end if;

    if v_assignment_type = 'COVER' and v_day_status <> 'WORKING' then
      raise exception using errcode = '22023', message = 'COVER can only be used with Working status.';
    end if;

    select * into v_staff
    from public.staff_members sm
    where sm.staff_id = (v_item ->> 'staff_id')::uuid
      and sm.production_staff = true
      and sm.deleted_at is null;

    if not found then
      raise exception using errcode = '22023', message = 'The roster contains deleted or non-production staff.';
    end if;

    select * into v_staff_default_shift
    from public.shifts sh
    where sh.shift_id = v_staff.default_shift_id
      and sh.active = true
      and sh.deleted_at is null;

    if not found then
      raise exception using errcode = '22023', message = 'The staff member does not have a valid Staff Master default shift.';
    end if;

    v_cross_shift := v_staff_default_shift.shift_id <> v_shift.shift_id;
    v_shift_override_confirmed := coalesce(nullif(v_item ->> 'shift_override_confirmed', '')::boolean, false);

    if v_cross_shift and not v_shift_override_confirmed then
      raise exception using
        errcode = '22023',
        message = format(
          '%s belongs to %s in Staff Master. Remove the row or add it explicitly as a temporary %s shift override.',
          v_staff.display_name,
          v_staff_default_shift.shift_name,
          v_shift.shift_name
        );
    end if;

    if v_staff.joined_on is not null
       and v_work_date < v_staff.joined_on
       and v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using errcode = '22023', message = 'The staff member is not available before the Staff Master Joined date.';
    end if;


    if v_staff.deactivated_on is not null
       and v_work_date > v_staff.deactivated_on
       and v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using
        errcode = '22023',
        message = format(
          '%s cannot be planned after the Staff Master exit date %s.',
          v_staff.display_name,
          to_char(v_staff.deactivated_on, 'YYYY-MM-DD')
        );
    end if;

    if v_staff.deactivated_on is null
       and (v_staff.active is not true or v_staff.roster_eligible is not true)
       and v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using
        errcode = '22023',
        message = format('%s is inactive or not roster-eligible in Staff Master.', v_staff.display_name);
    end if;

    if v_cross_shift and v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then
      v_conflict_shift_name := null;

      with other_active_version as (
        select distinct on (prv.shift_id)
          prv.roster_version_id,
          osh.shift_name
        from public.production_roster_versions prv
        join public.shifts osh on osh.shift_id = prv.shift_id
        where prv.roster_period_id = v_period_id
          and prv.shift_id <> v_shift.shift_id
          and prv.status in ('DRAFT', 'PUBLISHED')
        order by
          prv.shift_id,
          case prv.status when 'DRAFT' then 1 else 2 end,
          prv.version_number desc
      )
      select oav.shift_name
      into v_conflict_shift_name
      from other_active_version oav
      join public.production_roster_entries other_entry
        on other_entry.roster_version_id = oav.roster_version_id
       and other_entry.staff_id = v_staff.staff_id
       and other_entry.work_date = v_work_date
      where other_entry.day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS')
      limit 1;

      if v_conflict_shift_name is not null then
        raise exception using
          errcode = '22023',
          message = format(
            '%s is already planned in %s on %s. Review that shift and make the day non-working before saving the temporary %s override.',
            v_staff.display_name,
            v_conflict_shift_name,
            to_char(v_work_date, 'YYYY-MM-DD'),
            v_shift.shift_name
          );
      end if;
    end if;

    if v_display_section_code is null then
      select public.production_roster_default_display_section(opr.role_code, st.station_code)
      into v_display_section_code
      from public.staff_members sm
      left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
      left join public.stations st on st.station_id = sm.default_station_id
      where sm.staff_id = v_staff.staff_id;
    end if;

    if v_display_section_code not in (
      'SUPERVISOR', 'SORTING_AREA', 'LABEL',
      'FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3', 'FINISH_OTHER',
      'CLEANER', 'SUPPORT_ROLE'
    ) then
      raise exception using errcode = '22023', message = 'Invalid Production Roster display section.';
    end if;

    -- The weekly row section remains authoritative for the normal role/area.
    -- Finish Table rows intentionally allow a day-level override between
    -- Table 1, Table 2 and Table 3 without moving the weekly row. Changing
    -- SHOW ROW IN resets the frontend days to the new weekly table. SUPPORT_ROLE
    -- remains the broader mixed-location mode; COVER remains day-specific.
    if v_assignment_type = 'BASE'
       and v_day_status in ('WORKING', 'QUALITY_ANALYSIS')
       and v_display_section_code <> 'SUPPORT_ROLE' then
      select *
      into v_resolved_base
      from public.production_roster_resolve_display_assignment(
        v_display_section_code,
        v_role_code
      );

      v_role_code := v_resolved_base.role_code;
      v_area_code := v_resolved_base.area_code;

      if v_display_section_code in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3')
         and v_requested_station_code in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3') then
        v_station_code := v_requested_station_code;
      else
        v_station_code := v_resolved_base.station_code;
      end if;
    end if;

    v_role.operational_role_id := null;
    v_role.role_code := null;
    v_role.role_name := null;
    v_role.allow_as_cover := false;
    v_area.area_id := null;
    v_area.area_code := null;
    v_area.area_name := null;
    v_station.station_id := null;
    v_station.station_code := null;
    v_station.station_name := null;

    if v_day_status in ('WORKING', 'QUALITY_ANALYSIS') then
      if v_role_code is null or v_area_code is null then
        raise exception using errcode = '22023', message = 'Working assignments require an operational role and area.';
      end if;

      select * into v_role from public.operational_roles opr
      where opr.role_code = v_role_code and opr.active = true and opr.deleted_at is null;
      if not found then
        raise exception using errcode = '22023', message = 'Invalid operational role in roster entry.';
      end if;

      select * into v_area from public.areas a
      where a.area_code = v_area_code and a.active = true and a.deleted_at is null;
      if not found then
        raise exception using errcode = '22023', message = 'Invalid area in roster entry.';
      end if;

      if v_station_code is not null then
        select * into v_station from public.stations st
        where st.station_code = v_station_code
          and st.area_id = v_area.area_id
          and st.active = true
          and st.deleted_at is null;
        if not found then
          raise exception using errcode = '22023', message = 'The selected station does not belong to the selected area.';
        end if;
      end if;

      if v_assignment_type = 'COVER' then
        if v_role.allow_as_cover is not true
           or public.production_roster_cover_currently_authorised(
             v_staff.staff_id,
             v_role.operational_role_id
           ) is not true then
          raise exception using errcode = '22023', message = 'The staff member is not authorised for the selected COVER role.';
        end if;
      end if;
    else
      v_assignment_type := 'BASE';
      v_role_code := null;
      v_area_code := null;
      v_station_code := null;
    end if;

    if v_day_status = 'WORKING'
       and (v_area.area_code = 'SORTING' or v_role.role_code = 'SORTING_AREA') then
      -- NULL is an intentional "NO_DEDICATED_MOP" daily decision only when all
      -- Working Sorting rows for that date are NULL. The operational rule guard
      -- validates the complete day after all entries are written.
      if v_sorting_work_mode is not null
         and v_sorting_work_mode not in ('CLOTHES', 'MOP') then
        raise exception using errcode = '22023', message = 'Sorting work mode must be CLOTHES, MOP or null for an explicit No dedicated MOP day.';
      end if;
    else
      v_sorting_work_mode := null;
    end if;

    if v_cross_shift then
      insert into public.production_roster_shift_overrides (
        roster_version_id,
        staff_id,
        staff_default_shift_code_snapshot,
        staff_default_shift_name_snapshot,
        roster_shift_code_snapshot,
        roster_shift_name_snapshot,
        confirmed_days,
        source_application,
        created_by,
        updated_by
      ) values (
        v_draft.roster_version_id,
        v_staff.staff_id,
        v_staff_default_shift.shift_code,
        v_staff_default_shift.shift_name,
        v_shift.shift_code,
        v_shift.shift_name,
        case
          when v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then array[v_work_date]
          else '{}'::date[]
        end,
        p_source_application,
        auth.uid(),
        auth.uid()
      )
      on conflict (roster_version_id, staff_id) do update
      set confirmed_days = public.production_roster_shift_overrides.confirmed_days || excluded.confirmed_days,
          source_application = excluded.source_application,
          updated_at = now(),
          updated_by = auth.uid();
    end if;

    insert into public.production_roster_entries (
      roster_version_id, work_date, staff_id, day_status, assignment_type,
      operational_role_id, area_id, station_id,
      planned_start_time, planned_end_time, notes, display_section_code, sorting_work_mode,
      staff_display_name_snapshot, employee_code_snapshot,
      shift_code_snapshot, shift_name_snapshot,
      operational_role_code_snapshot, operational_role_name_snapshot,
      area_code_snapshot, area_name_snapshot,
      station_code_snapshot, station_name_snapshot,
      staff_primary_role_code_snapshot, staff_primary_role_name_snapshot,
      staff_default_area_code_snapshot, staff_default_area_name_snapshot,
      staff_default_station_code_snapshot, staff_default_station_name_snapshot,
      fire_training_snapshot, first_aid_training_snapshot, eod_capable_snapshot,
      created_by, updated_by
    ) values (
      v_draft.roster_version_id,
      v_work_date,
      v_staff.staff_id,
      v_day_status,
      v_assignment_type,
      v_role.operational_role_id,
      v_area.area_id,
      v_station.station_id,
      nullif(v_item ->> 'planned_start_time', '')::time,
      nullif(v_item ->> 'planned_end_time', '')::time,
      nullif(trim(v_item ->> 'notes'), ''),
      v_display_section_code,
      v_sorting_work_mode,
      v_staff.display_name,
      v_staff.employee_code,
      v_shift.shift_code,
      v_shift.shift_name,
      v_role.role_code,
      v_role.role_name,
      v_area.area_code,
      v_area.area_name,
      v_station.station_code,
      v_station.station_name,
      (select opr.role_code from public.operational_roles opr where opr.operational_role_id = v_staff.primary_operational_role_id),
      (select opr.role_name from public.operational_roles opr where opr.operational_role_id = v_staff.primary_operational_role_id),
      (select a.area_code from public.areas a where a.area_id = v_staff.default_area_id),
      (select a.area_name from public.areas a where a.area_id = v_staff.default_area_id),
      (select st.station_code from public.stations st where st.station_id = v_staff.default_station_id),
      (select st.station_name from public.stations st where st.station_id = v_staff.default_station_id),
      v_staff.fire_training,
      v_staff.first_aid_training,
      v_staff.eod_capable,
      auth.uid(),
      auth.uid()
    );
  end loop;

  select count(*), count(distinct staff_id)
  into v_entry_count, v_staff_count
  from public.production_roster_entries pre
  where pre.roster_version_id = v_draft.roster_version_id;

  select count(*)
  into v_shift_override_staff_count
  from public.production_roster_shift_overrides pro
  where pro.roster_version_id = v_draft.roster_version_id;

  if exists (
    select 1
    from public.production_roster_shift_overrides pro
    where pro.roster_version_id = v_draft.roster_version_id
      and cardinality(pro.confirmed_days) = 0
  ) then
    raise exception using
      errcode = '22023',
      message = 'A temporary shift override must contain at least one planned day.';
  end if;

  if v_staff_count = 0 or v_entry_count <> v_staff_count * v_expected_days then
    raise exception using errcode = '22023', message = 'Every included staff member must have exactly one entry for each visible day.';
  end if;

  if exists (
    select 1
    from public.production_roster_entries pre
    where pre.roster_version_id = v_draft.roster_version_id
    group by pre.staff_id
    having count(distinct pre.display_section_code) <> 1
  ) then
    raise exception using errcode = '22023', message = 'Each staff member must have one weekly display section per roster version.';
  end if;

  perform public.production_roster_assert_operational_rules(v_draft.roster_version_id);

  update public.production_roster_versions
  set include_sunday = p_include_sunday,
      week_note = nullif(trim(p_week_note), ''),
      saved_at = now(),
      saved_by = auth.uid(),
      updated_by = auth.uid(),
      row_version = row_version + 1
  where roster_version_id = v_draft.roster_version_id
  returning * into v_draft;

  insert into public.production_roster_events (
    roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason,
    metadata
  ) values (
    v_draft.roster_version_id, 'DRAFT_SAVED', auth.uid(), v_actor_staff,
    nullif(trim(p_change_reason), ''),
    jsonb_build_object(
      'entry_count', v_entry_count,
      'staff_count', v_staff_count,
      'shift_override_staff_count', v_shift_override_staff_count,
      'source_application', p_source_application
    )
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_DRAFT_SAVED',
    'production_roster_versions', v_draft.roster_version_id::text,
    jsonb_build_object(
      'week_start', v_week_start,
      'shift_code', v_shift.shift_code,
      'version_number', v_draft.version_number,
      'shift_override_staff_count', v_shift_override_staff_count
    ),
    nullif(trim(p_change_reason), ''), p_source_application
  );

  return jsonb_build_object(
    'roster_version_id', v_draft.roster_version_id,
    'version_number', v_draft.version_number,
    'status', v_draft.status,
    'row_version', v_draft.row_version,
    'entry_count', v_entry_count,
    'staff_count', v_staff_count,
    'shift_override_staff_count', v_shift_override_staff_count,
    'saved_at', v_draft.saved_at
  );
end;
$$;


create or replace function public.get_sorting_staff_work_context_v2(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_base jsonb;
  v_business_date date;
  v_shift_id uuid;
  v_staff jsonb := '[]'::jsonb;
  v_mop_staff_id uuid;
  v_mop_staff_name text;
  v_planned_mop_coverage text := 'UNDECIDED';
begin
  v_base := public.get_sorting_staff_work_context(p_shift_code);
  v_business_date := (v_base ->> 'business_date')::date;

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code = upper(trim(coalesce(p_shift_code, '')))
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  select case
    when count(*) filter (where pre.sorting_work_mode = 'MOP') = 1
      then 'DEDICATED'
    when count(*) > 0
         and count(*) filter (where pre.sorting_work_mode is null) = count(*)
      then 'NO_DEDICATED_MOP'
    when count(*) = 0
      then 'NO_SORTING_PLAN'
    else 'UNDECIDED'
  end
  into v_planned_mop_coverage
  from jsonb_array_elements(coalesce(v_base -> 'staff', '[]'::jsonb)) staff_row
  left join public.production_roster_entries pre
    on pre.roster_entry_id = nullif(staff_row.value ->> 'roster_entry_id', '')::uuid;

  select coalesce(jsonb_agg(
    staff_row.value ||
    jsonb_build_object(
      'work_mode', coalesce(mode_row.work_mode, pre.sorting_work_mode, 'CLOTHES'),
      'work_mode_explicit', mode_row.sorting_daily_staff_mode_id is not null,
      'work_mode_planned', mode_row.sorting_daily_staff_mode_id is null and pre.sorting_work_mode is not null,
      'work_mode_source', case
        when mode_row.sorting_daily_staff_mode_id is not null then 'ACTUAL_OVERRIDE'
        when pre.sorting_work_mode is not null then 'PUBLISHED_ROSTER'
        when v_planned_mop_coverage = 'NO_DEDICATED_MOP' then 'PUBLISHED_NO_DEDICATED_MOP'
        else 'DEFAULT_CLOTHES'
      end
    )
    order by lower(staff_row.value ->> 'display_name')
  ), '[]'::jsonb)
  into v_staff
  from jsonb_array_elements(coalesce(v_base -> 'staff', '[]'::jsonb)) staff_row
  left join public.production_roster_entries pre
    on pre.roster_entry_id = nullif(staff_row.value ->> 'roster_entry_id', '')::uuid
  left join public.sorting_daily_staff_modes mode_row
    on mode_row.business_date = v_business_date
   and mode_row.shift_id = v_shift_id
   and mode_row.staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid;

  select
    nullif(staff_row.value ->> 'staff_id', '')::uuid,
    staff_row.value ->> 'display_name'
  into v_mop_staff_id, v_mop_staff_name
  from jsonb_array_elements(v_staff) staff_row
  where staff_row.value ->> 'work_mode' = 'MOP'
  limit 1;

  return v_base || jsonb_build_object(
    'staff', v_staff,
    'mop_staff_id', v_mop_staff_id,
    'mop_staff_name', v_mop_staff_name,
    'planned_mop_coverage', v_planned_mop_coverage,
    'no_dedicated_mop_planned', v_planned_mop_coverage = 'NO_DEDICATED_MOP',
    'mop_assignment_missing',
      v_mop_staff_id is null
      and v_planned_mop_coverage not in ('NO_DEDICATED_MOP','NO_SORTING_PLAN'),
    'work_mode_source', 'ACTUAL_OVERRIDE_THEN_PUBLISHED_ROSTER'
  );
end;
$$;

revoke all on function public.production_roster_assert_operational_rules(uuid)
  from public, anon, authenticated;

grant execute on function public.save_production_roster_week(date,text,boolean,text,jsonb,integer,text,text)
  to authenticated;
grant execute on function public.get_sorting_staff_work_context_v2(text)
  to authenticated;

comment on column public.production_roster_entries.sorting_work_mode is
  'Planned Sorting subassignment. MOP/CLOTHES means a dedicated MOP decision; NULL on every Working Sorting row for the date means explicit No dedicated MOP.';

comment on function public.production_roster_assert_operational_rules(uuid) is
  'Private Roster guard for Staff Master employment dates and an explicit daily Sorting MOP decision: exactly one dedicated MOP or explicit No dedicated MOP.';

commit;
