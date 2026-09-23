-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608100008_sorting_auto_absence_and_simple_time_editor
-- =====================================================================

begin;

do $$
declare
  v_ctx jsonb;
begin
  if (
    select (value_json #>> '{}')::integer
    from public.app_config
    where config_key='sorting_auto_absent_grace_minutes'
  ) <> 15 then
    raise exception 'Default Sorting auto-absence grace must be 15 minutes.';
  end if;

  -- Monday Evening standard end is 23:20. Auto inference begins at 23:35.
  v_ctx := public.sorting_shift_auto_absence_context(
    date '2026-08-10',
    'EVENING',
    '2026-08-10 23:34:59 Europe/Dublin'::timestamptz
  );

  if coalesce((v_ctx ->> 'cutoff_reached')::boolean,false) then
    raise exception 'Evening staff became auto absent before standard end + grace: %',v_ctx;
  end if;

  v_ctx := public.sorting_shift_auto_absence_context(
    date '2026-08-10',
    'EVENING',
    '2026-08-10 23:35:00 Europe/Dublin'::timestamptz
  );

  if coalesce((v_ctx ->> 'cutoff_reached')::boolean,false) is not true then
    raise exception 'Evening auto-absence cutoff did not start at 23:35: %',v_ctx;
  end if;

  -- Morning Monday must use the latest legitimate end (16:00), not 15:00.
  v_ctx := public.sorting_shift_auto_absence_context(
    date '2026-08-10',
    'MORNING',
    '2026-08-10 16:14:59 Europe/Dublin'::timestamptz
  );

  if coalesce((v_ctx ->> 'cutoff_reached')::boolean,false) then
    raise exception 'Ambiguous Morning profile inferred absence before latest 16:00 + grace.';
  end if;

  v_ctx := public.sorting_shift_auto_absence_context(
    date '2026-08-10',
    'MORNING',
    '2026-08-10 16:15:00 Europe/Dublin'::timestamptz
  );

  if coalesce((v_ctx ->> 'cutoff_reached')::boolean,false) is not true then
    raise exception 'Morning auto-absence cutoff did not use latest legitimate standard finish.';
  end if;

  -- Deterministic status rules / misuse alternatives.
  if public.sorting_resolve_attendance_status(null,0,false,false,false) <> 'PLANNED' then
    raise exception 'No evidence before cutoff must remain PLANNED.';
  end if;

  if public.sorting_resolve_attendance_status(null,0,false,false,true) <> 'AUTO_ABSENT' then
    raise exception 'No evidence after cutoff must become AUTO_ABSENT.';
  end if;

  if public.sorting_resolve_attendance_status('ABSENT',5,true,true,true) <> 'ABSENT' then
    raise exception 'Confirmed ABSENT must win over inferred evidence.';
  end if;

  if public.sorting_resolve_attendance_status('PRESENT',0,false,false,true) <> 'PRESENT' then
    raise exception 'Explicit PRESENT must prevent auto absence.';
  end if;

  if public.sorting_resolve_attendance_status(null,1,false,false,true) <> 'PRESENT_EVIDENCE' then
    raise exception 'A RECORDED wash must clear inferred absence.';
  end if;

  if public.sorting_resolve_attendance_status(null,0,true,false,true) <> 'PRESENT_EVIDENCE' then
    raise exception 'Actual worked-time adjustment must prevent inferred absence.';
  end if;

  if public.sorting_resolve_attendance_status(null,0,false,true,true) <> 'PRESENT_EVIDENCE' then
    raise exception 'Manual Actual Sorting position must prevent inferred absence.';
  end if;
end;
$$;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr
      on sr.staff_id=sm.staff_id
     and sr.active=true
    join public.roles r
      on r.role_id=sr.role_id
     and r.active=true
     and r.role_code='ADMIN'
    where sm.auth_user_id is not null
      and sm.deleted_at is null
    order by sm.created_at
    limit 1
  ),
  true
);

set local role authenticated;

do $$
declare
  v_shift text := 'MORNING';
  v_dashboard jsonb;
begin
  if has_function_privilege(
    'authenticated',
    'public.sorting_shift_auto_absence_context(date,text,timestamptz)',
    'EXECUTE'
  ) then
    raise exception 'Auto-absence helper must remain private.';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.sorting_resolve_attendance_status(text,integer,boolean,boolean,boolean)',
    'EXECUTE'
  ) then
    raise exception 'Attendance inference helper must remain private.';
  end if;

  v_dashboard := public.get_sorting_staff_dashboard_context(v_shift);

  if not (v_dashboard ? 'auto_absence') then
    v_shift := 'EVENING';
    v_dashboard := public.get_sorting_staff_dashboard_context(v_shift);
  end if;

  if not (v_dashboard ? 'auto_absence')
     or not (v_dashboard -> 'auto_absence' ? 'auto_absent_cutoff_at')
     or not (v_dashboard -> 'attendance_summary' ? 'auto_absent') then
    raise exception 'Staff dashboard does not expose auto-absence read-model context.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608100008_sorting_auto_absence_and_simple_time_editor_validation',
  'auto_absence_is_inference_only',true,
  'no_activity_before_cutoff_stays_planned',true,
  'no_activity_after_cutoff_auto_absent',true,
  'recorded_wash_clears_auto_absence',true,
  'actual_time_adjustment_clears_auto_absence',true,
  'manual_actual_position_clears_auto_absence',true,
  'explicit_present_prevents_auto_absence',true,
  'confirmed_absence_remains_authoritative',true,
  'ambiguous_morning_uses_latest_finish',true,
  'private_inference_helpers_protected',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
