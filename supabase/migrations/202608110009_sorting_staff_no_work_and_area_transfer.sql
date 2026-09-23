-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110009_sorting_staff_no_work_and_area_transfer
--
-- Sorting Staff simplification:
-- - Mark absent becomes the broader operator action "No Work" in Sorting.
-- - A staff member can be recorded as not working in Sorting because they are
--   Sick / No show / Training / Other, or because their Actual position moved
--   to another operational area.
-- - Area movement is Actual operational evidence in work_sessions and never
--   rewrites the PUBLISHED Production Roster.
-- - A controlled cross-area read contract exposes incoming Actual transfers so
--   future Finish/MOP operational screens can show staff moved into the area.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Training is a valid reason for not working in Sorting.
--    attendance_status remains the existing Sorting-specific PRESENT/ABSENT
--    overlay; TRAINING is deliberately distinct from NO_SHOW.
-- ---------------------------------------------------------------------

alter table public.sorting_daily_staff_attendance
  drop constraint if exists sorting_daily_staff_attendance_absence_reason_check;

alter table public.sorting_daily_staff_attendance
  add constraint sorting_daily_staff_attendance_absence_reason_check
  check (absence_reason is null or absence_reason in ('SICK','NO_SHOW','TRAINING','OTHER'));

-- ---------------------------------------------------------------------
-- 2. Destination options use Area master data rather than browser constants.
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_staff_no_work_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_areas jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'area_code', a.area_code,
        'area_name', a.area_name
      ) order by a.sort_order, a.area_name
    ),
    '[]'::jsonb
  )
  into v_areas
  from public.areas a
  where a.active = true
    and a.deleted_at is null
    and a.area_code in ('FINISH','MOP','WASHING','DISTRIBUTION');

  return jsonb_build_object(
    'absence_reasons', jsonb_build_array(
      jsonb_build_object('code','SICK','label','Sick'),
      jsonb_build_object('code','NO_SHOW','label','No show'),
      jsonb_build_object('code','TRAINING','label','Training'),
      jsonb_build_object('code','OTHER','label','Other')
    ),
    'destination_areas', v_areas
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Actual area transfer from Sorting.
--    work_sessions remains the central Actual layer.
-- ---------------------------------------------------------------------

create or replace function public.set_sorting_staff_actual_area(
  p_shift_code text,
  p_staff_id uuid,
  p_target_area_code text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_target_code text := upper(trim(coalesce(p_target_area_code, '')));
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift public.shifts%rowtype;
  v_target_area public.areas%rowtype;
  v_sorting_area_id uuid;
  v_target jsonb;
  v_context jsonb;
  v_staff_name text;
  v_session public.work_sessions%rowtype;
  v_old_data jsonb;
  v_new public.work_sessions%rowtype;
  v_roster_entry_id uuid;
  v_roster_version_id uuid;
  v_break_minutes integer := 0;
  v_actor_staff_id uuid;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;

  if v_target_code = '' or v_target_code = 'SORTING' then
    raise exception using errcode = '22023', message = 'Choose another operational area.';
  end if;

  if v_notes is not null and length(v_notes) > 1000 then
    raise exception using errcode = '22023', message = 'Notes must be 1000 characters or fewer.';
  end if;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  select *
  into v_target_area
  from public.areas a
  where a.area_code = v_target_code
    and a.active = true
    and a.deleted_at is null
    and a.area_code in ('FINISH','MOP','WASHING','DISTRIBUTION')
  limit 1;

  if not found then
    raise exception using errcode = '22023', message = 'Selected destination area is not available for an Actual transfer.';
  end if;

  select a.area_id
  into v_sorting_area_id
  from public.areas a
  where a.area_code = 'SORTING'
    and a.active = true
    and a.deleted_at is null
  limit 1;

  v_context := public.get_sorting_staff_work_context_v2(v_shift_code);

  select value
  into v_target
  from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
  where value ->> 'staff_id' = p_staff_id::text
  limit 1;

  if v_target is null then
    raise exception using errcode = '22023', message = 'The selected staff member is not currently shown in Sorting for this shift.';
  end if;

  v_staff_name := coalesce(v_target ->> 'display_name', 'Selected staff member');
  v_roster_entry_id := nullif(v_target ->> 'roster_entry_id', '')::uuid;
  v_roster_version_id := nullif(v_target ->> 'roster_version_id', '')::uuid;
  v_break_minutes := coalesce(nullif(v_target ->> 'standard_break_minutes', '')::integer, 0);
  v_actor_staff_id := public.current_staff_id();

  if exists (
    select 1
    from public.sorting_daily_staff_attendance att
    where att.business_date = v_business_date
      and att.shift_id = v_shift.shift_id
      and att.staff_id = p_staff_id
      and att.attendance_status = 'ABSENT'
  ) then
    raise exception using
      errcode = '22023',
      message = format('%s is already recorded as not working in Sorting. Correct that status before moving the staff member to another area.', v_staff_name);
  end if;

  if exists (
    select 1
    from public.work_sessions ws
    where ws.work_date = v_business_date
      and ws.shift_id = v_shift.shift_id
      and ws.staff_id = p_staff_id
      and ws.source = 'SORTING_AREA_TRANSFER'
      and ws.status <> 'CANCELLED'
  ) then
    raise exception using
      errcode = '23505',
      message = format('%s already has an active Actual area transfer for this shift.', v_staff_name);
  end if;

  -- "No Work" is a whole-shift Sorting correction. Do not let it erase or
  -- contradict already-recorded Sorting production evidence.
  if exists (
    select 1
    from public.sorting_wash_runs wr
    where wr.business_date = v_business_date
      and wr.shift_id = v_shift.shift_id
      and wr.operator_staff_id = p_staff_id
      and wr.status = 'RECORDED'
  ) or exists (
    select 1
    from public.sorting_trolley_intakes sti
    where sti.business_date = v_business_date
      and sti.shift_id = v_shift.shift_id
      and sti.operator_staff_id = p_staff_id
  ) then
    raise exception using
      errcode = '22023',
      message = format('%s already has recorded Sorting activity for this Business Date and Shift. Correct that activity before replacing the whole-shift Sorting position.', v_staff_name);
  end if;

  -- Reuse an existing Actual work session when Edit time / manual Actual
  -- position already created one. Otherwise create the first Actual session.
  if nullif(v_target ->> 'work_session_id', '') is not null then
    select *
    into v_session
    from public.work_sessions ws
    where ws.work_session_id = (v_target ->> 'work_session_id')::uuid
      and ws.status <> 'CANCELLED';
  end if;

  if v_session.work_session_id is null and v_roster_entry_id is not null then
    select *
    into v_session
    from public.work_sessions ws
    where ws.production_roster_entry_id = v_roster_entry_id
      and ws.status <> 'CANCELLED'
    order by ws.updated_at desc
    limit 1;
  end if;

  if v_session.work_session_id is not null then
    v_old_data := to_jsonb(v_session);

    update public.work_sessions
    set area_id = v_target_area.area_id,
        station_id = null,
        source = 'SORTING_AREA_TRANSFER',
        notes = case
          when v_notes is null then notes
          else v_notes
        end,
        recorded_by_auth_user_id = auth.uid(),
        row_version = row_version + 1,
        updated_at = now()
    where work_session_id = v_session.work_session_id
    returning * into v_new;
  else
    insert into public.work_sessions (
      production_roster_entry_id,
      production_roster_version_id,
      work_date,
      staff_id,
      area_id,
      station_id,
      shift_id,
      actual_start_at,
      actual_end_at,
      break_minutes,
      extra_non_work_minutes,
      adjustment_reason,
      status,
      source,
      confirmed_by,
      notes,
      recorded_by_auth_user_id,
      row_version,
      updated_at
    )
    values (
      v_roster_entry_id,
      v_roster_version_id,
      v_business_date,
      p_staff_id,
      v_target_area.area_id,
      null,
      v_shift.shift_id,
      null,
      null,
      v_break_minutes,
      0,
      'NONE',
      'OPEN',
      'SORTING_AREA_TRANSFER',
      v_actor_staff_id,
      v_notes,
      auth.uid(),
      1,
      now()
    )
    returning * into v_new;
  end if;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    v_actor_staff_id,
    'SORTING_ACTUAL_AREA_TRANSFERRED',
    'work_sessions',
    v_new.work_session_id::text,
    v_old_data,
    to_jsonb(v_new),
    concat('Actual position moved from Sorting Area to ', v_target_area.area_name,
      case when v_notes is null then '' else ': ' || v_notes end),
    'SORTING_V2'
  );

  return jsonb_build_object(
    'status', 'success',
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'staff_id', p_staff_id,
    'staff_name', v_staff_name,
    'work_session_id', v_new.work_session_id,
    'actual_area_code', v_target_area.area_code,
    'actual_area_name', v_target_area.area_name,
    'roster_unchanged', true,
    'audit_recorded', true,
    'message', format('%s moved to %s for Actual staffing. The published Roster was not changed.', v_staff_name, v_target_area.area_name)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Restore a transferred person to Sorting Actual staffing.
-- ---------------------------------------------------------------------

create or replace function public.restore_sorting_staff_actual_area(
  p_shift_code text,
  p_staff_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_shift public.shifts%rowtype;
  v_session public.work_sessions%rowtype;
  v_old_data jsonb;
  v_new public.work_sessions%rowtype;
  v_sorting_area_id uuid;
  v_sorting_station_id uuid;
  v_planned_sorting boolean := false;
  v_staff_name text;
  v_actor_staff_id uuid;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;

  if v_reason is not null and length(v_reason) > 1000 then
    raise exception using errcode = '22023', message = 'Reason must be 1000 characters or fewer.';
  end if;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  select a.area_id
  into v_sorting_area_id
  from public.areas a
  where a.area_code = 'SORTING'
    and a.active = true
    and a.deleted_at is null
  limit 1;

  select st.station_id
  into v_sorting_station_id
  from public.stations st
  join public.areas a on a.area_id = st.area_id
  where st.station_code = 'SORTING_MAIN'
    and a.area_code = 'SORTING'
    and st.active = true
    and st.deleted_at is null
  limit 1;

  select ws.*
  into v_session
  from public.work_sessions ws
  where ws.work_date = v_business_date
    and ws.shift_id = v_shift.shift_id
    and ws.staff_id = p_staff_id
    and ws.source = 'SORTING_AREA_TRANSFER'
    and ws.status <> 'CANCELLED'
  order by ws.updated_at desc
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'No active Sorting area transfer was found for this staff member.';
  end if;

  select sm.display_name
  into v_staff_name
  from public.staff_members sm
  where sm.staff_id = p_staff_id;

  if v_session.production_roster_entry_id is not null then
    select exists (
      select 1
      from public.production_roster_entries pre
      left join public.areas a on a.area_id = pre.area_id
      left join public.stations st on st.station_id = pre.station_id
      left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
      where pre.roster_entry_id = v_session.production_roster_entry_id
        and pre.day_status = 'WORKING'
        and (
          coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) = 'SORTING'
          or coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) = 'SORTING_MAIN'
          or pre.display_section_code = 'SORTING_AREA'
          or coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) = 'SORTING_AREA'
        )
    ) into v_planned_sorting;
  end if;

  v_actor_staff_id := public.current_staff_id();
  v_old_data := to_jsonb(v_session);

  if v_planned_sorting
     and v_session.actual_start_at is null
     and v_session.actual_end_at is null
     and coalesce(v_session.extra_non_work_minutes, 0) = 0
     and coalesce(v_session.adjustment_reason, 'NONE') = 'NONE' then
    update public.work_sessions
    set status = 'CANCELLED',
        notes = coalesce(v_reason, notes),
        recorded_by_auth_user_id = auth.uid(),
        row_version = row_version + 1,
        updated_at = now()
    where work_session_id = v_session.work_session_id
    returning * into v_new;
  else
    update public.work_sessions
    set area_id = v_sorting_area_id,
        station_id = v_sorting_station_id,
        source = case when v_planned_sorting then 'SORTING_WORK_ADJUSTMENT' else 'SORTING_MANUAL_POSITION' end,
        notes = coalesce(v_reason, notes),
        recorded_by_auth_user_id = auth.uid(),
        row_version = row_version + 1,
        updated_at = now()
    where work_session_id = v_session.work_session_id
    returning * into v_new;
  end if;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    v_actor_staff_id,
    'SORTING_ACTUAL_AREA_RESTORED',
    'work_sessions',
    v_new.work_session_id::text,
    v_old_data,
    to_jsonb(v_new),
    coalesce(v_reason, 'Actual position restored to Sorting Area.'),
    'SORTING_V2'
  );

  return jsonb_build_object(
    'status', 'success',
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'staff_id', p_staff_id,
    'staff_name', v_staff_name,
    'roster_unchanged', true,
    'audit_recorded', true,
    'message', format('%s restored to Sorting Actual staffing. The published Roster was not changed.', coalesce(v_staff_name, 'Staff member'))
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Cross-area incoming transfer read model.
--    This is deliberately independent from a future Finish/MOP UI.
-- ---------------------------------------------------------------------

create or replace function public.get_operational_area_incoming_staff(
  p_area_code text,
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_area_code text := upper(trim(coalesce(p_area_code, '')));
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_area public.areas%rowtype;
  v_shift public.shifts%rowtype;
  v_rows jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication is required.';
  end if;

  if not public.has_any_role(array[
    'ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR',
    'FINISH_OPERATOR','MOP_OPERATOR','DISTRIBUTION_OPERATOR'
  ]) then
    raise exception using errcode = '42501', message = 'Operational staff access is required.';
  end if;

  select *
  into v_area
  from public.areas a
  where a.area_code = v_area_code
    and a.active = true
    and a.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'Selected operational area is not available.';
  end if;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'work_session_id', ws.work_session_id,
      'staff_id', sm.staff_id,
      'display_name', sm.display_name,
      'business_date', ws.work_date,
      'shift_code', v_shift.shift_code,
      'planned_area_code', coalesce(nullif(pre.area_code_snapshot, ''), planned_area.area_code),
      'planned_station_code', coalesce(nullif(pre.station_code_snapshot, ''), planned_station.station_code),
      'actual_area_code', v_area.area_code,
      'actual_area_name', v_area.area_name,
      'actual_start_time', case when ws.actual_start_at is null then null else (ws.actual_start_at at time zone 'Europe/Dublin')::time end,
      'actual_end_time', case when ws.actual_end_at is null then null else (ws.actual_end_at at time zone 'Europe/Dublin')::time end,
      'source', ws.source,
      'notes', ws.notes,
      'updated_at', ws.updated_at
    ) order by lower(sm.display_name)
  ), '[]'::jsonb)
  into v_rows
  from public.work_sessions ws
  join public.staff_members sm on sm.staff_id = ws.staff_id
  left join public.production_roster_entries pre
    on pre.roster_entry_id = ws.production_roster_entry_id
  left join public.areas planned_area on planned_area.area_id = pre.area_id
  left join public.stations planned_station on planned_station.station_id = pre.station_id
  where ws.work_date = v_business_date
    and ws.shift_id = v_shift.shift_id
    and ws.area_id = v_area.area_id
    and ws.source = 'SORTING_AREA_TRANSFER'
    and ws.status <> 'CANCELLED';

  return jsonb_build_object(
    'business_date', v_business_date,
    'shift_code', v_shift.shift_code,
    'area_code', v_area.area_code,
    'area_name', v_area.area_name,
    'incoming_transfers', v_rows,
    'source', 'WORK_SESSIONS_ACTUAL_AREA_TRANSFER'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Attendance write accepts Training and checks Trolley activity too.
-- ---------------------------------------------------------------------

create or replace function public.set_sorting_staff_attendance(
  p_shift_code text,
  p_staff_id uuid,
  p_attendance_status text,
  p_absence_reason text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_status text := upper(trim(coalesce(p_attendance_status, '')));
  v_reason text := nullif(upper(trim(coalesce(p_absence_reason, ''))), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift public.shifts%rowtype;
  v_context jsonb;
  v_target jsonb;
  v_staff_name text;
  v_actor_staff_id uuid;
  v_old_data jsonb;
  v_new public.sorting_daily_staff_attendance%rowtype;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;

  if v_status not in ('PRESENT','ABSENT') then
    raise exception using errcode = '22023', message = 'Attendance must be PRESENT or ABSENT.';
  end if;

  if v_status = 'ABSENT' and v_reason not in ('SICK','NO_SHOW','TRAINING','OTHER') then
    raise exception using
      errcode = '22023',
      message = 'Choose Sick, No show, Training or Other when the staff member is not working in Sorting.';
  end if;

  if v_status = 'PRESENT' then
    v_reason := null;
  end if;

  if v_notes is not null and length(v_notes) > 1000 then
    raise exception using errcode = '22023', message = 'Attendance notes must be 1000 characters or fewer.';
  end if;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  v_context := public.get_sorting_staff_work_context_v2(v_shift_code);

  select value
  into v_target
  from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
  where value ->> 'staff_id' = p_staff_id::text
  limit 1;

  if v_target is null then
    raise exception using
      errcode = '22023',
      message = 'The selected staff member is not active in Sorting for this shift.';
  end if;

  v_staff_name := v_target ->> 'display_name';
  v_actor_staff_id := public.current_staff_id();

  if v_status = 'ABSENT'
     and (
       exists (
         select 1
         from public.sorting_wash_runs wr
         where wr.business_date = v_business_date
           and wr.shift_id = v_shift.shift_id
           and wr.operator_staff_id = p_staff_id
           and wr.status = 'RECORDED'
       )
       or exists (
         select 1
         from public.sorting_trolley_intakes sti
         where sti.business_date = v_business_date
           and sti.shift_id = v_shift.shift_id
           and sti.operator_staff_id = p_staff_id
       )
     ) then
    raise exception using
      errcode = '22023',
      message = format(
        '%s already has recorded Sorting activity for this Business Date and Shift. Correct that activity before recording the staff member as not working in Sorting.',
        v_staff_name
      );
  end if;

  if v_status = 'ABSENT' and exists (
    select 1
    from public.work_sessions ws
    where ws.work_date = v_business_date
      and ws.shift_id = v_shift.shift_id
      and ws.staff_id = p_staff_id
      and ws.source = 'SORTING_AREA_TRANSFER'
      and ws.status <> 'CANCELLED'
  ) then
    raise exception using
      errcode = '22023',
      message = format('%s is already moved to another Actual area. Restore the area transfer before recording an absence/training status.', v_staff_name);
  end if;

  select to_jsonb(a)
  into v_old_data
  from public.sorting_daily_staff_attendance a
  where a.business_date = v_business_date
    and a.shift_id = v_shift.shift_id
    and a.staff_id = p_staff_id;

  insert into public.sorting_daily_staff_attendance (
    business_date,
    shift_id,
    staff_id,
    attendance_status,
    absence_reason,
    notes,
    source,
    created_by_auth_user_id,
    updated_by_auth_user_id
  )
  values (
    v_business_date,
    v_shift.shift_id,
    p_staff_id,
    v_status,
    v_reason,
    v_notes,
    'SORTING_WORKSTATION',
    auth.uid(),
    auth.uid()
  )
  on conflict (business_date, shift_id, staff_id)
  do update
  set attendance_status = excluded.attendance_status,
      absence_reason = excluded.absence_reason,
      notes = excluded.notes,
      source = 'SORTING_WORKSTATION',
      updated_at = now(),
      updated_by_auth_user_id = auth.uid()
  returning * into v_new;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    v_actor_staff_id,
    'SORTING_ATTENDANCE_CHANGED',
    'sorting_daily_staff_attendance',
    v_new.sorting_daily_staff_attendance_id::text,
    v_old_data,
    to_jsonb(v_new),
    case
      when v_status = 'ABSENT'
        then concat(
          replace(initcap(lower(v_reason)), '_', ' '),
          case when v_notes is null then '' else ': ' || v_notes end
        )
      else coalesce(v_notes, 'Attendance corrected to Present')
    end,
    'SORTING_V2'
  );

  return jsonb_build_object(
    'status', 'success',
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'staff_id', p_staff_id,
    'staff_name', v_staff_name,
    'attendance_status', v_status,
    'absence_reason', v_reason,
    'audit_recorded', true,
    'message', case
      when v_status = 'ABSENT' and v_reason = 'TRAINING'
        then format('%s recorded as Training and excluded from Sorting Actual staffing.', v_staff_name)
      when v_status = 'ABSENT'
        then format(
          '%s recorded as not working in Sorting (%s).',
          v_staff_name,
          replace(initcap(lower(v_reason)), '_', ' ')
        )
      else format('%s restored to Sorting attendance.', v_staff_name)
    end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Final Sorting Staff dashboard wrapper adds Actual area movement.
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_staff_dashboard_context_v2(
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
  v_available_count integer := 0;
  v_confirmed_absent_count integer := 0;
  v_auto_absent_count integer := 0;
  v_moved_count integer := 0;
  v_effective_mop_count integer := 0;
  v_effective_mop_staff_id uuid;
  v_effective_mop_staff_name text;
  v_operational_mop_coverage text := 'UNRESOLVED';
begin
  v_base := public.get_sorting_staff_dashboard_context(p_shift_code);
  v_business_date := (v_base ->> 'business_date')::date;

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code = upper(trim(coalesce(p_shift_code, '')))
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  select coalesce(jsonb_agg(
    staff_row.value || jsonb_build_object(
      'actual_in_sorting', transfer.work_session_id is null,
      'actual_area_code', coalesce(transfer.area_code, 'SORTING'),
      'actual_area_name', coalesce(transfer.area_name, 'Sorting Area'),
      'area_transfer_work_session_id', transfer.work_session_id,
      'area_transfer_notes', transfer.notes,
      'attendance_status', case when transfer.work_session_id is not null then 'MOVED' else staff_row.value ->> 'attendance_status' end,
      'attendance_source', case when transfer.work_session_id is not null then 'ACTUAL_AREA_TRANSFER' else staff_row.value ->> 'attendance_source' end,
      'performance', case
        when transfer.work_session_id is not null then
          coalesce(staff_row.value -> 'performance', '{}'::jsonb) || jsonb_build_object(
            'worked_minutes', 0,
            'worked_hours', 0,
            'clothes_kg_hr', null,
            'clothes_target_pct', null,
            'mop_kg_hr', null,
            'mop_target_pct', null
          )
        else staff_row.value -> 'performance'
      end,
      'trolley_intake_count',(
        select count(*)::integer
        from public.sorting_trolley_intakes sti
        where sti.business_date = v_business_date
          and sti.shift_id = v_shift_id
          and sti.operator_staff_id = nullif(staff_row.value ->> 'staff_id','')::uuid
      ),
      'has_actual_operational_activity',
        transfer.work_session_id is not null
        or coalesce((staff_row.value -> 'performance' ->> 'total_loads')::integer,0) > 0
        or exists(
          select 1
          from public.sorting_trolley_intakes sti
          where sti.business_date = v_business_date
            and sti.shift_id = v_shift_id
            and sti.operator_staff_id = nullif(staff_row.value ->> 'staff_id','')::uuid
        )
        or coalesce((staff_row.value ->> 'adjusted')::boolean,false)
        or coalesce((staff_row.value ->> 'manual_position')::boolean,false)
    )
    order by
      case
        when transfer.work_session_id is not null then 2
        when staff_row.value ->> 'attendance_status' in ('ABSENT','AUTO_ABSENT') then 1
        else 0
      end,
      lower(staff_row.value ->> 'display_name')
  ), '[]'::jsonb)
  into v_staff
  from jsonb_array_elements(coalesce(v_base -> 'staff','[]'::jsonb)) staff_row
  left join lateral (
    select
      ws.work_session_id,
      a.area_code,
      a.area_name,
      ws.notes
    from public.work_sessions ws
    join public.areas a on a.area_id = ws.area_id
    where ws.work_date = v_business_date
      and ws.shift_id = v_shift_id
      and ws.staff_id = nullif(staff_row.value ->> 'staff_id','')::uuid
      and ws.source = 'SORTING_AREA_TRANSFER'
      and ws.status <> 'CANCELLED'
    order by ws.updated_at desc
    limit 1
  ) transfer on true;

  select
    count(*) filter (
      where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT','MOVED')
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' = 'ABSENT'
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' = 'AUTO_ABSENT'
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' = 'MOVED'
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT','MOVED')
        and staff_row.value ->> 'work_mode' = 'MOP'
    )::integer
  into
    v_available_count,
    v_confirmed_absent_count,
    v_auto_absent_count,
    v_moved_count,
    v_effective_mop_count
  from jsonb_array_elements(v_staff) staff_row;

  select
    nullif(staff_row.value ->> 'staff_id', '')::uuid,
    staff_row.value ->> 'display_name'
  into v_effective_mop_staff_id, v_effective_mop_staff_name
  from jsonb_array_elements(v_staff) staff_row
  where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT','MOVED')
    and staff_row.value ->> 'work_mode' = 'MOP'
  limit 1;

  v_operational_mop_coverage := case
    when v_available_count = 0 then 'NO_PRESENT_SORTING_STAFF'
    when v_effective_mop_count = 1 then 'DEDICATED'
    when v_effective_mop_count = 0
         and coalesce(v_base ->> 'actual_mop_coverage', '') = 'NO_DEDICATED_MOP'
      then 'NO_DEDICATED_MOP'
    when v_effective_mop_count = 0
         and coalesce(v_base ->> 'actual_mop_coverage', '') = 'DEDICATED'
      then 'UNRESOLVED_ABSENT_MOP'
    else 'UNRESOLVED'
  end;

  return v_base || jsonb_build_object(
    'staff', v_staff,
    'attendance_summary', jsonb_build_object(
      'shown_staff', jsonb_array_length(v_staff),
      'available_in_sorting', v_available_count,
      'not_absent', v_available_count,
      'confirmed_absent', v_confirmed_absent_count,
      'auto_absent', v_auto_absent_count,
      'moved_to_other_area', v_moved_count,
      'absent_total', v_confirmed_absent_count + v_auto_absent_count
    ),
    'operational_mop_coverage', v_operational_mop_coverage,
    'operational_mop_staff_id', v_effective_mop_staff_id,
    'operational_mop_staff_name', v_effective_mop_staff_name,
    'actual_activity_sources', jsonb_build_array(
      'WASHING','TROLLEY_INTAKE','TIME_ADJUSTMENT','MANUAL_POSITION','AREA_TRANSFER'
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Permissions remain RPC-only. No direct work_sessions access.
-- ---------------------------------------------------------------------

revoke all on function public.get_sorting_staff_no_work_options()
  from public, anon, authenticated;
revoke all on function public.set_sorting_staff_actual_area(text,uuid,text,text)
  from public, anon, authenticated;
revoke all on function public.restore_sorting_staff_actual_area(text,uuid,text)
  from public, anon, authenticated;
revoke all on function public.get_operational_area_incoming_staff(text,text)
  from public, anon, authenticated;
revoke all on function public.set_sorting_staff_attendance(text,uuid,text,text,text)
  from public, anon, authenticated;
revoke all on function public.get_sorting_staff_dashboard_context_v2(text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_staff_no_work_options()
  to authenticated;
grant execute on function public.set_sorting_staff_actual_area(text,uuid,text,text)
  to authenticated;
grant execute on function public.restore_sorting_staff_actual_area(text,uuid,text)
  to authenticated;
grant execute on function public.get_operational_area_incoming_staff(text,text)
  to authenticated;
grant execute on function public.set_sorting_staff_attendance(text,uuid,text,text,text)
  to authenticated;
grant execute on function public.get_sorting_staff_dashboard_context_v2(text)
  to authenticated;

comment on function public.set_sorting_staff_actual_area(text,uuid,text,text) is
  'Records a whole-shift Actual area transfer from Sorting without changing the PUBLISHED Production Roster. Reuses work_sessions as the central Actual staffing layer and blocks contradictions with recorded Sorting activity.';

comment on function public.get_operational_area_incoming_staff(text,text) is
  'Controlled shared read model for staff moved from Sorting into another operational area. Future Finish/MOP applications can merge this Actual evidence with their PUBLISHED planned staffing.';

comment on function public.get_sorting_staff_dashboard_context_v2(text) is
  'Sorting Staff dashboard with attendance, performance, trolley activity and Actual area-transfer state. MOVED is operationally unavailable in Sorting but is not an absence.';

commit;
