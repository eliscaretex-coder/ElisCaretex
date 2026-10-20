-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610200004_sorting_mop_two_staff
--
-- Owner request (2026-10-20): Sorting MOP can be staffed by up to two people.
--
-- Roster rule (replaces "exactly one dedicated MOP"):
--   Every Working Sorting day still needs an explicit MOP decision:
--     A) DEDICATED: one or two Sorting rows = MOP; remaining rows = CLOTHES
--     B) NO_DEDICATED_MOP: every Working Sorting row has sorting_work_mode = NULL
--
-- Sorting workstation:
--   * Planned/Actual/Operational MOP coverage is DEDICATED with one or two MOP.
--   * Setting someone to MOP no longer forces the other MOP back to Clothes;
--     a third MOP is refused with a clear message.
--   * Contexts expose the full MOP list (mop_staff / operational_mop_staff and
--     *_names). The legacy single-staff keys keep the first MOP person.
--   * MOP batch attribution is unchanged: sorting_assert_current_mop_staff
--     already accepts any current Actual MOP operator.
--
-- Published history is untouched. MOP KG targets stay per staff hour, so MOP
-- capacity scales with the number of MOP staff without further changes.
-- =====================================================================

begin;

create or replace function public.production_roster_assert_operational_rules(
  p_roster_version_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_version public.production_roster_versions%rowtype;
  v_period public.roster_periods%rowtype;
  v_bad record;
begin
  select * into v_version
  from public.production_roster_versions prv
  where prv.roster_version_id = p_roster_version_id;

  if not found then
    raise exception using errcode='P0002', message='Production Roster version not found.';
  end if;

  select * into v_period
  from public.roster_periods rp
  where rp.roster_period_id = v_version.roster_period_id;

  select sm.display_name, sm.joined_on, sm.deactivated_on
  into v_bad
  from public.production_roster_entries pre
  join public.staff_members sm on sm.staff_id = pre.staff_id
  where pre.roster_version_id = p_roster_version_id
  group by sm.staff_id, sm.display_name, sm.joined_on, sm.deactivated_on, sm.production_staff, sm.deleted_at
  having sm.production_staff is not true
      or sm.deleted_at is not null
      or (sm.joined_on is not null and sm.joined_on > v_period.week_start + 6)
      or (sm.deactivated_on is not null and sm.deactivated_on < v_period.week_start)
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        '%s is outside the Staff Master employment dates for this roster week. Remove the staff row before saving or publishing.',
        v_bad.display_name
      );
  end if;

  select sm.display_name, pre.work_date, sm.joined_on, sm.deactivated_on
  into v_bad
  from public.production_roster_entries pre
  join public.staff_members sm on sm.staff_id = pre.staff_id
  where pre.roster_version_id = p_roster_version_id
    and pre.day_status in ('WORKING','TRAINING','QUALITY_ANALYSIS')
    and (
      (sm.joined_on is not null and pre.work_date < sm.joined_on)
      or (sm.deactivated_on is not null and pre.work_date > sm.deactivated_on)
      or (
        sm.deactivated_on is null
        and (sm.active is not true or sm.roster_eligible is not true)
      )
    )
  order by pre.work_date, sm.display_name
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        '%s cannot be planned as working on %s because Staff Master employment/eligibility does not allow that date.',
        v_bad.display_name,
        to_char(v_bad.work_date,'YYYY-MM-DD')
      );
  end if;

  -- Valid Sorting daily decisions:
  -- 1) one or two MOP, with all other Working Sorting rows explicitly CLOTHES;
  -- 2) zero MOP and every Working Sorting row NULL = explicit No dedicated MOP.
  select
    pre.work_date,
    count(*) as sorting_count,
    count(*) filter (where pre.sorting_work_mode = 'MOP') as mop_count,
    count(*) filter (where pre.sorting_work_mode = 'CLOTHES') as clothes_count,
    count(*) filter (where pre.sorting_work_mode is null) as null_count
  into v_bad
  from public.production_roster_entries pre
  where pre.roster_version_id = p_roster_version_id
    and pre.day_status = 'WORKING'
    and (
      pre.area_code_snapshot = 'SORTING'
      or pre.operational_role_code_snapshot = 'SORTING_AREA'
    )
  group by pre.work_date
  having not (
    (
      count(*) filter (where pre.sorting_work_mode = 'MOP') between 1 and 2
      and count(*) filter (where pre.sorting_work_mode is null) = 0
    )
    or
    (
      count(*) filter (where pre.sorting_work_mode = 'MOP') = 0
      and count(*) filter (where pre.sorting_work_mode is null) = count(*)
    )
  )
  order by pre.work_date
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        'Choose the Sorting MOP coverage for %s: select one or two dedicated MOP staff members, or explicitly choose No dedicated MOP. Sorting staff=%s, MOP=%s, Clothes=%s, undecided=%s.',
        to_char(v_bad.work_date,'YYYY-MM-DD'),
        v_bad.sorting_count,
        v_bad.mop_count,
        v_bad.clothes_count,
        v_bad.null_count
      );
  end if;
end;
$$;

create or replace function public.get_sorting_staff_work_context_v2(
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
  v_mop_staff_id uuid;
  v_mop_staff_name text;
  v_mop_staff jsonb := '[]'::jsonb;
  v_mop_staff_names text;
  v_planned_mop_coverage text := 'UNDECIDED';
  v_actual_mop_coverage text := 'UNRESOLVED';
  v_actual_mop_count integer := 0;
  v_planned_mop_changed_to_clothes boolean := false;
begin
  v_base := public.get_sorting_staff_work_context(p_shift_code);
  v_business_date := (v_base ->> 'business_date')::date;

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code = upper(trim(coalesce(p_shift_code, '')))
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  select case
    when count(*) filter (where pre.sorting_work_mode = 'MOP') between 1 and 2
      then 'DEDICATED'
    when count(*) > 0
         and count(*) filter (where pre.sorting_work_mode is null) = count(*)
      then 'NO_DEDICATED_MOP'
    when count(*) = 0
      then 'NO_SORTING_PLAN'
    else 'UNDECIDED'
  end
  into v_planned_mop_coverage
  from jsonb_array_elements(coalesce(v_base -> 'staff', '[]'::jsonb)) staff_row
  left join public.production_roster_entries pre
    on pre.roster_entry_id = nullif(staff_row.value ->> 'roster_entry_id', '')::uuid;

  select coalesce(jsonb_agg(
    staff_row.value ||
    jsonb_build_object(
      'planned_work_mode', pre.sorting_work_mode,
      'work_mode', coalesce(mode_row.work_mode, pre.sorting_work_mode, 'CLOTHES'),
      'work_mode_explicit', mode_row.sorting_daily_staff_mode_id is not null,
      'work_mode_planned', mode_row.sorting_daily_staff_mode_id is null and pre.sorting_work_mode is not null,
      'work_mode_changed',
        mode_row.sorting_daily_staff_mode_id is not null
        and mode_row.work_mode is distinct from pre.sorting_work_mode,
      'work_mode_change_reason', mode_row.notes,
      'work_mode_changed_at', mode_row.updated_at,
      'work_mode_source', case
        when mode_row.sorting_daily_staff_mode_id is not null then 'ACTUAL_OVERRIDE'
        when pre.sorting_work_mode is not null then 'PUBLISHED_ROSTER'
        when v_planned_mop_coverage = 'NO_DEDICATED_MOP' then 'PUBLISHED_NO_DEDICATED_MOP'
        else 'DEFAULT_CLOTHES'
      end
    )
    order by lower(staff_row.value ->> 'display_name')
  ), '[]'::jsonb)
  into v_staff
  from jsonb_array_elements(coalesce(v_base -> 'staff', '[]'::jsonb)) staff_row
  left join public.production_roster_entries pre
    on pre.roster_entry_id = nullif(staff_row.value ->> 'roster_entry_id', '')::uuid
  left join public.sorting_daily_staff_modes mode_row
    on mode_row.business_date = v_business_date
   and mode_row.shift_id = v_shift_id
   and mode_row.staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid;

  select
    count(*) filter (where staff_row.value ->> 'work_mode' = 'MOP')::integer,
    coalesce(bool_or(
      staff_row.value ->> 'planned_work_mode' = 'MOP'
      and staff_row.value ->> 'work_mode' = 'CLOTHES'
      and coalesce((staff_row.value ->> 'work_mode_explicit')::boolean, false)
    ), false)
  into v_actual_mop_count, v_planned_mop_changed_to_clothes
  from jsonb_array_elements(v_staff) staff_row;

  v_actual_mop_coverage := case
    when v_actual_mop_count between 1 and 2 then 'DEDICATED'
    when v_actual_mop_count = 0
         and (
           v_planned_mop_coverage = 'NO_DEDICATED_MOP'
           or v_planned_mop_changed_to_clothes
         )
      then 'NO_DEDICATED_MOP'
    when v_actual_mop_count = 0
         and v_planned_mop_coverage = 'NO_SORTING_PLAN'
      then 'NO_SORTING_PLAN'
    else 'UNRESOLVED'
  end;

  -- One or two Actual MOP staff. The first keeps the legacy single-staff keys.
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'staff_id', nullif(staff_row.value ->> 'staff_id', '')::uuid,
      'display_name', staff_row.value ->> 'display_name'
    ) order by ord), '[]'::jsonb),
    string_agg(staff_row.value ->> 'display_name', ' & ' order by ord)
  into v_mop_staff, v_mop_staff_names
  from jsonb_array_elements(v_staff) with ordinality staff_row(value, ord)
  where staff_row.value ->> 'work_mode' = 'MOP';

  v_mop_staff_id := nullif(v_mop_staff -> 0 ->> 'staff_id', '')::uuid;
  v_mop_staff_name := v_mop_staff -> 0 ->> 'display_name';

  return v_base || jsonb_build_object(
    'staff', v_staff,
    'mop_staff_id', v_mop_staff_id,
    'mop_staff_name', v_mop_staff_name,
    'mop_staff', v_mop_staff,
    'mop_staff_names', v_mop_staff_names,
    'planned_mop_coverage', v_planned_mop_coverage,
    'actual_mop_coverage', v_actual_mop_coverage,
    'no_dedicated_mop_planned', v_planned_mop_coverage = 'NO_DEDICATED_MOP',
    'no_dedicated_mop_actual', v_actual_mop_coverage = 'NO_DEDICATED_MOP',
    'mop_assignment_missing', v_actual_mop_coverage = 'UNRESOLVED',
    'work_mode_source', 'ACTUAL_OVERRIDE_THEN_PUBLISHED_ROSTER'
  );
end;
$$;

create or replace function public.set_sorting_staff_work_mode(
  p_shift_code text,
  p_staff_id uuid,
  p_work_mode text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_work_mode text := upper(trim(coalesce(p_work_mode, '')));
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_shift public.shifts%rowtype;
  v_context jsonb;
  v_target jsonb;
  v_staff_name text;
  v_mode_id uuid;
  v_old_effective text;
  v_old_planned text;
  v_old_source text;
  v_other_name text;
  v_other_mop_count integer := 0;
  v_actor_staff_id uuid;
  v_after jsonb;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode='22023', message='Staff is required.';
  end if;

  if v_work_mode not in ('MOP', 'CLOTHES') then
    raise exception using errcode='22023', message='Sorting work mode must be MOP or CLOTHES.';
  end if;

  if v_reason is null then
    raise exception using errcode='22023', message='Reason is required for a Sorting work-mode change.';
  end if;

  if length(v_reason) > 500 then
    raise exception using errcode='22023', message='Work-mode change reason must be 500 characters or fewer.';
  end if;

  select *
  into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  v_context := public.get_sorting_staff_work_context_v2(v_shift_code);

  select value
  into v_target
  from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
  where nullif(value ->> 'staff_id', '')::uuid = p_staff_id
  limit 1;

  if v_target is null then
    raise exception using
      errcode='22023',
      message='The selected staff member is not active in Sorting for this shift.';
  end if;

  v_staff_name := v_target ->> 'display_name';
  v_old_effective := coalesce(v_target ->> 'work_mode', 'CLOTHES');
  v_old_planned := v_target ->> 'planned_work_mode';
  v_old_source := v_target ->> 'work_mode_source';
  v_actor_staff_id := public.current_staff_id();

  perform pg_advisory_xact_lock(
    hashtext(v_business_date::text || ':' || v_shift.shift_id::text || ':SORTING_MOP')
  );

  -- Sorting allows at most two Actual MOP staff. A third MOP is refused
  -- instead of silently changing someone else back to Clothes.
  if v_work_mode = 'MOP' and v_old_effective <> 'MOP' then
    -- Re-read after the lock so two simultaneous MOP changes cannot both pass.
    v_context := public.get_sorting_staff_work_context_v2(v_shift_code);

    select count(*)::integer, string_agg(value ->> 'display_name', ' & ')
    into v_other_mop_count, v_other_name
    from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
    where value ->> 'work_mode' = 'MOP'
      and nullif(value ->> 'staff_id', '')::uuid <> p_staff_id;

    if v_other_mop_count >= 2 then
      raise exception using
        errcode='22023',
        message=format(
          'Sorting already has two Actual MOP staff (%s). Change one of them to Clothes first.',
          v_other_name
        );
    end if;
  end if;

  insert into public.sorting_daily_staff_modes (
    business_date,
    shift_id,
    staff_id,
    work_mode,
    source,
    notes,
    created_by_auth_user_id,
    updated_by_auth_user_id
  )
  values (
    v_business_date,
    v_shift.shift_id,
    p_staff_id,
    v_work_mode,
    'SORTING_WORKSTATION',
    v_reason,
    auth.uid(),
    auth.uid()
  )
  on conflict (business_date, shift_id, staff_id)
  do update
  set work_mode=excluded.work_mode,
      source='SORTING_WORKSTATION',
      notes=excluded.notes,
      updated_at=now(),
      updated_by_auth_user_id=auth.uid()
  returning sorting_daily_staff_mode_id into v_mode_id;

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
    'SORTING_WORK_MODE_CHANGED',
    'sorting_daily_staff_modes',
    v_mode_id::text,
    jsonb_build_object(
      'business_date', v_business_date,
      'shift_code', v_shift_code,
      'staff_id', p_staff_id,
      'staff_name', v_staff_name,
      'planned_work_mode', v_old_planned,
      'work_mode', v_old_effective,
      'source', v_old_source
    ),
    jsonb_build_object(
      'business_date', v_business_date,
      'shift_code', v_shift_code,
      'staff_id', p_staff_id,
      'staff_name', v_staff_name,
      'planned_work_mode', v_old_planned,
      'work_mode', v_work_mode,
      'source', 'SORTING_WORKSTATION'
    ),
    v_reason,
    'SORTING_V2'
  );

  v_after := public.get_sorting_staff_work_context_v2(v_shift_code);

  return jsonb_build_object(
    'status', 'success',
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'staff_id', p_staff_id,
    'staff_name', v_staff_name,
    'previous_work_mode', v_old_effective,
    'work_mode', v_work_mode,
    'reason', v_reason,
    'actual_mop_coverage', v_after ->> 'actual_mop_coverage',
    'mop_staff_id', v_after ->> 'mop_staff_id',
    'mop_staff_name', v_after ->> 'mop_staff_name',
    'mop_staff', coalesce(v_after -> 'mop_staff', '[]'::jsonb),
    'mop_staff_names', v_after ->> 'mop_staff_names',
    'audit_recorded', true,
    'message', case
      when v_work_mode='MOP'
        then format('%s is now Actual MOP for this shift. MOP staff: %s.',
          v_staff_name,
          coalesce(v_after ->> 'mop_staff_names', v_staff_name)
        )
      when v_old_effective='MOP'
        then format('%s changed from MOP to Clothes. Actual MOP coverage is now %s.',
          v_staff_name,
          replace(coalesce(v_after ->> 'actual_mop_coverage', 'UNRESOLVED'), '_', ' ')
        )
      else format('%s is now recorded as Clothes for this shift.', v_staff_name)
    end
  );
end;
$$;

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
      'attendance_status', case
        when transfer.work_session_id is not null then 'MOVED'
        else staff_row.value ->> 'attendance_status'
      end,
      'attendance_source', case
        when transfer.work_session_id is not null then 'ACTUAL_AREA_TRANSFER'
        else staff_row.value ->> 'attendance_source'
      end,
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
    select ws.work_session_id, a.area_code, a.area_name, ws.notes
    from public.work_sessions ws
    join public.areas a on a.area_id = ws.area_id
    where ws.work_date = v_business_date
      and ws.shift_id = v_shift_id
      and ws.staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
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

create or replace function public.get_sorting_mop_production_context(
  p_shift_code text default 'MORNING',
  p_at timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_now timestamptz := coalesce(p_at,now());
  v_local timestamp;
  v_local_date date;
  v_local_time time;
  v_cfg jsonb := public.sorting_mop_reconciliation_config();
  v_cutoff time;
  v_enforcement_from date;
  v_queue jsonb := '[]'::jsonb;
  v_recent jsonb := '[]'::jsonb;
  v_staff_ctx jsonb;
  v_mop_staff_id uuid;
  v_mop_staff_name text;
  v_overdue integer:=0;
  v_due_soon integer:=0;
begin
  perform public.begin_mop_operational_scope();
  v_local:=v_now at time zone coalesce(nullif(v_cfg->>'timezone',''),'Europe/Dublin');
  v_local_date:=v_local::date;
  v_local_time:=v_local::time;
  v_cutoff:=coalesce(nullif(v_cfg->>'cutoff_local_time','')::time,time '12:00');
  v_enforcement_from:=coalesce(nullif(v_cfg->>'enforcement_from','')::date,v_local_date);
  v_staff_ctx:=public.get_sorting_staff_dashboard_context_v2(p_shift_code);
  v_mop_staff_id:=nullif(v_staff_ctx->>'operational_mop_staff_id','')::uuid;
  v_mop_staff_name:=v_staff_ctx->>'operational_mop_staff_name';

  with candidate as (
    select
      pfi.production_flow_item_id,pfi.flow_code,pfi.customer_id,
      pfi.customer_code_snapshot,pfi.customer_name_snapshot as customer_name,
      pfi.scheduled_for_date,pfi.opened_business_date,
      public.next_distribution_business_date(coalesce(pfi.scheduled_for_date,pfi.opened_business_date)) as delivery_due_date,
      pfi.source_schedule_product_id,pfi.production_order_snapshot as production_order,
      pfi.route_code_snapshot as route_code,pfi.route_display_name_snapshot as route_display_name,
      pfi.route_color_snapshot as route_color,pfi.washed_kg_total,pfi.washed_load_count,pfi.washed_trace_count,pfi.last_wash_at,
      sp.production_instructions,
      coalesce(treq.planned_qty,0) as planned_output_trolley_quantity,
      coalesce(treq.requirements,'[]'::jsonb) as output_trolley_requirements,
      coalesce(models.models,'[]'::jsonb) as models,
      rec.decision as latest_reconciliation_decision,
      rec.reason as latest_reconciliation_reason,
      rec.recorded_at as latest_reconciliation_at
    from public.production_flow_items pfi
    left join public.customer_schedule_products sp on sp.schedule_product_id=pfi.source_schedule_product_id
    left join lateral (
      select
        coalesce(sum(req.quantity),0)::integer as planned_qty,
        coalesce(jsonb_agg(jsonb_build_object(
          'trolley_type_id',req.trolley_type_id,
          'trolley_type_code',tt.trolley_type_code,
          'display_code',tt.display_code,
          'trolley_type_name',tt.trolley_type_name,
          'quantity',req.quantity,
          'empty_trolley',req.empty_trolley
        ) order by tt.sort_order,tt.display_code,tt.trolley_type_code),'[]'::jsonb) as requirements
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt on tt.trolley_type_id=req.trolley_type_id and tt.active=true and tt.deleted_at is null
      where req.owner_schedule_product_id=pfi.source_schedule_product_id and req.active=true
    ) treq on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product_variant_id',pv.product_variant_id,
        'variant_code',pv.variant_code,
        'display_name',pv.display_name,
        'unit_weight_grams',case
          when coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
            then coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams')::numeric
          else null end,
        'image_url',nullif(coalesce(pv.metadata->>'image_url',pv.metadata->>'photo_url',''),''),
        'notes',nullif(coalesce(pv.metadata->>'notes',''),''),
        'sort_order',pv.sort_order
      ) order by pv.sort_order,pv.display_name),'[]'::jsonb) as models
      from public.customer_schedule_product_variants spv
      join public.product_variants pv
        on pv.product_variant_id=spv.product_variant_id
       and pv.active=true and pv.deleted_at is null
      where spv.schedule_product_id=pfi.source_schedule_product_id
    ) models on true
    left join lateral (
      select r.decision,r.reason,r.recorded_at
      from public.sorting_mop_reconciliations r
      where r.production_flow_item_id=pfi.production_flow_item_id
      order by r.recorded_at desc limit 1
    ) rec on true
    where pfi.product_code='MOP'
      and pfi.flow_status='OPEN'
      and pfi.washed_trace_count>0
      and coalesce(pfi.scheduled_for_date,pfi.opened_business_date)>=v_enforcement_from
      and not exists(
        select 1 from public.sorting_mop_production_batches mb
        where mb.production_flow_item_id=pfi.production_flow_item_id and mb.status='RECORDED'
      )
  ), classified as (
    select c.*,
      (c.planned_output_trolley_quantity>0) as output_trolley_required,
      case
        when c.latest_reconciliation_decision='NOT_PROCESSED' then 'NOT_PROCESSED_CONFIRMED'
        when c.delivery_due_date<v_local_date
          or (c.delivery_due_date=v_local_date and v_local_time>=v_cutoff)
          then 'RECONCILIATION_REQUIRED'
        when c.delivery_due_date=v_local_date and v_local_time<v_cutoff then 'DUE_BY_NOON'
        else 'READY'
      end as production_status
    from candidate c
  )
  select coalesce(jsonb_agg(to_jsonb(c) order by
    case c.production_status when 'RECONCILIATION_REQUIRED' then 0 when 'DUE_BY_NOON' then 1 when 'NOT_PROCESSED_CONFIRMED' then 2 else 3 end,
    c.delivery_due_date,c.production_order nulls last,lower(c.customer_name)
  ),'[]'::jsonb),
  count(*) filter(where c.production_status='RECONCILIATION_REQUIRED')::integer,
  count(*) filter(where c.production_status='DUE_BY_NOON')::integer
  into v_queue,v_overdue,v_due_soon
  from classified c;

  select coalesce(jsonb_agg(jsonb_build_object(
    'mop_production_batch_id',mb.mop_production_batch_id,
    'production_flow_item_id',mb.production_flow_item_id,
    'customer_id',mb.customer_id,
    'customer_name',mb.customer_name_snapshot,
    'business_date',mb.business_date,
    'scheduled_for_date',mb.scheduled_for_date,
    'delivery_due_date',mb.delivery_due_date,
    'operator_staff_id',mb.operator_staff_id,
    'operator_name',sm.display_name,
    'entry_mode',mb.entry_mode,
    'physical_processed_on',mb.physical_processed_on,
    'physical_processed_time',mb.physical_processed_time,
    'total_kg',mb.total_weight_kg,
    'total_units',mb.total_units,
    'trolley_capture_status',mb.trolley_capture_status,
    'trolley_codes',coalesce((select jsonb_agg(mt.trolley_code_snapshot order by mt.created_at) from public.sorting_mop_production_trolleys mt where mt.mop_production_batch_id=mb.mop_production_batch_id),'[]'::jsonb),
    'lines',coalesce((select jsonb_agg(jsonb_build_object(
      'variant_code',ml.variant_code_snapshot,'variant_name',ml.variant_name_snapshot,
      'weight_kg',ml.weight_kg,'units',ml.units,'unit_weight_grams',ml.unit_weight_grams_snapshot
    ) order by ml.created_at) from public.sorting_mop_production_lines ml where ml.mop_production_batch_id=mb.mop_production_batch_id),'[]'::jsonb),
    'recorded_at',mb.recorded_at,
    'notes',mb.notes
  ) order by mb.recorded_at desc),'[]'::jsonb)
  into v_recent
  from (
    select * from public.sorting_mop_production_batches
    where status='RECORDED'
    order by recorded_at desc limit 20
  ) mb
  left join public.staff_members sm on sm.staff_id=mb.operator_staff_id;

  return jsonb_build_object(
    'business_date',v_business_date,
    'shift_code',upper(trim(p_shift_code)),
    'generated_at',v_now,
    'local_now',v_local,
    'cutoff_local_time',v_cutoff,
    'enforcement_from',v_enforcement_from,
    'operational_mop_staff_id',v_mop_staff_id,
    'operational_mop_staff_name',v_mop_staff_name,
    'operational_mop_staff',coalesce(v_staff_ctx->'operational_mop_staff','[]'::jsonb),
    'operational_mop_staff_names',v_staff_ctx->>'operational_mop_staff_names',
    'operational_mop_coverage',v_staff_ctx->>'operational_mop_coverage',
    'queue',v_queue,
    'overdue_unresolved_count',v_overdue,
    'due_today_before_cutoff_count',v_due_soon,
    'reconciliation_blocked',v_overdue>0,
    'recent_production',v_recent,
    'source','PRODUCTION_FLOW_WASHED_MOP_PLUS_MOP_PRODUCTION'
  );
end;
$$;

comment on column public.production_roster_entries.sorting_work_mode is
  'Planned Sorting subassignment. MOP/CLOTHES means a dedicated MOP decision (one or two MOP staff per day); NULL on every Working Sorting row for the date means explicit No dedicated MOP.';

comment on function public.production_roster_assert_operational_rules(uuid) is
  'Private Roster guard for Staff Master employment dates and an explicit daily Sorting MOP decision: one or two dedicated MOP staff or explicit No dedicated MOP.';

commit;
