-- Sorting Staff: move a person to a Finish Table for part of the shift.
--
-- Until now Sorting could only move the whole shift to Finish
-- (move_sorting_staff_to_finish_table_v1). When someone works in Sorting first and
-- then goes to a Finish Table, the time must be split: Sorting keeps the time until
-- the move and Finish starts a new Actual session from the move time.
--
-- Also fixes the Sorting Staff list: it only recognised SORTING_AREA_TRANSFER, so
-- a person moved with move_sorting_staff_to_finish_table_v1 (SORTING_TO_FINISH_TRANSFER)
-- still looked as if they were working in Sorting.
--
-- The published Roster is not changed. Every move and return is written to audit_log.

create or replace function public.move_sorting_staff_to_finish_table_v2(
  p_shift_code text,
  p_staff_id uuid,
  p_target_table_code text,
  p_move_time time default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_table_code text := upper(trim(coalesce(p_target_table_code, '')));
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift public.shifts%rowtype;
  v_sorting_area_id uuid;
  v_sorting_station_id uuid;
  v_finish_area_id uuid;
  v_finish_station public.stations%rowtype;
  v_context jsonb;
  v_target jsonb;
  v_session public.work_sessions%rowtype;
  v_old_data jsonb;
  v_saved public.work_sessions%rowtype;
  v_finish public.work_sessions%rowtype;
  v_start_at timestamptz;
  v_move_at timestamptz;
  v_planned_end_at timestamptz;
  v_total_break integer;
  v_sorting_break integer;
  v_finish_break integer;
  v_actor_staff_id uuid := public.current_staff_id();
  v_staff_name text;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;
  if length(coalesce(p_notes, '')) > 1000 then
    raise exception using errcode = '22023', message = 'Notes must be 1000 characters or fewer.';
  end if;

  select * into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code and sh.active = true and sh.deleted_at is null
  limit 1;
  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  v_context := public.get_sorting_staff_work_context_v2(v_shift_code);
  select value into v_target
  from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
  where nullif(value ->> 'staff_id', '')::uuid = p_staff_id
  limit 1;
  if v_target is null then
    raise exception using errcode = '22023', message = 'The selected staff member is not currently shown in Sorting for this shift.';
  end if;

  v_start_at := public.operational_timestamp_for_shift(
    v_business_date, v_shift_code, nullif(v_target ->> 'actual_start_time', '')::time);
  v_move_at := case when p_move_time is null then null
    else public.operational_timestamp_for_shift(v_business_date, v_shift_code, p_move_time) end;

  -- A move at or before the start of the shift is a whole-shift move.
  if v_move_at is null or v_start_at is null or v_move_at <= v_start_at then
    return public.move_sorting_staff_to_finish_table_v1(v_shift_code, p_staff_id, v_table_code, v_notes);
  end if;

  if coalesce(v_target ->> 'attendance_status', '') = 'ABSENT' then
    raise exception using errcode = '22023', message = 'Correct the absence before moving this staff member to Finish.';
  end if;
  if v_move_at > now() + interval '5 minutes' then
    raise exception using errcode = '22023', message = 'The move time cannot be in the future.';
  end if;

  select area_id into v_sorting_area_id from public.areas
  where area_code = 'SORTING' and active = true and deleted_at is null limit 1;
  select st.station_id into v_sorting_station_id
  from public.stations st join public.areas a on a.area_id = st.area_id
  where st.station_code = 'SORTING_MAIN' and a.area_code = 'SORTING' and st.active = true and st.deleted_at is null
  limit 1;
  select area_id into v_finish_area_id from public.areas
  where area_code = 'FINISH' and active = true and deleted_at is null limit 1;
  select st.* into v_finish_station
  from public.stations st
  where st.area_id = v_finish_area_id
    and st.station_code = v_table_code
    and st.station_code in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3')
    and st.active = true and st.deleted_at is null
  limit 1;
  if not found then
    raise exception using errcode = '22023', message = 'Choose Finish Table 1, Table 2 or Table 3.';
  end if;

  if exists (
    select 1 from public.work_sessions ws
    where ws.work_date = v_business_date and ws.shift_id = v_shift.shift_id
      and ws.staff_id = p_staff_id and ws.area_id = v_finish_area_id and ws.status <> 'CANCELLED'
  ) then
    raise exception using errcode = '23505', message = 'This staff member already has a Finish Actual for this shift. Use Back to Sorting first.';
  end if;

  select sm.display_name into v_staff_name from public.staff_members sm where sm.staff_id = p_staff_id;

  v_planned_end_at := public.operational_timestamp_for_shift(
    v_business_date, v_shift_code, nullif(v_target ->> 'planned_end_time', '')::time);
  if v_shift_code = 'EVENING' and v_planned_end_at is not null and v_planned_end_at <= v_start_at then
    v_planned_end_at := v_planned_end_at + interval '1 day';
  end if;
  if v_planned_end_at is not null and v_move_at >= v_planned_end_at then
    raise exception using errcode = '22023', message = 'The move time is after the planned end of the shift. Use Leaving early instead.';
  end if;

  -- Split the standard break by the share of the shift worked in each area.
  v_total_break := coalesce(nullif(v_target ->> 'standard_break_minutes', '')::integer, 0);
  v_sorting_break := case
    when v_planned_end_at is null or v_planned_end_at <= v_start_at then 0
    else round(v_total_break * extract(epoch from (v_move_at - v_start_at)) / extract(epoch from (v_planned_end_at - v_start_at)))::integer
  end;
  v_sorting_break := least(v_sorting_break, greatest(0, floor(extract(epoch from (v_move_at - v_start_at)) / 60)::integer));
  v_finish_break := greatest(0, v_total_break - v_sorting_break);

  -- Close the Sorting session at the move time (create it when the person was As planned).
  select ws.* into v_session
  from public.work_sessions ws
  where ws.work_date = v_business_date and ws.shift_id = v_shift.shift_id
    and ws.staff_id = p_staff_id and ws.area_id = v_sorting_area_id and ws.status <> 'CANCELLED'
  order by case when ws.source = 'SORTING_MANUAL_POSITION' then 0 else 1 end, ws.updated_at desc
  limit 1
  for update;

  if found and v_session.actual_end_at is not null and v_session.status <> 'OPEN' and v_session.actual_end_at <= v_move_at then
    raise exception using errcode = '22023', message = 'This staff member already left Sorting before the move time. Correct the leaving time first.';
  end if;

  if found then
    v_old_data := to_jsonb(v_session);
    update public.work_sessions
    set actual_start_at = coalesce(actual_start_at, v_start_at),
        actual_end_at = v_move_at,
        break_minutes = v_sorting_break,
        status = 'CONFIRMED',
        notes = concat_ws(' ', nullif(trim(notes), ''), format('Moved to %s at %s.', v_finish_station.station_name, to_char(v_move_at at time zone 'Europe/Dublin', 'HH24:MI'))),
        confirmed_by = v_actor_staff_id,
        recorded_by_auth_user_id = auth.uid(),
        row_version = row_version + 1,
        updated_at = now()
    where work_session_id = v_session.work_session_id
    returning * into v_saved;
  else
    v_old_data := null;
    insert into public.work_sessions (
      production_roster_entry_id, production_roster_version_id, work_date, staff_id,
      area_id, station_id, shift_id, actual_start_at, actual_end_at, break_minutes,
      extra_non_work_minutes, adjustment_reason, status, source, confirmed_by, notes,
      recorded_by_auth_user_id, row_version, updated_at
    ) values (
      nullif(v_target ->> 'roster_entry_id', '')::uuid,
      nullif(v_target ->> 'roster_version_id', '')::uuid,
      v_business_date, p_staff_id, v_sorting_area_id, v_sorting_station_id, v_shift.shift_id,
      v_start_at, v_move_at, v_sorting_break, 0, 'NONE', 'CONFIRMED', 'SORTING_WORKSTATION',
      v_actor_staff_id,
      format('Moved to %s at %s.', v_finish_station.station_name, to_char(v_move_at at time zone 'Europe/Dublin', 'HH24:MI')),
      auth.uid(), 1, now()
    ) returning * into v_saved;
  end if;

  -- The Finish session has no roster entry: the roster entry stays on the Sorting session.
  insert into public.work_sessions (
    production_roster_entry_id, production_roster_version_id, work_date, staff_id,
    area_id, station_id, shift_id, actual_start_at, actual_end_at, break_minutes,
    extra_non_work_minutes, adjustment_reason, status, source, confirmed_by, notes,
    recorded_by_auth_user_id, row_version, updated_at
  ) values (
    null, nullif(v_target ->> 'roster_version_id', '')::uuid,
    v_business_date, p_staff_id, v_finish_area_id, v_finish_station.station_id, v_shift.shift_id,
    v_move_at, null, v_finish_break, 0, 'NONE', 'OPEN', 'SORTING_TO_FINISH_TRANSFER',
    v_actor_staff_id, v_notes, auth.uid(), 1, now()
  ) returning * into v_finish;

  insert into public.finish_daily_staff_attendance (
    business_date, shift_id, staff_id, attendance_status, source,
    created_by_auth_user_id, updated_by_auth_user_id
  ) values (
    v_business_date, v_shift.shift_id, p_staff_id, 'PRESENT',
    'SORTING_TO_FINISH_TRANSFER', auth.uid(), auth.uid()
  ) on conflict (business_date, shift_id, staff_id) do update
  set attendance_status = 'PRESENT', absence_reason = null, source = 'SORTING_TO_FINISH_TRANSFER',
      updated_at = now(), updated_by_auth_user_id = auth.uid();

  insert into public.finish_staff_table_segments (
    work_session_id, station_id, started_at, ended_at, notes,
    created_by_auth_user_id, updated_by_auth_user_id
  ) values (
    v_finish.work_session_id, v_finish_station.station_id, v_move_at, null, v_notes, auth.uid(), auth.uid()
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff_id, 'SORTING_STAFF_MOVED_TO_FINISH_TABLE_PARTIAL',
    'work_sessions', v_finish.work_session_id::text, v_old_data,
    jsonb_build_object('sorting_session', to_jsonb(v_saved), 'finish_session', to_jsonb(v_finish)),
    concat(format('%s moved from Sorting to %s at %s', coalesce(v_staff_name, 'Staff'), v_finish_station.station_name,
      to_char(v_move_at at time zone 'Europe/Dublin', 'HH24:MI')),
      case when v_notes is null then '' else ': ' || v_notes end),
    'SORTING_V4'
  );

  return jsonb_build_object(
    'status', 'success', 'staff_id', p_staff_id, 'staff_name', v_staff_name,
    'business_date', v_business_date, 'shift_code', v_shift_code,
    'table_code', v_finish_station.station_code, 'moved_at', v_move_at,
    'sorting_work_session_id', v_saved.work_session_id,
    'finish_work_session_id', v_finish.work_session_id,
    'message', format('%s moved to %s at %s. Sorting keeps the time until then. The published Roster was not changed.',
      coalesce(v_staff_name, 'Staff member'), v_finish_station.station_name,
      to_char(v_move_at at time zone 'Europe/Dublin', 'HH24:MI'))
  );
end;
$$;

revoke all on function public.move_sorting_staff_to_finish_table_v2(text, uuid, text, time, text) from public, anon;
grant execute on function public.move_sorting_staff_to_finish_table_v2(text, uuid, text, time, text) to authenticated;

-- Back to Sorting for both kinds of move. A partial move cancels the Finish session and
-- reopens the Sorting session; a whole-shift move is handled by the v1 function.
create or replace function public.restore_sorting_staff_from_finish_table_v2(
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
  v_reason text := coalesce(nullif(trim(p_reason), ''), 'Actual staffing returned to Sorting.');
  v_shift public.shifts%rowtype;
  v_finish public.work_sessions%rowtype;
  v_sorting public.work_sessions%rowtype;
  v_old jsonb;
  v_actor_staff_id uuid := public.current_staff_id();
begin
  perform public.require_sorting_operational_access();

  select * into v_shift from public.shifts sh
  where sh.shift_code = v_shift_code and sh.active = true and sh.deleted_at is null
  limit 1;
  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  select ws.* into v_finish
  from public.work_sessions ws
  join public.areas a on a.area_id = ws.area_id
  where ws.work_date = v_business_date and ws.shift_id = v_shift.shift_id
    and ws.staff_id = p_staff_id and a.area_code = 'FINISH'
    and ws.source = 'SORTING_TO_FINISH_TRANSFER' and ws.status <> 'CANCELLED'
  order by ws.updated_at desc
  limit 1
  for update;

  select ws.* into v_sorting
  from public.work_sessions ws
  join public.areas a on a.area_id = ws.area_id
  where ws.work_date = v_business_date and ws.shift_id = v_shift.shift_id
    and ws.staff_id = p_staff_id and a.area_code = 'SORTING' and ws.status <> 'CANCELLED'
  order by ws.updated_at desc
  limit 1
  for update;

  if v_finish.work_session_id is null or v_sorting.work_session_id is null then
    return public.restore_sorting_staff_from_finish_table_v1(v_shift_code, p_staff_id, v_reason);
  end if;

  v_old := jsonb_build_object('sorting_session', to_jsonb(v_sorting), 'finish_session', to_jsonb(v_finish));

  update public.finish_staff_table_segments
  set ended_at = started_at, updated_at = now(), updated_by_auth_user_id = auth.uid()
  where work_session_id = v_finish.work_session_id and ended_at is null;

  update public.work_sessions
  set status = 'CANCELLED', notes = concat_ws(' ', nullif(trim(notes), ''), v_reason),
      recorded_by_auth_user_id = auth.uid(), row_version = row_version + 1, updated_at = now()
  where work_session_id = v_finish.work_session_id
  returning * into v_finish;

  update public.work_sessions
  set actual_end_at = null,
      status = 'OPEN',
      break_minutes = break_minutes + coalesce(v_finish.break_minutes, 0),
      recorded_by_auth_user_id = auth.uid(),
      row_version = row_version + 1,
      updated_at = now()
  where work_session_id = v_sorting.work_session_id
  returning * into v_sorting;

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff_id, 'SORTING_STAFF_RETURNED_FROM_FINISH',
    'work_sessions', v_sorting.work_session_id::text, v_old,
    jsonb_build_object('sorting_session', to_jsonb(v_sorting), 'finish_session', to_jsonb(v_finish)),
    v_reason, 'SORTING_V4'
  );

  return jsonb_build_object(
    'status', 'success', 'staff_id', p_staff_id,
    'business_date', v_business_date, 'shift_code', v_shift_code,
    'message', 'Staff member returned to Sorting. The Finish Table move was cancelled and the published Roster was not changed.'
  );
end;
$$;

revoke all on function public.restore_sorting_staff_from_finish_table_v2(text, uuid, text) from public, anon;
grant execute on function public.restore_sorting_staff_from_finish_table_v2(text, uuid, text) to authenticated;

-- Sorting Staff list: recognise both transfer sources and keep the Sorting time of a
-- partial move.
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
  v_effective_mop_staff jsonb := '[]'::jsonb;
  v_effective_mop_staff_names text;
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
      'area_transfer_at', case
        when transfer.moved_at is null then null
        else to_char(transfer.moved_at at time zone 'Europe/Dublin', 'HH24:MI')
      end,
      'partial_area_transfer', transfer.work_session_id is not null and partial.is_partial,
      'attendance_status', case
        when transfer.work_session_id is not null then 'MOVED'
        else staff_row.value ->> 'attendance_status'
      end,
      'attendance_source', case
        when transfer.work_session_id is not null then 'ACTUAL_AREA_TRANSFER'
        else staff_row.value ->> 'attendance_source'
      end,
      'performance', case
        when transfer.work_session_id is not null and not partial.is_partial then
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
      'trolley_intake_count', (
        select count(*)::integer
        from public.sorting_trolley_intakes sti
        where sti.business_date = v_business_date
          and sti.shift_id = v_shift_id
          and sti.operator_staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
      ),
      'has_actual_operational_activity',
        transfer.work_session_id is not null
        or coalesce((staff_row.value -> 'performance' ->> 'total_loads')::integer, 0) > 0
        or exists (
          select 1
          from public.sorting_trolley_intakes sti
          where sti.business_date = v_business_date
            and sti.shift_id = v_shift_id
            and sti.operator_staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
        )
        or coalesce((staff_row.value ->> 'adjusted')::boolean, false)
        or coalesce((staff_row.value ->> 'manual_position')::boolean, false)
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
  from jsonb_array_elements(coalesce(v_base -> 'staff', '[]'::jsonb)) staff_row
  left join lateral (
    select ws.work_session_id, a.area_code, a.area_name, ws.notes, ws.actual_start_at as moved_at
    from public.work_sessions ws
    join public.areas a on a.area_id = ws.area_id
    where ws.work_date = v_business_date
      and ws.shift_id = v_shift_id
      and ws.staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
      and ws.source in ('SORTING_AREA_TRANSFER', 'SORTING_TO_FINISH_TRANSFER')
      and a.area_code <> 'SORTING'
      and ws.status <> 'CANCELLED'
    order by ws.updated_at desc
    limit 1
  ) transfer on true
  -- A partial move keeps the closed Sorting session; the row still counts that time.
  cross join lateral (
    select nullif(staff_row.value ->> 'work_session_id', '') is not null
      and nullif(staff_row.value ->> 'work_session_id', '')::uuid is distinct from transfer.work_session_id as is_partial
  ) partial;

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

  -- Sorting can run with one or two dedicated MOP staff. The first one keeps the
  -- legacy single-staff keys; the full list is exposed for operator selection.
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'staff_id', nullif(staff_row.value ->> 'staff_id', '')::uuid,
      'display_name', staff_row.value ->> 'display_name'
    ) order by ord), '[]'::jsonb),
    string_agg(staff_row.value ->> 'display_name', ' & ' order by ord)
  into v_effective_mop_staff, v_effective_mop_staff_names
  from jsonb_array_elements(v_staff) with ordinality staff_row(value, ord)
  where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT','MOVED')
    and staff_row.value ->> 'work_mode' = 'MOP';

  v_effective_mop_staff_id := nullif(v_effective_mop_staff -> 0 ->> 'staff_id', '')::uuid;
  v_effective_mop_staff_name := v_effective_mop_staff -> 0 ->> 'display_name';

  v_operational_mop_coverage := case
    when v_available_count = 0 then 'NO_PRESENT_SORTING_STAFF'
    when v_effective_mop_count between 1 and 2 then 'DEDICATED'
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
    'operational_mop_staff', v_effective_mop_staff,
    'operational_mop_staff_names', v_effective_mop_staff_names,
    'actual_activity_sources', jsonb_build_array(
      'WASHING','TROLLEY_INTAKE','TIME_ADJUSTMENT','MANUAL_POSITION','AREA_TRANSFER'
    )
  );
end;
$$;


