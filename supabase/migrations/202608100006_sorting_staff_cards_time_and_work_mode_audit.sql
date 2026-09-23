-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608100006_sorting_staff_cards_time_and_work_mode_audit
--
-- Purpose:
--   * make Sorting Actual MOP/CLOTHES changes explicitly auditable;
--   * allow the current MOP person to be changed back to CLOTHES;
--   * guarantee at most one Actual MOP after an override;
--   * expose Planned vs Actual work mode and change reason to Staff cards.
--
-- Time-away storage remains integer minutes in the database. The workstation
-- UI converts a simple Hours + Minutes input to minutes so operators do not
-- need to calculate minutes manually.
-- =====================================================================

begin;

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
    when count(*) filter (where pre.sorting_work_mode = 'MOP') = 1
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
    when v_actual_mop_count = 1 then 'DEDICATED'
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

  select
    nullif(staff_row.value ->> 'staff_id', '')::uuid,
    staff_row.value ->> 'display_name'
  into v_mop_staff_id, v_mop_staff_name
  from jsonb_array_elements(v_staff) staff_row
  where staff_row.value ->> 'work_mode' = 'MOP'
  limit 1;

  return v_base || jsonb_build_object(
    'staff', v_staff,
    'mop_staff_id', v_mop_staff_id,
    'mop_staff_name', v_mop_staff_name,
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
  v_other jsonb;
  v_other_staff_id uuid;
  v_other_mode_id uuid;
  v_other_name text;
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

  -- If a person becomes Actual MOP, every other effective MOP must become
  -- Actual CLOTHES, including a MOP inherited only from the Published Roster.
  if v_work_mode = 'MOP' then
    for v_other in
      select value
      from jsonb_array_elements(coalesce(v_context -> 'staff', '[]'::jsonb))
      where value ->> 'work_mode' = 'MOP'
        and nullif(value ->> 'staff_id', '')::uuid <> p_staff_id
    loop
      v_other_staff_id := nullif(v_other ->> 'staff_id', '')::uuid;
      v_other_name := v_other ->> 'display_name';

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
        v_other_staff_id,
        'CLOTHES',
        'SORTING_WORKSTATION',
        format(
          'Changed to CLOTHES because %s was assigned MOP. Reason: %s',
          v_staff_name,
          v_reason
        ),
        auth.uid(),
        auth.uid()
      )
      on conflict (business_date, shift_id, staff_id)
      do update
      set work_mode='CLOTHES',
          source='SORTING_WORKSTATION',
          notes=excluded.notes,
          updated_at=now(),
          updated_by_auth_user_id=auth.uid()
      returning sorting_daily_staff_mode_id into v_other_mode_id;

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
        v_other_mode_id::text,
        jsonb_build_object(
          'business_date', v_business_date,
          'shift_code', v_shift_code,
          'staff_id', v_other_staff_id,
          'staff_name', v_other_name,
          'work_mode', 'MOP',
          'source', v_other ->> 'work_mode_source'
        ),
        jsonb_build_object(
          'business_date', v_business_date,
          'shift_code', v_shift_code,
          'staff_id', v_other_staff_id,
          'staff_name', v_other_name,
          'work_mode', 'CLOTHES',
          'source', 'SORTING_WORKSTATION',
          'changed_because_new_mop_staff_id', p_staff_id
        ),
        v_reason,
        'SORTING_V2'
      );
    end loop;
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
    'audit_recorded', true,
    'message', case
      when v_work_mode='MOP'
        then format('%s is now the Actual MOP staff for this shift.', v_staff_name)
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

-- Compatibility wrapper used by older Sorting frontend snapshots.
create or replace function public.set_sorting_mop_staff(
  p_shift_code text,
  p_staff_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  return public.set_sorting_staff_work_mode(
    p_shift_code,
    p_staff_id,
    'MOP',
    'MOP assignment changed from Sorting workstation.'
  );
end;
$$;

revoke all on function public.get_sorting_staff_work_context_v2(text)
  from public, anon, authenticated;
revoke all on function public.set_sorting_staff_work_mode(text,uuid,text,text)
  from public, anon, authenticated;
revoke all on function public.set_sorting_mop_staff(text,uuid)
  from public, anon, authenticated;

grant execute on function public.get_sorting_staff_work_context_v2(text)
  to authenticated;
grant execute on function public.set_sorting_staff_work_mode(text,uuid,text,text)
  to authenticated;
grant execute on function public.set_sorting_mop_staff(text,uuid)
  to authenticated;

comment on function public.set_sorting_staff_work_mode(text,uuid,text,text) is
  'Traceable Actual Sorting work-mode override. Supports MOP -> CLOTHES and CLOTHES -> MOP with required reason and audit_log evidence. Assigning MOP automatically overrides every other effective MOP to CLOTHES, including a MOP inherited from the Published Roster.';

commit;
