begin;

create or replace function public.save_sorting_staff_actual_v3(
  p_shift_code text,
  p_staff_id uuid,
  p_actual_start_time time,
  p_actual_end_time time default null,
  p_extra_non_work_minutes integer default 0,
  p_adjustment_reason text default 'NONE',
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_context jsonb;
  v_target jsonb;
  v_reference_end time;
  v_saved jsonb;
  v_session public.work_sessions%rowtype;
  v_old_data jsonb;
begin
  perform public.require_sorting_operational_access();

  if p_actual_start_time is null then
    raise exception using errcode = '22023', message = 'Started at is required.';
  end if;

  if p_actual_end_time is null then
    v_context := public.get_sorting_staff_work_context_v2(v_shift_code);
    select value
    into v_target
    from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
    where nullif(value ->> 'staff_id', '')::uuid = p_staff_id
    limit 1;

    v_reference_end := nullif(v_target ->> 'planned_end_time', '')::time;
    if v_reference_end is null then
      raise exception using errcode = '22023', message = 'Leaving at is required when the planned end time is unavailable.';
    end if;
  end if;

  -- Reuse the existing guarded workflow so shift length, date ownership,
  -- authorization, roster linkage, and audit conventions stay identical.
  v_saved := public.save_sorting_staff_work_adjustment(
    v_shift_code,
    p_staff_id,
    p_actual_start_time,
    coalesce(p_actual_end_time, v_reference_end),
    p_extra_non_work_minutes,
    p_adjustment_reason,
    p_notes
  );

  if p_actual_end_time is not null then
    return v_saved;
  end if;

  select ws.*
  into v_session
  from public.work_sessions ws
  where ws.work_session_id = nullif(v_saved ->> 'work_session_id', '')::uuid
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Saved Sorting work session was not found.';
  end if;

  v_old_data := to_jsonb(v_session);

  update public.work_sessions
  set actual_end_at = null,
      status = 'OPEN',
      row_version = row_version + 1,
      updated_at = now()
  where work_session_id = v_session.work_session_id
  returning * into v_session;

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
    public.current_staff_id(),
    'OPEN_SORTING_STAFF_SHIFT',
    'work_sessions',
    v_session.work_session_id::text,
    v_old_data,
    to_jsonb(v_session),
    nullif(trim(p_notes), ''),
    'SORTING_WORKSTATION'
  );

  return v_saved || jsonb_build_object(
    'status', 'open',
    'actual_end_time', null,
    'message', 'Sorting staff actual saved with an open shift.'
  );
end;
$$;

revoke all on function public.save_sorting_staff_actual_v3(text,uuid,time,time,integer,text,text)
  from public, anon, authenticated;
grant execute on function public.save_sorting_staff_actual_v3(text,uuid,time,time,integer,text,text)
  to authenticated;

comment on function public.save_sorting_staff_actual_v3(text,uuid,time,time,integer,text,text) is
  'Sorting Staff Actual editor save. A null leaving time keeps the shift OPEN while preserving the guarded work-session workflow and audit history.';

commit;
