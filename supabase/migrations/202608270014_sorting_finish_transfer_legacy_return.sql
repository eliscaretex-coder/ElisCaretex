begin;

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

  select ws.* into v_session
  from public.work_sessions ws
  join public.areas a on a.area_id = ws.area_id
  where ws.work_date = v_business_date
    and ws.shift_id = v_shift.shift_id
    and ws.staff_id = p_staff_id
    and a.area_code = 'FINISH'
    and ws.source in ('SORTING_TO_FINISH_TRANSFER','SORTING_AREA_TRANSFER')
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

grant execute on function public.restore_sorting_staff_actual_area(text,uuid,text) to authenticated;

commit;
