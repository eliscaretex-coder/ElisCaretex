-- Staff Master "Primary work assignment": the primary role is the person's job
-- function, the default area is where they normally work.
--
-- SORTING_AREA was used both as a function and as an area. Sorting staff are
-- General Operatives whose default area is Sorting. SORTING_AREA stays as a
-- roster position (display section, roster entry role) and as a COVER
-- capability, so published rosters, Sorting workstations and Finish-to-Sorting
-- cover transfers keep working unchanged.
--
-- Adds the missing functions Production Manager and Maintenance.

insert into public.operational_roles (role_code, role_name, description, allow_as_primary, allow_as_cover, active, sort_order)
values
  ('PRODUCTION_MANAGER', 'Production Manager', 'Production management. Shown with Supervisors in the Production Roster.', true, false, true, 5),
  ('MAINTENANCE', 'Maintenance', 'Machine and facility maintenance. Shown with Support Role in the Production Roster.', true, false, true, 65)
on conflict (role_code) do nothing;

update public.operational_roles
set role_name = 'Label Operative'
where role_code = 'LABEL'
  and role_name = 'Label';

-- Move Sorting staff from the area-as-role to General Operative, keeping
-- Sorting as their default area and station.
with sorting as (
  select
    (select operational_role_id from public.operational_roles where role_code = 'SORTING_AREA') as old_role_id,
    (select operational_role_id from public.operational_roles where role_code = 'GENERAL_OPERATIVE') as new_role_id,
    (select area_id from public.areas where area_code = 'SORTING' and deleted_at is null) as area_id,
    (select st.station_id from public.stations st join public.areas a on a.area_id = st.area_id
      where st.station_code = 'SORTING_MAIN' and a.area_code = 'SORTING' and st.deleted_at is null) as station_id
), moved as (
  update public.staff_members sm
  set
    primary_operational_role_id = s.new_role_id,
    default_area_id = coalesce(sm.default_area_id, s.area_id),
    default_station_id = case when sm.default_area_id is null or sm.default_area_id = s.area_id
      then coalesce(sm.default_station_id, s.station_id) else sm.default_station_id end,
    row_version = sm.row_version + 1
  from sorting s
  where sm.primary_operational_role_id = s.old_role_id
    and sm.deleted_at is null
  returning sm.staff_id, sm.display_name
)
insert into public.audit_log (action, entity_table, entity_id, old_data, new_data, reason, source_application)
select
  'STAFF_PRIMARY_ROLE_CORRECTED',
  'staff_members',
  m.staff_id::text,
  jsonb_build_object('primary_role_code', 'SORTING_AREA'),
  jsonb_build_object('primary_role_code', 'GENERAL_OPERATIVE', 'default_area_code', 'SORTING'),
  'Sorting Area is a work area, not a job function. Primary role set to General Operative with Sorting as the default area.',
  'MIGRATION_202610200003'
from moved m;

-- Editable drafts show the corrected primary role. Published versions are history
-- and stay unchanged. Roster positions (operational_role_id) are not touched.
update public.production_roster_entries pre
set
  staff_primary_role_code_snapshot = 'GENERAL_OPERATIVE',
  staff_primary_role_name_snapshot = 'General Operative'
from public.production_roster_versions prv
join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
where pre.roster_version_id = prv.roster_version_id
  and prv.status = 'DRAFT'
  and rp.week_start >= public.production_roster_week_start(current_date)
  and pre.staff_primary_role_code_snapshot = 'SORTING_AREA';

update public.operational_roles
set
  allow_as_primary = false,
  description = 'Sorting Area roster position and COVER capability. Not a primary role: use General Operative with Sorting as the default area.'
where role_code = 'SORTING_AREA';

-- New rows in the Production Roster follow the default station when the role is
-- a general function: a General Operative in Sorting goes to the Sorting section.
create or replace function public.production_roster_default_display_section(p_primary_role_code text, p_default_station_code text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when upper(coalesce(p_primary_role_code, '')) in ('SUPERVISOR', 'SORTING_AREA', 'LABEL', 'CLEANER', 'SUPPORT_ROLE')
      then upper(p_primary_role_code)
    when upper(coalesce(p_primary_role_code, '')) = 'PRODUCTION_MANAGER'
      then 'SUPERVISOR'
    when upper(coalesce(p_primary_role_code, '')) = 'MAINTENANCE'
      then 'SUPPORT_ROLE'
    when upper(coalesce(p_default_station_code, '')) = 'SORTING_MAIN'
      then 'SORTING_AREA'
    when upper(coalesce(p_default_station_code, '')) in ('FINISH_TABLE_1', 'FINISH_TABLE_2', 'FINISH_TABLE_3')
      then upper(p_default_station_code)
    else 'FINISH_OTHER'
  end
$$;
