-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608100002_production_roster_mop_and_staff_exit_guard.sql
--
-- Planned Sorting rule: exactly one MOP staff per Business Date + Shift.
-- Staff availability rule: deactivated_on is the last employed day.
-- Published history remains immutable; current/future Drafts must reconcile.
-- =====================================================================

begin;

alter table public.production_roster_entries
  add column if not exists sorting_work_mode text;

alter table public.production_roster_entries
  drop constraint if exists production_roster_entries_sorting_work_mode_check;
alter table public.production_roster_entries
  add constraint production_roster_entries_sorting_work_mode_check
    check (sorting_work_mode is null or sorting_work_mode in ('CLOTHES','MOP'));

create index if not exists production_roster_entries_sorting_mop_idx
  on public.production_roster_entries (roster_version_id, work_date, sorting_work_mode)
  where sorting_work_mode is not null;

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

  -- A staff row cannot remain in a roster whose entire visible week is outside
  -- the Staff Master employment interval. deactivated_on is the LAST employed day.
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

  -- Working-like statuses must be inside the employment dates and current
  -- Staff Master eligibility unless an explicit exit date preserves earlier days.
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

  -- Exactly one MOP person is mandatory for every date that has at least one
  -- Working Sorting assignment. Every other Working Sorting entry is Clothes.
  select
    pre.work_date,
    count(*) filter (where pre.sorting_work_mode = 'MOP') as mop_count,
    count(*) as sorting_count
  into v_bad
  from public.production_roster_entries pre
  where pre.roster_version_id = p_roster_version_id
    and pre.day_status = 'WORKING'
    and (
      pre.area_code_snapshot = 'SORTING'
      or pre.operational_role_code_snapshot = 'SORTING_AREA'
    )
  group by pre.work_date
  having count(*) filter (where pre.sorting_work_mode = 'MOP') <> 1
  order by pre.work_date
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        'Select exactly one MOP staff member for Sorting on %s. %s Sorting staff are working and %s are marked MOP.',
        to_char(v_bad.work_date,'YYYY-MM-DD'),
        v_bad.sorting_count,
        v_bad.mop_count
      );
  end if;
end;
$$;

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
          pre.eod_capable_snapshot as eod_capable,
          sm.joined_on,
          sm.deactivated_on,
          sm.active as master_active,
          sm.roster_eligible as master_roster_eligible,
          sm.production_staff as master_production_staff,
          sm.deleted_at as master_deleted_at
        from public.production_roster_entries pre
        left join public.staff_members sm on sm.staff_id = pre.staff_id
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
          sm.deactivated_on,
          sm.active as master_active,
          sm.roster_eligible as master_roster_eligible,
          sm.production_staff as master_production_staff,
          sm.deleted_at as master_deleted_at,
          coalesce(opr.sort_order, 999) as role_sort,
          coalesce(st.sort_order, 999) as station_sort
        from public.staff_members sm
        join public.shifts sh on sh.shift_id = sm.default_shift_id
        left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
        left join public.areas a on a.area_id = sm.default_area_id
        left join public.stations st on st.station_id = sm.default_station_id
        where sm.production_staff = true
          and sm.deleted_at is null
          and (sm.joined_on is null or sm.joined_on <= v_week_start + 6)
          and (sm.deactivated_on is null or sm.deactivated_on >= v_week_start)
          and (
            (sm.active = true and sm.roster_eligible = true)
            or sm.deactivated_on is not null
          )
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
          cs.deactivated_on,
          cs.master_active,
          cs.master_roster_eligible,
          cs.master_production_staff,
          cs.master_deleted_at,
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
          vs.joined_on,
          vs.deactivated_on,
          vs.master_active,
          vs.master_roster_eligible,
          vs.master_production_staff,
          vs.master_deleted_at,
          true,
          (
            coalesce(vs.master_production_staff, false) = true
            and vs.master_deleted_at is null
            and (vs.joined_on is null or vs.joined_on <= v_week_start + 6)
            and (vs.deactivated_on is null or vs.deactivated_on >= v_week_start)
            and (
              (coalesce(vs.master_active, false) = true and coalesce(vs.master_roster_eligible, false) = true)
              or vs.deactivated_on is not null
            )
          ),
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
        'deactivated_on', p.deactivated_on,
        'master_active', p.master_active,
        'master_roster_eligible', p.master_roster_eligible,
        'master_production_staff', p.master_production_staff,
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

create or replace function public.get_production_roster_week(
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
  v_can_manage boolean;
  v_is_past boolean := v_week_start < public.production_roster_week_start(current_date);
begin
  perform public.require_production_roster_read_role();
  v_can_manage := public.has_any_role(array['ADMIN', 'MANAGER', 'ROSTER_MANAGER']);

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
    order by case prv.status when 'DRAFT' then 1 else 2 end, prv.version_number desc
    limit 1;
  end if;

  return jsonb_build_object(
    'week_start', v_week_start,
    'week_end', v_week_start + 6,
    'is_past', v_is_past,
    'can_manage', v_can_manage,
    'shift', jsonb_build_object(
      'shift_id', v_shift.shift_id,
      'shift_code', v_shift.shift_code,
      'shift_name', v_shift.shift_name,
      'start_time', v_shift.start_time,
      'end_time', v_shift.end_time
    ),
    'document', case when v_version.roster_version_id is null then null else jsonb_build_object(
      'roster_version_id', v_version.roster_version_id,
      'version_number', v_version.version_number,
      'status', v_version.status,
      'include_sunday', v_version.include_sunday,
      'week_note', v_version.week_note,
      'row_version', v_version.row_version,
      'based_on_version_id', v_version.based_on_version_id,
      'saved_at', v_version.saved_at,
      'published_at', v_version.published_at,
      'is_historical', p_roster_version_id is not null
    ) end,
    'published_document', (
      select jsonb_build_object(
        'roster_version_id', p.roster_version_id,
        'version_number', p.version_number,
        'published_at', p.published_at
      )
      from public.production_roster_versions p
      where p.roster_period_id = v_period_id
        and p.shift_id = v_shift.shift_id
        and p.status = 'PUBLISHED'
      limit 1
    ),
    'staff', case
      when v_version.roster_version_id is not null then coalesce((
        select jsonb_agg(staff_row order by
          (staff_row ->> 'display_section_sort')::integer,
          (staff_row ->> 'group_sort')::integer,
          (staff_row ->> 'station_sort')::integer,
          lower(staff_row ->> 'display_name')
        )
        from (
          select distinct on (pre.staff_id)
            jsonb_build_object(
              'staff_id', pre.staff_id,
              'display_name', pre.staff_display_name_snapshot,
              'employee_code', pre.employee_code_snapshot,
              'default_shift_code', coalesce(pre.staff_default_shift_code_snapshot, pre.shift_code_snapshot),
              'default_shift_name', coalesce(pre.staff_default_shift_name_snapshot, pre.shift_name_snapshot),
              'primary_role_code', coalesce(pre.staff_primary_role_code_snapshot, sm_role.role_code),
              'primary_role_name', coalesce(pre.staff_primary_role_name_snapshot, sm_role.role_name),
              'default_area_code', coalesce(pre.staff_default_area_code_snapshot, sm_area.area_code),
              'default_area_name', coalesce(pre.staff_default_area_name_snapshot, sm_area.area_name),
              'default_station_code', coalesce(pre.staff_default_station_code_snapshot, sm_station.station_code),
              'default_station_name', coalesce(pre.staff_default_station_name_snapshot, sm_station.station_name),
              'display_section_code', pre.display_section_code,
              'shift_override_authorized', exists (
                select 1
                from public.production_roster_shift_overrides pro
                where pro.roster_version_id = pre.roster_version_id
                  and pro.staff_id = pre.staff_id
              ),
              'shift_override_source', (
                select pro.source_application
                from public.production_roster_shift_overrides pro
                where pro.roster_version_id = pre.roster_version_id
                  and pro.staff_id = pre.staff_id
                limit 1
              ),
              'display_section_sort', public.production_roster_display_section_sort(pre.display_section_code),
              'fire_training', pre.fire_training_snapshot,
              'first_aid_training', pre.first_aid_training_snapshot,
              'eod_capable', pre.eod_capable_snapshot,
              'cover_role_codes', coalesce((
                select jsonb_agg(cr.role_code order by cr.sort_order)
                from public.staff_cover_capabilities scc
                join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
                where scc.staff_id = pre.staff_id
                  and scc.active = true
                  and scc.deleted_at is null
                  and scc.effective_from <= current_date
                  and (scc.effective_until is null or scc.effective_until >= current_date)
              ), '[]'::jsonb),
              'group_sort', coalesce(sm_role.sort_order, 999),
              'station_sort', coalesce(sm_station.sort_order, 999)
            ) as staff_row
          from public.production_roster_entries pre
          left join public.staff_members sm on sm.staff_id = pre.staff_id
          left join public.operational_roles sm_role on sm_role.operational_role_id = sm.primary_operational_role_id
          left join public.areas sm_area on sm_area.area_id = sm.default_area_id
          left join public.stations sm_station on sm_station.station_id = sm.default_station_id
          where pre.roster_version_id = v_version.roster_version_id
          order by pre.staff_id, pre.work_date
        ) rows
      ), '[]'::jsonb)
      else coalesce((
        select jsonb_agg(jsonb_build_object(
          'staff_id', sm.staff_id,
          'display_name', sm.display_name,
          'employee_code', sm.employee_code,
          'default_shift_code', s.shift_code,
          'primary_role_code', opr.role_code,
          'primary_role_name', opr.role_name,
          'default_area_code', a.area_code,
          'default_area_name', a.area_name,
          'default_station_code', st.station_code,
          'default_station_name', st.station_name,
          'display_section_code', public.production_roster_default_display_section(opr.role_code, st.station_code),
          'shift_override_authorized', false,
          'shift_override_source', null,
          'display_section_sort', public.production_roster_display_section_sort(public.production_roster_default_display_section(opr.role_code, st.station_code)),
          'fire_training', sm.fire_training,
          'first_aid_training', sm.first_aid_training,
          'eod_capable', sm.eod_capable,
          'cover_role_codes', coalesce((
            select jsonb_agg(cr.role_code order by cr.sort_order)
            from public.staff_cover_capabilities scc
            join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
            where scc.staff_id = sm.staff_id
              and scc.active = true
              and scc.deleted_at is null
              and scc.effective_from <= v_week_start + 6
              and (scc.effective_until is null or scc.effective_until >= v_week_start)
          ), '[]'::jsonb),
          'group_sort', coalesce(opr.sort_order, 999),
          'station_sort', coalesce(st.sort_order, 999)
        ) order by
          public.production_roster_display_section_sort(public.production_roster_default_display_section(opr.role_code, st.station_code)),
          coalesce(opr.sort_order, 999),
          coalesce(st.sort_order, 999),
          lower(sm.display_name))
        from public.staff_members sm
        join public.shifts s on s.shift_id = sm.default_shift_id
        left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
        left join public.areas a on a.area_id = sm.default_area_id
        left join public.stations st on st.station_id = sm.default_station_id
        where sm.production_staff = true
          and sm.active = true
          and sm.roster_eligible = true
          and sm.deleted_at is null
          and s.shift_id = v_shift.shift_id
      ), '[]'::jsonb)
    end,
    'entries', case when v_version.roster_version_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'roster_entry_id', pre.roster_entry_id,
        'staff_id', pre.staff_id,
        'work_date', pre.work_date,
        'day_status', pre.day_status,
        'assignment_type', pre.assignment_type,
        'operational_role_code', opr.role_code,
        'operational_role_name', pre.operational_role_name_snapshot,
        'area_code', a.area_code,
        'area_name', pre.area_name_snapshot,
        'station_code', st.station_code,
        'station_name', pre.station_name_snapshot,
        'sorting_work_mode', pre.sorting_work_mode,
        'display_section_code', pre.display_section_code,
        'shift_override_confirmed', exists (
          select 1
          from public.production_roster_shift_overrides pro
          where pro.roster_version_id = pre.roster_version_id
            and pro.staff_id = pre.staff_id
        ),
        'planned_start_time', pre.planned_start_time,
        'planned_end_time', pre.planned_end_time,
        'notes', pre.notes
      ) order by pre.work_date, lower(pre.staff_display_name_snapshot))
      from public.production_roster_entries pre
      left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
      left join public.areas a on a.area_id = pre.area_id
      left join public.stations st on st.station_id = pre.station_id
      where pre.roster_version_id = v_version.roster_version_id
    ), '[]'::jsonb) end
  );
end;
$$;

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
  v_sorting_work_mode text;
  v_expected_days integer := case when p_include_sunday then 7 else 6 end;
  v_entry_count integer;
  v_staff_count integer;
  v_actor_staff uuid := public.current_staff_id();
  v_next_version integer;
  v_staff_default_shift public.shifts%rowtype;
  v_cross_shift boolean;
  v_shift_override_confirmed boolean;
  v_conflict_shift_name text;
  v_shift_override_staff_count integer := 0;
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

  delete from public.production_roster_shift_overrides pro
  where pro.roster_version_id = v_draft.roster_version_id;

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
    v_sorting_work_mode := upper(nullif(trim(v_item ->> 'sorting_work_mode'), ''));

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
      and sm.deleted_at is null;

    if not found then
      raise exception using errcode = '22023', message = 'The roster contains deleted or non-production staff.';
    end if;

    select * into v_staff_default_shift
    from public.shifts sh
    where sh.shift_id = v_staff.default_shift_id
      and sh.active = true
      and sh.deleted_at is null;

    if not found then
      raise exception using errcode = '22023', message = 'The staff member does not have a valid Staff Master default shift.';
    end if;

    v_cross_shift := v_staff_default_shift.shift_id <> v_shift.shift_id;
    v_shift_override_confirmed := coalesce(nullif(v_item ->> 'shift_override_confirmed', '')::boolean, false);

    if v_cross_shift and not v_shift_override_confirmed then
      raise exception using
        errcode = '22023',
        message = format(
          '%s belongs to %s in Staff Master. Remove the row or add it explicitly as a temporary %s shift override.',
          v_staff.display_name,
          v_staff_default_shift.shift_name,
          v_shift.shift_name
        );
    end if;

    if v_staff.joined_on is not null
       and v_work_date < v_staff.joined_on
       and v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using errcode = '22023', message = 'The staff member is not available before the Staff Master Joined date.';
    end if;


    if v_staff.deactivated_on is not null
       and v_work_date > v_staff.deactivated_on
       and v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using
        errcode = '22023',
        message = format(
          '%s cannot be planned after the Staff Master exit date %s.',
          v_staff.display_name,
          to_char(v_staff.deactivated_on, 'YYYY-MM-DD')
        );
    end if;

    if v_staff.deactivated_on is null
       and (v_staff.active is not true or v_staff.roster_eligible is not true)
       and v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then
      raise exception using
        errcode = '22023',
        message = format('%s is inactive or not roster-eligible in Staff Master.', v_staff.display_name);
    end if;

    if v_cross_shift and v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then
      v_conflict_shift_name := null;

      with other_active_version as (
        select distinct on (prv.shift_id)
          prv.roster_version_id,
          osh.shift_name
        from public.production_roster_versions prv
        join public.shifts osh on osh.shift_id = prv.shift_id
        where prv.roster_period_id = v_period_id
          and prv.shift_id <> v_shift.shift_id
          and prv.status in ('DRAFT', 'PUBLISHED')
        order by
          prv.shift_id,
          case prv.status when 'DRAFT' then 1 else 2 end,
          prv.version_number desc
      )
      select oav.shift_name
      into v_conflict_shift_name
      from other_active_version oav
      join public.production_roster_entries other_entry
        on other_entry.roster_version_id = oav.roster_version_id
       and other_entry.staff_id = v_staff.staff_id
       and other_entry.work_date = v_work_date
      where other_entry.day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS')
      limit 1;

      if v_conflict_shift_name is not null then
        raise exception using
          errcode = '22023',
          message = format(
            '%s is already planned in %s on %s. Review that shift and make the day non-working before saving the temporary %s override.',
            v_staff.display_name,
            v_conflict_shift_name,
            to_char(v_work_date, 'YYYY-MM-DD'),
            v_shift.shift_name
          );
      end if;
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

    if v_day_status = 'WORKING'
       and (v_area.area_code = 'SORTING' or v_role.role_code = 'SORTING_AREA') then
      v_sorting_work_mode := coalesce(v_sorting_work_mode, 'CLOTHES');
      if v_sorting_work_mode not in ('CLOTHES', 'MOP') then
        raise exception using errcode = '22023', message = 'Sorting work mode must be CLOTHES or MOP.';
      end if;
    else
      v_sorting_work_mode := null;
    end if;

    if v_cross_shift then
      insert into public.production_roster_shift_overrides (
        roster_version_id,
        staff_id,
        staff_default_shift_code_snapshot,
        staff_default_shift_name_snapshot,
        roster_shift_code_snapshot,
        roster_shift_name_snapshot,
        confirmed_days,
        source_application,
        created_by,
        updated_by
      ) values (
        v_draft.roster_version_id,
        v_staff.staff_id,
        v_staff_default_shift.shift_code,
        v_staff_default_shift.shift_name,
        v_shift.shift_code,
        v_shift.shift_name,
        case
          when v_day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') then array[v_work_date]
          else '{}'::date[]
        end,
        p_source_application,
        auth.uid(),
        auth.uid()
      )
      on conflict (roster_version_id, staff_id) do update
      set confirmed_days = public.production_roster_shift_overrides.confirmed_days || excluded.confirmed_days,
          source_application = excluded.source_application,
          updated_at = now(),
          updated_by = auth.uid();
    end if;

    insert into public.production_roster_entries (
      roster_version_id, work_date, staff_id, day_status, assignment_type,
      operational_role_id, area_id, station_id,
      planned_start_time, planned_end_time, notes, display_section_code, sorting_work_mode,
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
      v_sorting_work_mode,
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

  select count(*)
  into v_shift_override_staff_count
  from public.production_roster_shift_overrides pro
  where pro.roster_version_id = v_draft.roster_version_id;

  if exists (
    select 1
    from public.production_roster_shift_overrides pro
    where pro.roster_version_id = v_draft.roster_version_id
      and cardinality(pro.confirmed_days) = 0
  ) then
    raise exception using
      errcode = '22023',
      message = 'A temporary shift override must contain at least one planned day.';
  end if;

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

  perform public.production_roster_assert_operational_rules(v_draft.roster_version_id);

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
    jsonb_build_object(
      'entry_count', v_entry_count,
      'staff_count', v_staff_count,
      'shift_override_staff_count', v_shift_override_staff_count,
      'source_application', p_source_application
    )
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_DRAFT_SAVED',
    'production_roster_versions', v_draft.roster_version_id::text,
    jsonb_build_object(
      'week_start', v_week_start,
      'shift_code', v_shift.shift_code,
      'version_number', v_draft.version_number,
      'shift_override_staff_count', v_shift_override_staff_count
    ),
    nullif(trim(p_change_reason), ''), p_source_application
  );

  return jsonb_build_object(
    'roster_version_id', v_draft.roster_version_id,
    'version_number', v_draft.version_number,
    'status', v_draft.status,
    'row_version', v_draft.row_version,
    'entry_count', v_entry_count,
    'staff_count', v_staff_count,
    'shift_override_staff_count', v_shift_override_staff_count,
    'saved_at', v_draft.saved_at
  );
end;
$$;

create or replace function public.publish_production_roster_week(
  p_roster_version_id uuid,
  p_base_row_version integer,
  p_reason text default null,
  p_source_application text default 'PRODUCTION_ROSTER'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_draft public.production_roster_versions%rowtype;
  v_period public.roster_periods%rowtype;
  v_previous_id uuid;
  v_actor_staff uuid := public.current_staff_id();
  v_entries integer;
begin
  perform public.require_production_roster_manage_role();

  select prv.* into v_draft
  from public.production_roster_versions prv
  where prv.roster_version_id = p_roster_version_id
    and prv.status = 'DRAFT'
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Production Roster draft not found.';
  end if;

  if v_draft.row_version <> p_base_row_version then
    raise exception using errcode = '40001', message = 'The Production Roster was changed by another user. Reload before publishing.';
  end if;

  select * into v_period from public.roster_periods rp
  where rp.roster_period_id = v_draft.roster_period_id;

  if v_period.week_start < public.production_roster_week_start(current_date) then
    raise exception using errcode = '55000', message = 'Past Production Roster weeks cannot be published.';
  end if;

  select count(*) into v_entries
  from public.production_roster_entries pre
  where pre.roster_version_id = v_draft.roster_version_id;

  if v_entries = 0 then
    raise exception using errcode = '22023', message = 'An empty Production Roster cannot be published.';
  end if;


  perform public.production_roster_assert_operational_rules(v_draft.roster_version_id);

  select prv.roster_version_id into v_previous_id
  from public.production_roster_versions prv
  where prv.roster_period_id = v_draft.roster_period_id
    and prv.shift_id = v_draft.shift_id
    and prv.status = 'PUBLISHED'
  limit 1
  for update;

  if v_previous_id is not null then
    update public.production_roster_versions
    set status = 'SUPERSEDED', updated_by = auth.uid(), row_version = row_version + 1
    where roster_version_id = v_previous_id;

    insert into public.production_roster_events (
      roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason,
      metadata
    ) values (
      v_previous_id, 'SUPERSEDED', auth.uid(), v_actor_staff,
      nullif(trim(p_reason), ''), jsonb_build_object('superseded_by', v_draft.roster_version_id)
    );
  end if;

  update public.production_roster_versions
  set status = 'PUBLISHED',
      published_at = now(),
      published_by = auth.uid(),
      updated_by = auth.uid(),
      row_version = row_version + 1
  where roster_version_id = v_draft.roster_version_id
  returning * into v_draft;

  update public.roster_periods
  set status = 'PUBLISHED', published_at = now(), published_by = auth.uid(), updated_at = now()
  where roster_period_id = v_draft.roster_period_id;

  insert into public.production_roster_events (
    roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason,
    metadata
  ) values (
    v_draft.roster_version_id, 'PUBLISHED', auth.uid(), v_actor_staff,
    nullif(trim(p_reason), ''), jsonb_build_object('source_application', p_source_application)
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_PUBLISHED',
    'production_roster_versions', v_draft.roster_version_id::text,
    jsonb_build_object('version_number', v_draft.version_number, 'published_at', v_draft.published_at),
    nullif(trim(p_reason), ''), p_source_application
  );

  return jsonb_build_object(
    'roster_version_id', v_draft.roster_version_id,
    'version_number', v_draft.version_number,
    'status', v_draft.status,
    'row_version', v_draft.row_version,
    'published_at', v_draft.published_at,
    'superseded_version_id', v_previous_id
  );
end;
$$;

create or replace function public.get_published_production_roster_portal(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_current_week date;
begin
  perform public.require_production_roster_staff_portal_token(p_token);
  v_current_week := public.production_roster_week_start(v_today);

  update public.production_roster_staff_portal_links
  set last_used_at = now()
  where scope_code = 'STAFF_PORTAL'
    and active = true;

  return jsonb_build_object(
    'generated_at', now(),
    'fixed_link', true,
    'shifts', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'shift_code', s.shift_code,
          'shift_name', s.shift_name,
          'weeks', coalesce((
            select jsonb_agg(week_json order by (week_json ->> 'week_start')::date)
            from (
              select jsonb_build_object(
                'week_start', rp.week_start,
                'week_end', rp.week_start + 6,
                'version_number', prv.version_number,
                'published_at', prv.published_at,
                'week_note', prv.week_note,
                'include_sunday', prv.include_sunday,
                'entries', coalesce((
                  select jsonb_agg(jsonb_build_object(
                    'staff_id', pre.staff_id,
                    'display_name', pre.staff_display_name_snapshot,
                    'work_date', pre.work_date,
                    'day_status', pre.day_status,
                    'assignment_type', pre.assignment_type,
                    'operational_role_code', pre.operational_role_code_snapshot,
                    'operational_role_name', pre.operational_role_name_snapshot,
                    'area_code', pre.area_code_snapshot,
                    'area_name', pre.area_name_snapshot,
                    'station_code', pre.station_code_snapshot,
                    'station_name', pre.station_name_snapshot,
                    'sorting_work_mode', pre.sorting_work_mode,
                    'display_section_code', coalesce(
                      pre.display_section_code,
                      public.production_roster_default_display_section(
                        pre.staff_primary_role_code_snapshot,
                        pre.staff_default_station_code_snapshot
                      )
                    ),
                    'staff_primary_role_code', pre.staff_primary_role_code_snapshot,
                    'staff_primary_role_name', pre.staff_primary_role_name_snapshot,
                    'staff_default_area_code', pre.staff_default_area_code_snapshot,
                    'staff_default_area_name', pre.staff_default_area_name_snapshot,
                    'staff_default_station_code', pre.staff_default_station_code_snapshot,
                    'staff_default_station_name', pre.staff_default_station_name_snapshot,
                    'staff_default_shift_code', coalesce(pre.staff_default_shift_code_snapshot, pre.shift_code_snapshot),
                    'staff_default_shift_name', coalesce(pre.staff_default_shift_name_snapshot, pre.shift_name_snapshot),
                    'roster_shift_code', pre.shift_code_snapshot,
                    'roster_shift_name', pre.shift_name_snapshot,
                    'fire_training', pre.fire_training_snapshot,
                    'first_aid_training', pre.first_aid_training_snapshot,
                    'eod_capable', pre.eod_capable_snapshot,
                    'notes', pre.notes
                  ) order by
                    public.production_roster_display_section_sort(coalesce(
                      pre.display_section_code,
                      public.production_roster_default_display_section(
                        pre.staff_primary_role_code_snapshot,
                        pre.staff_default_station_code_snapshot
                      )
                    )),
                    lower(pre.staff_display_name_snapshot),
                    pre.work_date)
                  from public.production_roster_entries pre
                  where pre.roster_version_id = prv.roster_version_id
                ), '[]'::jsonb)
              ) as week_json
              from public.production_roster_versions prv
              join public.roster_periods rp
                on rp.roster_period_id = prv.roster_period_id
              where prv.shift_id = s.shift_id
                and prv.status = 'PUBLISHED'
                and rp.week_start in (v_current_week, v_current_week + 7)
            ) published_weeks
          ), '[]'::jsonb)
        )
        order by case upper(s.shift_code) when 'MORNING' then 1 when 'EVENING' then 2 else 99 end
      )
      from public.shifts s
      where upper(s.shift_code) in ('MORNING', 'EVENING')
        and s.active = true
        and s.deleted_at is null
    ), '[]'::jsonb)
  );
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

  select coalesce(jsonb_agg(
    staff_row.value ||
    jsonb_build_object(
      'work_mode', coalesce(mode_row.work_mode, pre.sorting_work_mode, 'CLOTHES'),
      'work_mode_explicit', mode_row.sorting_daily_staff_mode_id is not null,
      'work_mode_planned', mode_row.sorting_daily_staff_mode_id is null and pre.sorting_work_mode is not null,
      'work_mode_source', case
        when mode_row.sorting_daily_staff_mode_id is not null then 'ACTUAL_OVERRIDE'
        when pre.sorting_work_mode is not null then 'PUBLISHED_ROSTER'
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
    'mop_assignment_missing', v_mop_staff_id is null,
    'work_mode_source', 'ACTUAL_OVERRIDE_THEN_PUBLISHED_ROSTER'
  );
end;
$$;

revoke all on function public.production_roster_assert_operational_rules(uuid)
  from public, anon, authenticated;

-- Existing browser-facing RPC grants are preserved explicitly.
grant execute on function public.get_production_roster_staff_pool(date,text,uuid) to authenticated;
grant execute on function public.get_production_roster_week(date,text,uuid) to authenticated;
grant execute on function public.save_production_roster_week(date,text,boolean,text,jsonb,integer,text,text) to authenticated;
grant execute on function public.publish_production_roster_week(uuid,integer,text,text) to authenticated;
grant execute on function public.get_published_production_roster_portal(text) to anon, authenticated;
grant execute on function public.get_sorting_staff_work_context_v2(text) to authenticated;

comment on column public.production_roster_entries.sorting_work_mode is
  'Planned Sorting subassignment for a Working roster entry. Exactly one MOP is required per date/shift whenever Sorting has Working staff; remaining Sorting staff are CLOTHES.';

comment on function public.production_roster_assert_operational_rules(uuid) is
  'Private server-side guard for Staff Master employment dates and the mandatory one-MOP-per-Sorting-day roster rule.';

commit;
