-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610300002_legacy_sync_rosters
--
-- Seventh part of the nightly legacy sync (owner request 2026-10-30): the
-- Production and Distribution weekly rosters are still made in the legacy
-- apps, so they are synced too. One kind "roster" with two record types:
--   * PRODUCTION_ROSTER    Weekly Shift Roster_db RosterStoreV2, one record per
--                          week and shift (source id "2026-11-02|MORNING")
--                          -> public.production_roster_versions / entries
--   * DISTRIBUTION_ROSTER  Distribution_db Roster, one record per week
--                          (source id "2026-11-02")
--                          -> public.distribution_roster_versions / entries
--
-- Rules:
--   * a published roster is never edited. A legacy change creates a new
--     version that is published at once; the previous one is superseded, as
--     the Production Roster and Distribution pages do;
--   * only the current week and later weeks. Past weeks are history;
--   * days before today are never changed, even inside the current week;
--   * a Production week+shift is synced only after a manager saved it in the
--     legacy app (meta.saveMode). Future weeks that only hold leave are skipped;
--   * the legacy reading rule: a member without a cell works Monday-Saturday
--     in the weekly position and is off on Sunday; a cell keyed by the user ID
--     wins over a cell keyed by the name;
--   * each cell the legacy app changed since the last sync is written, every
--     other cell keeps what V2 has (hand edits in V2 are kept). The first time
--     a week is met the legacy roster wins (owner decision 2026-10-30): every
--     cell that differs is written from the legacy app;
--   * a week with an open draft in V2, an unknown person, driver, vehicle or
--     route, or a roster V2 would refuse to publish (employment dates, shift,
--     cover authorisation, Sorting MOP choice, driver leave, vehicle limits)
--     is held for review, never guessed;
--   * a published Distribution week creates or updates the daily route runs
--     exactly like Publish (runs already dispatched are never touched).
--
-- New switch ROSTER_IMPORT (seeded OFF, limit 40). The Apps Script control
-- ON/OFF switches it with the others.
-- Apply after 202610280002 and 202610300001.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.distribution_apply_published_roster_runs(uuid)') is null then
    raise exception 'Apply 202610300001_distribution_board_imported_roster_runs.sql first.';
  end if;
  if to_regprocedure('integration.legacy_sync_import_schedule(uuid,jsonb)') is null then
    raise exception 'Apply 202610280002_legacy_sync_customer_schedules.sql first.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. Switch
-- ---------------------------------------------------------------------
insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('ROSTER_IMPORT', false, 40, 'migration 202610300002',
        'Seeded disabled. Production and Distribution weekly rosters. Turned on with the other imports from the Apps Script page.')
on conflict (setting_key) do nothing;

-- ---------------------------------------------------------------------
-- 2. Production: one week+shift as a flat map, one key per value:
--    "S|<person>"        weekly row (display section)
--    "<date>|<person>"   "STATUS|TYPE|ROLE|AREA|STATION|SORTING_MODE"
--    "sunday"            Sunday included
--    <person> is the legacy user ID, or "staff:<uuid>" for a V2-only person.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_roster_position(p_value text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case lower(regexp_replace(btrim(coalesce(p_value, '')), '\s+', ' ', 'g'))
    when 'general operative - table 1' then 'GO1'
    when 'general operative - table 2' then 'GO2'
    when 'general operative - table 3' then 'GO3'
    when 'team leader - table 1' then 'TL1'
    when 'team leader - table 2' then 'TL2'
    when 'team leader - table 3' then 'TL3'
    when 'sorting area' then 'SA'
    when 'label' then 'LBL'
    when 'supervisor' then 'SUP'
    when 'cleaner' then 'CLN'
    when 'support role' then 'SR'
  end;
$$;

-- One legacy cell in V2 terms, resolved as save_production_roster_week does.
create or replace function integration.legacy_sync_roster_cell(
  p_section text, p_status text, p_position text, p_notes text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_status text := case lower(btrim(coalesce(p_status, '')))
    when 'working' then 'WORKING' when 'cover' then 'COVER' when 'off' then 'OFF'
    when 'holiday' then 'HOLIDAY' when 'sick' then 'SICK' when 'training' then 'TRAINING'
    when 'quality analysis' then 'QUALITY_ANALYSIS' end;
  v_pos text := integration.legacy_sync_roster_position(p_position);
  v_cover text := substring(coalesce(p_notes, '') from 'cover=(TL|SP|SA)');
  v_type text := 'BASE';
  v_role text;
  v_area text;
  v_station text;
  v_mode text;
  v_warning jsonb := '[]'::jsonb;
begin
  if v_status is null then
    return jsonb_build_object('blocker', integration.legacy_sync_issue('INVALID_ROSTER_STATUS', p_status));
  end if;
  if v_status in ('OFF','HOLIDAY','SICK','TRAINING') then
    return jsonb_build_object('value', v_status || '|BASE||||', 'warnings', v_warning);
  end if;
  if v_pos is null then
    return jsonb_build_object('blocker', integration.legacy_sync_issue('INVALID_ROSTER_POSITION', p_position));
  end if;

  if v_status = 'COVER' and v_cover is null then
    v_warning := integration.legacy_sync_issue('COVER_WITHOUT_ROLE', p_position);
    v_status := 'WORKING';
  end if;

  if v_status = 'COVER' then
    v_status := 'WORKING';
    v_type := 'COVER';
    v_role := case v_cover when 'TL' then 'TEAM_LEADER' when 'SP' then 'SUPERVISOR' else 'SORTING_AREA' end;
    v_area := case when v_cover = 'SA' then 'SORTING' else staging.legacy_roster_position_area(v_pos) end;
    v_station := case when v_cover = 'SA' then 'SORTING_MAIN' else staging.legacy_roster_position_station(v_pos) end;
  elsif p_section = 'SUPPORT_ROLE' then
    v_role := staging.legacy_roster_position_role(v_pos);
    v_area := staging.legacy_roster_position_area(v_pos);
    v_station := staging.legacy_roster_position_station(v_pos);
  else
    select r.role_code, r.area_code, r.station_code into v_role, v_area, v_station
    from public.production_roster_resolve_display_assignment(p_section, staging.legacy_roster_position_role(v_pos)) r;
    -- A Finish Table row can work another table for the day.
    if p_section in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
       and staging.legacy_roster_position_station(v_pos) in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then
      v_station := staging.legacy_roster_position_station(v_pos);
    end if;
  end if;

  if v_status = 'WORKING' and (v_area = 'SORTING' or v_role = 'SORTING_AREA') then
    v_mode := case when p_notes ~ 'svc=MOP' then 'MOP' when p_notes ~ 'svc=CLO' then 'CLOTHES' end;
  end if;

  return jsonb_build_object('value', concat_ws('|', v_status, v_type, coalesce(v_role, ''), coalesce(v_area, ''),
    coalesce(v_station, ''), coalesce(v_mode, '')), 'warnings', v_warning);
end;
$$;

-- The legacy week of one shift as the flat map, with the legacy reading rule.
create or replace function integration.legacy_sync_roster_production_want(p_row jsonb, p_week date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_data jsonb := case when jsonb_typeof(p_row->'data') = 'object' then p_row->'data' end;
  v_cells jsonb;
  v_sunday boolean;
  v_want jsonb := '{}'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_member jsonb;
  v_uid text;
  v_key text;
  v_name text;
  v_section text;
  v_day integer;
  v_date date;
  v_cell jsonb;
  v_out jsonb;
begin
  if v_data is null or jsonb_typeof(v_data->'usersSnapshot') <> 'array' then
    return jsonb_build_object('want', '{}'::jsonb, 'blockers', integration.legacy_sync_issue('INVALID_RECORD', 'PRODUCTION_ROSTER'),
      'warnings', '[]'::jsonb);
  end if;
  v_cells := case when jsonb_typeof(v_data->'cells') = 'object' then v_data->'cells' else '{}'::jsonb end;
  v_sunday := lower(coalesce(integration.legacy_sync_text(p_row, 'HasSunday'), v_data->>'hasSunday', '')) in ('yes','true');
  v_want := jsonb_build_object('sunday', v_sunday);

  for v_member in select value from jsonb_array_elements(v_data->'usersSnapshot') loop
    v_uid := btrim(coalesce(v_member->>'id', ''));
    v_name := nullif(btrim(coalesce(v_member->>'user', '')), '');
    if v_uid !~ '^[0-9]{1,9}$' then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_ROSTER_MEMBER', coalesce(v_name, v_uid));
      continue;
    end if;
    -- A retired legacy user ID the owner mapped to the person's current ID.
    v_key := coalesce(integration.legacy_sync_map_value('CENTRALDB', 'STAFF_USER_ALIAS', v_uid), v_uid);
    if not exists (select 1 from public.staff_members sm where sm.legacy_user_id = v_key::integer and sm.deleted_at is null) then
      v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_NOT_IN_V2', v_uid || ' ' || coalesce(v_name, ''));
      continue;
    end if;
    if v_want ? ('S|' || v_key) then
      v_blockers := v_blockers || integration.legacy_sync_issue('DUPLICATE_ROSTER_MEMBER', v_uid || ' ' || coalesce(v_name, ''));
      continue;
    end if;
    v_section := staging.legacy_roster_display_section(integration.legacy_sync_roster_position(v_member->>'position'));
    v_want := v_want || jsonb_build_object('S|' || v_key, v_section);

    for v_day in 0 .. case when v_sunday then 6 else 5 end loop
      v_date := p_week + v_day;
      v_cell := coalesce(v_cells->(v_date::text || '::' || v_uid), v_cells->(v_date::text || '::' || coalesce(v_name, '')));
      if v_cell is null and v_day = 6 then
        v_out := jsonb_build_object('value', 'OFF|BASE||||');
      elsif v_cell is null then
        v_out := integration.legacy_sync_roster_cell(v_section, 'Working', v_member->>'position', null);
      else
        v_out := integration.legacy_sync_roster_cell(v_section, v_cell->>'status',
          coalesce(nullif(btrim(coalesce(v_cell->>'position', '')), ''), v_member->>'position'), v_cell->>'notes');
      end if;
      if v_out ? 'blocker' then
        v_blockers := v_blockers || jsonb_build_array((v_out->'blocker'->0) || jsonb_build_object('detail',
          coalesce(v_name, v_uid) || ' ' || to_char(v_date, 'Dy DD/MM') || ': ' || coalesce(v_out->'blocker'->0->>'detail', '-')));
      else
        v_want := v_want || jsonb_build_object(v_date::text || '|' || v_key, v_out->>'value');
        v_warnings := v_warnings || coalesce(v_out->'warnings', '[]'::jsonb);
      end if;
    end loop;
  end loop;

  return jsonb_build_object('want', v_want, 'blockers', v_blockers, 'warnings', v_warnings);
end;
$$;

-- One V2 Production Roster version as the same flat map.
create or replace function integration.legacy_sync_roster_production_have(p_version_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  with e as (
    select coalesce(sm.legacy_user_id::text, 'staff:' || pre.staff_id::text) as person, pre.*
    from public.production_roster_entries pre
    left join public.staff_members sm on sm.staff_id = pre.staff_id
    where pre.roster_version_id = p_version_id
  )
  select jsonb_build_object('sunday', (select v.include_sunday from public.production_roster_versions v where v.roster_version_id = p_version_id))
    || coalesce((select jsonb_object_agg(e.work_date::text || '|' || e.person,
                   concat_ws('|', e.day_status, e.assignment_type, coalesce(e.operational_role_code_snapshot, ''),
                     coalesce(e.area_code_snapshot, ''), coalesce(e.station_code_snapshot, ''), coalesce(e.sorting_work_mode, '')))
                 from e), '{}'::jsonb)
    || coalesce((select jsonb_object_agg('S|' || x.person, x.section)
                 from (select e.person, min(e.display_section_code) as section from e group by e.person) x), '{}'::jsonb);
$$;

-- The rows a flat map describes, one per person and day of the week.
create or replace function integration.legacy_sync_roster_production_rows(p_map jsonb, p_week date)
returns table(person text, staff_id uuid, work_date date, day_status text, assignment_type text,
  role_code text, area_code text, station_code text, sorting_work_mode text, display_section_code text)
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  with people as (
    select substr(k, 3) as person, p_map->>k as section
    from jsonb_object_keys(p_map) k where k like 'S|%'
  ), days as (
    select p_week + d as work_date
    from generate_series(0, case when coalesce((p_map->>'sunday')::boolean, false) then 6 else 5 end) d
  )
  select p.person,
         case when p.person like 'staff:%' then substr(p.person, 7)::uuid
              else (select sm.staff_id from public.staff_members sm
                    where sm.legacy_user_id::text = p.person and sm.deleted_at is null limit 1) end,
         d.work_date,
         split_part(v.value, '|', 1), split_part(v.value, '|', 2),
         nullif(split_part(v.value, '|', 3), ''), nullif(split_part(v.value, '|', 4), ''),
         nullif(split_part(v.value, '|', 5), ''), nullif(split_part(v.value, '|', 6), ''),
         p.section
  from people p cross join days d
  -- A V2-only person kept by the sync has no Sunday when the legacy app adds one: off.
  cross join lateral (select coalesce(p_map->>(d.work_date::text || '|' || p.person),
                                      case when extract(isodow from d.work_date) = 7 then 'OFF|BASE||||' end) as value) v;
$$;

-- The checks of save_production_roster_week and publish_production_roster_week, as review reasons.
create or replace function integration.legacy_sync_roster_production_check(p_map jsonb, p_week date, p_shift_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_blockers jsonb := '[]'::jsonb;
  v_r record;
begin
  for v_r in
    select r.*, sm.display_name, sm.default_shift_id, sm.production_staff, sm.deleted_at, sm.joined_on, sm.deactivated_on,
           sm.production_roster_from, sm.production_roster_until, sm.active, sm.roster_eligible
    from integration.legacy_sync_roster_production_rows(p_map, p_week) r
    left join public.staff_members sm on sm.staff_id = r.staff_id
    order by r.person, r.work_date
  loop
    if v_r.staff_id is null or v_r.display_name is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_NOT_IN_V2', v_r.person);
      continue;
    end if;
    if v_r.day_status = '' or v_r.day_status is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('ROSTER_INCOMPLETE', v_r.display_name || ' ' || to_char(v_r.work_date, 'Dy DD/MM'));
      continue;
    end if;
    if v_r.default_shift_id is distinct from p_shift_id then
      v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_SHIFT_DIFFERS', v_r.display_name);
    end if;
    if v_r.production_staff is not true or v_r.deleted_at is not null
       or (v_r.joined_on is not null and v_r.joined_on > p_week + 6)
       or (v_r.deactivated_on is not null and v_r.deactivated_on < p_week)
       or (v_r.production_roster_until is not null and v_r.production_roster_until < p_week)
       or (v_r.production_roster_from is not null and v_r.production_roster_from > p_week + 6)
       or (v_r.day_status in ('WORKING','TRAINING','QUALITY_ANALYSIS') and (
             (v_r.joined_on is not null and v_r.work_date < v_r.joined_on)
             or (v_r.deactivated_on is not null and v_r.work_date > v_r.deactivated_on)
             or (v_r.production_roster_until is not null and v_r.work_date > v_r.production_roster_until)
             or (v_r.production_roster_from is not null and v_r.work_date < v_r.production_roster_from)
             or (v_r.deactivated_on is null and (v_r.active is not true or v_r.roster_eligible is not true)))) then
      v_blockers := v_blockers || integration.legacy_sync_issue('STAFF_NOT_AVAILABLE',
        v_r.display_name || case when v_r.day_status in ('WORKING','TRAINING','QUALITY_ANALYSIS')
                                 then ' ' || to_char(v_r.work_date, 'Dy DD/MM') else '' end);
    end if;
    if v_r.day_status in ('WORKING','QUALITY_ANALYSIS') and (
         not exists (select 1 from public.operational_roles o where o.role_code = v_r.role_code and o.active and o.deleted_at is null)
         or not exists (select 1 from public.areas a where a.area_code = v_r.area_code and a.active and a.deleted_at is null)
         or (v_r.station_code is not null and not exists (
               select 1 from public.stations st join public.areas a on a.area_id = st.area_id
               where st.station_code = v_r.station_code and a.area_code = v_r.area_code and st.active and st.deleted_at is null))) then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_ROSTER_POSITION',
        v_r.display_name || ' ' || to_char(v_r.work_date, 'Dy DD/MM') || ': ' || concat_ws('/', v_r.role_code, v_r.area_code, v_r.station_code));
    end if;
    if v_r.assignment_type = 'COVER' and not exists (
         select 1 from public.operational_roles o
         where o.role_code = v_r.role_code and o.allow_as_cover is true
           and public.production_roster_cover_currently_authorised(v_r.staff_id, o.operational_role_id)) then
      v_blockers := v_blockers || integration.legacy_sync_issue('COVER_NOT_AUTHORISED',
        v_r.display_name || ' ' || to_char(v_r.work_date, 'Dy DD/MM') || ' as ' || v_r.role_code);
    end if;
  end loop;

  -- Sorting MOP: one or two MOP with the others CLOTHES, or nobody chosen (No dedicated MOP).
  for v_r in
    select r.work_date, count(*) filter (where r.sorting_work_mode = 'MOP') as mop,
           count(*) filter (where r.sorting_work_mode is null) as undecided, count(*) as total
    from integration.legacy_sync_roster_production_rows(p_map, p_week) r
    where r.day_status = 'WORKING' and (r.area_code = 'SORTING' or r.role_code = 'SORTING_AREA')
    group by r.work_date
    having not ((count(*) filter (where r.sorting_work_mode = 'MOP') between 1 and 2
                 and count(*) filter (where r.sorting_work_mode is null) = 0)
                or (count(*) filter (where r.sorting_work_mode = 'MOP') = 0
                    and count(*) filter (where r.sorting_work_mode is null) = count(*)))
  loop
    v_blockers := v_blockers || integration.legacy_sync_issue('SORTING_MOP_UNDECIDED',
      to_char(v_r.work_date, 'Dy DD/MM') || ': ' || v_r.mop || ' MOP, ' || v_r.undecided || ' without Clothes/MOP of ' || v_r.total);
  end loop;

  select coalesce(jsonb_agg(b), '[]'::jsonb) into v_blockers
  from (select distinct b from jsonb_array_elements(v_blockers) b) x;
  return v_blockers;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Distribution: one week as a flat map:
--    "<date>|<driver>"   "PLANNED|<route code>|<registration>", "OFF", "HOLIDAY",
--                        "TRAINING", "ABSENT", "SICK"; "SUPPORT|<route code>"
--                        for a V2 support driver
--    "required|<date>"   routes required that day
--    <driver> is the legacy driver ID, or "driver:<uuid>" for a V2-only driver.
--    Monday-Saturday only, as the Distribution roster.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_roster_route_code(p_value text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when lower(regexp_replace(btrim(coalesce(p_value, '')), '\s+', '', 'g')) in ('westcork','615westcork') then 'WEST_CORK'
    when lower(regexp_replace(btrim(coalesce(p_value, '')), '\s+', '', 'g')) in ('ballymounttrunking','ballymount') then 'BALLYMOUNT'
    when btrim(coalesce(p_value, '')) ~* '^route\s*[0-9a-z_-]{1,20}$' then upper(regexp_replace(btrim(p_value), '^[Rr][Oo][Uu][Tt][Ee]\s*', ''))
  end;
$$;

create or replace function integration.legacy_sync_roster_distribution_want(p_row jsonb, p_week date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_data jsonb := case when jsonb_typeof(p_row->'data') = 'object' then p_row->'data' end;
  v_days constant text[] := array['mon','tue','wed','thu','fri','sat','sun'];
  v_want jsonb := '{}'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_a jsonb;
  v_driver text;
  v_name text;
  v_num numeric;
  v_day integer;
  v_date date;
  v_raw text;
  v_route text;
  v_plate text;
  v_value text;
  v_required text;
begin
  if v_data is null or jsonb_typeof(v_data->'assignments') <> 'array' then
    return jsonb_build_object('want', '{}'::jsonb, 'blockers', integration.legacy_sync_issue('INVALID_RECORD', 'DISTRIBUTION_ROSTER'),
      'warnings', '[]'::jsonb);
  end if;

  for v_day in 1 .. 7 loop
    v_required := btrim(coalesce(v_data->'requiredRoutes'->>v_days[v_day], ''));
    if v_required ~ '^[0-9]{1,3}$' then
      v_want := v_want || jsonb_build_object('required|' || (p_week + v_day - 1)::text, v_required::integer);
    end if;
  end loop;

  for v_a in select value from jsonb_array_elements(v_data->'assignments') loop
    v_num := integration.legacy_sync_parse_number(v_a->>'driverId');
    if v_num is null or v_num <> trunc(v_num) then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_ROSTER_MEMBER', v_a->>'driverId');
      continue;
    end if;
    v_driver := trunc(v_num)::text;
    select d.display_name into v_name from public.distribution_drivers d
    where d.legacy_driver_id = v_driver and d.deleted_at is null;
    if not found then
      if exists (select 1 from jsonb_each_text(v_a) x where x.key = any(v_days[1:6]) and btrim(x.value) <> '') then
        v_blockers := v_blockers || integration.legacy_sync_issue('DRIVER_NOT_IN_V2', v_driver);
      end if;
      continue;
    end if;

    for v_day in 1 .. 7 loop
      v_raw := btrim(coalesce(v_a->>v_days[v_day], ''));
      continue when v_raw = '';
      v_date := p_week + v_day - 1;
      v_value := case lower(v_raw)
        when 'off' then 'OFF' when 'hols' then 'HOLIDAY' when 'holiday' then 'HOLIDAY' when 'holidays' then 'HOLIDAY'
        when 'training' then 'TRAINING' when 'absent' then 'ABSENT' when 'sick' then 'SICK' end;
      if v_value is null then
        v_route := integration.legacy_sync_roster_route_code(split_part(v_raw, '|', 1));
        v_plate := nullif(upper(regexp_replace(split_part(v_raw, '|', 2), '\s', '', 'g')), '');
        if v_route is null then
          v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_ROSTER_VALUE',
            v_name || ' ' || to_char(v_date, 'Dy DD/MM') || ': ' || v_raw);
          continue;
        end if;
        if v_day = 7 then
          v_warnings := v_warnings || integration.legacy_sync_issue('SUNDAY_NOT_IN_V2', v_name || ': ' || v_raw);
          continue;
        end if;
        if v_plate is null then
          v_blockers := v_blockers || integration.legacy_sync_issue('VEHICLE_MISSING',
            v_name || ' ' || to_char(v_date, 'Dy DD/MM') || ': ' || v_raw);
          continue;
        end if;
        v_value := 'PLANNED|' || v_route || '|' || v_plate;
      end if;
      continue when v_day = 7;
      v_want := v_want || jsonb_build_object(v_date::text || '|' || v_driver, v_value);
    end loop;
  end loop;

  return jsonb_build_object('want', v_want, 'blockers', v_blockers, 'warnings', v_warnings);
end;
$$;

create or replace function integration.legacy_sync_roster_distribution_have(p_version_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  with v as (
    select * from public.distribution_roster_versions where distribution_roster_version_id = p_version_id
  )
  select coalesce((
      select jsonb_object_agg(x.k, x.val) from (
        select e.work_date::text || '|' || coalesce(pd.legacy_driver_id, 'driver:' || e.primary_driver_id::text) as k,
               case when e.assignment_status = 'PLANNED'
                    then 'PLANNED|' || coalesce(e.route_code_snapshot, '') || '|' || coalesce(upper(e.vehicle_registration_snapshot), '')
                    else e.assignment_status end as val
        from public.distribution_roster_entries e
        left join public.distribution_drivers pd on pd.driver_id = e.primary_driver_id
        where e.distribution_roster_version_id = p_version_id and e.primary_driver_id is not null
        union all
        select e.work_date::text || '|' || coalesce(sd.legacy_driver_id, 'driver:' || e.support_driver_id::text),
               'SUPPORT|' || coalesce(e.route_code_snapshot, '')
        from public.distribution_roster_entries e
        left join public.distribution_drivers sd on sd.driver_id = e.support_driver_id
        where e.distribution_roster_version_id = p_version_id and e.support_driver_id is not null
      ) x), '{}'::jsonb)
    -- Required routes are kept by weekday (imports) or by date (Distribution page).
    || coalesce((
      select jsonb_object_agg('required|' || coalesce(integration.legacy_sync_parse_date(r.key),
               v.week_start + array_position(array['mon','tue','wed','thu','fri','sat','sun'], lower(r.key)) - 1)::text,
               (r.value)::integer)
      from v, jsonb_each_text(coalesce(v.required_routes, '{}'::jsonb)) r
      where r.value ~ '^[0-9]{1,3}$'
        and (integration.legacy_sync_parse_date(r.key) is not null
             or lower(r.key) in ('mon','tue','wed','thu','fri','sat','sun'))), '{}'::jsonb);
$$;

-- The rows a flat map describes: one per planned route and day, plus driver states.
create or replace function integration.legacy_sync_roster_distribution_rows(p_map jsonb)
returns table(work_date date, assignment_status text, route_code text, route_id uuid, primary_key text,
  primary_driver_id uuid, support_driver_id uuid, registration text, vehicle_id uuid)
language sql
stable
security definer
set search_path = public, integration, pg_temp
as $$
  with cells as (
    select split_part(k, '|', 1)::date as work_date, substr(k, 12) as person, p_map->>k as value
    from jsonb_object_keys(p_map) k
    where k ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}\|'
  ), drivers as (
    select c.*, case when c.person like 'driver:%' then substr(c.person, 8)::uuid
                     else (select d.driver_id from public.distribution_drivers d
                           where d.legacy_driver_id = c.person and d.deleted_at is null limit 1) end as driver_id
    from cells c
  )
  select d.work_date, 'PLANNED', split_part(d.value, '|', 2),
         (select r.route_id from public.distribution_routes r where r.route_code = split_part(d.value, '|', 2) and r.deleted_at is null limit 1),
         d.person, d.driver_id,
         (select s.driver_id from drivers s where s.work_date = d.work_date and s.value = 'SUPPORT|' || split_part(d.value, '|', 2)
            and s.driver_id is distinct from d.driver_id limit 1),
         split_part(d.value, '|', 3),
         (select fv.vehicle_id from public.fleet_vehicles fv
          where upper(regexp_replace(fv.registration_number, '\s', '', 'g')) = split_part(d.value, '|', 3)
            and fv.deleted_at is null limit 1)
  from drivers d where d.value like 'PLANNED|%'
  union all
  select d.work_date, d.value, null, null, d.person, d.driver_id, null, null, null
  from drivers d where d.value in ('OFF','HOLIDAY','TRAINING','ABSENT','SICK');
$$;

-- The checks of save_distribution_roster_week, validate_distribution_roster_version and
-- publish_distribution_roster_week, as review reasons.
create or replace function integration.legacy_sync_roster_distribution_check(p_map jsonb, p_week date, p_current_version_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_blockers jsonb := '[]'::jsonb;
  v_r record;
begin
  for v_r in
    select r.*, d.display_name, d.employment_status, d.availability_status, d.joined_on, d.deleted_at as driver_deleted,
           rt.active as route_active, rt.display_name as route_name
    from integration.legacy_sync_roster_distribution_rows(p_map) r
    left join public.distribution_drivers d on d.driver_id = r.primary_driver_id
    left join public.distribution_routes rt on rt.route_id = r.route_id
    order by r.work_date, r.route_code
  loop
    if v_r.primary_driver_id is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('DRIVER_NOT_IN_V2', v_r.primary_key);
      continue;
    end if;
    continue when v_r.assignment_status <> 'PLANNED';
    if v_r.route_id is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('ROUTE_NOT_IN_V2', v_r.route_code);
    elsif not v_r.route_active then
      v_blockers := v_blockers || integration.legacy_sync_issue('ROUTE_INACTIVE_IN_V2', v_r.route_name);
    end if;
    if v_r.vehicle_id is null then
      v_blockers := v_blockers || integration.legacy_sync_issue('VEHICLE_NOT_IN_V2', v_r.registration);
    end if;
    if v_r.joined_on is not null and v_r.work_date < v_r.joined_on then
      v_blockers := v_blockers || integration.legacy_sync_issue('DRIVER_NOT_AVAILABLE',
        v_r.display_name || ' starts ' || to_char(v_r.joined_on, 'DD/MM'));
    end if;
    if v_r.driver_deleted is not null or v_r.employment_status <> 'ACTIVE' or v_r.availability_status <> 'AVAILABLE' then
      v_blockers := v_blockers || integration.legacy_sync_issue('DRIVER_NOT_AVAILABLE', v_r.display_name);
    end if;
    if exists (select 1 from public.distribution_driver_absences a
               where a.driver_id in (v_r.primary_driver_id, v_r.support_driver_id) and a.absence_status = 'APPROVED'
                 and v_r.work_date between a.starts_on and a.ends_on) then
      v_blockers := v_blockers || integration.legacy_sync_issue('DRIVER_ON_LEAVE_IN_V2',
        v_r.display_name || ' ' || to_char(v_r.work_date, 'Dy DD/MM'));
    end if;
    if v_r.vehicle_id is not null and v_r.work_date >= current_date
       and public.distribution_vehicle_block_reason(v_r.vehicle_id, v_r.work_date) is not null
       and not exists (
         select 1 from public.distribution_roster_entries p
         where p.distribution_roster_version_id = p_current_version_id and p.assignment_status = 'PLANNED'
           and p.work_date = v_r.work_date and p.route_id is not distinct from v_r.route_id and p.vehicle_id = v_r.vehicle_id) then
      v_blockers := v_blockers || integration.legacy_sync_issue('VEHICLE_NOT_AVAILABLE',
        v_r.registration || ' ' || to_char(v_r.work_date, 'Dy DD/MM') || ': '
        || public.distribution_vehicle_block_reason(v_r.vehicle_id, v_r.work_date));
    end if;
    if exists (select 1 from public.distribution_route_runs rr
               where rr.business_date = v_r.work_date and rr.route_id = v_r.route_id
                 and rr.run_status not in ('DRAFT','READY')
                 and (rr.primary_driver_id is distinct from v_r.primary_driver_id
                      or rr.support_driver_id is distinct from v_r.support_driver_id
                      or rr.vehicle_id is distinct from v_r.vehicle_id)) then
      v_blockers := v_blockers || integration.legacy_sync_issue('RUN_ALREADY_STARTED',
        v_r.route_name || ' ' || to_char(v_r.work_date, 'Dy DD/MM'));
    end if;
  end loop;

  for v_r in
    select r.work_date, r.route_code from integration.legacy_sync_roster_distribution_rows(p_map) r
    where r.assignment_status = 'PLANNED' group by 1, 2 having count(*) > 1
  loop
    v_blockers := v_blockers || integration.legacy_sync_issue('ROUTE_TWICE_IN_A_DAY',
      'Route ' || v_r.route_code || ' ' || to_char(v_r.work_date, 'Dy DD/MM'));
  end loop;
  for v_r in
    select r.work_date, r.registration from integration.legacy_sync_roster_distribution_rows(p_map) r
    join public.fleet_vehicles fv on fv.vehicle_id = r.vehicle_id
    where r.assignment_status = 'PLANNED'
    group by r.work_date, r.registration, fv.vehicle_type
    having count(*) > case when fv.vehicle_type = 'VAN' then 2 else 1 end
  loop
    v_blockers := v_blockers || integration.legacy_sync_issue('VEHICLE_TWICE_IN_A_DAY',
      v_r.registration || ' ' || to_char(v_r.work_date, 'Dy DD/MM'));
  end loop;

  select coalesce(jsonb_agg(b), '[]'::jsonb) into v_blockers
  from (select distinct b from jsonb_array_elements(v_blockers) b) x;
  return v_blockers;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Plans (read-only)
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_roster(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_type text := upper(coalesce(p_record->>'record_type', ''));
  v_row jsonb := case when jsonb_typeof(p_record->'row') = 'object' then p_record->'row' end;
  v_id text := integration.legacy_sync_text(p_record, 'source_record_id');
  v_table text := case upper(coalesce(p_record->>'record_type', '')) when 'PRODUCTION_ROSTER' then 'RosterStoreV2' else 'Roster' end;
  v_system text := case upper(coalesce(p_record->>'record_type', '')) when 'PRODUCTION_ROSTER' then 'ROSTERDB' else 'DISTRIBUTIONDB' end;
  v_today date := public.current_business_date();
  v_week date;
  v_shift public.shifts%rowtype;
  v_built jsonb;
  v_want jsonb;
  v_fp text;
  v_blockers jsonb;
  v_warnings jsonb;
  v_state integration.legacy_sync_master_states%rowtype;
  v_current uuid;
  v_draft uuid;
  v_have jsonb := '{}'::jsonb;
  v_base jsonb;
  v_merged jsonb;
  v_keys text[];
  v_apply text[];
  v_action text;
  v_k text;
begin
  v_week := integration.legacy_sync_parse_date(split_part(coalesce(v_id, ''), '|', 1));
  if v_type not in ('PRODUCTION_ROSTER','DISTRIBUTION_ROSTER') or v_row is null or v_week is null
     or extract(isodow from v_week) <> 1 then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD', v_type),'warnings','[]'::jsonb);
  end if;
  if v_type = 'PRODUCTION_ROSTER' then
    select * into v_shift from public.shifts s
    where s.shift_code = upper(split_part(v_id, '|', 2)) and s.active and s.deleted_at is null;
    if v_shift.shift_id is null then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,
        'blockers', integration.legacy_sync_issue('INVALID_RECORD', 'shift ' || split_part(v_id, '|', 2)),'warnings','[]'::jsonb);
    end if;
    v_id := v_week::text || '|' || v_shift.shift_code;
  else
    v_id := v_week::text;
  end if;

  if v_week + 6 < v_today then
    return jsonb_build_object('outcome','SKIPPED','record_type',v_type,'source_record_id',v_id,
      'skip_reason','PAST_WEEK','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_type = 'PRODUCTION_ROSTER' and nullif(v_row->'data'->'meta'->>'saveMode', '') is null then
    return jsonb_build_object('outcome','SKIPPED','record_type',v_type,'source_record_id',v_id,
      'skip_reason','NOT_PLANNED_IN_LEGACY','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  v_built := case when v_type = 'PRODUCTION_ROSTER' then integration.legacy_sync_roster_production_want(v_row, v_week)
                  else integration.legacy_sync_roster_distribution_want(v_row, v_week) end;
  v_want := v_built->'want';
  v_blockers := v_built->'blockers';
  v_warnings := v_built->'warnings';
  v_fp := integration.legacy_sync_fingerprint(v_want);

  select * into v_state from integration.legacy_sync_master_states s
  where s.source_system = v_system and s.source_table = v_table and s.source_record_id = v_id
  order by s.state_id desc limit 1;
  if v_state.state_id is not null and v_state.source_fingerprint = v_fp then
    return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type',v_type,'source_record_id',v_id,
      'fingerprint',v_fp,'target_id',v_state.target_id,'blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  if jsonb_array_length(v_blockers) > 0 then
    select coalesce(jsonb_agg(b), '[]'::jsonb) into v_blockers
    from (select distinct b from jsonb_array_elements(v_blockers) b) x;
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'blockers',v_blockers,'warnings',v_warnings);
  end if;

  if v_type = 'PRODUCTION_ROSTER' then
    select prv.roster_version_id into v_current from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where rp.week_start = v_week and prv.shift_id = v_shift.shift_id and prv.status = 'PUBLISHED'
    order by prv.version_number desc limit 1;
    select prv.roster_version_id into v_draft from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where rp.week_start = v_week and prv.shift_id = v_shift.shift_id and prv.status = 'DRAFT' limit 1;
    if v_current is not null then
      v_have := integration.legacy_sync_roster_production_have(v_current);
    end if;
  else
    select d.distribution_roster_version_id into v_current from public.distribution_roster_versions d
    where d.week_start = v_week and d.roster_status = 'PUBLISHED' order by d.version_number desc limit 1;
    select d.distribution_roster_version_id into v_draft from public.distribution_roster_versions d
    where d.week_start = v_week and d.roster_status = 'DRAFT' limit 1;
    if v_current is not null then
      v_have := integration.legacy_sync_roster_distribution_have(v_current);
    end if;
  end if;

  -- Baseline: what the legacy app said last time. The first time, the legacy roster wins.
  if v_state.state_id is not null then
    v_base := v_state.synced;
  end if;

  select array_agg(distinct k) into v_keys from (
    select jsonb_object_keys(v_want) k union select jsonb_object_keys(v_have)
    union select jsonb_object_keys(coalesce(v_base, '{}'::jsonb))) x;

  -- Days before today are history and never change.
  select array_agg(k order by k) into v_apply from unnest(v_keys) k
  where coalesce(v_want->k, 'null'::jsonb) is distinct from coalesce(v_have->k, 'null'::jsonb)
    and (v_base is null or coalesce(v_want->k, 'null'::jsonb) is distinct from coalesce(v_base->k, 'null'::jsonb))
    and (v_current is null
         or coalesce(integration.legacy_sync_parse_date(case when k like 'required|%' then split_part(k, '|', 2)
                                                            else split_part(k, '|', 1) end), v_today) >= v_today);

  v_action := case when v_current is null then 'CREATE'
                   when v_apply is not null then 'UPDATE'
                   when v_state.state_id is null then 'ADOPT' else 'RELINK' end;

  if v_action in ('CREATE','UPDATE') then
    if v_draft is not null then
      v_blockers := v_blockers || integration.legacy_sync_issue('ROSTER_DRAFT_OPEN_IN_V2');
    end if;
    v_merged := v_have;
    foreach v_k in array coalesce(v_apply, '{}'::text[]) loop
      v_merged := case when v_want ? v_k then v_merged || jsonb_build_object(v_k, v_want->v_k) else v_merged - v_k end;
    end loop;
    if v_type = 'PRODUCTION_ROSTER' then
      if not exists (select 1 from jsonb_object_keys(v_merged) k where k like 'S|%') then
        v_blockers := v_blockers || integration.legacy_sync_issue('EMPTY_ROSTER');
      end if;
      v_blockers := v_blockers || integration.legacy_sync_roster_production_check(v_merged, v_week, v_shift.shift_id);
    else
      v_blockers := v_blockers || integration.legacy_sync_roster_distribution_check(v_merged, v_week, v_current);
    end if;
    select coalesce(jsonb_agg(b), '[]'::jsonb) into v_blockers
    from (select distinct b from jsonb_array_elements(v_blockers) b) x;
    if jsonb_array_length(v_blockers) > 0 then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'action',v_action,'blockers',v_blockers,'warnings',v_warnings,'current_version_id',v_current);
    end if;
  end if;

  return jsonb_build_object('outcome','READY','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
    'action',v_action,'current_version_id',v_current,'shift_id',v_shift.shift_id,'week_start',v_week,
    'baseline', case when v_state.state_id is not null then 'LAST_SYNC' else 'LEGACY_WINS_FIRST_TIME' end,
    'change_count', coalesce(array_length(v_apply, 1), 0),
    'changes', (select coalesce(jsonb_object_agg(k, jsonb_build_object('v2', coalesce(v_have->k, 'null'::jsonb),
                                                                         'legacy', coalesce(v_want->k, 'null'::jsonb))), '{}'::jsonb)
                from (select k from unnest(coalesce(v_apply, '{}'::text[])) k order by k limit 40) x),
    'want', v_want, 'merged', v_merged, 'blockers','[]'::jsonb, 'warnings', v_warnings);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Dry run: 1-60 records. Read-only.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_roster_dry_run(p_records jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_plans jsonb := '[]'::jsonb;
  v_record jsonb;
  v_plan jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  if p_records is null or jsonb_typeof(p_records) <> 'array'
     or jsonb_array_length(p_records) = 0 or jsonb_array_length(p_records) > 60 then
    raise exception using errcode='22023', message='Send between 1 and 60 legacy roster records.';
  end if;

  for v_record in select value from jsonb_array_elements(p_records) loop
    v_plans := v_plans || jsonb_build_array(integration.legacy_sync_plan_roster(v_record));
  end loop;

  for v_plan in select value from jsonb_array_elements(v_plans) loop
    if (select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' = v_plan->>'source_record_id'
          and o->>'record_type' is not distinct from v_plan->>'record_type') > 1
       and v_plan->>'outcome' in ('READY','BLOCKED') then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','action',null,
        'blockers', coalesce(v_plan->'blockers','[]'::jsonb) || integration.legacy_sync_issue('DUPLICATE_SOURCE_ID_IN_BATCH'));
    end if;
    v_out := v_out || jsonb_build_array(v_plan - 'want' - 'merged');
  end loop;

  return jsonb_build_object(
    'mode', 'DRY_RUN',
    'writes_performed', 0,
    'records', jsonb_array_length(v_out),
    'ready', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='READY'),
    'actions', (select coalesce(jsonb_object_agg(a, n),'{}'::jsonb) from (
        select (o->>'record_type')||':'||(o->>'action') as a, count(*) as n from jsonb_array_elements(v_out) o
        where o->>'outcome'='READY' group by 1) x),
    'already_imported', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='ALREADY_IMPORTED'),
    'blocked', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='BLOCKED'),
    'skipped', (select count(*) from jsonb_array_elements(v_out) o where o->>'outcome'='SKIPPED'),
    'blocker_counts', (select coalesce(jsonb_object_agg(code, n),'{}'::jsonb) from (
        select b->>'code' as code, count(*) as n
        from jsonb_array_elements(v_out) o, jsonb_array_elements(coalesce(o->'blockers','[]'::jsonb)) b
        group by 1) x),
    'warning_counts', (select coalesce(jsonb_object_agg(code, n),'{}'::jsonb) from (
        select w->>'code' as code, count(*) as n
        from jsonb_array_elements(v_out) o, jsonb_array_elements(coalesce(o->'warnings','[]'::jsonb)) w
        group by 1) x),
    'plans', v_out);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Writers
-- ---------------------------------------------------------------------

-- New Production Roster version: a DRAFT with the merged rows, the checks of
-- save_production_roster_week and publish_production_roster_week, then publication.
create or replace function integration.legacy_sync_roster_publish_production(
  p_week date, p_shift_id uuid, p_current_version_id uuid, p_merged jsonb, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_shift public.shifts%rowtype;
  v_period_id uuid;
  v_version public.production_roster_versions%rowtype;
  v_previous uuid;
  v_days integer := case when coalesce((p_merged->>'sunday')::boolean, false) then 7 else 6 end;
  v_entries integer;
  v_staff integer;
begin
  select * into v_shift from public.shifts s where s.shift_id = p_shift_id;

  insert into public.roster_periods(week_start, status, created_by)
  values (p_week, 'DRAFT', null)
  on conflict (week_start) do nothing;
  select rp.roster_period_id into v_period_id from public.roster_periods rp where rp.week_start = p_week for update;

  if exists (select 1 from public.production_roster_versions prv
             where prv.roster_period_id = v_period_id and prv.shift_id = p_shift_id and prv.status = 'DRAFT') then
    raise exception using errcode='55000', message='This roster week has an open draft in V2.';
  end if;
  select prv.roster_version_id into v_previous from public.production_roster_versions prv
  where prv.roster_period_id = v_period_id and prv.shift_id = p_shift_id and prv.status = 'PUBLISHED'
  limit 1 for update;
  if v_previous is distinct from p_current_version_id then
    raise exception using errcode='40001', message='The V2 roster changed during import. Retry.';
  end if;

  insert into public.production_roster_versions(roster_period_id, shift_id, version_number, status, include_sunday,
    week_note, based_on_version_id, saved_at, saved_by, created_by, updated_by)
  values (v_period_id, p_shift_id,
    (select coalesce(max(prv.version_number), 0) + 1 from public.production_roster_versions prv
     where prv.roster_period_id = v_period_id and prv.shift_id = p_shift_id),
    'DRAFT', v_days = 7, null, p_current_version_id, now(), null, null, null)
  returning * into v_version;

  insert into public.production_roster_events(roster_version_id, event_type, reason, metadata)
  values (v_version.roster_version_id, 'DRAFT_CREATED', p_reason,
    jsonb_build_object('week_start', p_week, 'shift_code', v_shift.shift_code, 'source_application', 'LEGACY_SYNC'));

  insert into public.production_roster_entries(
    roster_version_id, work_date, staff_id, day_status, assignment_type,
    operational_role_id, area_id, station_id, planned_start_time, planned_end_time, notes,
    display_section_code, sorting_work_mode,
    staff_display_name_snapshot, employee_code_snapshot, shift_code_snapshot, shift_name_snapshot,
    operational_role_code_snapshot, operational_role_name_snapshot, area_code_snapshot, area_name_snapshot,
    station_code_snapshot, station_name_snapshot,
    staff_primary_role_code_snapshot, staff_primary_role_name_snapshot,
    staff_default_area_code_snapshot, staff_default_area_name_snapshot,
    staff_default_station_code_snapshot, staff_default_station_name_snapshot,
    fire_training_snapshot, first_aid_training_snapshot, eod_capable_snapshot)
  select v_version.roster_version_id, r.work_date, r.staff_id, r.day_status,
    case when r.day_status in ('WORKING','QUALITY_ANALYSIS') then r.assignment_type else 'BASE' end,
    o.operational_role_id, a.area_id, st.station_id, null, null, null,
    r.display_section_code,
    case when r.day_status = 'WORKING' and (a.area_code = 'SORTING' or o.role_code = 'SORTING_AREA') then r.sorting_work_mode end,
    sm.display_name, sm.employee_code, v_shift.shift_code, v_shift.shift_name,
    o.role_code, o.role_name, a.area_code, a.area_name, st.station_code, st.station_name,
    pr.role_code, pr.role_name, da.area_code, da.area_name, ds.station_code, ds.station_name,
    sm.fire_training, sm.first_aid_training, sm.eod_capable
  from integration.legacy_sync_roster_production_rows(p_merged, p_week) r
  join public.staff_members sm on sm.staff_id = r.staff_id
  left join public.operational_roles o on r.day_status in ('WORKING','QUALITY_ANALYSIS')
    and o.role_code = r.role_code and o.active and o.deleted_at is null
  left join public.areas a on r.day_status in ('WORKING','QUALITY_ANALYSIS')
    and a.area_code = r.area_code and a.active and a.deleted_at is null
  left join public.stations st on r.day_status in ('WORKING','QUALITY_ANALYSIS')
    and st.station_code = r.station_code and st.area_id = a.area_id and st.active and st.deleted_at is null
  left join public.operational_roles pr on pr.operational_role_id = sm.primary_operational_role_id
  left join public.areas da on da.area_id = sm.default_area_id
  left join public.stations ds on ds.station_id = sm.default_station_id
  order by r.person, r.work_date;

  select count(*), count(distinct pre.staff_id) into v_entries, v_staff
  from public.production_roster_entries pre where pre.roster_version_id = v_version.roster_version_id;
  if v_staff = 0 or v_entries <> v_staff * v_days then
    raise exception using errcode='22023', message='Every included staff member must have exactly one entry for each visible day.';
  end if;
  if exists (select 1 from public.production_roster_entries pre
             where pre.roster_version_id = v_version.roster_version_id
             group by pre.staff_id having count(distinct pre.display_section_code) <> 1) then
    raise exception using errcode='22023', message='Each staff member must have one weekly display section per roster version.';
  end if;
  if exists (select 1 from public.production_roster_entries pre join public.staff_members sm on sm.staff_id = pre.staff_id
             where pre.roster_version_id = v_version.roster_version_id and sm.default_shift_id is distinct from p_shift_id) then
    raise exception using errcode='22023', message='The roster contains staff of another shift.';
  end if;
  perform public.production_roster_assert_operational_rules(v_version.roster_version_id);

  update public.production_roster_versions
  set row_version = row_version + 1
  where roster_version_id = v_version.roster_version_id;
  insert into public.production_roster_events(roster_version_id, event_type, reason, metadata)
  values (v_version.roster_version_id, 'DRAFT_SAVED', p_reason,
    jsonb_build_object('entry_count', v_entries, 'staff_count', v_staff, 'shift_override_staff_count', 0,
                       'source_application', 'LEGACY_SYNC'));

  -- As publish_production_roster_week.
  if v_previous is not null then
    update public.production_roster_versions
    set status = 'SUPERSEDED', updated_by = null, row_version = row_version + 1
    where roster_version_id = v_previous;
    insert into public.production_roster_events(roster_version_id, event_type, reason, metadata)
    values (v_previous, 'SUPERSEDED', p_reason, jsonb_build_object('superseded_by', v_version.roster_version_id));
  end if;

  update public.production_roster_versions
  set status = 'PUBLISHED', published_at = now(), published_by = null, updated_by = null, row_version = row_version + 1
  where roster_version_id = v_version.roster_version_id;
  update public.roster_periods
  set status = 'PUBLISHED', published_at = now(), published_by = null, updated_at = now()
  where roster_period_id = v_period_id;
  insert into public.production_roster_events(roster_version_id, event_type, reason, metadata)
  values (v_version.roster_version_id, 'PUBLISHED', p_reason, jsonb_build_object('source_application', 'LEGACY_SYNC'));

  return v_version.roster_version_id;
end;
$$;

-- New Distribution roster version, published as publish_distribution_roster_week does:
-- the previous version is superseded, the daily route runs follow the new version.
create or replace function integration.legacy_sync_roster_publish_distribution(
  p_week date, p_current_version_id uuid, p_merged jsonb, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_roster public.distribution_roster_versions%rowtype;
  v_previous uuid;
  v_entry public.distribution_roster_entries%rowtype;
  v_run_id uuid;
  v_required jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('DISTRIBUTION_ROSTER_WEEK:' || p_week::text, 0));
  if exists (select 1 from public.distribution_roster_versions d where d.week_start = p_week and d.roster_status = 'DRAFT') then
    raise exception using errcode='55000', message='This roster week has an open draft in V2.';
  end if;
  select d.distribution_roster_version_id into v_previous from public.distribution_roster_versions d
  where d.week_start = p_week and d.roster_status = 'PUBLISHED' order by d.version_number desc limit 1 for update;
  if v_previous is distinct from p_current_version_id then
    raise exception using errcode='40001', message='The V2 roster changed during import. Retry.';
  end if;

  select coalesce(jsonb_object_agg(substr(k, 10), (p_merged->>k)::integer), '{}'::jsonb) into v_required
  from jsonb_object_keys(p_merged) k where k like 'required|%';

  insert into public.distribution_roster_versions(week_start, version_number, roster_note, required_routes,
    based_on_version_id, change_reason, created_by, updated_by)
  values (p_week, (select coalesce(max(d.version_number), 0) + 1 from public.distribution_roster_versions d where d.week_start = p_week),
    null, v_required, p_current_version_id, p_reason, null, null)
  returning * into v_roster;
  insert into public.distribution_roster_events(distribution_roster_version_id, event_type, event_payload, recorded_by)
  values (v_roster.distribution_roster_version_id, 'DRAFT_CREATED', jsonb_build_object('source', 'LEGACY_SYNC'), null);

  insert into public.distribution_roster_entries(distribution_roster_version_id, work_date, route_id, assignment_status,
    primary_driver_id, support_driver_id, vehicle_id, route_code_snapshot, route_name_snapshot, route_color_snapshot,
    primary_driver_name_snapshot, support_driver_name_snapshot, vehicle_registration_snapshot, vehicle_name_snapshot,
    entry_note, created_by, updated_by)
  select v_roster.distribution_roster_version_id, r.work_date,
    case when r.assignment_status = 'PLANNED' then r.route_id end,
    r.assignment_status, r.primary_driver_id,
    case when r.assignment_status = 'PLANNED' then r.support_driver_id end,
    case when r.assignment_status = 'PLANNED' then r.vehicle_id end,
    rt.route_code, rt.display_name, rt.route_color,
    pd.display_name, case when r.assignment_status = 'PLANNED' then sd.display_name end,
    case when r.assignment_status = 'PLANNED' then fv.registration_number end,
    case when r.assignment_status = 'PLANNED' then fv.display_name end,
    null, null, null
  from integration.legacy_sync_roster_distribution_rows(p_merged) r
  left join public.distribution_routes rt on rt.route_id = r.route_id and r.assignment_status = 'PLANNED'
  left join public.distribution_drivers pd on pd.driver_id = r.primary_driver_id
  left join public.distribution_drivers sd on sd.driver_id = r.support_driver_id
  left join public.fleet_vehicles fv on fv.vehicle_id = r.vehicle_id
  where extract(isodow from r.work_date) between 1 and 6
  order by r.work_date, rt.route_code;

  perform public.validate_distribution_roster_version(v_roster.distribution_roster_version_id);
  insert into public.distribution_roster_events(distribution_roster_version_id, event_type, event_payload, recorded_by)
  values (v_roster.distribution_roster_version_id, 'DRAFT_SAVED',
    jsonb_build_object('entry_count', (select count(*) from public.distribution_roster_entries e
                                       where e.distribution_roster_version_id = v_roster.distribution_roster_version_id),
                       'source', 'LEGACY_SYNC'), null);

  -- As publish_distribution_roster_week.
  if exists (
    select 1 from public.distribution_roster_entries e
    join public.distribution_route_runs r on r.business_date = e.work_date and r.route_id = e.route_id
    where e.distribution_roster_version_id = v_roster.distribution_roster_version_id and e.assignment_status = 'PLANNED'
      and r.run_status not in ('DRAFT','READY')
      and (r.primary_driver_id is distinct from e.primary_driver_id or r.support_driver_id is distinct from e.support_driver_id
           or r.vehicle_id is distinct from e.vehicle_id)) then
    raise exception using errcode='22023', message='Roster cannot replace an operational run already started.';
  end if;

  update public.distribution_roster_versions
  set roster_status = 'SUPERSEDED', superseded_at = now(), superseded_by = null, updated_by = null, row_version = row_version + 1
  where week_start = p_week and roster_status = 'PUBLISHED';
  update public.distribution_roster_versions
  set roster_status = 'PUBLISHED', published_at = now(), published_by = null, updated_by = null, row_version = row_version + 1
  where distribution_roster_version_id = v_roster.distribution_roster_version_id
  returning * into v_roster;

  -- Daily routes the new version no longer plans: free their driver and vehicle.
  with cleared as (
    update public.distribution_route_runs r
    set run_status = 'DRAFT', primary_driver_id = null, support_driver_id = null, vehicle_id = null,
        updated_by = null, row_version = r.row_version + 1
    where r.business_date between p_week and p_week + 6
      and r.business_date >= current_date
      and r.run_status in ('DRAFT','READY')
      and (r.run_status = 'READY' or r.primary_driver_id is not null or r.support_driver_id is not null or r.vehicle_id is not null)
      and not exists (
        select 1 from public.distribution_roster_entries e
        where e.distribution_roster_version_id = v_roster.distribution_roster_version_id
          and e.assignment_status = 'PLANNED' and e.work_date = r.business_date and e.route_id = r.route_id)
    returning r.run_id
  )
  insert into public.distribution_run_events(run_id, event_type, event_payload, recorded_by)
  select run_id, 'ROSTER_REMOVED',
    jsonb_build_object('distribution_roster_version_id', v_roster.distribution_roster_version_id, 'source', 'LEGACY_SYNC'), null
  from cleared;

  for v_entry in
    select * from public.distribution_roster_entries
    where distribution_roster_version_id = v_roster.distribution_roster_version_id and assignment_status = 'PLANNED'
    order by work_date, route_code_snapshot
  loop
    v_run_id := null;
    insert into public.distribution_route_runs(business_date, route_id, run_status, primary_driver_id, support_driver_id,
      vehicle_id, dispatch_notes, created_by, updated_by)
    values (v_entry.work_date, v_entry.route_id, 'READY', v_entry.primary_driver_id, v_entry.support_driver_id,
      v_entry.vehicle_id, v_entry.entry_note, null, null)
    on conflict (business_date, route_id) do update
    set run_status = 'READY', primary_driver_id = excluded.primary_driver_id, support_driver_id = excluded.support_driver_id,
        vehicle_id = excluded.vehicle_id, dispatch_notes = excluded.dispatch_notes, updated_by = null,
        row_version = public.distribution_route_runs.row_version + 1
    where public.distribution_route_runs.run_status in ('DRAFT','READY')
    returning run_id into v_run_id;
    continue when v_run_id is null;
    perform public.sync_distribution_route_run_stops(v_run_id);
    insert into public.distribution_run_events(run_id, event_type, event_payload, recorded_by)
    values (v_run_id, 'ROSTER_PUBLISHED',
      jsonb_build_object('distribution_roster_version_id', v_roster.distribution_roster_version_id, 'source', 'LEGACY_SYNC'), null);
  end loop;

  insert into public.distribution_roster_events(distribution_roster_version_id, event_type, event_payload, recorded_by)
  values (v_roster.distribution_roster_version_id, 'PUBLISHED',
    jsonb_build_object('published_at', v_roster.published_at, 'source', 'LEGACY_SYNC'), null);

  return v_roster.distribution_roster_version_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Importer: one record, or {"records": [...]} up to 60, each in its own
--    subtransaction.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_roster_one(
  p_sync_run_id uuid,
  p_record jsonb,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_ROSTER';
  v_type text := upper(coalesce(p_record->>'record_type',''));
  v_table text := case upper(coalesce(p_record->>'record_type','')) when 'PRODUCTION_ROSTER' then 'RosterStoreV2' else 'Roster' end;
  v_system text := case upper(coalesce(p_record->>'record_type','')) when 'PRODUCTION_ROSTER' then 'ROSTERDB' else 'DISTRIBUTIONDB' end;
  v_plan jsonb;
  v_id text;
  v_action text;
  v_target uuid;
  v_done integer;
  v_reason text;
begin
  if v_type not in ('PRODUCTION_ROSTER','DISTRIBUTION_ROSTER') then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',p_record->>'source_record_id',
      'blockers', integration.legacy_sync_issue('INVALID_RECORD', v_type));
  end if;

  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_ROSTER:' || v_type || ':' || lower(coalesce(p_record->>'source_record_id','')), 0));
  v_plan := integration.legacy_sync_plan_roster(p_record);
  v_id := v_plan->>'source_record_id';
  if v_plan->>'outcome' = 'SKIPPED' then
    return v_plan;
  end if;
  perform integration.legacy_sync_keep_version(v_system, v_table, v_id, v_plan->>'fingerprint', p_record->'row', p_sync_run_id);

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review(v_system, v_table, v_plan, p_record, p_sync_run_id);
    return v_plan - 'want' - 'merged';
  end if;

  v_action := v_plan->>'action';
  v_target := nullif(v_plan->>'current_version_id','')::uuid;

  if v_action in ('CREATE','UPDATE') then
    select count(*) into v_done from public.audit_log a
    where a.correlation_id = p_sync_run_id and a.source_application = c_source;
    if v_done >= p_limit then
      return jsonb_build_object('outcome','RUN_LIMIT_REACHED','record_type',v_type,'source_record_id',v_id,
        'max_entries_per_run',p_limit);
    end if;

    v_reason := left('Legacy sync: ' || case v_type when 'PRODUCTION_ROSTER' then 'Weekly Shift Roster ' else 'Distribution roster ' end
      || v_id || case when v_action = 'CREATE' then ' imported.'
                      else ' changed in the legacy app (' || (v_plan->>'change_count') || ' cells).' end, 500);
    if v_type = 'PRODUCTION_ROSTER' then
      v_target := integration.legacy_sync_roster_publish_production((v_plan->>'week_start')::date,
        (v_plan->>'shift_id')::uuid, nullif(v_plan->>'current_version_id','')::uuid, v_plan->'merged', v_reason);
    else
      v_target := integration.legacy_sync_roster_publish_distribution((v_plan->>'week_start')::date,
        nullif(v_plan->>'current_version_id','')::uuid, v_plan->'merged', v_reason);
    end if;
    insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
    values (case v_type when 'PRODUCTION_ROSTER' then 'PRODUCTION_ROSTER_PUBLISHED' else 'DISTRIBUTION_ROSTER_PUBLISHED' end,
      case v_type when 'PRODUCTION_ROSTER' then 'production_roster_versions' else 'distribution_roster_versions' end,
      v_target::text, jsonb_build_object('roster_version_id', v_plan->>'current_version_id'),
      jsonb_build_object('roster_version_id', v_target, 'week', v_id, 'baseline', v_plan->>'baseline',
                         'change_count', (v_plan->>'change_count')::integer, 'changes', v_plan->'changes'),
      v_reason, c_source, p_sync_run_id);
  end if;

  insert into integration.legacy_sync_master_states(source_system, source_table, source_record_id, target_table,
    target_id, action, synced, source_fingerprint, sync_run_id)
  values (v_system, v_table, v_id,
    case v_type when 'PRODUCTION_ROSTER' then 'public.production_roster_versions' else 'public.distribution_roster_versions' end,
    v_target, v_action, v_plan->'want', v_plan->>'fingerprint', p_sync_run_id);

  return (v_plan - 'want' - 'merged') || jsonb_build_object('outcome',
    case v_action when 'CREATE' then 'IMPORTED' when 'UPDATE' then 'UPDATED' when 'RELINK' then 'RELINKED' else 'ADOPTED' end,
    'imported', true, 'target_id', v_target);
end;
$$;

create or replace function integration.legacy_sync_import_roster(
  p_sync_run_id uuid,
  p_record jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_setting integration.legacy_sync_settings%rowtype;
  v_run integration.legacy_sync_runs%rowtype;
  v_records jsonb;
  v_record jsonb;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync importer cannot run as an application user.';
  end if;

  select * into v_setting from integration.legacy_sync_settings
  where setting_key='ROSTER_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy roster import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;

  if jsonb_typeof(p_record->'records') = 'array' then
    v_records := p_record->'records';
    if jsonb_array_length(v_records) = 0 or jsonb_array_length(v_records) > 60 then
      raise exception using errcode='22023', message='Send between 1 and 60 legacy roster records.';
    end if;
  else
    v_records := jsonb_build_array(p_record);
  end if;

  for v_record in select value from jsonb_array_elements(v_records) loop
    begin
      v_result := integration.legacy_sync_import_roster_one(p_sync_run_id, v_record, v_setting.max_entries_per_run);
    exception when others then
      v_result := jsonb_build_object('outcome','ERROR','record_type',upper(coalesce(v_record->>'record_type','')),
        'source_record_id', v_record->>'source_record_id', 'sqlstate', sqlstate, 'error', left(sqlerrm, 300));
    end;
    v_results := v_results || jsonb_build_array(v_result);
    exit when v_result->>'outcome' = 'RUN_LIMIT_REACHED';
  end loop;

  if jsonb_typeof(p_record->'records') <> 'array' or p_record->'records' is null then
    return v_results->0;
  end if;
  return jsonb_build_object('outcome','BATCH','records',jsonb_array_length(v_results),
    'counts', (select coalesce(jsonb_object_agg(o, n), '{}'::jsonb) from (
        select r->>'outcome' as o, count(*) as n from jsonb_array_elements(v_results) r group by 1) x),
    'results', v_results);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Dispatchers: add the kind "roster".
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_dispatch_dry_run(p_kind text, p_records jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
begin
  case p_kind
    when 'wash' then return integration.legacy_sync_wash_dry_run(p_records);
    when 'mop' then return integration.legacy_sync_mop_dry_run(p_records);
    when 'trolley' then return integration.legacy_sync_trolley_dry_run(p_records);
    when 'attendance' then return integration.legacy_sync_attendance_dry_run(p_records);
    when 'master' then return integration.legacy_sync_master_dry_run(p_records);
    when 'schedule' then return integration.legacy_sync_schedule_dry_run(p_records);
    when 'roster' then return integration.legacy_sync_roster_dry_run(p_records);
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

create or replace function integration.legacy_sync_dispatch_import(p_kind text, p_sync_run_id uuid, p_record jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
begin
  case p_kind
    when 'wash' then return integration.legacy_sync_import_wash(p_sync_run_id, p_record);
    when 'mop' then return integration.legacy_sync_import_mop(p_sync_run_id, p_record);
    when 'trolley' then return integration.legacy_sync_import_trolley(p_sync_run_id, p_record);
    when 'attendance' then return integration.legacy_sync_import_attendance(p_sync_run_id, p_record);
    when 'master' then return integration.legacy_sync_import_master(p_sync_run_id, p_record);
    when 'schedule' then return integration.legacy_sync_import_schedule(p_sync_run_id, p_record);
    when 'roster' then return integration.legacy_sync_import_roster(p_sync_run_id, p_record);
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Review page: people, drivers and vehicles the next run of the
--    registers creates are "waiting".
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_review_waiting_codes()
returns text[]
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select array['WASH_NOT_IN_V2','MOP_NOT_IN_V2','FINISH_ENTRY_NOT_IN_V2','TROLLEY_NOT_IN_V2',
               'CUSTOMER_NOT_IN_V2','ROUTE_NOT_IN_V2','STAFF_NOT_IN_V2','DRIVER_NOT_IN_V2','VEHICLE_NOT_IN_V2']::text[];
$$;

-- ---------------------------------------------------------------------
-- 10. Access: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_roster_position(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_cell(text, text, text, text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_production_want(jsonb, date) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_production_have(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_production_rows(jsonb, date) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_production_check(jsonb, date, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_route_code(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_distribution_want(jsonb, date) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_distribution_have(uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_distribution_rows(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_distribution_check(jsonb, date, uuid) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_roster(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_publish_production(date, uuid, uuid, jsonb, text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_roster_publish_distribution(date, uuid, jsonb, text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_roster_one(uuid, jsonb, integer) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_roster(uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_dry_run(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_review_waiting_codes() from public, anon, authenticated;

grant execute on function integration.legacy_sync_roster_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_roster(uuid, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_dry_run(text, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) to service_role;

comment on function integration.legacy_sync_plan_roster(jsonb) is
  'Read-only plan for one legacy weekly roster (Production week+shift or Distribution week): cells the legacy app changed since the last sync that V2 does not have; the first time, every cell that differs.';
comment on function integration.legacy_sync_import_roster(uuid, jsonb) is
  'Imports legacy Production and Distribution weekly rosters inside an open COMMIT run, when ROSTER_IMPORT is enabled. A change is a new published roster version. service_role only.';

commit;
