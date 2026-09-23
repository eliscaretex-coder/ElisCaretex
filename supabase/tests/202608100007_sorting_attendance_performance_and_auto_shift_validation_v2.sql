-- =====================================================================
-- ElisCaretex V2
-- Validation V2: 202608100007_sorting_attendance_performance_and_auto_shift
--
-- Includes normal paths AND likely operator misuse paths.
-- V2 establishes the ADMIN JWT context before every protected RPC test.
-- =====================================================================

begin;

-- Establish an authenticated ADMIN identity before calling any protected RPC.
-- The validation intentionally keeps the production functions protected;
-- it does not bypass require_sorting_operational_access().
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

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN auth user is available for Validation 019 V2.';
  end if;
end;
$$;

-- Deterministic Auto Shift schedule tests.
do $$
declare
  v_ctx jsonb;
begin
  v_ctx := public.get_sorting_auto_shift_context(
    '2026-08-10 13:59:00 Europe/Dublin'::timestamptz
  );
  if v_ctx ->> 'recommended_shift_code' <> 'MORNING' then
    raise exception 'Monday 13:59 must recommend Morning: %', v_ctx;
  end if;

  v_ctx := public.get_sorting_auto_shift_context(
    '2026-08-10 15:00:00 Europe/Dublin'::timestamptz
  );
  if v_ctx ->> 'recommended_shift_code' <> 'EVENING' then
    raise exception 'Monday 15:00 must recommend Evening: %', v_ctx;
  end if;

  v_ctx := public.get_sorting_auto_shift_context(
    '2026-08-13 13:59:00 Europe/Dublin'::timestamptz
  );
  if v_ctx ->> 'recommended_shift_code' <> 'MORNING' then
    raise exception 'Thursday 13:59 must recommend Morning: %', v_ctx;
  end if;

  v_ctx := public.get_sorting_auto_shift_context(
    '2026-08-13 14:00:00 Europe/Dublin'::timestamptz
  );
  if v_ctx ->> 'recommended_shift_code' <> 'EVENING' then
    raise exception 'Thursday 14:00 must recommend Evening: %', v_ctx;
  end if;

  v_ctx := public.get_sorting_auto_shift_context(
    '2026-08-11 01:30:00 Europe/Dublin'::timestamptz
  );
  if v_ctx ->> 'recommended_shift_code' <> 'EVENING'
     or (v_ctx ->> 'business_date')::date <> date '2026-08-10' then
    raise exception 'Overnight Evening Auto Shift/Business Date failed: %', v_ctx;
  end if;
end;
$$;

-- Targets must be part of Roster Settings source, not hidden app constants.
do $$
declare
  v_settings jsonb;
begin
  v_settings := public.get_production_roster_operational_settings(
    current_date - 1,
    current_date + 7
  );

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_settings -> 'targets', '[]'::jsonb)) t
    where t ->> 'target_code' = 'SORTING_CLOTHES_KG_PER_STAFF_HOUR'
      and (t ->> 'target_value')::numeric = 160
  ) then
    raise exception 'Sorting Clothes 160 KG/hr target is missing from Roster Settings.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_settings -> 'targets', '[]'::jsonb)) t
    where t ->> 'target_code' = 'SORTING_MOP_KG_PER_STAFF_HOUR'
      and (t ->> 'target_value')::numeric = 100
      and lower(t ->> 'description') like '%provisional%'
  ) then
    raise exception 'Provisional Sorting MOP 100 KG/hr target is missing from Roster Settings.';
  end if;
end;
$$;


-- Prepare a current staff/operator with no existing wash so the attendance
-- validation does not conflict with real Development data.
do $$
declare
  v_shift text;
  v_context jsonb;
  v_staff_id uuid;
  v_candidate jsonb;
  v_business_date date;
  v_shift_id uuid;
  v_board jsonb;
  v_customer jsonb;
begin
  foreach v_shift in array array['MORNING','EVENING'] loop
    v_context := public.get_sorting_staff_work_context_v2(v_shift);
    v_business_date := (v_context ->> 'business_date')::date;

    select sh.shift_id
    into v_shift_id
    from public.shifts sh
    where sh.shift_code = v_shift
      and sh.active = true
      and sh.deleted_at is null
    limit 1;

    select value
    into v_candidate
    from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
    where not exists (
      select 1
      from public.sorting_wash_runs wr
      where wr.business_date = v_business_date
        and wr.shift_id = v_shift_id
        and wr.operator_staff_id = nullif(value ->> 'staff_id', '')::uuid
        and wr.status = 'RECORDED'
    )
    order by value ->> 'display_name'
    limit 1;

    if v_candidate is not null then
      v_staff_id := nullif(v_candidate ->> 'staff_id', '')::uuid;
      exit;
    end if;
  end loop;

  if v_staff_id is null then
    raise exception 'Need one current Sorting staff member without an existing wash for misuse validation.';
  end if;

  v_board := public.get_sorting_customer_board_v3(v_shift);

  select value
  into v_customer
  from jsonb_array_elements(coalesce(v_board -> 'customers', '[]'::jsonb))
  where value ->> 'day_relation' = 'TODAY'
    and value ->> 'product_code' in ('CLOTHES','MOP')
  order by
    case when value ->> 'product_code' = 'CLOTHES' then 0 else 1 end,
    value ->> 'customer_name'
  limit 1;

  if v_customer is null then
    raise exception 'Need a current scheduled Clothes/MOP customer for performance validation.';
  end if;

  perform set_config('eliscaretex.validation.shift', v_shift, true);
  perform set_config('eliscaretex.validation.staff_id', v_staff_id::text, true);
  perform set_config('eliscaretex.validation.customer', v_customer::text, true);
  perform set_config(
    'eliscaretex.validation.washer_code',
    'VS19' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
    true
  );
end;
$$;

insert into public.sorting_washers (
  washer_code,
  washer_name,
  capacity_kg,
  category,
  active,
  sort_order,
  notes,
  metadata
)
values (
  current_setting('eliscaretex.validation.washer_code'),
  'Snapshot 69 Validation Washer',
  10,
  'VALIDATION',
  true,
  9999,
  'Temporary attendance/performance misuse validation washer.',
  '{"validation":true}'::jsonb
);

select set_config(
  'eliscaretex.validation.washer_id',
  (
    select washer_id::text
    from public.sorting_washers
    where washer_code = current_setting('eliscaretex.validation.washer_code')
  ),
  true
);

set local role authenticated;

do $$
declare
  v_shift text := current_setting('eliscaretex.validation.shift');
  v_staff_id uuid := current_setting('eliscaretex.validation.staff_id')::uuid;
  v_customer jsonb := current_setting('eliscaretex.validation.customer')::jsonb;
  v_result jsonb;
  v_dashboard jsonb;
  v_staff jsonb;
  v_wash jsonb;
  v_rejected boolean;
  v_start time;
begin
  -- Security: browser never gets direct attendance-table access.
  if has_table_privilege(
    'authenticated',
    'public.sorting_daily_staff_attendance',
    'SELECT'
  ) then
    raise exception 'sorting_daily_staff_attendance must remain private.';
  end if;

  -- Normal path: mark absent.
  v_result := public.set_sorting_staff_attendance(
    v_shift,
    v_staff_id,
    'ABSENT',
    'NO_SHOW',
    'Snapshot 69 validation absence.'
  );

  if coalesce(v_result ->> 'attendance_status', '') <> 'ABSENT'
     or coalesce(v_result ->> 'audit_recorded', 'false')::boolean is not true then
    raise exception 'Normal absence path failed: %', v_result;
  end if;

  v_dashboard := public.get_sorting_staff_dashboard_context(v_shift);

  select value
  into v_staff
  from jsonb_array_elements(coalesce(v_dashboard -> 'staff', '[]'::jsonb))
  where value ->> 'staff_id' = v_staff_id::text
  limit 1;

  if coalesce(v_staff ->> 'attendance_status', '') <> 'ABSENT'
     or coalesce((v_staff -> 'performance' ->> 'worked_minutes')::integer, -1) <> 0 then
    raise exception 'Absent staff was not excluded from worked/performance time: %', v_staff;
  end if;

  -- Misuse path 1: easiest click = set absent staff as MOP. Must fail.
  v_rejected := false;
  begin
    perform public.set_sorting_staff_work_mode(
      v_shift,
      v_staff_id,
      'MOP',
      'Snapshot 69 misuse test: absent staff must not become MOP.'
    );
  exception
    when others then
      if sqlstate = '22023'
         and position('marked absent' in lower(sqlerrm)) > 0 then
        v_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'Absent staff was incorrectly allowed to become Actual MOP.';
  end if;

  -- Misuse path 2: use absent staff as a wash operator. Must fail in DB,
  -- even if an old/cached browser still lists the person.
  v_start := case
    when (now() at time zone 'Europe/Dublin')::time > time '00:10'
      then ((now() at time zone 'Europe/Dublin') - interval '5 minutes')::time
    else time '00:00'
  end;

  v_rejected := false;
  begin
    perform public.save_sorting_wash_run_v2(
      v_shift,
      current_setting('eliscaretex.validation.washer_id')::uuid,
      v_staff_id,
      v_start,
      1.00,
      v_customer ->> 'product_code',
      jsonb_build_array(jsonb_build_object(
        'customer_id', v_customer ->> 'customer_id',
        'schedule_product_id', v_customer ->> 'schedule_product_id',
        'scheduled_for_date', v_customer ->> 'scheduled_for_date'
      )),
      'Snapshot 69 misuse test.'
    );
  exception
    when others then
      if sqlstate = '22023'
         and position('marked absent' in lower(sqlerrm)) > 0 then
        v_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'Absent staff was incorrectly accepted as wash operator.';
  end if;

  -- Correct the attendance first.
  perform public.set_sorting_staff_attendance(
    v_shift,
    v_staff_id,
    'PRESENT',
    null,
    'Snapshot 69 validation attendance correction.'
  );

  -- Normal washing path creates performance attribution.
  v_wash := public.save_sorting_wash_run_v2(
    v_shift,
    current_setting('eliscaretex.validation.washer_id')::uuid,
    v_staff_id,
    v_start,
    2.00,
    v_customer ->> 'product_code',
    jsonb_build_array(jsonb_build_object(
      'customer_id', v_customer ->> 'customer_id',
      'schedule_product_id', v_customer ->> 'schedule_product_id',
      'scheduled_for_date', v_customer ->> 'scheduled_for_date'
    )),
    'Snapshot 69 performance validation.'
  );

  v_dashboard := public.get_sorting_staff_dashboard_context(v_shift);

  select value
  into v_staff
  from jsonb_array_elements(coalesce(v_dashboard -> 'staff', '[]'::jsonb))
  where value ->> 'staff_id' = v_staff_id::text
  limit 1;

  if coalesce((v_staff -> 'performance' ->> 'total_loads')::integer, 0) < 1 then
    raise exception 'Recorded wash was not attributed to operator performance: %', v_staff;
  end if;

  -- Misuse path 3: after recorded work exists, clicking Absent must not erase
  -- the person's contribution or create contradictory attendance.
  v_rejected := false;
  begin
    perform public.set_sorting_staff_attendance(
      v_shift,
      v_staff_id,
      'ABSENT',
      'NO_SHOW',
      'Snapshot 69 misuse test after recorded wash.'
    );
  exception
    when others then
      if sqlstate = '22023'
         and position('already has recorded washing activity' in lower(sqlerrm)) > 0 then
        v_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'Staff with recorded wash was incorrectly allowed to become absent.';
  end if;

  -- Settings are live source: temporarily change Clothes target and prove
  -- dashboard reads the Roster Settings value. Transaction will roll back.
  if v_customer ->> 'product_code' = 'CLOTHES' then
    perform public.save_production_roster_target(
      'SORTING_CLOTHES_KG_PER_STAFF_HOUR',
      161
    );

    v_dashboard := public.get_sorting_staff_dashboard_context(v_shift);

    if (v_dashboard -> 'performance_targets' ->> 'clothes_kg_hr')::numeric <> 161 then
      raise exception 'Sorting dashboard did not read the updated Roster Settings target.';
    end if;
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608100007_sorting_attendance_performance_and_auto_shift_validation_v2',
  'absence_actual_overlay', true,
  'absent_staff_excluded_from_performance_time', true,
  'absent_staff_cannot_be_mop', true,
  'absent_staff_cannot_record_wash', true,
  'staff_with_wash_cannot_be_marked_absent', true,
  'operator_wash_performance_attribution', true,
  'clothes_target_in_roster_settings', true,
  'mop_provisional_target_in_roster_settings', true,
  'settings_are_live_performance_source', true,
  'auto_shift_weekly_schedule', true,
  'auto_shift_overnight_business_date', true,
  'private_attendance_table_protected', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
