begin;

create or replace function public.get_sorting_staff_no_work_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_tables jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'station_code', st.station_code,
        'station_name', st.station_name
      ) order by st.station_code
    ),
    '[]'::jsonb
  )
  into v_tables
  from public.stations st
  join public.areas a on a.area_id = st.area_id
  where a.area_code = 'FINISH'
    and a.active = true
    and a.deleted_at is null
    and st.active = true
    and st.deleted_at is null
    and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3');

  return jsonb_build_object(
    'absence_reasons', jsonb_build_array(
      jsonb_build_object('code','SICK','label','Sick'),
      jsonb_build_object('code','NO_SHOW','label','No show'),
      jsonb_build_object('code','TRAINING','label','Training'),
      jsonb_build_object('code','OTHER','label','Other')
    ),
    'finish_tables', v_tables
  );
end;
$$;

create or replace function public.move_sorting_staff_to_finish_table_v1(
  p_shift_code text,
  p_staff_id uuid,
  p_target_table_code text,
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
  v_finish_area public.areas%rowtype;
  v_finish_station public.stations%rowtype;
  v_context jsonb;
  v_target jsonb;
  v_session public.work_sessions%rowtype;
  v_new public.work_sessions%rowtype;
  v_old_data jsonb;
  v_actor_staff_id uuid := public.current_staff_id();
  v_staff_name text;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;

  select * into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;
  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  select a.* into v_finish_area
  from public.areas a
  where a.area_code = 'FINISH'
    and a.active = true
    and a.deleted_at is null
  limit 1;

  select st.* into v_finish_station
  from public.stations st
  where st.area_id = v_finish_area.area_id
    and st.station_code = v_table_code
    and st.active = true
    and st.deleted_at is null
    and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
  limit 1;
  if not found then
    raise exception using errcode = '22023', message = 'Choose Finish Table 1, Table 2 or Table 3.';
  end if;

  v_context := public.get_sorting_staff_work_context_v2(v_shift_code);
  select value into v_target
  from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
  where nullif(value ->> 'staff_id', '')::uuid = p_staff_id
  limit 1;
  if v_target is null then
    raise exception using errcode = '22023', message = 'The selected staff member is not currently shown in Sorting for this shift.';
  end if;
  if coalesce(v_target ->> 'attendance_status', '') = 'ABSENT' then
    raise exception using errcode = '22023', message = 'Correct the absence before moving this staff member to Finish.';
  end if;

  select sm.display_name into v_staff_name
  from public.staff_members sm
  where sm.staff_id = p_staff_id;

  if exists (
    select 1 from public.sorting_wash_runs wr
    where wr.business_date = v_business_date
      and wr.shift_id = v_shift.shift_id
      and wr.operator_staff_id = p_staff_id
      and wr.status = 'RECORDED'
  ) or exists (
    select 1 from public.sorting_trolley_intakes sti
    where sti.business_date = v_business_date
      and sti.shift_id = v_shift.shift_id
      and sti.operator_staff_id = p_staff_id
  ) then
    raise exception using errcode = '22023', message = format('%s already has recorded Sorting activity for this Business Date and Shift. Correct that activity before moving the whole shift to Finish.', coalesce(v_staff_name, 'This staff member'));
  end if;

  if nullif(v_target ->> 'work_session_id', '') is not null then
    select * into v_session
    from public.work_sessions ws
    where ws.work_session_id = nullif(v_target ->> 'work_session_id', '')::uuid
      and ws.status <> 'CANCELLED'
    for update;
  end if;

  if v_session.work_session_id is null and nullif(v_target ->> 'roster_entry_id', '') is not null then
    select * into v_session
    from public.work_sessions ws
    where ws.production_roster_entry_id = nullif(v_target ->> 'roster_entry_id', '')::uuid
      and ws.status <> 'CANCELLED'
    order by ws.updated_at desc
    limit 1
    for update;
  end if;

  v_old_data := case when v_session.work_session_id is null then null else to_jsonb(v_session) end;
  if v_session.work_session_id is not null then
    update public.work_sessions
    set area_id = v_finish_area.area_id,
        station_id = v_finish_station.station_id,
        source = 'SORTING_TO_FINISH_TRANSFER',
        notes = coalesce(v_notes, notes),
        confirmed_by = v_actor_staff_id,
        recorded_by_auth_user_id = auth.uid(),
        row_version = row_version + 1,
        updated_at = now()
    where work_session_id = v_session.work_session_id
    returning * into v_new;
  else
    insert into public.work_sessions (
      production_roster_entry_id, production_roster_version_id, work_date,
      staff_id, area_id, station_id, shift_id, break_minutes,
      extra_non_work_minutes, adjustment_reason, status, source,
      confirmed_by, notes, recorded_by_auth_user_id, row_version, updated_at
    ) values (
      nullif(v_target ->> 'roster_entry_id', '')::uuid,
      nullif(v_target ->> 'roster_version_id', '')::uuid,
      v_business_date, p_staff_id, v_finish_area.area_id, v_finish_station.station_id,
      v_shift.shift_id, coalesce(nullif(v_target ->> 'standard_break_minutes', '')::integer, 0),
      0, 'NONE', 'OPEN', 'SORTING_TO_FINISH_TRANSFER',
      v_actor_staff_id, v_notes, auth.uid(), 1, now()
    ) returning * into v_new;
  end if;

  insert into public.finish_daily_staff_attendance (
    business_date, shift_id, staff_id, attendance_status, source,
    created_by_auth_user_id, updated_by_auth_user_id
  ) values (
    v_business_date, v_shift.shift_id, p_staff_id, 'PRESENT',
    'SORTING_TO_FINISH_TRANSFER', auth.uid(), auth.uid()
  ) on conflict (business_date, shift_id, staff_id) do update
  set attendance_status = 'PRESENT',
      absence_reason = null,
      source = 'SORTING_TO_FINISH_TRANSFER',
      updated_at = now(),
      updated_by_auth_user_id = auth.uid();

  if v_new.actual_start_at is not null and not exists (
    select 1 from public.finish_staff_table_segments s
    where s.work_session_id = v_new.work_session_id
  ) then
    insert into public.finish_staff_table_segments (
      work_session_id, station_id, started_at, ended_at, notes,
      created_by_auth_user_id, updated_by_auth_user_id
    ) values (
      v_new.work_session_id, v_finish_station.station_id,
      v_new.actual_start_at, v_new.actual_end_at, v_notes, auth.uid(), auth.uid()
    );
  end if;

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff_id, 'SORTING_STAFF_MOVED_TO_FINISH_TABLE',
    'work_sessions', v_new.work_session_id::text, v_old_data, to_jsonb(v_new),
    concat('Actual whole-shift transfer from Sorting to ', v_finish_station.station_name,
      case when v_notes is null then '' else ': ' || v_notes end),
    'SORTING_V4'
  );

  return jsonb_build_object(
    'status', 'success', 'staff_id', p_staff_id, 'staff_name', v_staff_name,
    'business_date', v_business_date, 'shift_code', v_shift_code,
    'table_code', v_finish_station.station_code,
    'message', format('%s moved to %s for Actual staffing. The published Roster was not changed.', coalesce(v_staff_name, 'Staff member'), v_finish_station.station_name)
  );
end;
$$;

create or replace function public.restore_sorting_staff_from_finish_table_v1(
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
  v_shift public.shifts%rowtype;
  v_sorting_area public.areas%rowtype;
  v_sorting_station public.stations%rowtype;
  v_session public.work_sessions%rowtype;
  v_new public.work_sessions%rowtype;
  v_actor_staff_id uuid := public.current_staff_id();
  v_old_data jsonb;
begin
  perform public.require_sorting_operational_access();

  select * into v_shift from public.shifts sh
  where sh.shift_code = v_shift_code and sh.active = true and sh.deleted_at is null
  limit 1;
  if not found then raise exception using errcode = 'P0002', message = 'Selected shift is not available.'; end if;

  select * into v_sorting_area from public.areas a
  where a.area_code = 'SORTING' and a.active = true and a.deleted_at is null
  limit 1;
  select * into v_sorting_station from public.stations st
  where st.area_id = v_sorting_area.area_id and st.station_code = 'SORTING_MAIN'
    and st.active = true and st.deleted_at is null
  limit 1;

  select * into v_session from public.work_sessions ws
  where ws.work_date = v_business_date
    and ws.shift_id = v_shift.shift_id
    and ws.staff_id = p_staff_id
    and ws.source = 'SORTING_TO_FINISH_TRANSFER'
    and ws.status <> 'CANCELLED'
  order by ws.updated_at desc
  limit 1
  for update;
  if not found then raise exception using errcode = 'P0002', message = 'No active Sorting-to-Finish transfer was found for this staff member.'; end if;

  v_old_data := to_jsonb(v_session);
  update public.work_sessions
  set area_id = v_sorting_area.area_id,
      station_id = v_sorting_station.station_id,
      source = 'SORTING_MANUAL_POSITION',
      notes = coalesce(nullif(trim(p_reason), ''), notes),
      recorded_by_auth_user_id = auth.uid(),
      row_version = row_version + 1,
      updated_at = now()
  where work_session_id = v_session.work_session_id
  returning * into v_new;

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff_id, 'SORTING_STAFF_RETURNED_FROM_FINISH',
    'work_sessions', v_new.work_session_id::text, v_old_data, to_jsonb(v_new),
    coalesce(nullif(trim(p_reason), ''), 'Actual staffing returned to Sorting.'),
    'SORTING_V4'
  );

  return jsonb_build_object(
    'status', 'success', 'staff_id', p_staff_id,
    'business_date', v_business_date, 'shift_code', v_shift_code,
    'message', 'Staff member returned to Sorting Actual staffing. The published Roster was not changed.'
  );
end;
$$;

revoke all on function public.move_sorting_staff_to_finish_table_v1(text,uuid,text,text) from public, anon, authenticated;
revoke all on function public.restore_sorting_staff_from_finish_table_v1(text,uuid,text) from public, anon, authenticated;
revoke all on function public.set_sorting_staff_actual_area(text,uuid,text,text) from authenticated;
revoke all on function public.restore_sorting_staff_actual_area(text,uuid,text) from authenticated;
grant execute on function public.get_sorting_staff_no_work_options() to authenticated;
grant execute on function public.move_sorting_staff_to_finish_table_v1(text,uuid,text,text) to authenticated;
grant execute on function public.restore_sorting_staff_from_finish_table_v1(text,uuid,text) to authenticated;

comment on function public.move_sorting_staff_to_finish_table_v1(text,uuid,text,text) is
  'Whole-shift Sorting No Work correction that moves Actual staffing only to a named Finish Table. It preserves the published Roster and records an audit event.';

commit;
