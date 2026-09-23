-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110009_sorting_staff_no_work_and_area_transfer
--
-- Validates the controlled workstation path only. All writes roll back.
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr
      on sr.staff_id = sm.staff_id
     and sr.active = true
    join public.roles r
      on r.role_id = sr.role_id
     and r.active = true
     and r.role_code = 'ADMIN'
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
  v_options jsonb;
  v_shift text;
  v_dashboard jsonb;
  v_candidate jsonb;
  v_staff_id uuid;
  v_result jsonb;
  v_row jsonb;
  v_incoming jsonb;
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No ADMIN auth user available for Validation 029.';
  end if;

  if has_table_privilege('authenticated', 'public.work_sessions', 'SELECT') then
    raise exception 'Authenticated must not receive direct work_sessions SELECT.';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.get_sorting_staff_no_work_options()',
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    'public.set_sorting_staff_actual_area(text,uuid,text,text)',
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    'public.restore_sorting_staff_actual_area(text,uuid,text)',
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    'public.get_operational_area_incoming_staff(text,text)',
    'EXECUTE'
  ) then
    raise exception 'Authenticated workstation is missing one or more Snapshot 83 RPC permissions.';
  end if;

  v_options := public.get_sorting_staff_no_work_options();

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_options -> 'destination_areas', '[]'::jsonb)) a
    where a ->> 'area_code' = 'FINISH'
      and nullif(a ->> 'area_name', '') is not null
  ) then
    raise exception 'Finish Area is missing from the controlled No Work destination list: %', v_options;
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_options -> 'absence_reasons', '[]'::jsonb)) r
    where r ->> 'code' = 'TRAINING'
  ) then
    raise exception 'Training is missing from No Work reasons: %', v_options;
  end if;

  foreach v_shift in array array['MORNING','EVENING'] loop
    v_dashboard := public.get_sorting_staff_dashboard_context_v2(v_shift);

    select value
    into v_candidate
    from jsonb_array_elements(coalesce(v_dashboard -> 'staff', '[]'::jsonb))
    where coalesce((value ->> 'has_actual_operational_activity')::boolean, false) = false
      and coalesce(value ->> 'attendance_status', '') not in ('ABSENT','MOVED')
    order by value ->> 'display_name'
    limit 1;

    if v_candidate is not null then
      v_staff_id := nullif(v_candidate ->> 'staff_id', '')::uuid;
      exit;
    end if;
  end loop;

  if v_staff_id is null then
    raise exception 'Need one current Sorting staff member without Actual operational activity for Validation 029.';
  end if;

  -- Training is explicitly not No show.
  v_result := public.set_sorting_staff_attendance(
    v_shift,
    v_staff_id,
    'ABSENT',
    'TRAINING',
    'Validation 029 Training path.'
  );

  if v_result ->> 'absence_reason' <> 'TRAINING' then
    raise exception 'Training reason was not preserved: %', v_result;
  end if;

  v_dashboard := public.get_sorting_staff_dashboard_context_v2(v_shift);
  select value
  into v_row
  from jsonb_array_elements(coalesce(v_dashboard -> 'staff', '[]'::jsonb))
  where value ->> 'staff_id' = v_staff_id::text
  limit 1;

  if v_row ->> 'attendance_status' <> 'ABSENT'
     or v_row ->> 'absence_reason' <> 'TRAINING' then
    raise exception 'Training is not visible in the Sorting Staff read model: %', v_row;
  end if;

  perform public.set_sorting_staff_attendance(
    v_shift,
    v_staff_id,
    'PRESENT',
    null,
    'Validation 029 restore before transfer.'
  );

  -- Move to Finish is Actual, not an absence, and must be shared cross-area.
  v_result := public.set_sorting_staff_actual_area(
    v_shift,
    v_staff_id,
    'FINISH',
    'Validation 029 move to Finish.'
  );

  if v_result ->> 'actual_area_code' <> 'FINISH'
     or coalesce((v_result ->> 'roster_unchanged')::boolean, false) <> true then
    raise exception 'Finish Actual transfer result is invalid: %', v_result;
  end if;

  v_dashboard := public.get_sorting_staff_dashboard_context_v2(v_shift);
  select value
  into v_row
  from jsonb_array_elements(coalesce(v_dashboard -> 'staff', '[]'::jsonb))
  where value ->> 'staff_id' = v_staff_id::text
  limit 1;

  if v_row ->> 'attendance_status' <> 'MOVED'
     or v_row ->> 'actual_area_code' <> 'FINISH'
     or coalesce((v_row ->> 'actual_in_sorting')::boolean, true) <> false then
    raise exception 'Moved staff is not isolated from Sorting Actual staffing: %', v_row;
  end if;

  v_incoming := public.get_operational_area_incoming_staff('FINISH', v_shift);

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_incoming -> 'incoming_transfers', '[]'::jsonb)) i
    where i ->> 'staff_id' = v_staff_id::text
      and i ->> 'actual_area_code' = 'FINISH'
  ) then
    raise exception 'Finish incoming Actual staff read model does not contain the transferred staff member: %', v_incoming;
  end if;

  perform public.restore_sorting_staff_actual_area(
    v_shift,
    v_staff_id,
    'Validation 029 restore to Sorting.'
  );

  v_dashboard := public.get_sorting_staff_dashboard_context_v2(v_shift);
  select value
  into v_row
  from jsonb_array_elements(coalesce(v_dashboard -> 'staff', '[]'::jsonb))
  where value ->> 'staff_id' = v_staff_id::text
  limit 1;

  if v_row ->> 'attendance_status' = 'MOVED'
     or coalesce((v_row ->> 'actual_in_sorting')::boolean, false) <> true then
    raise exception 'Restored staff member did not return to Sorting Actual staffing: %', v_row;
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608110009_sorting_staff_no_work_and_area_transfer_validation',
  'no_work_options_master_driven',true,
  'training_distinct_from_no_show',true,
  'finish_transfer_is_actual_not_absence',true,
  'finish_incoming_read_contract',true,
  'published_roster_unchanged',true,
  'direct_work_sessions_select_still_revoked',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
