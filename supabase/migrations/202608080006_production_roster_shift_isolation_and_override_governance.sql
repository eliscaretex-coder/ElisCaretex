-- =====================================================================
-- ElisCaretex V2
-- Migration: Production Roster shift isolation + explicit override governance
-- Date: 2026-08-08
--
-- Guarantees:
--   * Morning/Evening staff are isolated by Staff Master default shift.
--   * Cross-shift staff require an explicit temporary override confirmation.
--   * A temporary override cannot double-allocate the same staff/date in the
--     other active shift roster.
--   * Cross-shift overrides are stored separately from roster entries so the
--     intent remains traceable after publication.
--   * Obvious contaminated drafts (all staff from the other shift) are
--     quarantined once, with their full entry payload preserved privately.
--   * Published/Superseded roster history remains immutable.
-- =====================================================================

begin;

create table if not exists public.production_roster_shift_overrides (
  roster_version_id uuid not null
    references public.production_roster_versions(roster_version_id) on delete cascade,
  staff_id uuid not null
    references public.staff_members(staff_id),
  staff_default_shift_code_snapshot text not null,
  staff_default_shift_name_snapshot text not null,
  roster_shift_code_snapshot text not null,
  roster_shift_name_snapshot text not null,
  confirmed_days date[] not null default '{}'::date[],
  source_application text not null default 'PRODUCTION_ROSTER_UI',
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (roster_version_id, staff_id),
  constraint production_roster_shift_override_different_shift_ck
    check (staff_default_shift_code_snapshot <> roster_shift_code_snapshot)
);

create index if not exists production_roster_shift_overrides_staff_idx
  on public.production_roster_shift_overrides(staff_id, roster_version_id);

alter table public.production_roster_shift_overrides enable row level security;
revoke all on table public.production_roster_shift_overrides from public, anon, authenticated;

create or replace function public.protect_production_roster_shift_overrides()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_version_id uuid := coalesce(new.roster_version_id, old.roster_version_id);
  v_status text;
begin
  select prv.status into v_status
  from public.production_roster_versions prv
  where prv.roster_version_id = v_version_id;

  if v_status is distinct from 'DRAFT' then
    raise exception using
      errcode = '55000',
      message = 'Production Roster shift overrides may only be changed while the roster is a DRAFT.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists production_roster_shift_overrides_immutable
  on public.production_roster_shift_overrides;
create trigger production_roster_shift_overrides_immutable
before insert or update or delete on public.production_roster_shift_overrides
for each row execute function public.protect_production_roster_shift_overrides();

create table if not exists public.production_roster_draft_recovery_snapshots (
  recovery_id uuid primary key default gen_random_uuid(),
  roster_version_id uuid not null,
  week_start date not null,
  shift_code text not null,
  shift_name text not null,
  version_number integer not null,
  reason text not null,
  staff_count integer not null,
  entry_count integer not null,
  entries_snapshot jsonb not null,
  captured_at timestamptz not null default now(),
  source_application text not null default 'DATABASE_MIGRATION'
);

create unique index if not exists production_roster_draft_recovery_version_uq
  on public.production_roster_draft_recovery_snapshots(roster_version_id);

alter table public.production_roster_draft_recovery_snapshots enable row level security;
revoke all on table public.production_roster_draft_recovery_snapshots from public, anon, authenticated;

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


-- ---------------------------------------------------------------------
-- One-time recovery for drafts that are demonstrably contaminated:
-- at least 5 staff, zero staff from the roster's own default shift,
-- every included staff from the other shift, and a valid published
-- version exists for the same week/shift.
-- ---------------------------------------------------------------------

do $$
declare
  v record;
  v_entries jsonb;
  v_entry_count integer;
  v_staff_count integer;
begin
  for v in
    with draft_counts as (
      select
        prv.roster_version_id,
        prv.roster_period_id,
        prv.shift_id,
        prv.version_number,
        rp.week_start,
        sh.shift_code,
        sh.shift_name,
        count(distinct pre.staff_id) as staff_count,
        count(distinct pre.staff_id) filter (
          where coalesce(pre.staff_default_shift_code_snapshot, pre.shift_code_snapshot) = sh.shift_code
        ) as same_shift_staff,
        count(distinct pre.staff_id) filter (
          where coalesce(pre.staff_default_shift_code_snapshot, pre.shift_code_snapshot) <> sh.shift_code
        ) as cross_shift_staff,
        count(pre.roster_entry_id) as entry_count
      from public.production_roster_versions prv
      join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
      join public.shifts sh on sh.shift_id = prv.shift_id
      join public.production_roster_entries pre on pre.roster_version_id = prv.roster_version_id
      where prv.status = 'DRAFT'
      group by
        prv.roster_version_id, prv.roster_period_id, prv.shift_id,
        prv.version_number, rp.week_start, sh.shift_code, sh.shift_name
    )
    select dc.*
    from draft_counts dc
    where dc.staff_count >= 5
      and dc.same_shift_staff = 0
      and dc.cross_shift_staff = dc.staff_count
      and exists (
        select 1
        from public.production_roster_versions published
        where published.roster_period_id = dc.roster_period_id
          and published.shift_id = dc.shift_id
          and published.status = 'PUBLISHED'
      )
  loop
    select
      coalesce(jsonb_agg(to_jsonb(pre) order by pre.work_date, pre.staff_display_name_snapshot), '[]'::jsonb),
      count(*),
      count(distinct pre.staff_id)
    into v_entries, v_entry_count, v_staff_count
    from public.production_roster_entries pre
    where pre.roster_version_id = v.roster_version_id;

    insert into public.production_roster_draft_recovery_snapshots (
      roster_version_id,
      week_start,
      shift_code,
      shift_name,
      version_number,
      reason,
      staff_count,
      entry_count,
      entries_snapshot
    ) values (
      v.roster_version_id,
      v.week_start,
      v.shift_code,
      v.shift_name,
      v.version_number,
      'Automatic integrity quarantine: draft contains only staff whose Staff Master default shift is different from the roster shift.',
      v_staff_count,
      v_entry_count,
      v_entries
    )
    on conflict (roster_version_id) do nothing;

    delete from public.production_roster_shift_overrides
    where roster_version_id = v.roster_version_id;

    delete from public.production_roster_entries
    where roster_version_id = v.roster_version_id;

    update public.production_roster_versions
    set status = 'CANCELLED',
        updated_at = now(),
        row_version = row_version + 1
    where roster_version_id = v.roster_version_id
      and status = 'DRAFT';

    insert into public.production_roster_events (
      roster_version_id,
      event_type,
      actor_auth_user_id,
      actor_staff_id,
      reason,
      metadata
    ) values (
      v.roster_version_id,
      'DRAFT_CANCELLED',
      null,
      null,
      'Automatic shift-integrity quarantine.',
      jsonb_build_object(
        'automatic_integrity_recovery', true,
        'week_start', v.week_start,
        'shift_code', v.shift_code,
        'staff_count', v_staff_count,
        'entry_count', v_entry_count,
        'recovery_snapshot_preserved', true
      )
    );

    insert into public.audit_log (
      actor_auth_user_id,
      actor_staff_id,
      action,
      entity_table,
      entity_id,
      new_data,
      reason,
      source_application
    ) values (
      null,
      null,
      'PRODUCTION_ROSTER_DRAFT_QUARANTINED',
      'production_roster_versions',
      v.roster_version_id::text,
      jsonb_build_object(
        'week_start', v.week_start,
        'shift_code', v.shift_code,
        'version_number', v.version_number,
        'staff_count', v_staff_count,
        'entry_count', v_entry_count
      ),
      'Draft contained only staff from another default shift.',
      'DATABASE_MIGRATION'
    );
  end loop;
end;
$$;


revoke all on function public.get_production_roster_week(date, text, uuid)
  from public, anon;
grant execute on function public.get_production_roster_week(date, text, uuid)
  to authenticated;

revoke all on function public.save_production_roster_week(date, text, boolean, text, jsonb, integer, text, text)
  from public, anon;
grant execute on function public.save_production_roster_week(date, text, boolean, text, jsonb, integer, text, text)
  to authenticated;

comment on table public.production_roster_shift_overrides is
  'Private, immutable-after-publication evidence of explicit temporary cross-shift roster assignments. Cross-shift staff are never inferred automatically.';
comment on table public.production_roster_draft_recovery_snapshots is
  'Private forensic snapshot of roster drafts automatically quarantined by shift-integrity recovery.';
comment on function public.get_production_roster_week(date, text, uuid) is
  'Returns one Production Roster week/shift and preserves Staff Master default-shift snapshots plus explicit cross-shift override evidence.';
comment on function public.save_production_roster_week(date, text, boolean, text, jsonb, integer, text, text) is
  'Atomically saves one Production Roster shift. Cross-shift staff require explicit confirmation and cannot be double-planned in the other active shift.';

commit;
