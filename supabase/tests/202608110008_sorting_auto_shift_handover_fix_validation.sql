-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110008_sorting_auto_shift_handover_fix
-- =====================================================================

begin;

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
  v_now jsonb;
  v_null jsonb;
  v_before jsonb;
  v_at_start jsonb;
  v_evening_start time;
  v_recommended text;
  v_staff_context jsonb;
begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is null then
    raise exception 'No ADMIN auth user available for Validation 028.';
  end if;

  v_now := public.get_sorting_auto_shift_context(now());
  v_null := public.get_sorting_auto_shift_context(null);

  if nullif(v_null->>'local_date','') is null
     or nullif(v_null->>'local_time','') is null
     or nullif(v_null->>'business_date','') is null then
    raise exception 'NULL p_at still produces a NULL operational clock context.';
  end if;

  if v_null->>'recommended_shift_code' <> v_now->>'recommended_shift_code'
     or v_null->>'business_date' <> v_now->>'business_date' then
    raise exception
      'NULL p_at does not behave like now(): null=% now=%',
      v_null,v_now;
  end if;

  -- Monday 2026-08-11 profile is used because current V2 roster profile data
  -- has an explicit Evening start. Times below are Dublin-local expressed in UTC
  -- during Irish Summer Time (UTC+1).
  v_before := public.get_sorting_auto_shift_context(
    timestamptz '2026-08-11 13:59:00+00'
  );
  v_at_start := public.get_sorting_auto_shift_context(
    timestamptz '2026-08-11 14:00:00+00'
  );

  v_evening_start := (v_at_start->>'evening_standard_start')::time;

  if v_evening_start <> time '15:00' then
    raise exception
      'Validation 028 expected current Monday-Wednesday Evening profile to start at 15:00, got %.',
      v_evening_start;
  end if;

  if v_before->>'recommended_shift_code' <> 'MORNING' then
    raise exception 'Auto Shift should still be MORNING one minute before Evening start: %',v_before;
  end if;

  if v_at_start->>'recommended_shift_code' <> 'EVENING' then
    raise exception 'Auto Shift did not switch to EVENING at Evening start: %',v_at_start;
  end if;

  v_recommended := v_now->>'recommended_shift_code';
  v_staff_context := public.get_sorting_staff_work_context_v2(v_recommended);

  if v_staff_context->>'shift_code' <> v_recommended then
    raise exception
      'Staff context shift does not match Auto Shift recommendation: auto=% staff=%',
      v_recommended,v_staff_context->>'shift_code';
  end if;

  if jsonb_array_length(coalesce(v_staff_context->'staff','[]'::jsonb))=0 then
    raise exception
      'Recommended shift has no Sorting staff in the current published/actual context.';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.get_sorting_auto_shift_context(timestamp with time zone)',
    'EXECUTE'
  ) then
    raise exception 'Authenticated workstation lost Auto Shift RPC permission.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608110008_sorting_auto_shift_handover_fix_validation',
  'null_parameter_uses_now',true,
  'handover_boundary_switches_shift',true,
  'recommended_shift_staff_context_matches',true,
  'current_recommended_shift_has_staff',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
