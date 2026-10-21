-- Fix for 202610210002: Back to Sorting after a partial move closed the Finish table
-- segment with ended_at = started_at, which finish_staff_table_segments_time_check
-- refuses (ended_at > started_at). The Finish session is cancelled, so its open
-- segment is left untouched as history: every reader of finish_staff_table_segments
-- goes through a non-cancelled work session, so it is no longer counted anywhere.

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

  -- The Finish table segment stays on the cancelled Finish session as history.
  v_old := jsonb_build_object('sorting_session', to_jsonb(v_sorting), 'finish_session', to_jsonb(v_finish));

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
