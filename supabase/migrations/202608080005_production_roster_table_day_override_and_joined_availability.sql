-- =====================================================================
-- ElisCaretex V2
-- Migration: Production Roster table-day overrides + Joined date availability
-- Date: 2026-08-08
--
-- Rules:
--   * SHOW ROW IN defines the weekly/base section.
--   * Changing SHOW ROW IN resets normal Working/QA days to that section.
--   * A staff row in Table 1/2/3 may override an individual Working/QA day
--     to another Finish Table without moving the weekly row.
--   * Support Role keeps broad mixed daily assignment capability.
--   * Sorting/Label/Supervisor/Cleaner normal BASE days remain fixed to the
--     weekly section.
--   * Staff Master joined_on controls roster availability. A staff member is
--     exposed to the planner only when the selected week reaches joined_on,
--     and Working/Training/QA/COVER before joined_on is rejected.
--   * Published roster history remains immutable.
-- =====================================================================

begin;

create or replace function public.get_production_roster_staff_pool(
  p_week_start date,
  p_shift_code text,
  p_roster_version_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift public.shifts%rowtype;
  v_version public.production_roster_versions%rowtype;
  v_period_id uuid;
begin
  perform public.require_production_roster_read_role();

  select * into v_shift
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code))
    and s.active = true
    and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid or inactive shift.';
  end if;

  select rp.roster_period_id into v_period_id
  from public.roster_periods rp
  where rp.week_start = v_week_start;

  if p_roster_version_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where prv.roster_version_id = p_roster_version_id
      and rp.week_start = v_week_start
      and prv.shift_id = v_shift.shift_id;
  elsif v_period_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id
      and prv.shift_id = v_shift.shift_id
      and prv.status in ('DRAFT', 'PUBLISHED')
    order by case prv.status when 'DRAFT' then 1 else 2 end,
             prv.version_number desc
    limit 1;
  end if;

  return jsonb_build_object(
    'week_start', v_week_start,
    'roster_shift_code', v_shift.shift_code,
    'roster_shift_name', v_shift.shift_name,
    'roster_version_id', v_version.roster_version_id,
    'staff', coalesce((
      with version_staff as (
        select distinct on (pre.staff_id)
          pre.staff_id,
          pre.staff_display_name_snapshot as display_name,
          pre.employee_code_snapshot as employee_code,
          coalesce(
            pre.staff_default_shift_code_snapshot,
            pre.shift_code_snapshot
          ) as default_shift_code,
          coalesce(
            pre.staff_default_shift_name_snapshot,
            pre.shift_name_snapshot
          ) as default_shift_name,
          pre.staff_primary_role_code_snapshot as primary_role_code,
          pre.staff_primary_role_name_snapshot as primary_role_name,
          pre.staff_default_area_code_snapshot as default_area_code,
          pre.staff_default_area_name_snapshot as default_area_name,
          pre.staff_default_station_code_snapshot as default_station_code,
          pre.staff_default_station_name_snapshot as default_station_name,
          pre.display_section_code,
          pre.fire_training_snapshot as fire_training,
          pre.first_aid_training_snapshot as first_aid_training,
          pre.eod_capable_snapshot as eod_capable
        from public.production_roster_entries pre
        where pre.roster_version_id = v_version.roster_version_id
        order by pre.staff_id, pre.work_date
      ),
      current_staff as (
        select
          sm.staff_id,
          sm.display_name,
          sm.employee_code,
          sh.shift_code as default_shift_code,
          sh.shift_name as default_shift_name,
          opr.role_code as primary_role_code,
          opr.role_name as primary_role_name,
          a.area_code as default_area_code,
          a.area_name as default_area_name,
          st.station_code as default_station_code,
          st.station_name as default_station_name,
          public.production_roster_default_display_section(opr.role_code, st.station_code) as display_section_code,
          sm.fire_training,
          sm.first_aid_training,
          sm.eod_capable,
          sm.joined_on,
          coalesce(opr.sort_order, 999) as role_sort,
          coalesce(st.sort_order, 999) as station_sort
        from public.staff_members sm
        join public.shifts sh on sh.shift_id = sm.default_shift_id
        left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
        left join public.areas a on a.area_id = sm.default_area_id
        left join public.stations st on st.station_id = sm.default_station_id
        where sm.production_staff = true
          and sm.active = true
          and sm.roster_eligible = true
          and sm.deleted_at is null
          and (sm.joined_on is null or sm.joined_on <= v_week_start + 6)
          and sh.active = true
          and sh.deleted_at is null
      ),
      pool as (
        select
          cs.staff_id,
          coalesce(vs.display_name, cs.display_name) as display_name,
          coalesce(vs.employee_code, cs.employee_code) as employee_code,
          coalesce(vs.default_shift_code, cs.default_shift_code) as default_shift_code,
          coalesce(vs.default_shift_name, cs.default_shift_name) as default_shift_name,
          coalesce(vs.primary_role_code, cs.primary_role_code) as primary_role_code,
          coalesce(vs.primary_role_name, cs.primary_role_name) as primary_role_name,
          coalesce(vs.default_area_code, cs.default_area_code) as default_area_code,
          coalesce(vs.default_area_name, cs.default_area_name) as default_area_name,
          coalesce(vs.default_station_code, cs.default_station_code) as default_station_code,
          coalesce(vs.default_station_name, cs.default_station_name) as default_station_name,
          coalesce(vs.display_section_code, cs.display_section_code) as display_section_code,
          coalesce(vs.fire_training, cs.fire_training, false) as fire_training,
          coalesce(vs.first_aid_training, cs.first_aid_training, false) as first_aid_training,
          coalesce(vs.eod_capable, cs.eod_capable, false) as eod_capable,
          cs.joined_on,
          (vs.staff_id is not null) as included_in_roster,
          true as currently_eligible,
          cs.role_sort,
          cs.station_sort
        from current_staff cs
        left join version_staff vs on vs.staff_id = cs.staff_id

        union all

        select
          vs.staff_id,
          vs.display_name,
          vs.employee_code,
          vs.default_shift_code,
          vs.default_shift_name,
          vs.primary_role_code,
          vs.primary_role_name,
          vs.default_area_code,
          vs.default_area_name,
          vs.default_station_code,
          vs.default_station_name,
          vs.display_section_code,
          coalesce(vs.fire_training, false),
          coalesce(vs.first_aid_training, false),
          coalesce(vs.eod_capable, false),
          null::date,
          true,
          false,
          999,
          999
        from version_staff vs
        where not exists (
          select 1 from current_staff cs where cs.staff_id = vs.staff_id
        )
      )
      select jsonb_agg(jsonb_build_object(
        'staff_id', p.staff_id,
        'display_name', p.display_name,
        'employee_code', p.employee_code,
        'default_shift_code', p.default_shift_code,
        'default_shift_name', p.default_shift_name,
        'primary_role_code', p.primary_role_code,
        'primary_role_name', p.primary_role_name,
        'default_area_code', p.default_area_code,
        'default_area_name', p.default_area_name,
        'default_station_code', p.default_station_code,
        'default_station_name', p.default_station_name,
        'display_section_code', p.display_section_code,
        'fire_training', p.fire_training,
        'first_aid_training', p.first_aid_training,
        'eod_capable', p.eod_capable,
        'joined_on', p.joined_on,
        'cover_role_codes', coalesce((
          select jsonb_agg(cr.role_code order by cr.sort_order)
          from public.staff_cover_capabilities scc
          join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
          where scc.staff_id = p.staff_id
            and scc.active = true
            and scc.deleted_at is null
            and scc.effective_from <= v_week_start + 6
            and (scc.effective_until is null or scc.effective_until >= v_week_start)
        ), '[]'::jsonb),
        'included_in_roster', p.included_in_roster,
        'currently_eligible', p.currently_eligible,
        'shift_override', coalesce(p.default_shift_code, '') <> v_shift.shift_code,
        'roster_shift_code', v_shift.shift_code,
        'roster_shift_name', v_shift.shift_name
      ) order by
        case when p.default_shift_code = v_shift.shift_code then 0 else 1 end,
        p.role_sort,
        p.station_sort,
        lower(p.display_name))
      from pool p
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_production_roster_staff_pool(date, text, uuid) from public, anon;
grant execute on function public.get_production_roster_staff_pool(date, text, uuid) to authenticated;

comment on function public.get_production_roster_staff_pool(date, text, uuid) is
  'Controlled Production Roster staff pool. Current production staff become available when the selected week reaches Staff Master joined_on. Historical included staff remain visible from immutable snapshots.';

create or replace function public.save_production_roster_week(
  p_week_start date,
  p_shift_code text,
  p_include_sunday boolean,
  p_week_note text,
  p_entries jsonb,
  p_base_row_version integer default null,
  p_change_reason text default null,
  p_source_application text default 'PRODUCTION_ROSTER'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift public.shifts%rowtype;
  v_period_id uuid;
  v_draft public.production_roster_versions%rowtype;
  v_published public.production_roster_versions%rowtype;
  v_item jsonb;
  v_staff public.staff_members%rowtype;
  v_role public.operational_roles%rowtype;
  v_area public.areas%rowtype;
  v_station public.stations%rowtype;
  v_resolved_base record;
  v_work_date date;
  v_day_status text;
  v_assignment_type text;
  v_role_code text;
  v_area_code text;
  v_station_code text;
  v_requested_station_code text;
  v_display_section_code text;
  v_expected_days integer := case when p_include_sunday then 7 else 6 end;
  v_entry_count integer;
  v_staff_count integer;
  v_actor_staff uuid := public.current_staff_id();
  v_next_version integer;
begin
  perform public.require_production_roster_manage_role();

  if v_week_start < public.production_roster_week_start(current_date) then
    raise exception using errcode = '55000', message = 'Past Production Roster weeks are read-only.';
  end if;

  if p_entries is null or jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) = 0 then
    raise exception using errcode = '22023', message = 'The Production Roster must contain staff entries.';
  end if;

  select * into v_shift
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code)) and s.active = true and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid or inactive shift.';
  end if;

  insert into public.roster_periods (week_start, status, created_by)
  values (v_week_start, 'DRAFT', auth.uid())
  on conflict (week_start) do nothing;

  select rp.roster_period_id into v_period_id
  from public.roster_periods rp
  where rp.week_start = v_week_start
  for update;

  select * into v_draft
  from public.production_roster_versions prv
  where prv.roster_period_id = v_period_id
    and prv.shift_id = v_shift.shift_id
    and prv.status = 'DRAFT'
  for update;

  if v_draft.roster_version_id is not null then
    if p_base_row_version is null or p_base_row_version <> v_draft.row_version then
      raise exception using errcode = '40001', message = 'The Production Roster was changed by another user. Reload before saving.';
    end if;
  else
    select * into v_published
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id
      and prv.shift_id = v_shift.shift_id
      and prv.status = 'PUBLISHED'
    limit 1;

    select coalesce(max(prv.version_number), 0) + 1 into v_next_version
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id and prv.shift_id = v_shift.shift_id;

    insert into public.production_roster_versions (
      roster_period_id, shift_id, version_number, status, include_sunday,
      week_note, based_on_version_id, saved_at, saved_by, created_by, updated_by
    ) values (
      v_period_id, v_shift.shift_id, v_next_version, 'DRAFT', p_include_sunday,
      nullif(trim(p_week_note), ''), v_published.roster_version_id,
      now(), auth.uid(), auth.uid(), auth.uid()
    ) returning * into v_draft;

    insert into public.production_roster_events (
      roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason, metadata
    ) values (
      v_draft.roster_version_id, 'DRAFT_CREATED', auth.uid(), v_actor_staff,
      nullif(trim(p_change_reason), ''),
      jsonb_build_object('week_start', v_week_start, 'shift_code', v_shift.shift_code)
    );
  end if;

  delete from public.production_roster_entries pre
  where pre.roster_version_id = v_draft.roster_version_id;

  for v_item in select value from jsonb_array_elements(p_entries)
  loop
    v_work_date := (v_item ->> 'work_date')::date;
    v_day_status := upper(coalesce(nullif(trim(v_item ->> 'day_status'), ''), 'WORKING'));
    v_assignment_type := upper(coalesce(nullif(trim(v_item ->> 'assignment_type'), ''), 'BASE'));
    v_role_code := upper(nullif(trim(v_item ->> 'operational_role_code'), ''));
    v_area_code := upper(nullif(trim(v_item ->> 'area_code'), ''));
    v_requested_station_code := upper(nullif(trim(v_item ->> 'station_code'), ''));
    v_station_code := v_requested_station_code;
    v_display_section_code := upper(nullif(trim(v_item ->> 'display_section_code'), ''));

    if v_work_date < v_week_start
       or v_work_date > v_week_start + (v_expected_days - 1) then
      raise exception using errcode = '22023', message = 'A roster entry is outside the selected week.';
    end if;

    if v_day_status not in ('WORKING', 'OFF', 'SICK', 'HOLIDAY', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using errcode = '22023', message = 'Invalid Production Roster day status.';
    end if;

    if v_assignment_type not in ('BASE', 'COVER') then
      raise exception using errcode = '22023', message = 'Invalid Production Roster assignment type.';
    end if;

    if v_assignment_type = 'COVER' and v_day_status <> 'WORKING' then
      raise exception using errcode = '22023', message = 'COVER can only be used with Working status.';
    end if;

    select * into v_staff
    from public.staff_members sm
    where sm.staff_id = (v_item ->> 'staff_id')::uuid
      and sm.production_staff = true
      and sm.active = true
      and sm.roster_eligible = true
      and sm.deleted_at is null;

    if not found then
      raise exception using errcode = '22023', message = 'The roster contains inactive, ineligible or non-production staff.';
    end if;

    if v_staff.joined_on is not null
       and v_work_date < v_staff.joined_on
       and v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using errcode = '22023', message = 'The staff member is not available before the Staff Master Joined date.';
    end if;

    if v_display_section_code is null then
      select public.production_roster_default_display_section(opr.role_code, st.station_code)
      into v_display_section_code
      from public.staff_members sm
      left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
      left join public.stations st on st.station_id = sm.default_station_id
      where sm.staff_id = v_staff.staff_id;
    end if;

    if v_display_section_code not in (
      'SUPERVISOR', 'SORTING_AREA', 'LABEL',
      'FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3', 'FINISH_OTHER',
      'CLEANER', 'SUPPORT_ROLE'
    ) then
      raise exception using errcode = '22023', message = 'Invalid Production Roster display section.';
    end if;

    -- The weekly row section remains authoritative for the normal role/area.
    -- Finish Table rows intentionally allow a day-level override between
    -- Table 1, Table 2 and Table 3 without moving the weekly row. Changing
    -- SHOW ROW IN resets the frontend days to the new weekly table. SUPPORT_ROLE
    -- remains the broader mixed-location mode; COVER remains day-specific.
    if v_assignment_type = 'BASE'
       and v_day_status in ('WORKING', 'QUALITY_ANALYSIS')
       and v_display_section_code <> 'SUPPORT_ROLE' then
      select *
      into v_resolved_base
      from public.production_roster_resolve_display_assignment(
        v_display_section_code,
        v_role_code
      );

      v_role_code := v_resolved_base.role_code;
      v_area_code := v_resolved_base.area_code;

      if v_display_section_code in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3')
         and v_requested_station_code in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3') then
        v_station_code := v_requested_station_code;
      else
        v_station_code := v_resolved_base.station_code;
      end if;
    end if;

    v_role.operational_role_id := null;
    v_role.role_code := null;
    v_role.role_name := null;
    v_role.allow_as_cover := false;
    v_area.area_id := null;
    v_area.area_code := null;
    v_area.area_name := null;
    v_station.station_id := null;
    v_station.station_code := null;
    v_station.station_name := null;

    if v_day_status in ('WORKING', 'QUALITY_ANALYSIS') then
      if v_role_code is null or v_area_code is null then
        raise exception using errcode = '22023', message = 'Working assignments require an operational role and area.';
      end if;

      select * into v_role from public.operational_roles opr
      where opr.role_code = v_role_code and opr.active = true and opr.deleted_at is null;
      if not found then
        raise exception using errcode = '22023', message = 'Invalid operational role in roster entry.';
      end if;

      select * into v_area from public.areas a
      where a.area_code = v_area_code and a.active = true and a.deleted_at is null;
      if not found then
        raise exception using errcode = '22023', message = 'Invalid area in roster entry.';
      end if;

      if v_station_code is not null then
        select * into v_station from public.stations st
        where st.station_code = v_station_code
          and st.area_id = v_area.area_id
          and st.active = true
          and st.deleted_at is null;
        if not found then
          raise exception using errcode = '22023', message = 'The selected station does not belong to the selected area.';
        end if;
      end if;

      if v_assignment_type = 'COVER' then
        if v_role.allow_as_cover is not true
           or public.production_roster_cover_currently_authorised(
             v_staff.staff_id,
             v_role.operational_role_id
           ) is not true then
          raise exception using errcode = '22023', message = 'The staff member is not authorised for the selected COVER role.';
        end if;
      end if;
    else
      v_assignment_type := 'BASE';
      v_role_code := null;
      v_area_code := null;
      v_station_code := null;
    end if;

    insert into public.production_roster_entries (
      roster_version_id, work_date, staff_id, day_status, assignment_type,
      operational_role_id, area_id, station_id,
      planned_start_time, planned_end_time, notes, display_section_code,
      staff_display_name_snapshot, employee_code_snapshot,
      shift_code_snapshot, shift_name_snapshot,
      operational_role_code_snapshot, operational_role_name_snapshot,
      area_code_snapshot, area_name_snapshot,
      station_code_snapshot, station_name_snapshot,
      staff_primary_role_code_snapshot, staff_primary_role_name_snapshot,
      staff_default_area_code_snapshot, staff_default_area_name_snapshot,
      staff_default_station_code_snapshot, staff_default_station_name_snapshot,
      fire_training_snapshot, first_aid_training_snapshot, eod_capable_snapshot,
      created_by, updated_by
    ) values (
      v_draft.roster_version_id,
      v_work_date,
      v_staff.staff_id,
      v_day_status,
      v_assignment_type,
      v_role.operational_role_id,
      v_area.area_id,
      v_station.station_id,
      nullif(v_item ->> 'planned_start_time', '')::time,
      nullif(v_item ->> 'planned_end_time', '')::time,
      nullif(trim(v_item ->> 'notes'), ''),
      v_display_section_code,
      v_staff.display_name,
      v_staff.employee_code,
      v_shift.shift_code,
      v_shift.shift_name,
      v_role.role_code,
      v_role.role_name,
      v_area.area_code,
      v_area.area_name,
      v_station.station_code,
      v_station.station_name,
      (select opr.role_code from public.operational_roles opr where opr.operational_role_id = v_staff.primary_operational_role_id),
      (select opr.role_name from public.operational_roles opr where opr.operational_role_id = v_staff.primary_operational_role_id),
      (select a.area_code from public.areas a where a.area_id = v_staff.default_area_id),
      (select a.area_name from public.areas a where a.area_id = v_staff.default_area_id),
      (select st.station_code from public.stations st where st.station_id = v_staff.default_station_id),
      (select st.station_name from public.stations st where st.station_id = v_staff.default_station_id),
      v_staff.fire_training,
      v_staff.first_aid_training,
      v_staff.eod_capable,
      auth.uid(),
      auth.uid()
    );
  end loop;

  select count(*), count(distinct staff_id)
  into v_entry_count, v_staff_count
  from public.production_roster_entries pre
  where pre.roster_version_id = v_draft.roster_version_id;

  if v_staff_count = 0 or v_entry_count <> v_staff_count * v_expected_days then
    raise exception using errcode = '22023', message = 'Every included staff member must have exactly one entry for each visible day.';
  end if;

  if exists (
    select 1
    from public.production_roster_entries pre
    where pre.roster_version_id = v_draft.roster_version_id
    group by pre.staff_id
    having count(distinct pre.display_section_code) <> 1
  ) then
    raise exception using errcode = '22023', message = 'Each staff member must have one weekly display section per roster version.';
  end if;

  update public.production_roster_versions
  set include_sunday = p_include_sunday,
      week_note = nullif(trim(p_week_note), ''),
      saved_at = now(),
      saved_by = auth.uid(),
      updated_by = auth.uid(),
      row_version = row_version + 1
  where roster_version_id = v_draft.roster_version_id
  returning * into v_draft;

  insert into public.production_roster_events (
    roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason,
    metadata
  ) values (
    v_draft.roster_version_id, 'DRAFT_SAVED', auth.uid(), v_actor_staff,
    nullif(trim(p_change_reason), ''),
    jsonb_build_object('entry_count', v_entry_count, 'staff_count', v_staff_count, 'source_application', p_source_application)
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_DRAFT_SAVED',
    'production_roster_versions', v_draft.roster_version_id::text,
    jsonb_build_object('week_start', v_week_start, 'shift_code', v_shift.shift_code, 'version_number', v_draft.version_number),
    nullif(trim(p_change_reason), ''), p_source_application
  );

  return jsonb_build_object(
    'roster_version_id', v_draft.roster_version_id,
    'version_number', v_draft.version_number,
    'status', v_draft.status,
    'row_version', v_draft.row_version,
    'entry_count', v_entry_count,
    'staff_count', v_staff_count,
    'saved_at', v_draft.saved_at
  );
end;
$$;

revoke all on function public.save_production_roster_week(date, text, boolean, text, jsonb, integer, text, text)
  from public, anon;
grant execute on function public.save_production_roster_week(date, text, boolean, text, jsonb, integer, text, text)
  to authenticated;

comment on function public.save_production_roster_week(date, text, boolean, text, jsonb, integer, text, text) is
  'Atomically saves an editable Production Roster draft. Weekly sections control base role/area; Finish Table rows may override an individual day between Table 1/2/3; Staff Master joined_on blocks work before the join date; COVER uses current authorised capabilities.';

commit;
