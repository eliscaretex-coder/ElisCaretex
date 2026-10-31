-- Staff transfer between production areas from "Add someone".
--
-- Owner request (2026-10-30): when Finish uses "Add someone to Finish/Table" (or Sorting
-- and MOP use "Add someone to Sorting") for a person who is working in another area at
-- that time, the system must notice it, ask, and transfer the person: the previous area
-- stops at the chosen time, the new area starts at that time and each area keeps its
-- own hours.
--
-- Until now:
--   * upsert_finish_staff_actual created a Finish session without looking at Sorting, so
--     a Sorting person added to Finish was counted in both areas.
--   * add_sorting_actual_staff created a whole-shift Sorting session without looking at
--     Finish, with the same double count.
--   * Label and Cleaner people had no station time, so a move to a Table lost the time
--     worked before the move.
--
-- This migration:
--   0. Lets a transfer mark the destination work session as the latest one (see the
--      work_sessions updated_at trigger below).
--   1. Adds the FINISH_CLEANER station so Cleaner time can be kept as a segment
--      (Label already has FINISH_LABEL). Table metrics only read Tables 1-3.
--   2. staff_area_presence_v1 (internal): where a person is at a given time of the
--      shift, from Actual work sessions first and the published Roster second.
--   3. staff_area_transfer_plan_v1 (internal) and get_staff_area_transfer_check_v1
--      (RPC): what adding the person to a Table or to Sorting means (transfer, table
--      move, whole-shift move, return to an area worked earlier, or nothing).
--   4. transfer_staff_into_area_v1 (+ Finish terminal wrapper): performs the transfer.
--      The session shapes match the existing moves (move_sorting_staff_to_finish_table_v2
--      and move_finish_staff_to_sorting_v1), so Sorting and Finish lists read them as
--      before. A return to an area worked earlier in the shift reopens that area: Finish
--      adds a new Table segment; Sorting records the time away as non-work minutes.
--   5. upsert_finish_staff_actual and add_sorting_actual_staff refuse to create a second
--      area record for someone who is working elsewhere, and point to the transfer.
--   6. get_finish_staff_context_v4 also returns the Finish segments of people who left
--      Finish, so the Table metrics keep the hours they worked there.
--
-- The published Roster is never changed. Every transfer is written to audit_log.

begin;

insert into public.stations (area_id, station_code, station_name, station_type, active, sort_order)
select a.area_id, 'FINISH_CLEANER', 'Cleaner', 'WORKSTATION', true, 50
from public.areas a
where a.area_code = 'FINISH' and a.deleted_at is null
on conflict (station_code) do nothing;

-- Finish Staff reads the most recently updated work session as the person's current
-- area. A transfer writes two sessions in one transaction, where now() is the same for
-- both, so the destination is written with clock_timestamp(). The work_sessions trigger
-- keeps such a later value; every other update still gets now(), as before.
create or replace function public.work_sessions_set_updated_at_v2()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.updated_at is null or new.updated_at <= now() or new.updated_at is not distinct from old.updated_at then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

revoke all on function public.work_sessions_set_updated_at_v2() from public, anon, authenticated;

create or replace trigger work_sessions_set_updated_at
  before update on public.work_sessions
  for each row execute function public.work_sessions_set_updated_at_v2();

-- ---------------------------------------------------------------------------
-- 2. Where is this person at this time of the shift?
-- ---------------------------------------------------------------------------
create or replace function public.staff_area_presence_v1(
  p_staff_id uuid,
  p_shift_code text,
  p_move_time time
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift public.shifts%rowtype;
  v_business_date date;
  v_move_at timestamptz;
  v_staff_name text;
  v_profile jsonb;
  v_profile_start time;
  v_profile_end time;
  v_profile_break integer := 0;
  v_plan record;
  v_plan_area text;
  v_plan_station text;
  v_plan_working boolean := false;
  v_plan_start_at timestamptz;
  v_plan_end_at timestamptz;
  v_ws record;
  v_seg record;
  v_status text := 'NOT_WORKING';
  v_basis text;
  v_area_code text;
  v_area_name text;
  v_station_code text;
  v_station_name text;
  v_since timestamptz;
  v_until timestamptz;
  v_session_id uuid;
  v_work_mode text;
  v_label text;
begin
  select * into v_shift from public.shifts
  where shift_code = upper(trim(coalesce(p_shift_code, ''))) and active = true and deleted_at is null
  limit 1;
  if not found or v_shift.shift_code not in ('MORNING', 'EVENING') then
    raise exception using errcode = '22023', message = 'Shift must be Morning or Evening.';
  end if;
  if p_staff_id is null or p_move_time is null then
    raise exception using errcode = '22023', message = 'Staff and time are required.';
  end if;
  select sm.display_name into v_staff_name from public.staff_members sm
  where sm.staff_id = p_staff_id and sm.deleted_at is null;
  if v_staff_name is null then
    raise exception using errcode = 'P0002', message = 'Selected staff member is not available.';
  end if;

  v_business_date := public.operational_business_date_for_shift(v_shift.shift_code);
  v_move_at := public.operational_timestamp_for_shift(v_business_date, v_shift.shift_code, p_move_time);
  v_profile := public.production_roster_work_profile_context(v_business_date, v_shift.shift_code);
  v_profile_start := nullif(v_profile ->> 'default_start_time', '')::time;
  v_profile_end := nullif(v_profile ->> 'default_end_time', '')::time;
  v_profile_break := coalesce(nullif(v_profile ->> 'break_minutes', '')::integer, 0);

  -- Published plan for this shift.
  select
    pre.roster_entry_id, pre.roster_version_id, pre.day_status,
    pre.planned_start_time, pre.planned_end_time, pre.display_section_code, pre.sorting_work_mode,
    coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) as area_code,
    coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) as station_code,
    coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) as role_code
  into v_plan
  from public.production_roster_entries pre
  join public.production_roster_versions prv on prv.roster_version_id = pre.roster_version_id
  left join public.areas a on a.area_id = pre.area_id
  left join public.stations st on st.station_id = pre.station_id
  left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
  where prv.status = 'PUBLISHED'
    and prv.shift_id = v_shift.shift_id
    and pre.work_date = v_business_date
    and pre.staff_id = p_staff_id
  order by prv.published_at desc nulls last, prv.version_number desc
  limit 1;

  if v_plan.roster_entry_id is not null then
    if v_plan.area_code = 'SORTING' or v_plan.station_code = 'SORTING_MAIN'
       or v_plan.display_section_code = 'SORTING_AREA' or v_plan.role_code = 'SORTING_AREA' then
      v_plan_area := 'SORTING';
      v_plan_station := 'SORTING_MAIN';
      v_plan_working := v_plan.day_status = 'WORKING';
    elsif v_plan.area_code = 'FINISH' then
      v_plan_area := 'FINISH';
      v_plan_station := case
        when v_plan.station_code is not null then v_plan.station_code
        when v_plan.display_section_code = 'CLEANER' or v_plan.role_code = 'CLEANER' then 'FINISH_CLEANER'
      end;
      v_plan_working := v_plan.day_status in ('WORKING', 'QUALITY_ANALYSIS');
    else
      v_plan_area := v_plan.area_code;
      v_plan_working := v_plan.day_status = 'WORKING';
    end if;
  end if;

  v_plan_start_at := public.operational_timestamp_for_shift(
    v_business_date, v_shift.shift_code, coalesce(v_plan.planned_start_time, v_profile_start));
  v_plan_end_at := public.operational_timestamp_for_shift(
    v_business_date, v_shift.shift_code, coalesce(v_plan.planned_end_time, v_profile_end));
  if v_plan_start_at is not null and v_plan_end_at is not null and v_plan_end_at <= v_plan_start_at then
    v_plan_end_at := v_plan_end_at + interval '1 day';
  end if;

  -- Actual work that covers the time wins over the Roster.
  select ws.work_session_id, ws.actual_start_at, ws.actual_end_at, ws.source,
    a.area_code, a.area_name, st.station_code, st.station_name,
    coalesce(ws.actual_start_at, v_plan_start_at) as effective_start
  into v_ws
  from public.work_sessions ws
  join public.areas a on a.area_id = ws.area_id
  left join public.stations st on st.station_id = ws.station_id
  where ws.work_date = v_business_date
    and ws.shift_id = v_shift.shift_id
    and ws.staff_id = p_staff_id
    and ws.status <> 'CANCELLED'
    and coalesce(ws.actual_start_at, v_plan_start_at, v_move_at) <= v_move_at
    and (ws.actual_end_at is null or ws.actual_end_at > v_move_at)
  order by ws.updated_at desc
  limit 1;

  if v_ws.work_session_id is not null then
    v_status := 'ACTIVE';
    v_basis := 'ACTUAL';
    v_session_id := v_ws.work_session_id;
    v_area_code := v_ws.area_code;
    v_area_name := v_ws.area_name;
    v_station_code := v_ws.station_code;
    v_station_name := v_ws.station_name;
    v_since := v_ws.effective_start;
    v_until := coalesce(v_ws.actual_end_at, v_plan_end_at);
    if v_area_code = 'FINISH' then
      select st.station_code, st.station_name, s.started_at into v_seg
      from public.finish_staff_table_segments s
      join public.stations st on st.station_id = s.station_id
      where s.work_session_id = v_ws.work_session_id
        and s.started_at <= v_move_at
        and (s.ended_at is null or s.ended_at > v_move_at)
      order by s.started_at desc
      limit 1;
      if v_seg.station_code is not null then
        v_station_code := v_seg.station_code;
        v_station_name := v_seg.station_name;
        v_since := v_seg.started_at;
      end if;
    end if;
  else
    -- Actual work exists but not at this time: starts later or already finished.
    select ws.work_session_id, ws.actual_start_at, ws.actual_end_at, a.area_code, a.area_name,
      st.station_code, st.station_name, coalesce(ws.actual_start_at, v_plan_start_at) as effective_start
    into v_ws
    from public.work_sessions ws
    join public.areas a on a.area_id = ws.area_id
    left join public.stations st on st.station_id = ws.station_id
    where ws.work_date = v_business_date
      and ws.shift_id = v_shift.shift_id
      and ws.staff_id = p_staff_id
      and ws.status <> 'CANCELLED'
      and coalesce(ws.actual_start_at, v_plan_start_at) > v_move_at
    order by coalesce(ws.actual_start_at, v_plan_start_at)
    limit 1;
    if v_ws.work_session_id is not null then
      v_status := 'STARTS_LATER';
    else
      select ws.work_session_id, ws.actual_start_at, ws.actual_end_at, a.area_code, a.area_name,
        st.station_code, st.station_name, coalesce(ws.actual_start_at, v_plan_start_at) as effective_start
      into v_ws
      from public.work_sessions ws
      join public.areas a on a.area_id = ws.area_id
      left join public.stations st on st.station_id = ws.station_id
      where ws.work_date = v_business_date
        and ws.shift_id = v_shift.shift_id
        and ws.staff_id = p_staff_id
        and ws.status <> 'CANCELLED'
      order by ws.actual_end_at desc nulls last
      limit 1;
      if v_ws.work_session_id is not null then
        v_status := 'FINISHED';
      end if;
    end if;

    if v_ws.work_session_id is not null then
      v_basis := 'ACTUAL';
      v_session_id := v_ws.work_session_id;
      v_area_code := v_ws.area_code;
      v_area_name := v_ws.area_name;
      v_station_code := v_ws.station_code;
      v_station_name := v_ws.station_name;
      v_since := v_ws.effective_start;
      v_until := v_ws.actual_end_at;
    elsif v_plan_working then
      v_basis := 'ROSTER';
      v_area_code := v_plan_area;
      v_station_code := v_plan_station;
      select a.area_name into v_area_name from public.areas a where a.area_code = v_plan_area and a.deleted_at is null limit 1;
      select st.station_name into v_station_name from public.stations st where st.station_code = v_plan_station and st.deleted_at is null limit 1;
      v_since := v_plan_start_at;
      v_until := v_plan_end_at;
      if (v_plan_area = 'SORTING' and exists (
            select 1 from public.sorting_daily_staff_attendance att
            where att.business_date = v_business_date and att.shift_id = v_shift.shift_id
              and att.staff_id = p_staff_id and att.attendance_status = 'ABSENT'))
         or (v_plan_area = 'FINISH' and exists (
            select 1 from public.finish_daily_staff_attendance att
            where att.business_date = v_business_date and att.shift_id = v_shift.shift_id
              and att.staff_id = p_staff_id and att.attendance_status = 'ABSENT')) then
        v_status := 'ABSENT';
      elsif v_plan_start_at is not null and v_move_at < v_plan_start_at then
        v_status := 'STARTS_LATER';
      elsif v_plan_end_at is not null and v_move_at >= v_plan_end_at then
        v_status := 'FINISHED';
      else
        v_status := 'ACTIVE';
      end if;
    end if;
  end if;

  if v_area_code = 'SORTING' then
    select m.work_mode into v_work_mode from public.sorting_daily_staff_modes m
    where m.business_date = v_business_date and m.shift_id = v_shift.shift_id and m.staff_id = p_staff_id
    limit 1;
    v_work_mode := coalesce(v_work_mode, case when v_plan_area = 'SORTING' then v_plan.sorting_work_mode end, 'CLOTHES');
  end if;

  v_label := case
    when v_area_code is null then null
    when v_area_code = 'SORTING' then 'Sorting' || case when v_work_mode = 'MOP' then ' (MOP)' else '' end
    when v_area_code = 'FINISH' and v_station_code like 'FINISH_TABLE_%' then 'Finish ' || coalesce(v_station_name, v_station_code)
    when v_area_code = 'FINISH' and v_station_name is not null then v_station_name
    when v_area_code = 'FINISH' then 'Finish'
    else coalesce(v_area_name, v_area_code)
  end;

  return jsonb_build_object(
    'staff_id', p_staff_id,
    'staff_name', v_staff_name,
    'business_date', v_business_date,
    'shift_code', v_shift.shift_code,
    'shift_id', v_shift.shift_id,
    'move_time', to_char(v_move_at at time zone 'Europe/Dublin', 'HH24:MI'),
    'move_at', v_move_at,
    'status', v_status,
    'basis', v_basis,
    'area_code', v_area_code,
    'area_label', v_label,
    'station_code', v_station_code,
    'work_mode', v_work_mode,
    'work_session_id', v_session_id,
    'since_at', v_since,
    'since_time', to_char(v_since at time zone 'Europe/Dublin', 'HH24:MI'),
    'until_at', v_until,
    'until_time', to_char(v_until at time zone 'Europe/Dublin', 'HH24:MI'),
    'plan_area_code', v_plan_area,
    'plan_station_code', v_plan_station,
    'plan_working', v_plan_working,
    'roster_entry_id', v_plan.roster_entry_id,
    'roster_version_id', v_plan.roster_version_id,
    'plan_start_at', v_plan_start_at,
    'plan_end_at', v_plan_end_at,
    'standard_break_minutes', v_profile_break
  );
end;
$$;

revoke all on function public.staff_area_presence_v1(uuid, text, time) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. What does adding this person to a Table or to Sorting mean?
-- ---------------------------------------------------------------------------
create or replace function public.staff_area_transfer_plan_v1(
  p_staff_id uuid,
  p_shift_code text,
  p_to_area_code text,
  p_to_table_code text,
  p_move_time time
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_to text := upper(trim(coalesce(p_to_area_code, '')));
  v_table text := nullif(upper(trim(coalesce(p_to_table_code, ''))), '');
  v_p jsonb;
  v_status text;
  v_area text;
  v_station text;
  v_basis text;
  v_name text;
  v_label text;
  v_since timestamptz;
  v_move_at timestamptz;
  v_plan_end_at timestamptz;
  v_dest_label text;
  v_dest record;
  v_mode text := 'NONE';
  v_return boolean := false;
  v_reason text;
  v_message text;
  v_cover boolean := false;
begin
  if v_to = 'FINISH' then
    if v_table is null or v_table not in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3') then
      raise exception using errcode = '22023', message = 'Choose Finish Table 1, Table 2 or Table 3.';
    end if;
    v_dest_label := 'Finish Table ' || right(v_table, 1);
  elsif v_to = 'SORTING' then
    v_table := null;
    v_dest_label := 'Sorting';
  else
    raise exception using errcode = '22023', message = 'Choose Finish or Sorting as the destination.';
  end if;

  v_p := public.staff_area_presence_v1(p_staff_id, p_shift_code, p_move_time);
  v_status := v_p ->> 'status';
  v_area := v_p ->> 'area_code';
  v_station := v_p ->> 'station_code';
  v_basis := v_p ->> 'basis';
  v_name := v_p ->> 'staff_name';
  v_label := v_p ->> 'area_label';
  v_since := nullif(v_p ->> 'since_at', '')::timestamptz;
  v_move_at := (v_p ->> 'move_at')::timestamptz;
  v_plan_end_at := nullif(v_p ->> 'plan_end_at', '')::timestamptz;

  if v_status = 'ACTIVE' and v_since is null and (
       (v_to = 'FINISH' and v_area = 'SORTING')
       or (v_to = 'SORTING' and v_area = 'FINISH')
       or (v_to = 'FINISH' and v_area = 'FINISH' and v_station is not null and v_station <> v_table)) then
    -- Without a start time the time worked before the transfer cannot be split.
    v_mode := 'BLOCKED';
    v_reason := format('The Roster has no start time for %s today. Confirm their start time in %s first, then add them again.', v_name, v_label);
  elsif v_status in ('ACTIVE', 'STARTS_LATER') and v_area is not null then
    if v_to = 'FINISH' then
      if v_area = 'FINISH' then
        if v_station = v_table then
          v_mode := 'ALREADY_HERE';
        elsif v_status = 'ACTIVE' and v_station is not null and v_since is not null and v_move_at > v_since then
          v_mode := 'TABLE_MOVE';
        end if;
      elsif v_area = 'SORTING' then
        v_mode := case when v_status = 'ACTIVE' and v_since is not null and v_move_at > v_since then 'PARTIAL' else 'WHOLE_SHIFT' end;
        if v_mode = 'WHOLE_SHIFT' and v_basis = 'ACTUAL' and v_status = 'ACTIVE' then
          v_mode := 'BLOCKED';
          v_reason := format('%s started in %s at %s. Choose a time after the start.', v_name, v_label, v_p ->> 'since_time');
        end if;
      else
        v_mode := 'BLOCKED';
        v_reason := format('%s has Actual work in %s at %s. Change it in that area first.', v_name, v_label, v_p ->> 'move_time');
      end if;
    else
      if v_area = 'SORTING' then
        v_mode := 'ALREADY_HERE';
      elsif v_area = 'FINISH' then
        if v_status = 'ACTIVE' and v_since is not null and v_move_at > v_since then
          v_mode := 'PARTIAL';
        elsif v_basis = 'ACTUAL' then
          v_mode := 'BLOCKED';
          v_reason := format('%s is recorded in %s from %s. Choose a time after that start or correct the Finish time first.', v_name, v_label, v_p ->> 'since_time');
        end if;
      else
        v_mode := 'BLOCKED';
        v_reason := format('%s has Actual work in %s at %s. Change it in that area first.', v_name, v_label, v_p ->> 'move_time');
      end if;
    end if;
  end if;

  if v_mode in ('PARTIAL', 'WHOLE_SHIFT', 'TABLE_MOVE') then
    if v_move_at > now() + interval '5 minutes' then
      v_mode := 'BLOCKED';
      v_reason := 'The transfer time cannot be in the future.';
    end if;
  end if;

  -- A person who already worked in the destination earlier in this shift returns to it.
  if v_mode in ('PARTIAL', 'WHOLE_SHIFT') then
    select ws.work_session_id, ws.actual_start_at, ws.actual_end_at into v_dest
    from public.work_sessions ws
    join public.areas a on a.area_id = ws.area_id
    where ws.work_date = (v_p ->> 'business_date')::date
      and ws.shift_id = (v_p ->> 'shift_id')::uuid
      and ws.staff_id = p_staff_id
      and a.area_code = v_to
      and ws.status <> 'CANCELLED'
    order by ws.updated_at desc
    limit 1;
    if v_dest.work_session_id is not null then
      if v_mode = 'PARTIAL' and v_dest.actual_end_at is not null and v_dest.actual_end_at <= v_move_at
         and (v_dest.actual_start_at is null or v_dest.actual_start_at < v_move_at) then
        v_return := true;
      else
        v_mode := 'BLOCKED';
        v_reason := format('%s already has %s time in this shift that overlaps %s. Correct it in %s first.',
          v_name, v_dest_label, v_p ->> 'move_time', case when v_to = 'FINISH' then 'Finish' else 'Sorting' end);
      end if;
    end if;
  end if;

  if v_mode = 'PARTIAL' and v_to = 'SORTING' and v_plan_end_at is not null and v_plan_end_at <= v_move_at then
    v_mode := 'BLOCKED';
    v_reason := format('The shift of %s ends before %s.', v_name, v_p ->> 'move_time');
  end if;

  if v_to = 'SORTING' then
    select exists (
      select 1 from public.staff_cover_capabilities scc
      join public.operational_roles role on role.operational_role_id = scc.operational_role_id
      where scc.staff_id = p_staff_id and role.role_code = 'SORTING_AREA' and scc.active = true and scc.deleted_at is null
        and scc.effective_from <= (v_p ->> 'business_date')::date
        and (scc.effective_until is null or scc.effective_until >= (v_p ->> 'business_date')::date)
    ) into v_cover;
  end if;

  v_message := case v_mode
    when 'PARTIAL' then format('%s is working in %s since %s. Transfer to %s at %s? %s keeps the time until %s.%s',
      v_name, v_label, v_p ->> 'since_time', v_dest_label, v_p ->> 'move_time', v_label, v_p ->> 'move_time',
      case when v_return then format(' %s goes back to %s: the earlier time there is kept.', v_name, v_dest_label) else '' end)
    when 'WHOLE_SHIFT' then format('%s is planned in %s today (%s-%s). Move the whole shift to %s from %s? %s will not count time for %s in this shift.',
      v_name, v_label, coalesce(v_p ->> 'since_time', '?'), coalesce(v_p ->> 'until_time', '?'), v_dest_label, v_p ->> 'move_time', v_label, v_name)
    when 'TABLE_MOVE' then format('%s is working in %s since %s. Move to %s at %s? %s keeps the time until %s.',
      v_name, v_label, v_p ->> 'since_time', v_dest_label, v_p ->> 'move_time', v_label, v_p ->> 'move_time')
    when 'ALREADY_HERE' then format('%s is already working in %s.', v_name, v_dest_label)
    when 'BLOCKED' then v_reason
    else null
  end;

  return v_p || jsonb_build_object(
    'to_area_code', v_to,
    'to_table_code', v_table,
    'to_label', v_dest_label,
    'mode', v_mode,
    'transfer_needed', v_mode in ('PARTIAL', 'WHOLE_SHIFT', 'TABLE_MOVE'),
    'is_return', v_return,
    'blocked_reason', v_reason,
    'message', v_message,
    'has_sorting_cover_capability', v_cover
  );
end;
$$;

revoke all on function public.staff_area_transfer_plan_v1(uuid, text, text, text, time) from public, anon, authenticated;

create or replace function public.get_staff_area_transfer_check_v1(
  p_staff_id uuid,
  p_shift_code text,
  p_to_area_code text,
  p_to_table_code text default null,
  p_move_time time default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_to text := upper(trim(coalesce(p_to_area_code, '')));
begin
  if v_to = 'FINISH' then
    perform public.require_finish_production_access();
  elsif v_to = 'SORTING' then
    perform public.require_sorting_operational_access();
  else
    raise exception using errcode = '22023', message = 'Choose Finish or Sorting as the destination.';
  end if;
  return jsonb_build_object('schema_version', 'STAFF_AREA_TRANSFER_CHECK_V1')
    || public.staff_area_transfer_plan_v1(
      p_staff_id, p_shift_code, v_to, p_to_table_code,
      coalesce(p_move_time, (now() at time zone 'Europe/Dublin')::time));
end;
$$;

revoke all on function public.get_staff_area_transfer_check_v1(uuid, text, text, text, time) from public, anon;
grant execute on function public.get_staff_area_transfer_check_v1(uuid, text, text, text, time) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Perform the transfer.
-- ---------------------------------------------------------------------------
create or replace function public.transfer_staff_into_area_v1(
  p_staff_id uuid,
  p_shift_code text,
  p_to_area_code text,
  p_to_table_code text,
  p_move_time time,
  p_notes text default null,
  p_whole_shift boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_to text := upper(trim(coalesce(p_to_area_code, '')));
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_plan jsonb;
  v_mode text;
  v_return boolean;
  v_name text;
  v_from_label text;
  v_to_label text;
  v_business_date date;
  v_shift_id uuid;
  v_move_at timestamptz;
  v_move_text text;
  v_since timestamptz;
  v_plan_end_at timestamptz;
  v_standard_break integer;
  v_roster_entry_id uuid;
  v_roster_version_id uuid;
  v_sorting_area_id uuid;
  v_sorting_station_id uuid;
  v_finish_area_id uuid;
  v_dest_station public.stations%rowtype;
  v_source_station_id uuid;
  v_sorting public.work_sessions%rowtype;
  v_finish public.work_sessions%rowtype;
  v_open public.finish_staff_table_segments%rowtype;
  v_old jsonb;
  v_start_at timestamptz;
  v_full_end_at timestamptz;
  v_total_break integer;
  v_kept_break integer;
  v_returned_break integer := 0;
  v_gap_minutes integer;
  v_actor uuid := public.current_staff_id();
  v_action text;
  v_result_message text;
begin
  if v_to = 'FINISH' then
    perform public.require_finish_production_access();
  elsif v_to = 'SORTING' then
    perform public.require_sorting_operational_access();
  else
    raise exception using errcode = '22023', message = 'Choose Finish or Sorting as the destination.';
  end if;
  if p_move_time is null then
    raise exception using errcode = '22023', message = 'Enter the transfer time.';
  end if;
  if length(coalesce(p_notes, '')) > 1000 then
    raise exception using errcode = '22023', message = 'Notes must be 1000 characters or fewer.';
  end if;

  -- One transfer at a time for the same person.
  perform 1 from public.staff_members where staff_id = p_staff_id for update;

  v_plan := public.staff_area_transfer_plan_v1(p_staff_id, p_shift_code, v_to, p_to_table_code, p_move_time);
  v_mode := v_plan ->> 'mode';
  if v_mode = 'BLOCKED' then
    raise exception using errcode = '22023', message = v_plan ->> 'blocked_reason';
  end if;
  if v_mode not in ('PARTIAL', 'WHOLE_SHIFT', 'TABLE_MOVE') then
    raise exception using errcode = '22023', message = coalesce(v_plan ->> 'message',
      format('%s is not working in another area at %s. Add them normally.', v_plan ->> 'staff_name', v_plan ->> 'move_time'));
  end if;

  v_return := coalesce((v_plan ->> 'is_return')::boolean, false);
  if coalesce(p_whole_shift, false) and v_mode = 'PARTIAL' and v_to = 'FINISH'
     and v_plan ->> 'area_code' = 'SORTING' and v_plan ->> 'basis' = 'ROSTER' and not v_return then
    v_mode := 'WHOLE_SHIFT';
  end if;

  v_name := v_plan ->> 'staff_name';
  v_from_label := v_plan ->> 'area_label';
  v_to_label := v_plan ->> 'to_label';
  v_business_date := (v_plan ->> 'business_date')::date;
  v_shift_id := (v_plan ->> 'shift_id')::uuid;
  v_move_at := (v_plan ->> 'move_at')::timestamptz;
  v_move_text := v_plan ->> 'move_time';
  v_since := nullif(v_plan ->> 'since_at', '')::timestamptz;
  v_plan_end_at := nullif(v_plan ->> 'plan_end_at', '')::timestamptz;
  v_standard_break := coalesce(nullif(v_plan ->> 'standard_break_minutes', '')::integer, 0);
  v_roster_entry_id := nullif(v_plan ->> 'roster_entry_id', '')::uuid;
  v_roster_version_id := nullif(v_plan ->> 'roster_version_id', '')::uuid;

  select area_id into v_sorting_area_id from public.areas where area_code = 'SORTING' and active = true and deleted_at is null limit 1;
  select st.station_id into v_sorting_station_id from public.stations st
  where st.area_id = v_sorting_area_id and st.station_code = 'SORTING_MAIN' and st.active = true and st.deleted_at is null limit 1;
  select area_id into v_finish_area_id from public.areas where area_code = 'FINISH' and active = true and deleted_at is null limit 1;
  if v_sorting_area_id is null or v_finish_area_id is null then
    raise exception using errcode = 'P0002', message = 'Sorting or Finish master data is not available.';
  end if;
  if v_to = 'FINISH' then
    select st.* into v_dest_station from public.stations st
    where st.area_id = v_finish_area_id and st.station_code = v_plan ->> 'to_table_code' and st.active = true and st.deleted_at is null;
  end if;
  select st.station_id into v_source_station_id from public.stations st
  where st.station_code = v_plan ->> 'station_code' and st.deleted_at is null limit 1;

  select ws.* into v_finish from public.work_sessions ws
  where ws.work_date = v_business_date and ws.shift_id = v_shift_id and ws.staff_id = p_staff_id
    and ws.area_id = v_finish_area_id and ws.status <> 'CANCELLED'
  order by ws.updated_at desc limit 1 for update;
  select ws.* into v_sorting from public.work_sessions ws
  where ws.work_date = v_business_date and ws.shift_id = v_shift_id and ws.staff_id = p_staff_id
    and ws.area_id = v_sorting_area_id and ws.status <> 'CANCELLED'
  order by case when ws.production_roster_entry_id is not null then 0 else 1 end, ws.updated_at desc
  limit 1 for update;

  -- ---------------------------------------------------------------- Finish Table move
  if v_mode = 'TABLE_MOVE' then
    v_old := to_jsonb(v_finish);
    if v_finish.work_session_id is null then
      insert into public.work_sessions (work_date, staff_id, area_id, station_id, shift_id, actual_start_at, actual_end_at,
        break_minutes, status, source, confirmed_by, notes, recorded_by_auth_user_id)
      values (v_business_date, p_staff_id, v_finish_area_id, v_source_station_id, v_shift_id, v_since, null,
        v_standard_break, 'OPEN', 'FINISH_V2', v_actor, v_notes, auth.uid())
      returning * into v_finish;
      insert into public.finish_daily_staff_attendance (business_date, shift_id, staff_id, attendance_status, source, created_by_auth_user_id, updated_by_auth_user_id)
      values (v_business_date, v_shift_id, p_staff_id, 'PRESENT', 'FINISH_WORKSTATION', auth.uid(), auth.uid())
      on conflict (business_date, shift_id, staff_id) do update
      set attendance_status = 'PRESENT', absence_reason = null, updated_at = now(), updated_by_auth_user_id = auth.uid();
    end if;
    select * into v_open from public.finish_staff_table_segments s
    where s.work_session_id = v_finish.work_session_id and s.ended_at is null
    order by s.started_at desc limit 1 for update;
    if v_open.finish_staff_table_segment_id is not null then
      update public.finish_staff_table_segments set ended_at = v_move_at, updated_at = now(), updated_by_auth_user_id = auth.uid()
      where finish_staff_table_segment_id = v_open.finish_staff_table_segment_id;
    elsif not exists (select 1 from public.finish_staff_table_segments s where s.work_session_id = v_finish.work_session_id) then
      insert into public.finish_staff_table_segments (work_session_id, station_id, started_at, ended_at, notes, created_by_auth_user_id, updated_by_auth_user_id)
      values (v_finish.work_session_id, coalesce(v_source_station_id, v_finish.station_id), coalesce(v_finish.actual_start_at, v_since), v_move_at, v_notes, auth.uid(), auth.uid());
    end if;
    insert into public.finish_staff_table_segments (work_session_id, station_id, started_at, notes, created_by_auth_user_id, updated_by_auth_user_id)
    values (v_finish.work_session_id, v_dest_station.station_id, v_move_at, v_notes, auth.uid(), auth.uid());
    update public.work_sessions
    set station_id = v_dest_station.station_id,
        actual_start_at = coalesce(actual_start_at, v_since),
        actual_end_at = null, status = 'OPEN', source = 'FINISH_TABLE_TRANSFER',
        notes = concat_ws(' ', nullif(trim(notes), ''), format('Moved from %s to %s at %s.', v_from_label, v_to_label, v_move_text), v_notes),
        confirmed_by = v_actor, updated_at = clock_timestamp()
    where work_session_id = v_finish.work_session_id
    returning * into v_finish;
    v_action := 'FINISH_STAFF_ADDED_FROM_OTHER_STATION';
    v_result_message := format('%s moved from %s to %s at %s.', v_name, v_from_label, v_to_label, v_move_text);

  -- ---------------------------------------------------------------- Sorting -> Finish
  elsif v_to = 'FINISH' then
    v_old := jsonb_build_object('sorting_session', to_jsonb(v_sorting), 'finish_session', to_jsonb(v_finish));
    if v_mode = 'WHOLE_SHIFT' then
      if exists (select 1 from public.sorting_wash_runs wr where wr.business_date = v_business_date and wr.shift_id = v_shift_id
                   and wr.operator_staff_id = p_staff_id and wr.status = 'RECORDED')
         or exists (select 1 from public.sorting_trolley_intakes sti where sti.business_date = v_business_date and sti.shift_id = v_shift_id
                   and sti.operator_staff_id = p_staff_id) then
        raise exception using errcode = '22023', message = format('%s already has recorded Sorting activity in this shift. Choose the time they left Sorting instead.', v_name);
      end if;
      if v_sorting.work_session_id is not null then
        -- Their only Sorting record becomes the Finish record, as in the whole-shift Sorting move.
        update public.work_sessions
        set area_id = v_finish_area_id, station_id = v_dest_station.station_id,
            actual_start_at = v_move_at, actual_end_at = null, status = 'OPEN',
            source = 'SORTING_TO_FINISH_TRANSFER', confirmed_by = v_actor,
            notes = concat_ws(' ', nullif(trim(notes), ''), format('Whole shift moved from %s to %s from %s.', v_from_label, v_to_label, v_move_text), v_notes),
            recorded_by_auth_user_id = auth.uid(), row_version = row_version + 1, updated_at = clock_timestamp()
        where work_session_id = v_sorting.work_session_id
        returning * into v_finish;
      else
        insert into public.work_sessions (production_roster_entry_id, production_roster_version_id, work_date, staff_id, area_id, station_id,
          shift_id, actual_start_at, actual_end_at, break_minutes, extra_non_work_minutes, adjustment_reason, status, source, confirmed_by, notes,
          recorded_by_auth_user_id, row_version, updated_at)
        values (v_roster_entry_id, v_roster_version_id, v_business_date, p_staff_id, v_finish_area_id, v_dest_station.station_id,
          v_shift_id, v_move_at, null, v_standard_break, 0, 'NONE', 'OPEN', 'SORTING_TO_FINISH_TRANSFER', v_actor,
          concat_ws(' ', format('Whole shift moved from %s to %s from %s.', v_from_label, v_to_label, v_move_text), v_notes),
          auth.uid(), 1, clock_timestamp())
        returning * into v_finish;
      end if;
      insert into public.finish_staff_table_segments (work_session_id, station_id, started_at, notes, created_by_auth_user_id, updated_by_auth_user_id)
      values (v_finish.work_session_id, v_dest_station.station_id, v_move_at, v_notes, auth.uid(), auth.uid());
      v_action := 'STAFF_MOVED_WHOLE_SHIFT_SORTING_TO_FINISH';
      v_result_message := format('%s moved to %s for the whole shift from %s. Sorting does not count this shift.', v_name, v_to_label, v_move_text);
    else
      -- Close Sorting at the transfer time and share the break by the time in each area.
      v_start_at := coalesce(v_sorting.actual_start_at, v_since);
      v_full_end_at := greatest(coalesce(v_sorting.actual_end_at, v_plan_end_at, v_move_at), v_move_at);
      v_total_break := coalesce(v_sorting.break_minutes, v_standard_break);
      v_kept_break := case when v_full_end_at <= v_start_at then v_total_break
        else round(v_total_break * extract(epoch from (v_move_at - v_start_at)) / extract(epoch from (v_full_end_at - v_start_at)))::integer end;
      v_kept_break := least(v_kept_break, greatest(0, floor(extract(epoch from (v_move_at - v_start_at)) / 60)::integer));
      v_returned_break := greatest(0, v_total_break - v_kept_break);
      if v_sorting.work_session_id is not null then
        update public.work_sessions
        set actual_start_at = v_start_at, actual_end_at = v_move_at, break_minutes = v_kept_break, status = 'CONFIRMED',
            notes = concat_ws(' ', nullif(trim(notes), ''), format('Moved to %s at %s.', v_to_label, v_move_text)),
            confirmed_by = v_actor, recorded_by_auth_user_id = auth.uid(), row_version = row_version + 1, updated_at = now()
        where work_session_id = v_sorting.work_session_id
        returning * into v_sorting;
      else
        insert into public.work_sessions (production_roster_entry_id, production_roster_version_id, work_date, staff_id, area_id, station_id,
          shift_id, actual_start_at, actual_end_at, break_minutes, extra_non_work_minutes, adjustment_reason, status, source, confirmed_by, notes,
          recorded_by_auth_user_id, row_version, updated_at)
        values (v_roster_entry_id, v_roster_version_id, v_business_date, p_staff_id, v_sorting_area_id, v_sorting_station_id,
          v_shift_id, v_start_at, v_move_at, v_kept_break, 0, 'NONE', 'CONFIRMED', 'SORTING_WORKSTATION', v_actor,
          format('Moved to %s at %s.', v_to_label, v_move_text), auth.uid(), 1, now())
        returning * into v_sorting;
      end if;

      if v_return then
        insert into public.finish_staff_table_segments (work_session_id, station_id, started_at, notes, created_by_auth_user_id, updated_by_auth_user_id)
        values (v_finish.work_session_id, v_dest_station.station_id, v_move_at, v_notes, auth.uid(), auth.uid());
        update public.work_sessions
        set station_id = v_dest_station.station_id, actual_end_at = null, status = 'OPEN',
            source = case when v_sorting.production_roster_entry_id is not null then 'SORTING_TO_FINISH_TRANSFER' else 'FINISH_TABLE_TRANSFER' end,
            break_minutes = coalesce(break_minutes, 0) + v_returned_break,
            notes = concat_ws(' ', nullif(trim(notes), ''), format('Back from %s at %s.', v_from_label, v_move_text), v_notes),
            confirmed_by = v_actor, recorded_by_auth_user_id = auth.uid(), row_version = row_version + 1, updated_at = clock_timestamp()
        where work_session_id = v_finish.work_session_id
        returning * into v_finish;
      else
        insert into public.work_sessions (production_roster_entry_id, production_roster_version_id, work_date, staff_id, area_id, station_id,
          shift_id, actual_start_at, actual_end_at, break_minutes, extra_non_work_minutes, adjustment_reason, status, source, confirmed_by, notes,
          recorded_by_auth_user_id, row_version, updated_at)
        values (null, v_roster_version_id, v_business_date, p_staff_id, v_finish_area_id, v_dest_station.station_id,
          v_shift_id, v_move_at, null, v_returned_break, 0, 'NONE', 'OPEN', 'SORTING_TO_FINISH_TRANSFER', v_actor,
          concat_ws(' ', format('Came from %s at %s.', v_from_label, v_move_text), v_notes), auth.uid(), 1, clock_timestamp())
        returning * into v_finish;
        insert into public.finish_staff_table_segments (work_session_id, station_id, started_at, notes, created_by_auth_user_id, updated_by_auth_user_id)
        values (v_finish.work_session_id, v_dest_station.station_id, v_move_at, v_notes, auth.uid(), auth.uid());
      end if;
      v_action := 'STAFF_TRANSFERRED_SORTING_TO_FINISH';
      v_result_message := format('%s moved from %s to %s at %s. %s keeps the time until then.', v_name, v_from_label, v_to_label, v_move_text, v_from_label);
    end if;
    insert into public.finish_daily_staff_attendance (business_date, shift_id, staff_id, attendance_status, source, created_by_auth_user_id, updated_by_auth_user_id)
    values (v_business_date, v_shift_id, p_staff_id, 'PRESENT', 'SORTING_TO_FINISH_TRANSFER', auth.uid(), auth.uid())
    on conflict (business_date, shift_id, staff_id) do update
    set attendance_status = 'PRESENT', absence_reason = null, source = 'SORTING_TO_FINISH_TRANSFER',
        updated_at = now(), updated_by_auth_user_id = auth.uid();

  -- ---------------------------------------------------------------- Finish -> Sorting
  else
    v_old := jsonb_build_object('finish_session', to_jsonb(v_finish), 'sorting_session', to_jsonb(v_sorting));
    if v_finish.work_session_id is null then
      insert into public.work_sessions (work_date, staff_id, area_id, station_id, shift_id, actual_start_at, actual_end_at,
        break_minutes, status, source, confirmed_by, notes, recorded_by_auth_user_id)
      values (v_business_date, p_staff_id, v_finish_area_id, v_source_station_id, v_shift_id, v_since, null,
        v_standard_break, 'OPEN', 'FINISH_V2', v_actor, null, auth.uid())
      returning * into v_finish;
      insert into public.finish_daily_staff_attendance (business_date, shift_id, staff_id, attendance_status, source, created_by_auth_user_id, updated_by_auth_user_id)
      values (v_business_date, v_shift_id, p_staff_id, 'PRESENT', 'FINISH_WORKSTATION', auth.uid(), auth.uid())
      on conflict (business_date, shift_id, staff_id) do update
      set attendance_status = 'PRESENT', absence_reason = null, updated_at = now(), updated_by_auth_user_id = auth.uid();
    end if;
    select * into v_open from public.finish_staff_table_segments s
    where s.work_session_id = v_finish.work_session_id and s.ended_at is null
    order by s.started_at desc limit 1 for update;
    if v_open.finish_staff_table_segment_id is not null then
      update public.finish_staff_table_segments set ended_at = v_move_at, updated_at = now(), updated_by_auth_user_id = auth.uid()
      where finish_staff_table_segment_id = v_open.finish_staff_table_segment_id;
    elsif coalesce(v_source_station_id, v_finish.station_id) is not null
          and not exists (select 1 from public.finish_staff_table_segments s where s.work_session_id = v_finish.work_session_id) then
      insert into public.finish_staff_table_segments (work_session_id, station_id, started_at, ended_at, notes, created_by_auth_user_id, updated_by_auth_user_id)
      values (v_finish.work_session_id, coalesce(v_source_station_id, v_finish.station_id), coalesce(v_finish.actual_start_at, v_since), v_move_at, v_notes, auth.uid(), auth.uid());
    end if;

    v_start_at := coalesce(v_finish.actual_start_at, v_since);
    v_full_end_at := greatest(coalesce(v_plan_end_at, v_move_at), v_move_at);
    v_total_break := coalesce(v_finish.break_minutes, v_standard_break);
    v_kept_break := case when v_full_end_at <= v_start_at then v_total_break
      else round(v_total_break * extract(epoch from (v_move_at - v_start_at)) / extract(epoch from (v_full_end_at - v_start_at)))::integer end;
    v_kept_break := least(v_kept_break, greatest(0, floor(extract(epoch from (v_move_at - v_start_at)) / 60)::integer));
    v_returned_break := greatest(0, v_total_break - v_kept_break);

    update public.work_sessions
    set actual_start_at = v_start_at, actual_end_at = v_move_at, break_minutes = v_kept_break, status = 'CONFIRMED',
        source = 'FINISH_TO_SORTING_TRANSFER',
        notes = concat_ws(' ', nullif(trim(notes), ''), format('Moved to Sorting at %s.', v_move_text)),
        confirmed_by = v_actor, recorded_by_auth_user_id = auth.uid(), row_version = row_version + 1, updated_at = now()
    where work_session_id = v_finish.work_session_id
    returning * into v_finish;

    if v_return then
      -- Back to Sorting: the same Sorting record continues and the time away counts as non-work.
      v_gap_minutes := greatest(0, round(extract(epoch from (v_move_at - v_sorting.actual_end_at)) / 60)::integer);
      if coalesce(v_sorting.extra_non_work_minutes, 0) + v_gap_minutes > 720 then
        raise exception using errcode = '22023', message = 'The time away from Sorting is too long to record in one shift.';
      end if;
      update public.work_sessions
      set actual_end_at = case when v_plan_end_at is null then null else greatest(v_plan_end_at, v_move_at + interval '1 minute') end,
          extra_non_work_minutes = coalesce(extra_non_work_minutes, 0) + v_gap_minutes,
          adjustment_reason = case when adjustment_reason = 'NONE' then 'OTHER' else adjustment_reason end,
          break_minutes = coalesce(break_minutes, 0) + v_returned_break,
          status = case when v_plan_end_at is null then 'OPEN' else 'CONFIRMED' end,
          notes = concat_ws(' ', nullif(trim(notes), ''),
            format('In %s from %s to %s.', v_from_label, to_char(v_sorting.actual_end_at at time zone 'Europe/Dublin', 'HH24:MI'), v_move_text), v_notes),
          confirmed_by = v_actor, recorded_by_auth_user_id = auth.uid(), row_version = row_version + 1, updated_at = clock_timestamp()
      where work_session_id = v_sorting.work_session_id
      returning * into v_sorting;
    else
      insert into public.work_sessions (production_roster_entry_id, production_roster_version_id, work_date, staff_id, area_id, station_id,
        shift_id, actual_start_at, actual_end_at, break_minutes, extra_non_work_minutes, adjustment_reason, status, source, confirmed_by, notes,
        recorded_by_auth_user_id, row_version, updated_at)
      values (null, v_roster_version_id, v_business_date, p_staff_id, v_sorting_area_id, v_sorting_station_id,
        v_shift_id, v_move_at, v_plan_end_at, v_returned_break, 0, 'NONE',
        case when v_plan_end_at is null then 'OPEN' else 'CONFIRMED' end, 'SORTING_MANUAL_POSITION', v_actor,
        concat_ws(' ', format('Came from %s at %s.', v_from_label, v_move_text), v_notes), auth.uid(), 1, clock_timestamp())
      returning * into v_sorting;
    end if;
    v_action := 'STAFF_TRANSFERRED_FINISH_TO_SORTING';
    v_result_message := format('%s moved from %s to Sorting at %s. %s keeps the time until then.', v_name, v_from_label, v_move_text, v_from_label);
  end if;

  insert into public.audit_log (actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
  values (auth.uid(), v_actor, v_action, 'work_sessions',
    coalesce(case when v_to = 'FINISH' then v_finish.work_session_id else v_sorting.work_session_id end)::text,
    v_old,
    jsonb_build_object('sorting_session', to_jsonb(v_sorting), 'finish_session', to_jsonb(v_finish), 'mode', v_mode, 'is_return', v_return),
    concat(v_result_message, case when v_notes is null then '' else ' ' || v_notes end),
    'STAFF_AREA_TRANSFER_V1');

  return jsonb_build_object(
    'status', 'transferred',
    'mode', v_mode,
    'is_return', v_return,
    'staff_id', p_staff_id,
    'staff_name', v_name,
    'business_date', v_business_date,
    'shift_code', v_plan ->> 'shift_code',
    'from_label', v_from_label,
    'to_label', v_to_label,
    'moved_at', v_move_at,
    'sorting_work_session_id', v_sorting.work_session_id,
    'finish_work_session_id', v_finish.work_session_id,
    'message', v_result_message || ' The published Roster was not changed.'
  );
end;
$$;

revoke all on function public.transfer_staff_into_area_v1(uuid, text, text, text, time, text, boolean) from public, anon;
grant execute on function public.transfer_staff_into_area_v1(uuid, text, text, text, time, text, boolean) to authenticated;

create or replace function public.terminal_transfer_staff_into_area_v1(
  p_staff_id uuid,
  p_shift_code text,
  p_to_area_code text,
  p_to_table_code text,
  p_move_time time,
  p_notes text default null,
  p_whole_shift boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if upper(trim(coalesce(p_to_area_code, ''))) <> 'FINISH' then
    raise exception using errcode = '42501', message = 'A Finish terminal can only add staff to its own Table.';
  end if;
  perform public.require_production_terminal('FINISH', p_to_table_code);
  return public.transfer_staff_into_area_v1(p_staff_id, p_shift_code, p_to_area_code, p_to_table_code, p_move_time, p_notes, p_whole_shift);
end;
$$;

revoke all on function public.terminal_transfer_staff_into_area_v1(uuid, text, text, text, time, text, boolean) from public, anon;
grant execute on function public.terminal_transfer_staff_into_area_v1(uuid, text, text, text, time, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. The plain "add" functions no longer create a second area record.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_finish_staff_actual(
  p_staff_id uuid,
  p_shift_code text,
  p_table_code text,
  p_start_time time default null,
  p_end_time time default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date; v_shift public.shifts%rowtype; v_station public.stations%rowtype; v_area_id uuid;
  v_staff public.staff_members%rowtype; v_existing public.work_sessions%rowtype; v_saved public.work_sessions%rowtype;
  v_start timestamptz; v_end timestamptz; v_actor uuid; v_old jsonb; v_segment_count integer:=0; v_transfer jsonb;
begin
  perform public.require_finish_production_access();
  if p_staff_id is null then raise exception using errcode='22023', message='Staff member is required.'; end if;
  if p_start_time is null then raise exception using errcode='22023', message='Enter the actual start time before saving.'; end if;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null;
  if not found or v_shift.shift_code not in ('MORNING','EVENING') then raise exception using errcode='22023', message='Shift must be Morning or Evening.'; end if;
  select st.* into v_station from public.stations st join public.areas a on a.area_id=st.area_id where st.station_code=upper(trim(coalesce(p_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  if not found or v_station.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then raise exception using errcode='22023', message='Choose Finish Table 1, Table 2 or Table 3.'; end if;
  select area_id into v_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null;
  select * into v_staff from public.staff_members where staff_id=p_staff_id and production_staff=true and active=true and roster_eligible=true and deleted_at is null;
  if not found then raise exception using errcode='22023', message='Selected staff member is not active production staff.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  v_start:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_start_time);
  if p_end_time is not null then v_end:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_end_time); end if;
  if v_end is not null and (v_end<=v_start or v_end-v_start>interval '13 hours') then raise exception using errcode='22023', message='Actual worked span must be more than zero and no longer than 13 hours.'; end if;
  v_actor:=public.current_staff_id();

  select * into v_existing from public.work_sessions ws where ws.work_date=v_business_date and ws.staff_id=p_staff_id and ws.shift_id=v_shift.shift_id and ws.area_id=v_area_id and ws.status<>'CANCELLED' order by ws.updated_at desc limit 1 for update;
  if not found then
    -- A new Finish record for someone who is working in Sorting (or another area) would count the hours twice.
    v_transfer:=public.staff_area_transfer_plan_v1(p_staff_id,v_shift.shift_code,'FINISH',v_station.station_code,p_start_time);
    if coalesce(v_transfer->>'area_code','')<>'FINISH' and v_transfer->>'mode' in ('PARTIAL','WHOLE_SHIFT','BLOCKED') then
      raise exception using errcode='22023', message=format('%s is working in %s at %s. Add them again and confirm the transfer, so the hours are not counted in both areas.',
        v_staff.display_name,coalesce(v_transfer->>'area_label','another area'),to_char(p_start_time,'HH24:MI'));
    end if;
  end if;

  insert into public.finish_daily_staff_attendance (business_date,shift_id,staff_id,attendance_status,source,created_by_auth_user_id,updated_by_auth_user_id)
  values (v_business_date,v_shift.shift_id,p_staff_id,'PRESENT','FINISH_WORKSTATION',auth.uid(),auth.uid())
  on conflict (business_date,shift_id,staff_id) do update
    set attendance_status='PRESENT',absence_reason=null,source='FINISH_WORKSTATION',updated_at=now(),updated_by_auth_user_id=auth.uid();

  if v_existing.work_session_id is not null then
    select count(*) into v_segment_count from public.finish_staff_table_segments s where s.work_session_id=v_existing.work_session_id;
    if v_existing.station_id is distinct from v_station.station_id and v_segment_count>0 then
      raise exception using errcode='22023', message='Use Move table so the hours already worked stay with the original Table.';
    end if;
    if v_segment_count>1 and (p_start_time is not null or p_end_time is not null) then
      raise exception using errcode='22023', message='This staff member has table transfers. Use Move table for the next timed change.';
    end if;
    v_old:=to_jsonb(v_existing);
    update public.work_sessions set station_id=v_station.station_id,actual_start_at=v_start,actual_end_at=v_end,status=case when v_end is null then 'OPEN' else 'CONFIRMED' end,source='FINISH_V2',confirmed_by=v_actor,notes=coalesce(nullif(trim(p_reason),''),notes),updated_at=now() where work_session_id=v_existing.work_session_id returning * into v_saved;
  else
    v_old:=null;
    insert into public.work_sessions(work_date,staff_id,area_id,station_id,shift_id,actual_start_at,actual_end_at,status,source,confirmed_by,notes)
    values(v_business_date,p_staff_id,v_area_id,v_station.station_id,v_shift.shift_id,v_start,v_end,case when v_end is null then 'OPEN' else 'CONFIRMED' end,'FINISH_V2',v_actor,nullif(trim(p_reason),'')) returning * into v_saved;
  end if;

  if v_saved.actual_start_at is not null and not exists(select 1 from public.finish_staff_table_segments s where s.work_session_id=v_saved.work_session_id) then
    insert into public.finish_staff_table_segments(work_session_id,station_id,started_at,ended_at,notes,created_by_auth_user_id,updated_by_auth_user_id)
    values(v_saved.work_session_id,v_station.station_id,v_saved.actual_start_at,v_saved.actual_end_at,nullif(trim(p_reason),''),auth.uid(),auth.uid());
  elsif v_segment_count=1 then
    update public.finish_staff_table_segments
    set started_at=v_start,ended_at=v_end,updated_at=now(),updated_by_auth_user_id=auth.uid()
    where work_session_id=v_saved.work_session_id;
  end if;

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,case when v_old is null then 'CREATE_FINISH_STAFF_ACTUAL' else 'UPDATE_FINISH_STAFF_ACTUAL' end,'work_sessions',v_saved.work_session_id::text,v_old,to_jsonb(v_saved),p_reason,'FINISH_V2');
  return jsonb_build_object('status','saved','work_session_id',v_saved.work_session_id,'staff_id',p_staff_id,'table_code',v_station.station_code,'business_date',v_business_date,'shift_code',v_shift.shift_code,'actual_start_at',v_saved.actual_start_at,'actual_end_at',v_saved.actual_end_at);
end;
$$;

revoke all on function public.upsert_finish_staff_actual(uuid, text, text, time, time, text) from public, anon;
grant execute on function public.upsert_finish_staff_actual(uuid, text, text, time, time, text) to authenticated;

create or replace function public.add_sorting_actual_staff(
  p_shift_code text,
  p_staff_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_shift public.shifts%rowtype;
  v_staff public.staff_members%rowtype;
  v_sorting_area_id uuid;
  v_sorting_station_id uuid;
  v_entry public.production_roster_entries%rowtype;
  v_roster_version_id uuid;
  v_profile jsonb;
  v_break_minutes integer := 0;
  v_default_start time;
  v_default_end time;
  v_actual_start timestamptz;
  v_actual_end timestamptz;
  v_session_id uuid;
  v_planned_position text := 'Not planned today';
  v_transfer jsonb;
begin
  perform public.require_sorting_operational_access();

  if p_staff_id is null then
    raise exception using errcode = '22023', message = 'Staff is required.';
  end if;

  if length(coalesce(p_notes, '')) > 1000 then
    raise exception using errcode = '22023', message = 'Notes must be 1000 characters or fewer.';
  end if;

  select * into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code and sh.active = true and sh.deleted_at is null
  limit 1;
  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  select * into v_staff
  from public.staff_members sm
  where sm.staff_id = p_staff_id and sm.production_staff = true and sm.active = true
    and sm.roster_eligible = true and sm.deleted_at is null;
  if not found then
    raise exception using errcode = 'P0002', message = 'Selected staff member is not active production staff.';
  end if;

  select a.area_id into v_sorting_area_id
  from public.areas a where a.area_code = 'SORTING' and a.deleted_at is null limit 1;

  select st.station_id into v_sorting_station_id
  from public.stations st join public.areas a on a.area_id = st.area_id
  where st.station_code = 'SORTING_MAIN' and a.area_code = 'SORTING' and st.deleted_at is null
  limit 1;

  if v_sorting_area_id is null then
    raise exception using errcode = 'P0002', message = 'Sorting Area master data is not available.';
  end if;

  if exists (
    select 1 from public.work_sessions ws
    where ws.work_date = v_business_date and ws.staff_id = p_staff_id and ws.shift_id = v_shift.shift_id
      and ws.area_id = v_sorting_area_id and ws.status <> 'CANCELLED'
  ) then
    raise exception using errcode = '23505', message = format('%s is already active in Sorting for this shift.', v_staff.display_name);
  end if;

  -- A whole-shift Sorting record for someone who is working in Finish now would count the hours twice.
  v_transfer := public.staff_area_transfer_plan_v1(p_staff_id, v_shift_code, 'SORTING', null, (now() at time zone 'Europe/Dublin')::time);
  if coalesce(v_transfer ->> 'area_code', '') <> 'SORTING' and v_transfer ->> 'mode' in ('PARTIAL', 'BLOCKED') then
    raise exception using errcode = '22023', message = format('%s is working in %s now. Add them again and confirm the transfer, so the hours are not counted in both areas.',
      v_staff.display_name, coalesce(v_transfer ->> 'area_label', 'another area'));
  end if;

  -- Link only to the selected-shift published entry. If there is no selected-
  -- shift entry (not planned / other shift), keep the Actual session independent
  -- and derive the mismatch from the published Roster when displaying it.
  select pre.* into v_entry
  from public.production_roster_versions prv
  join public.roster_periods rp
    on rp.roster_period_id = prv.roster_period_id
   and rp.week_start = public.production_roster_week_start(v_business_date)
  join public.production_roster_entries pre
    on pre.roster_version_id = prv.roster_version_id
   and pre.work_date = v_business_date
   and pre.staff_id = p_staff_id
  where prv.status = 'PUBLISHED' and prv.shift_id = v_shift.shift_id
  order by prv.published_at desc nulls last, prv.version_number desc
  limit 1;

  if found then
    v_roster_version_id := v_entry.roster_version_id;

    select case
      when pre.display_section_code is not null then replace(pre.display_section_code, '_', ' ')
      when nullif(pre.station_code_snapshot, '') is not null then replace(pre.station_code_snapshot, '_', ' ')
      when nullif(pre.area_code_snapshot, '') is not null then replace(pre.area_code_snapshot, '_', ' ')
      else 'Published Roster'
    end
    into v_planned_position
    from public.production_roster_entries pre
    where pre.roster_entry_id = v_entry.roster_entry_id;
  end if;

  v_profile := public.production_roster_work_profile_context(v_business_date, v_shift_code);
  v_break_minutes := coalesce((v_profile ->> 'break_minutes')::integer, 0);
  v_default_start := nullif(v_profile ->> 'default_start_time', '')::time;
  v_default_end := nullif(v_profile ->> 'default_end_time', '')::time;

  if v_default_start is not null then
    v_actual_start := ((v_business_date::text || ' ' || v_default_start::text)::timestamp at time zone 'Europe/Dublin');
  end if;

  if v_default_end is not null then
    v_actual_end := ((v_business_date::text || ' ' || v_default_end::text)::timestamp at time zone 'Europe/Dublin');
  end if;

  insert into public.work_sessions (
    production_roster_entry_id, production_roster_version_id, work_date, staff_id, area_id, station_id, shift_id,
    actual_start_at, actual_end_at, break_minutes, extra_non_work_minutes, adjustment_reason, status, source,
    confirmed_by, notes, recorded_by_auth_user_id, row_version, updated_at
  )
  values (
    case when v_entry.roster_entry_id is null then null else v_entry.roster_entry_id end,
    v_roster_version_id, v_business_date, v_staff.staff_id, v_sorting_area_id, v_sorting_station_id, v_shift.shift_id,
    v_actual_start, v_actual_end, v_break_minutes, 0, 'NONE',
    case when v_actual_start is null or v_actual_end is null then 'OPEN' else 'CONFIRMED' end,
    'SORTING_MANUAL_POSITION', public.current_staff_id(), nullif(trim(p_notes), ''), auth.uid(), 1, now()
  )
  returning work_session_id into v_session_id;

  return jsonb_build_object(
    'status', 'success',
    'work_session_id', v_session_id,
    'staff_id', v_staff.staff_id,
    'staff_name', v_staff.display_name,
    'business_date', v_business_date,
    'shift_code', v_shift_code,
    'planned_position', v_planned_position,
    'actual_position', 'Sorting Area',
    'message', format('%s added to Sorting Actual staffing.', v_staff.display_name)
  );
end;
$$;

revoke all on function public.add_sorting_actual_staff(text, uuid, text) from public, anon;
grant execute on function public.add_sorting_actual_staff(text, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Finish Staff keeps the Table hours of people who left Finish.
-- ---------------------------------------------------------------------------
create or replace function public.get_finish_staff_context_v4(
  p_shift_code text default 'MORNING',
  p_at timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_base jsonb; v_staff jsonb; v_tables jsonb; v_business_date date; v_units_per_kg numeric:=6; v_shift_id uuid; v_finish_area_id uuid; v_extra jsonb;
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_staff_context_v3(p_shift_code,p_at);
  v_business_date:=nullif(v_base->>'business_date','')::date;
  select shift_id into v_shift_id from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,'MORNING'))) and active=true and deleted_at is null limit 1;
  select area_id into v_finish_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null limit 1;
  select coalesce((select target_value from public.production_targets where target_code='FINISH_UNITS_PER_KG' and active=true limit 1),6) into v_units_per_kg;
  v_units_per_kg:=greatest(v_units_per_kg,0.001);

  with finish_work as (
    select distinct on (ws.staff_id) ws.staff_id, ws.work_session_id, ws.actual_start_at, ws.actual_end_at, ws.break_minutes
    from public.work_sessions ws
    where ws.work_date=v_business_date and ws.shift_id=v_shift_id and ws.area_id=v_finish_area_id and ws.status<>'CANCELLED'
    order by ws.staff_id, ws.updated_at desc
  ), finish_segments as (
    select fw.staff_id,
      jsonb_agg(jsonb_build_object('table_code',st.station_code,'started_at',s.started_at,'ended_at',s.ended_at) order by s.started_at) as items
    from finish_work fw
    join public.finish_staff_table_segments s on s.work_session_id=fw.work_session_id
    join public.stations st on st.station_id=s.station_id
    group by fw.staff_id
  )
  select coalesce(jsonb_agg(br.item||jsonb_build_object(
    'is_sorting_cover',exists(
      select 1 from public.staff_cover_capabilities scc join public.operational_roles role on role.operational_role_id=scc.operational_role_id
      where scc.staff_id=nullif(br.item->>'staff_id','')::uuid and role.role_code='SORTING_AREA' and scc.active=true and scc.deleted_at is null
        and scc.effective_from<=v_business_date and(scc.effective_until is null or scc.effective_until>=v_business_date)),
    'finish_segments',coalesce(fs.items,'[]'::jsonb),
    'finish_started_at',fw.actual_start_at,
    'finish_ended_at',fw.actual_end_at,
    'finish_break_minutes',fw.break_minutes
  ) order by br.ordinality),'[]'::jsonb) into v_staff
  from jsonb_array_elements(coalesce(v_base->'staff','[]'::jsonb)) with ordinality br(item,ordinality)
  left join finish_work fw on fw.staff_id=nullif(br.item->>'staff_id','')::uuid
  left join finish_segments fs on fs.staff_id=fw.staff_id;

  -- People who worked in Finish earlier in the shift but are now in another area and are not
  -- planned in Finish: keep them in the list so their Table hours still count.
  with listed as (
    select nullif(value->>'staff_id','')::uuid as staff_id from jsonb_array_elements(v_staff)
  ), finish_work as (
    select distinct on (ws.staff_id) ws.staff_id, ws.work_session_id, ws.actual_start_at, ws.actual_end_at, ws.break_minutes
    from public.work_sessions ws
    where ws.work_date=v_business_date and ws.shift_id=v_shift_id and ws.area_id=v_finish_area_id and ws.status<>'CANCELLED'
      and ws.staff_id not in (select staff_id from listed where staff_id is not null)
    order by ws.staff_id, ws.updated_at desc
  ), latest as (
    select distinct on (ws.staff_id) ws.staff_id, ws.work_session_id, ws.actual_start_at, ws.actual_end_at, ws.status, ws.source, a.area_code, a.area_name
    from public.work_sessions ws join public.areas a on a.area_id=ws.area_id
    where ws.work_date=v_business_date and ws.shift_id=v_shift_id and ws.status<>'CANCELLED'
      and ws.staff_id in (select staff_id from finish_work)
    order by ws.staff_id, ws.updated_at desc
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id',sm.staff_id,'display_name',sm.display_name,
    'planned_table_code',null,'planned_start_time',null,'planned_end_time',null,
    'work_session_id',l.work_session_id,'actual_area_code',l.area_code,'actual_area_name',l.area_name,
    'actual_start_at',l.actual_start_at,'actual_end_at',l.actual_end_at,'actual_status',l.status,'actual_source',l.source,
    'actual_in_finish',false,'effective_table_code',null,
    'effective_start_time',(fw.actual_start_at at time zone 'Europe/Dublin')::time,
    'effective_end_time',(fw.actual_end_at at time zone 'Europe/Dublin')::time,
    'break_minutes',coalesce(fw.break_minutes,0),'extra_non_work_minutes',0,
    'staff_state','ACTUAL_ELSEWHERE','attendance_status','PRESENT','requires_time_choice',false,
    'table_segments','[]'::jsonb,'is_sorting_cover',false,
    'finish_segments',coalesce((
      select jsonb_agg(jsonb_build_object('table_code',st.station_code,'started_at',s.started_at,'ended_at',s.ended_at) order by s.started_at)
      from public.finish_staff_table_segments s join public.stations st on st.station_id=s.station_id
      where s.work_session_id=fw.work_session_id),'[]'::jsonb),
    'finish_started_at',fw.actual_start_at,'finish_ended_at',fw.actual_end_at,'finish_break_minutes',fw.break_minutes
  ) order by lower(sm.display_name)),'[]'::jsonb) into v_extra
  from finish_work fw
  join public.staff_members sm on sm.staff_id=fw.staff_id
  join latest l on l.staff_id=fw.staff_id
  where l.area_code<>'FINISH';

  v_staff:=v_staff||coalesce(v_extra,'[]'::jsonb);

  with base_tables as (select value item from jsonb_array_elements(coalesce(v_base->'tables','[]'::jsonb)))
  select coalesce(jsonb_agg(item||jsonb_build_object(
    'recorded_kg',coalesce((item->>'produced_kg')::numeric,0),
    'units_kg_equivalent',round(coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg,2),
    'produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg
  ) order by item->>'table_code'),'[]'::jsonb) into v_tables
  from base_tables;

  return(v_base-'schema_version'-'source_contract'-'staff'-'tables')||jsonb_build_object(
    'schema_version','FINISH_STAFF_V4','source_contract','PUBLISHED_ROSTER_PLUS_ATTENDANCE_TABLE_SEGMENTS_AND_SORTING_COVER_CAPABILITY',
    'units_per_kg',v_units_per_kg,'staff',v_staff,'tables',v_tables
  );
end;
$$;

revoke all on function public.get_finish_staff_context_v4(text, timestamptz) from public, anon;
grant execute on function public.get_finish_staff_context_v4(text, timestamptz) to authenticated;

commit;
