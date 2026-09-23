-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608050002_production_roster_shift_override.sql
-- Purpose:
--   - Preserve each staff member's Staff Master default shift in roster
--     entry snapshots.
--   - Provide a controlled staff pool so Roster Managers can temporarily
--     include eligible staff from another shift for a week or selected days.
--   - Keep the temporary roster shift independent from Staff Master.
-- =====================================================================

alter table public.production_roster_entries
  add column if not exists staff_default_shift_code_snapshot text;

alter table public.production_roster_entries
  add column if not exists staff_default_shift_name_snapshot text;

-- Published roster entries are immutable. Do not backfill the new columns
-- with UPDATE statements, because that would rewrite historical rows and be
-- rejected by protect_published_production_roster_entries().
--
-- Legacy rows remain nullable in these two new columns. Controlled read models
-- fall back to the existing roster shift snapshots. Before shift overrides
-- existed, the roster shift was also the staff member's effective default shift
-- for that saved version.
alter table public.production_roster_entries
  alter column staff_default_shift_code_snapshot drop not null;

alter table public.production_roster_entries
  alter column staff_default_shift_name_snapshot drop not null;

create or replace function public.production_roster_set_default_shift_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift_code text;
  v_shift_name text;
begin
  if new.staff_default_shift_code_snapshot is null
     or new.staff_default_shift_name_snapshot is null then
    select s.shift_code, s.shift_name
    into v_shift_code, v_shift_name
    from public.staff_members sm
    left join public.shifts s on s.shift_id = sm.default_shift_id
    where sm.staff_id = new.staff_id;

    new.staff_default_shift_code_snapshot := coalesce(
      new.staff_default_shift_code_snapshot,
      v_shift_code,
      new.shift_code_snapshot
    );
    new.staff_default_shift_name_snapshot := coalesce(
      new.staff_default_shift_name_snapshot,
      v_shift_name,
      new.shift_name_snapshot
    );
  end if;

  return new;
end;
$$;

revoke all on function public.production_roster_set_default_shift_snapshot() from public, anon, authenticated;

drop trigger if exists production_roster_entries_default_shift_snapshot_trg
  on public.production_roster_entries;

create trigger production_roster_entries_default_shift_snapshot_trg
before insert or update of staff_id
on public.production_roster_entries
for each row
execute function public.production_roster_set_default_shift_snapshot();

comment on column public.production_roster_entries.staff_default_shift_code_snapshot is
  'Staff Master default shift code at save time. Legacy pre-override rows remain NULL and use shift_code_snapshot as the immutable read fallback.';

comment on column public.production_roster_entries.staff_default_shift_name_snapshot is
  'Staff Master default shift name at save time. Legacy pre-override rows remain NULL and use shift_name_snapshot as the immutable read fallback.';

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
  'Controlled Production Roster staff pool. Returns all active roster-eligible production staff and preserves the Staff Master default shift independently from a temporary roster shift override.';
