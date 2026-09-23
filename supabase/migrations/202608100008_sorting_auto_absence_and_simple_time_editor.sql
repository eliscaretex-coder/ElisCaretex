-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608100008_sorting_auto_absence_and_simple_time_editor
--
-- Attendance rule:
--   * confirmed ABSENT remains an explicit audited fact;
--   * AUTO_ABSENT is an inferred read-model state only;
--   * AUTO_ABSENT is used after the standard shift finish + grace period when
--     there is no washing or other Actual-work evidence;
--   * a later RECORDED wash immediately becomes presence evidence and removes
--     the inferred AUTO_ABSENT state;
--   * future Trolley Intake activity can be added as another evidence source.
--
-- Time editor:
--   Database API remains Started/Leaving + optional extra_non_work_minutes.
--   The frontend hides Time away/Reason unless the operator explicitly says
--   there was time away during the shift.
-- =====================================================================

begin;

insert into public.app_config (
  config_key,
  value_json,
  description
)
values (
  'sorting_auto_absent_grace_minutes',
  to_jsonb(15),
  'Minutes after the latest standard shift finish before a planned Sorting staff member with no Actual activity is shown as inferred AUTO_ABSENT.'
)
on conflict (config_key) do nothing;

create or replace function public.sorting_shift_auto_absence_context(
  p_business_date date,
  p_shift_code text,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_profile jsonb;
  v_profile_code text;
  v_end_time time;
  v_grace integer := 15;
  v_cutoff_at timestamptz;
begin
  if p_business_date is null then
    raise exception using errcode='22023', message='Business Date is required.';
  end if;

  if v_shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be MORNING or EVENING.';
  end if;

  v_profile := public.production_roster_work_profile_context(
    p_business_date,
    v_shift_code
  );

  v_profile_code := v_profile ->> 'profile_code';

  if nullif(v_profile ->> 'default_end_time', '') is not null then
    v_end_time := (v_profile ->> 'default_end_time')::time;
  else
    -- Morning Monday-Friday has two legitimate standard windows.
    -- Absence inference must use the latest possible standard finish so that
    -- a 07:00 starter is never inferred absent while still inside the normal shift.
    v_end_time := case v_profile_code
      when 'MORNING_MON_WED' then time '16:00'
      when 'MORNING_THU_FRI' then time '15:00'
      when 'MORNING_SAT_BANK' then time '15:00'
      else case
        when v_shift_code='MORNING' then time '16:00'
        else time '23:20'
      end
    end;
  end if;

  select coalesce((value_json #>> '{}')::integer, 15)
  into v_grace
  from public.app_config
  where config_key='sorting_auto_absent_grace_minutes';

  v_grace := greatest(0, least(coalesce(v_grace,15), 180));

  v_cutoff_at :=
    public.operational_timestamp_for_shift(
      p_business_date,
      v_shift_code,
      v_end_time
    )
    + make_interval(mins => v_grace);

  return jsonb_build_object(
    'business_date', p_business_date,
    'shift_code', v_shift_code,
    'profile_code', v_profile_code,
    'standard_schedule_label', v_profile ->> 'schedule_label',
    'latest_standard_end_time', v_end_time,
    'grace_minutes', v_grace,
    'auto_absent_cutoff_at', v_cutoff_at,
    'cutoff_reached', p_at >= v_cutoff_at,
    'inference_only', true
  );
end;
$$;

create or replace function public.sorting_resolve_attendance_status(
  p_explicit_status text,
  p_recorded_loads integer,
  p_adjusted boolean,
  p_manual_position boolean,
  p_cutoff_reached boolean
)
returns text
language sql
immutable
as $$
  select case
    when upper(coalesce(p_explicit_status,'')) = 'ABSENT'
      then 'ABSENT'
    when upper(coalesce(p_explicit_status,'')) = 'PRESENT'
      then 'PRESENT'
    when coalesce(p_recorded_loads,0) > 0
      or coalesce(p_adjusted,false)
      or coalesce(p_manual_position,false)
      then 'PRESENT_EVIDENCE'
    when coalesce(p_cutoff_reached,false)
      then 'AUTO_ABSENT'
    else 'PLANNED'
  end;
$$;

create or replace function public.get_sorting_staff_dashboard_context(
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
  v_clothes_target numeric := 160;
  v_mop_target numeric := 100;
  v_staff jsonb := '[]'::jsonb;
  v_not_absent_count integer := 0;
  v_confirmed_absent_count integer := 0;
  v_auto_absent_count integer := 0;
  v_effective_mop_count integer := 0;
  v_effective_mop_staff_id uuid;
  v_effective_mop_staff_name text;
  v_operational_mop_coverage text := 'UNRESOLVED';
  v_auto_absence jsonb;
begin
  v_base := public.get_sorting_staff_work_context_v2(p_shift_code);
  v_business_date := (v_base ->> 'business_date')::date;

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code = upper(trim(coalesce(p_shift_code, '')))
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  v_auto_absence := public.sorting_shift_auto_absence_context(
    v_business_date,
    p_shift_code,
    now()
  );

  select coalesce(pt.target_value, 160)
  into v_clothes_target
  from public.production_targets pt
  where pt.target_code = 'SORTING_CLOTHES_KG_PER_STAFF_HOUR'
    and pt.active = true;

  v_clothes_target := coalesce(v_clothes_target, 160);

  select coalesce(pt.target_value, 100)
  into v_mop_target
  from public.production_targets pt
  where pt.target_code = 'SORTING_MOP_KG_PER_STAFF_HOUR'
    and pt.active = true;

  v_mop_target := coalesce(v_mop_target, 100);

  select coalesce(jsonb_agg(
    staff_row.value ||
    jsonb_build_object(
      'attendance_status', resolved.attendance_status,
      'attendance_inferred', resolved.attendance_status = 'AUTO_ABSENT',
      'attendance_source', case resolved.attendance_status
        when 'ABSENT' then 'CONFIRMED_ATTENDANCE'
        when 'PRESENT' then 'CONFIRMED_ATTENDANCE'
        when 'PRESENT_EVIDENCE' then case
          when coalesce(perf.total_loads,0) > 0 then 'WASH_ACTIVITY'
          when coalesce((staff_row.value ->> 'adjusted')::boolean,false) then 'ACTUAL_TIME_ADJUSTMENT'
          when coalesce((staff_row.value ->> 'manual_position')::boolean,false) then 'MANUAL_ACTUAL_POSITION'
          else 'ACTUAL_EVIDENCE'
        end
        when 'AUTO_ABSENT' then 'AUTO_NO_WASH_ACTIVITY'
        else 'PUBLISHED_ROSTER_ONLY'
      end,
      'absence_reason', att.absence_reason,
      'attendance_notes', att.notes,
      'attendance_changed_at', att.updated_at,
      'auto_absent_cutoff_at', v_auto_absence ->> 'auto_absent_cutoff_at',
      'performance',
        jsonb_build_object(
          'basis', 'EFFECTIVE_SHIFT_MINUTES',
          'worked_minutes',
            case
              when resolved.attendance_status in ('ABSENT','AUTO_ABSENT') then 0
              else coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::integer, 0)
            end,
          'worked_hours',
            case
              when resolved.attendance_status in ('ABSENT','AUTO_ABSENT') then 0
              else round(
                coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) / 60.0,
                2
              )
            end,
          'clothes_kg', coalesce(perf.clothes_kg, 0),
          'clothes_loads', coalesce(perf.clothes_loads, 0),
          'clothes_kg_hr',
            case
              when resolved.attendance_status in ('ABSENT','AUTO_ABSENT')
                or coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) <= 0
                then null
              else round(
                coalesce(perf.clothes_kg, 0) * 60.0 /
                nullif(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0),
                1
              )
            end,
          'clothes_target_kg_hr', v_clothes_target,
          'clothes_target_pct',
            case
              when resolved.attendance_status in ('ABSENT','AUTO_ABSENT')
                or coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) <= 0
                then null
              else round(
                (
                  coalesce(perf.clothes_kg, 0) * 60.0 /
                  nullif(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0)
                ) / nullif(v_clothes_target, 0) * 100.0,
                1
              )
            end,
          'mop_kg', coalesce(perf.mop_kg, 0),
          'mop_loads', coalesce(perf.mop_loads, 0),
          'mop_kg_hr',
            case
              when resolved.attendance_status in ('ABSENT','AUTO_ABSENT')
                or coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) <= 0
                then null
              else round(
                coalesce(perf.mop_kg, 0) * 60.0 /
                nullif(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0),
                1
              )
            end,
          'mop_target_kg_hr', v_mop_target,
          'mop_target_pct',
            case
              when resolved.attendance_status in ('ABSENT','AUTO_ABSENT')
                or coalesce(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0) <= 0
                then null
              else round(
                (
                  coalesce(perf.mop_kg, 0) * 60.0 /
                  nullif(nullif(staff_row.value ->> 'net_work_minutes', '')::numeric, 0)
                ) / nullif(v_mop_target, 0) * 100.0,
                1
              )
            end,
          'mop_target_provisional', true,
          'total_loads', coalesce(perf.total_loads, 0)
        )
    )
    order by
      case when resolved.attendance_status in ('ABSENT','AUTO_ABSENT') then 1 else 0 end,
      lower(staff_row.value ->> 'display_name')
  ), '[]'::jsonb)
  into v_staff
  from jsonb_array_elements(coalesce(v_base -> 'staff', '[]'::jsonb)) staff_row
  left join public.sorting_daily_staff_attendance att
    on att.business_date = v_business_date
   and att.shift_id = v_shift_id
   and att.staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
  left join lateral (
    select
      coalesce(sum(wr.total_weight_kg) filter (where wr.wash_type = 'CLOTHES'), 0) as clothes_kg,
      count(*) filter (where wr.wash_type = 'CLOTHES')::integer as clothes_loads,
      coalesce(sum(wr.total_weight_kg) filter (where wr.wash_type = 'MOP'), 0) as mop_kg,
      count(*) filter (where wr.wash_type = 'MOP')::integer as mop_loads,
      count(*)::integer as total_loads
    from public.sorting_wash_runs wr
    where wr.business_date = v_business_date
      and wr.shift_id = v_shift_id
      and wr.operator_staff_id = nullif(staff_row.value ->> 'staff_id', '')::uuid
      and wr.status = 'RECORDED'
  ) perf on true
  left join lateral (
    select public.sorting_resolve_attendance_status(
      att.attendance_status,
      perf.total_loads,
      coalesce((staff_row.value ->> 'adjusted')::boolean,false),
      coalesce((staff_row.value ->> 'manual_position')::boolean,false),
      coalesce((v_auto_absence ->> 'cutoff_reached')::boolean,false)
    ) as attendance_status
  ) resolved on true;

  select
    count(*) filter (
      where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT')
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' = 'ABSENT'
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' = 'AUTO_ABSENT'
    )::integer,
    count(*) filter (
      where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT')
        and staff_row.value ->> 'work_mode' = 'MOP'
    )::integer
  into
    v_not_absent_count,
    v_confirmed_absent_count,
    v_auto_absent_count,
    v_effective_mop_count
  from jsonb_array_elements(v_staff) staff_row;

  select
    nullif(staff_row.value ->> 'staff_id', '')::uuid,
    staff_row.value ->> 'display_name'
  into v_effective_mop_staff_id, v_effective_mop_staff_name
  from jsonb_array_elements(v_staff) staff_row
  where staff_row.value ->> 'attendance_status' not in ('ABSENT','AUTO_ABSENT')
    and staff_row.value ->> 'work_mode' = 'MOP'
  limit 1;

  v_operational_mop_coverage := case
    when v_not_absent_count = 0 then 'NO_PRESENT_SORTING_STAFF'
    when v_effective_mop_count = 1 then 'DEDICATED'
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
      'not_absent', v_not_absent_count,
      'confirmed_absent', v_confirmed_absent_count,
      'auto_absent', v_auto_absent_count,
      'absent_total', v_confirmed_absent_count + v_auto_absent_count
    ),
    'auto_absence', v_auto_absence,
    'performance_targets', jsonb_build_object(
      'clothes_kg_hr', v_clothes_target,
      'mop_kg_hr', v_mop_target,
      'mop_provisional', true,
      'source', 'PRODUCTION_TARGETS'
    ),
    'operational_mop_coverage', v_operational_mop_coverage,
    'operational_mop_staff_id', v_effective_mop_staff_id,
    'operational_mop_staff_name', v_effective_mop_staff_name
  );
end;
$$;

revoke all on function public.sorting_shift_auto_absence_context(date,text,timestamptz)
  from public, anon, authenticated;
revoke all on function public.sorting_resolve_attendance_status(text,integer,boolean,boolean,boolean)
  from public, anon, authenticated;
revoke all on function public.get_sorting_staff_dashboard_context(text)
  from public, anon, authenticated;

grant execute on function public.get_sorting_staff_dashboard_context(text)
  to authenticated;

comment on function public.sorting_resolve_attendance_status(text,integer,boolean,boolean,boolean) is
  'Private deterministic attendance read-model resolver. AUTO_ABSENT is inferred only and is never equivalent to a confirmed SICK/NO_SHOW/OTHER absence.';

comment on function public.get_sorting_staff_dashboard_context(text) is
  'Sorting Staff card context with confirmed/inferred attendance and per-operator performance. Planned staff with no Actual activity become AUTO_ABSENT only after the standard shift finish plus grace period; later activity automatically restores presence evidence.';

commit;
