-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270010_legacy_sync_attendance
--
-- Fourth part of the nightly legacy sync (owner decision 2026-10-27:
-- everything the legacy apps still record goes to V2, as if the team had
-- typed it in V2): who worked, where and when.
--
-- One kind "attendance" with three record types, sent in the order they
-- were typed:
--   * FINISH_SESSION: one Finish Area StaffSessions (+History) row (key
--     SessionID). Written like upsert_finish_staff_actual: Finish attendance
--     PRESENT, a Finish work session at the legacy Table with the legacy
--     start, end and break, and its table segment.
--   * FINISH_NOT_WORKING: one Finish Area RosterNotWorking row (key
--     DismissalID). Written like set_finish_staff_attendance_v1: Finish
--     attendance ABSENT (OTHER, "Not working") and the person's Finish work
--     sessions of that shift cancelled.
--   * SORTING_STAFF: one Sorting workbook "Staff" row (key
--     "<business date>|<shift>|<name>"). Written like
--     add_sorting_actual_staff + save_sorting_staff_work_adjustment: Sorting
--     attendance PRESENT and a Sorting work session with the legacy start,
--     end and break, linked to the published roster entry when there is one.
--
-- Rules:
--   * business date, shift, person, table, times and break are the legacy
--     values; the legacy value wins over V2 (owner decision): an ABSENT row
--     is set back to PRESENT by a legacy session typed after it, and a work
--     session typed in V2 for the same person and shift takes the legacy
--     times (the old values stay in the audit log);
--   * a legacy session that is cancelled cancels the V2 work session;
--   * Sunday 2026-10-25 is skipped (owner test day); rows before 2026-10-24
--     are skipped unless already linked;
--   * an unknown person, table or shift, invalid times, more than 13 hours
--     of work in one day, a "not working" row for someone with Finish
--     production that shift, or table transfers already recorded in V2 go to
--     the review queue.
--
-- New switch ATTENDANCE_IMPORT (seeded OFF, limit 300). The Apps Script
-- control ON/OFF switches it with the others.
-- Apply after 202610270007, 0008 and 0009: it recreates the provenance checks
-- and the dispatchers with every part.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Switch and provenance roles
-- ---------------------------------------------------------------------
insert into integration.legacy_sync_settings(setting_key, enabled, max_entries_per_run, changed_by, note)
values ('ATTENDANCE_IMPORT', false, 300, 'migration 202610270010',
        'Seeded disabled. Turned on with the other imports from the Apps Script page.')
on conflict (setting_key) do nothing;

alter table integration.legacy_sync_record_links
  drop constraint legacy_sync_record_links_link_role_check,
  drop constraint legacy_sync_record_links_target_role_check;

alter table integration.legacy_sync_record_links
  add constraint legacy_sync_record_links_link_role_check check (link_role in
    ('CUSTOMER','WASH_ITEM_TO_FLOW','FINISH_ENTRY_TO_ENTRY','FINISH_ENTRY_TO_LINE',
     'HOUSEHOLD_TO_REWASH_ENTRY','REWASH_LINE_TO_LINE','SORTING_WASH_TO_RUN','MOP_ITEM_TO_BATCH',
     'TROLLEY_OUT_TO_STAY','TROLLEY_RETURN_TO_INTAKE',
     'STAFF_SESSION_TO_WORK_SESSION','NOT_WORKING_TO_ATTENDANCE')),
  add constraint legacy_sync_record_links_target_role_check check (
    (link_role='CUSTOMER' and target_table='public.customers') or
    (link_role='WASH_ITEM_TO_FLOW' and target_table='public.production_flow_items') or
    (link_role='FINISH_ENTRY_TO_ENTRY' and target_table='public.finish_production_entries') or
    (link_role='FINISH_ENTRY_TO_LINE' and target_table='public.finish_production_lines') or
    (link_role='HOUSEHOLD_TO_REWASH_ENTRY' and target_table='public.finish_rewash_entries') or
    (link_role='REWASH_LINE_TO_LINE' and target_table='public.finish_rewash_lines') or
    (link_role='SORTING_WASH_TO_RUN' and target_table='public.sorting_wash_runs') or
    (link_role='MOP_ITEM_TO_BATCH' and target_table='public.sorting_mop_production_batches') or
    (link_role='TROLLEY_OUT_TO_STAY' and target_table='public.trolley_customer_stays') or
    (link_role='TROLLEY_RETURN_TO_INTAKE' and target_table='public.sorting_trolley_intakes') or
    (link_role='STAFF_SESSION_TO_WORK_SESSION' and target_table='public.work_sessions') or
    (link_role='NOT_WORKING_TO_ATTENDANCE' and target_table='public.finish_daily_staff_attendance')
  );

-- ---------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------

-- A legacy time of day: "07:00", "07:00:00", or a date-time whose clock is used.
create or replace function integration.legacy_sync_parse_clock(p_value text)
returns time
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v text := btrim(coalesce(p_value,''));
  m text[];
begin
  m := regexp_match(v, '(?:^|[ T])([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?(?:\.[0-9]+)?(?:Z|[+-][0-9:]+)?$');
  if m is null or m[1]::integer > 23 or m[2]::integer > 59 or coalesce(m[3],'0')::integer > 59 then
    return null;
  end if;
  return make_time(m[1]::integer, m[2]::integer, coalesce(m[3],'0')::integer);
end;
$$;

-- A legacy break: minutes ("45") or a duration ("00:45", "00:45:00").
create or replace function integration.legacy_sync_parse_minutes(p_value text)
returns integer
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v text := btrim(coalesce(p_value,''));
  m text[];
begin
  if v = '' then return 0; end if;
  if v ~ '^[0-9]{1,3}(\.0+)?$' then return round(v::numeric)::integer; end if;
  m := regexp_match(v, '^([0-9]{1,2}):([0-9]{2})(?::[0-9]{2})?$');
  if m is null then return null; end if;
  return m[1]::integer * 60 + m[2]::integer;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Planner. Read-only.
--
-- p_record:
-- { "record_type": "FINISH_SESSION", "source_record_id": "<SessionID>",
--   "row": { SessionID, CreatedAt, BusinessDate, Shift, TableID, UserName, UserID, StartTime,
--            EndTime, BreakMin, SessionType, Comments, Status } }
-- { "record_type": "FINISH_NOT_WORKING", "source_record_id": "<DismissalID>",
--   "row": { DismissalID, CreatedAt, BusinessDate, Shift, TableID, UserName, UserID, Reason, Status } }
-- { "record_type": "SORTING_STAFF", "source_record_id": "<yyyy-mm-dd>|<Shift>|<name>",
--   "row": { BusinessDate, Shift, Name, UserID, StartShift, EndShift, Break, Comments, WorkPosition, EnteredAt } }
-- Actions: CREATE, UPDATE, ADOPT, ADOPT_AND_UPDATE, CANCEL (sessions); ABSENT (not working).
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_plan_attendance(p_record jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_type text := upper(coalesce(p_record->>'record_type',''));
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_row jsonb := case when jsonb_typeof(p_record->'row')='object' then p_record->'row' end;
  v_system text;
  v_table text;
  v_role text;
  v_area text;
  v_fp text;
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_link integration.legacy_sync_record_links%rowtype;
  v_business date;
  v_shift_code text;
  v_shift public.shifts%rowtype;
  v_staff jsonb;
  v_staff_id uuid;
  v_name text;
  v_user_id text;
  v_area_id uuid;
  v_station public.stations%rowtype;
  v_table_code text;
  v_start_t time;
  v_end_t time;
  v_start timestamptz;
  v_end timestamptz;
  v_break integer;
  v_status text;
  v_session public.work_sessions%rowtype;
  v_target_via text;
  v_other numeric;
  v_segments integer;
  v_facts jsonb;
  v_current jsonb;
  v_action text;
  v_att text;
begin
  if v_row is null or v_type not in ('FINISH_SESSION','FINISH_NOT_WORKING','SORTING_STAFF') then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,
      'blockers', integration.legacy_sync_issue('INVALID_RECORD', v_type),'warnings','[]'::jsonb);
  end if;
  v_fp := integration.legacy_sync_fingerprint(v_row);
  case v_type
    when 'FINISH_SESSION' then
      v_system := 'FINISH_AREA'; v_table := 'StaffSessions'; v_role := 'STAFF_SESSION_TO_WORK_SESSION'; v_area := 'FINISH';
      v_name := integration.legacy_sync_text(v_row,'UserName');
      if integration.legacy_sync_text(v_row,'SessionID') is distinct from v_id then
        v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH', v_id);
      end if;
    when 'FINISH_NOT_WORKING' then
      v_system := 'FINISH_AREA'; v_table := 'RosterNotWorking'; v_role := 'NOT_WORKING_TO_ATTENDANCE'; v_area := 'FINISH';
      v_name := integration.legacy_sync_text(v_row,'UserName');
      if integration.legacy_sync_text(v_row,'DismissalID') is distinct from v_id then
        v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH', v_id);
      end if;
    else
      v_system := 'SORTING_AREA'; v_table := 'Staff'; v_role := 'STAFF_SESSION_TO_WORK_SESSION'; v_area := 'SORTING';
      v_name := integration.legacy_sync_text(v_row,'Name');
      if v_id is distinct from concat_ws('|', integration.legacy_sync_text(v_row,'BusinessDate'),
                                         integration.legacy_sync_text(v_row,'Shift'), lower(v_name)) then
        v_blockers := v_blockers || integration.legacy_sync_issue('SOURCE_ID_MISMATCH', v_id);
      end if;
  end case;
  if v_id is null or length(v_id) > 160 then
    v_blockers := v_blockers || integration.legacy_sync_issue('MISSING_SOURCE_ID');
  end if;

  select * into v_link from integration.legacy_sync_record_links l
  where l.source_system=v_system and l.source_table=v_table and l.source_record_id=v_id and l.link_role=v_role;

  v_business := integration.legacy_sync_parse_date(integration.legacy_sync_text(v_row,'BusinessDate'));
  if v_business is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_BUSINESS_DATE', integration.legacy_sync_text(v_row,'BusinessDate'));
  end if;
  if v_link.link_id is null and v_business = date '2026-10-25' then
    return jsonb_build_object('outcome','SKIPPED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','OWNER_TEST_DAY','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_link.link_id is null and v_business < integration.legacy_sync_finish_window_start() then
    return jsonb_build_object('outcome','SKIPPED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','BEFORE_SYNC_WINDOW','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  v_status := upper(coalesce(integration.legacy_sync_text(v_row,'Status'), case when v_type='SORTING_STAFF' then 'OPEN' end, ''));

  -- "Not working" withdrawn, or a cancelled session.
  if v_type = 'FINISH_NOT_WORKING' and v_status <> 'NOT_WORKING' then
    if v_link.link_id is not null then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'blockers', integration.legacy_sync_issue('NOT_WORKING_WITHDRAWN', v_status),'warnings','[]'::jsonb);
    end if;
    return jsonb_build_object('outcome','SKIPPED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','SOURCE_NOT_ACTIVE','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_type = 'FINISH_SESSION' and v_status in ('CANCELLED','DELETED','VOID','VOIDED') then
    if v_link.link_id is not null then
      select * into v_session from public.work_sessions ws where ws.work_session_id=v_link.target_id;
      if v_session.status <> 'CANCELLED' then
        return jsonb_build_object('outcome','READY','action','CANCEL','record_type',v_type,'source_record_id',v_id,
          'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings','[]'::jsonb,
          'target', jsonb_build_object('work_session_id', v_session.work_session_id, 'row_version', v_session.row_version));
      end if;
      return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'blockers','[]'::jsonb,'warnings','[]'::jsonb);
    end if;
    return jsonb_build_object('outcome','SKIPPED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'skip_reason','SOURCE_CANCELLED','blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;
  if v_type = 'FINISH_NOT_WORKING' and v_link.link_id is not null then
    return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'blockers','[]'::jsonb,'warnings','[]'::jsonb);
  end if;

  -- Shift and person.
  v_shift_code := integration.legacy_sync_map_value('FINISH_AREA','SHIFT', integration.legacy_sync_text(v_row,'Shift'));
  select * into v_shift from public.shifts s where s.shift_code=v_shift_code and s.deleted_at is null;
  if v_shift.shift_id is null or v_shift.shift_code not in ('MORNING','EVENING') then
    v_blockers := v_blockers || integration.legacy_sync_issue('SHIFT_UNMAPPED', integration.legacy_sync_text(v_row,'Shift'));
  end if;
  v_user_id := integration.legacy_sync_text(v_row,'UserID');
  if v_user_id ~ '^[0-9]+\.0+$' then v_user_id := split_part(v_user_id,'.',1); end if;
  v_staff := integration.legacy_sync_resolve_staff(v_user_id, v_name);
  if v_staff->>'staff_id' is null and v_user_id is not null then
    v_staff := integration.legacy_sync_resolve_staff(null, v_name);
  end if;
  v_staff_id := nullif(v_staff->>'staff_id','')::uuid;
  if v_staff_id is null then
    v_blockers := v_blockers || integration.legacy_sync_issue(
      case when v_name is null then 'STAFF_MISSING'
           when v_staff->'warnings' @> '[{"code":"PROCESSED_BY_NAME_AMBIGUOUS"}]' then 'STAFF_AMBIGUOUS'
           else 'STAFF_UNMATCHED' end,
      concat_ws(' / legacy UserID ', v_name, v_user_id));
  end if;
  select a.area_id into v_area_id from public.areas a where a.area_code=v_area and a.deleted_at is null;

  -- Not working: ABSENT in Finish.
  if v_type = 'FINISH_NOT_WORKING' then
    if v_staff_id is not null and v_shift.shift_id is not null and exists (
         select 1 from public.finish_production_entries e
         where e.production_business_date=v_business and e.shift_id=v_shift.shift_id
           and e.status='ACTIVE' and e.processed_by_staff_id=v_staff_id) then
      v_blockers := v_blockers || integration.legacy_sync_issue('FINISH_PRODUCTION_RECORDED',
        format('%s has Finish production on %s %s.', v_name, v_business, v_shift_code));
    end if;
    if jsonb_array_length(v_blockers) > 0 then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'blockers',v_blockers,'warnings',v_warnings);
    end if;
    select a.attendance_status into v_att from public.finish_daily_staff_attendance a
    where a.business_date=v_business and a.shift_id=v_shift.shift_id and a.staff_id=v_staff_id;
    if v_att = 'PRESENT' then
      v_warnings := v_warnings || integration.legacy_sync_issue('PRESENT_REPLACED',
        format('%s was PRESENT in V2 Finish on %s %s.', v_name, v_business, v_shift_code));
    end if;
    return jsonb_build_object('outcome','READY','action','ABSENT','record_type',v_type,'source_record_id',v_id,
      'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings',v_warnings,
      'resolved', jsonb_build_object('area', v_area, 'business_date', v_business, 'shift_id', v_shift.shift_id,
        'shift_code', v_shift.shift_code, 'staff_id', v_staff_id, 'staff_name', v_name,
        'notes', concat_ws(' ', coalesce(integration.legacy_sync_text(v_row,'Reason'),'Not working'),
                           '(legacy Finish ' || coalesce(integration.legacy_sync_text(v_row,'TableID'),'') || ').')));
  end if;

  -- Sessions: station, times, break.
  if v_type = 'FINISH_SESSION' then
    v_table_code := integration.legacy_sync_map_value('FINISH_AREA','FINISH_TABLE', integration.legacy_sync_text(v_row,'TableID'));
    v_start_t := integration.legacy_sync_parse_clock(integration.legacy_sync_text(v_row,'StartTime'));
    v_end_t := integration.legacy_sync_parse_clock(integration.legacy_sync_text(v_row,'EndTime'));
    v_break := integration.legacy_sync_parse_minutes(integration.legacy_sync_text(v_row,'BreakMin'));
  else
    v_table_code := 'SORTING_MAIN';
    v_start_t := integration.legacy_sync_parse_clock(integration.legacy_sync_text(v_row,'StartShift'));
    v_end_t := integration.legacy_sync_parse_clock(integration.legacy_sync_text(v_row,'EndShift'));
    v_break := integration.legacy_sync_parse_minutes(integration.legacy_sync_text(v_row,'Break'));
  end if;
  select st.* into v_station from public.stations st join public.areas a on a.area_id=st.area_id
  where st.station_code=v_table_code and a.area_code=v_area and st.deleted_at is null;
  if v_station.station_id is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('TABLE_UNMAPPED',
      coalesce(integration.legacy_sync_text(v_row,'TableID'), v_table_code));
  end if;
  if v_start_t is null then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_START_TIME',
      coalesce(integration.legacy_sync_text(v_row,'StartTime'), integration.legacy_sync_text(v_row,'StartShift')));
  end if;
  if v_break is null or v_break > 720 then
    v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_BREAK',
      coalesce(integration.legacy_sync_text(v_row,'BreakMin'), integration.legacy_sync_text(v_row,'Break')));
  end if;
  if v_start_t is not null and v_shift.shift_id is not null and v_business is not null then
    v_start := public.operational_timestamp_for_shift(v_business, v_shift.shift_code, v_start_t);
    v_end := public.operational_timestamp_for_shift(v_business, v_shift.shift_code, v_end_t);
    if v_end is not null and v_end <= v_start and v_shift.shift_code = 'EVENING' then
      v_end := v_end + interval '1 day';
    end if;
    if v_end is not null and (v_end <= v_start or v_end - v_start > interval '13 hours') then
      v_blockers := v_blockers || integration.legacy_sync_issue('INVALID_WORK_TIMES', format('%s - %s', v_start_t, v_end_t));
    elsif v_start > now() + interval '5 minutes' then
      v_blockers := v_blockers || integration.legacy_sync_issue('START_IN_FUTURE', v_start::text);
    end if;
  end if;
  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
      'blockers',v_blockers,'warnings',v_warnings);
  end if;

  -- V2 target: our link, else the person's work session of that area and shift.
  if v_link.link_id is not null then
    select * into v_session from public.work_sessions ws where ws.work_session_id=v_link.target_id;
    v_target_via := 'LINK';
    if v_session.status = 'CANCELLED' then
      return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'blockers','[]'::jsonb,'warnings', integration.legacy_sync_issue('WORK_SESSION_CANCELLED_IN_V2'),
        'target', jsonb_build_object('work_session_id', v_session.work_session_id));
    end if;
  else
    select ws.* into v_session from public.work_sessions ws
    where ws.work_date=v_business and ws.staff_id=v_staff_id and ws.shift_id=v_shift.shift_id
      and ws.area_id=v_area_id and ws.status <> 'CANCELLED'
      and not exists (select 1 from integration.legacy_sync_record_links l
                      where l.link_role='STAFF_SESSION_TO_WORK_SESSION' and l.target_id=ws.work_session_id)
    order by case when ws.source in ('SORTING_MANUAL_POSITION','FINISH_V2') then 0 else 1 end, ws.updated_at desc
    limit 1;
    if v_session.work_session_id is not null then v_target_via := 'V2_SESSION'; end if;
  end if;

  -- 13 hours a day, every area together.
  if v_end is not null then
    select coalesce(sum(extract(epoch from (ws.actual_end_at - ws.actual_start_at))/60.0), 0) into v_other
    from public.work_sessions ws
    where ws.staff_id=v_staff_id and ws.work_date=v_business and ws.status <> 'CANCELLED'
      and ws.work_session_id is distinct from v_session.work_session_id
      and ws.actual_start_at is not null and ws.actual_end_at is not null;
    if v_other + extract(epoch from (v_end - v_start))/60.0 > 780 then
      return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'blockers', integration.legacy_sync_issue('WORK_OVER_13_HOURS',
          format('%s already has %s minutes recorded on %s.', v_name, round(v_other), v_business)),'warnings',v_warnings);
    end if;
  end if;

  v_facts := jsonb_build_object('station_id', v_station.station_id, 'actual_start_at', v_start,
    'actual_end_at', v_end, 'break_minutes', v_break);
  if v_session.work_session_id is not null then
    v_current := jsonb_build_object('station_id', v_session.station_id, 'actual_start_at', v_session.actual_start_at,
      'actual_end_at', v_session.actual_end_at, 'break_minutes', v_session.break_minutes);
    if v_area = 'FINISH' and v_session.station_id is distinct from v_station.station_id then
      select count(*) into v_segments from public.finish_staff_table_segments s where s.work_session_id=v_session.work_session_id;
      if v_segments > 1 then
        return jsonb_build_object('outcome','BLOCKED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
          'blockers', integration.legacy_sync_issue('TABLE_TRANSFERS_IN_V2',
            format('%s moved between Finish tables in V2 on %s.', v_name, v_business)),'warnings',v_warnings);
      end if;
    end if;
    v_action := case
      when v_target_via='LINK' and v_current = v_facts then null
      when v_target_via='LINK' then 'UPDATE'
      when v_current = v_facts then 'ADOPT'
      else 'ADOPT_AND_UPDATE' end;
    if v_action is null then
      return jsonb_build_object('outcome','ALREADY_IMPORTED','record_type',v_type,'source_record_id',v_id,'fingerprint',v_fp,
        'blockers','[]'::jsonb,'warnings','[]'::jsonb,
        'target', jsonb_build_object('work_session_id', v_session.work_session_id));
    end if;
    if v_action = 'ADOPT_AND_UPDATE' then
      v_warnings := v_warnings || integration.legacy_sync_issue('V2_TIMES_REPLACED',
        'The work session typed in V2 takes the legacy table and times (owner decision: the legacy value wins).');
    end if;
  else
    v_action := 'CREATE';
  end if;

  select a.attendance_status into v_att from (
    select attendance_status from public.finish_daily_staff_attendance f
    where v_area='FINISH' and f.business_date=v_business and f.shift_id=v_shift.shift_id and f.staff_id=v_staff_id
    union all
    select attendance_status from public.sorting_daily_staff_attendance s
    where v_area='SORTING' and s.business_date=v_business and s.shift_id=v_shift.shift_id and s.staff_id=v_staff_id) a;
  if v_att = 'ABSENT' then
    v_warnings := v_warnings || integration.legacy_sync_issue('ABSENCE_REPLACED',
      format('%s was ABSENT in V2 %s on %s %s.', v_name, initcap(v_area), v_business, v_shift.shift_code));
  end if;

  return jsonb_build_object('outcome','READY','action',v_action,'record_type',v_type,'source_record_id',v_id,
    'fingerprint',v_fp,'blockers','[]'::jsonb,'warnings',v_warnings,
    'target', case when v_session.work_session_id is not null then jsonb_build_object(
      'work_session_id', v_session.work_session_id, 'row_version', v_session.row_version, 'via', v_target_via) end,
    'resolved', v_facts || jsonb_build_object('area', v_area, 'area_id', v_area_id, 'business_date', v_business,
      'shift_id', v_shift.shift_id, 'shift_code', v_shift.shift_code, 'staff_id', v_staff_id, 'staff_name', v_name,
      'station_code', v_station.station_code, 'attendance', v_att,
      'notes', concat_ws('; ', 'Legacy ' || initcap(v_area) || ' staff ' || v_id,
        nullif(integration.legacy_sync_text(v_row,'SessionType'),'Regular'),
        integration.legacy_sync_text(v_row,'WorkPosition'),
        integration.legacy_sync_text(v_row,'Comments'))));
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Dry run: 1-60 records. Read-only.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_attendance_dry_run(p_records jsonb)
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
    raise exception using errcode='22023', message='Send between 1 and 60 legacy attendance records.';
  end if;

  for v_record in select value from jsonb_array_elements(p_records) loop
    v_plans := v_plans || jsonb_build_array(integration.legacy_sync_plan_attendance(v_record));
  end loop;

  for v_plan in select value from jsonb_array_elements(v_plans) loop
    if (select count(*) from jsonb_array_elements(v_plans) o
        where o->>'source_record_id' = v_plan->>'source_record_id'
          and o->>'record_type' is not distinct from v_plan->>'record_type') > 1
       and v_plan->>'outcome' in ('READY','BLOCKED') then
      v_plan := v_plan || jsonb_build_object('outcome','BLOCKED','action',null,
        'blockers', coalesce(v_plan->'blockers','[]'::jsonb) || integration.legacy_sync_issue('DUPLICATE_SOURCE_ID_IN_BATCH'));
    end if;
    v_out := v_out || jsonb_build_array(v_plan);
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
-- 5. Importer: one record, one transaction.
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_import_attendance(
  p_sync_run_id uuid,
  p_record jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  c_source constant text := 'LEGACY_SYNC_ATTENDANCE';
  v_setting integration.legacy_sync_settings%rowtype;
  v_run integration.legacy_sync_runs%rowtype;
  v_plan jsonb;
  v_r jsonb;
  v_type text := upper(coalesce(p_record->>'record_type',''));
  v_id text := integration.legacy_sync_text(p_record,'source_record_id');
  v_system text;
  v_table text;
  v_done integer;
  v_action text;
  v_old public.work_sessions%rowtype;
  v_saved public.work_sessions%rowtype;
  v_entry public.production_roster_entries%rowtype;
  v_att_old jsonb;
  v_att_id uuid;
  v_cancelled integer;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync importer cannot run as an application user.';
  end if;

  select * into v_setting from integration.legacy_sync_settings
  where setting_key='ATTENDANCE_IMPORT' for share;
  if not found or not v_setting.enabled then
    raise exception using errcode='55000', message='Legacy attendance import is disabled.';
  end if;

  select * into v_run from integration.legacy_sync_runs where sync_run_id=p_sync_run_id for update;
  if not found or v_run.mode <> 'COMMIT' or v_run.status not in ('CREATED','RUNNING') then
    raise exception using errcode='55000', message='An open COMMIT run is required.';
  end if;
  if v_id is null then
    raise exception using errcode='22023', message='source_record_id is required.';
  end if;

  v_system := case v_type when 'SORTING_STAFF' then 'SORTING_AREA' else 'FINISH_AREA' end;
  v_table := case v_type when 'SORTING_STAFF' then 'Staff' when 'FINISH_NOT_WORKING' then 'RosterNotWorking' else 'StaffSessions' end;

  v_plan := integration.legacy_sync_plan_attendance(p_record);
  perform pg_advisory_xact_lock(hashtextextended('LEGACY_SYNC_ATTENDANCE:'||coalesce(v_plan#>>'{resolved,staff_id}', v_id), 0));
  v_plan := integration.legacy_sync_plan_attendance(p_record);
  perform integration.legacy_sync_keep_version(v_system, v_table, v_id, v_plan->>'fingerprint', p_record->'row', p_sync_run_id);

  if v_plan->>'outcome' <> 'READY' then
    perform integration.legacy_sync_hold_for_review(v_system, v_table, v_plan, p_record, p_sync_run_id);
    return v_plan;
  end if;

  select count(*) into v_done from public.audit_log a
  where a.correlation_id=p_sync_run_id
    and a.action in ('IMPORT_LEGACY_STAFF_SESSION','CORRECT_LEGACY_STAFF_SESSION','ADOPT_LEGACY_STAFF_SESSION',
                     'CANCEL_LEGACY_STAFF_SESSION','IMPORT_LEGACY_NOT_WORKING');
  if v_done >= v_setting.max_entries_per_run then
    return jsonb_build_object('outcome','RUN_LIMIT_REACHED','source_record_id',v_id,
      'max_entries_per_run',v_setting.max_entries_per_run);
  end if;

  v_r := v_plan->'resolved';
  v_action := v_plan->>'action';

  -- Legacy cancellation of a session.
  if v_action = 'CANCEL' then
    select * into v_old from public.work_sessions where work_session_id=(v_plan#>>'{target,work_session_id}')::uuid for update;
    if v_old.status = 'CANCELLED' or v_old.row_version <> (v_plan#>>'{target,row_version}')::integer then
      raise exception using errcode='40001', message='The V2 work session changed during import. Retry.';
    end if;
    update public.work_sessions
    set status='CANCELLED', notes=concat_ws(' | ', notes, 'Cancelled in the legacy app (legacy sync).'),
        row_version=row_version+1, updated_at=now()
    where work_session_id=v_old.work_session_id returning * into v_saved;
    insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
    values ('CANCEL_LEGACY_STAFF_SESSION', 'work_sessions', v_saved.work_session_id::text, to_jsonb(v_old), to_jsonb(v_saved),
      'Legacy sync: the staff session was cancelled in the legacy app.', c_source, p_sync_run_id);
    return v_plan || jsonb_build_object('outcome','CANCELLED','imported',true,'work_session_id',v_saved.work_session_id);
  end if;

  -- Not working: ABSENT in Finish, the person's Finish sessions of that shift cancelled.
  if v_action = 'ABSENT' then
    select to_jsonb(a) into v_att_old from public.finish_daily_staff_attendance a
    where a.business_date=(v_r->>'business_date')::date and a.shift_id=(v_r->>'shift_id')::uuid and a.staff_id=(v_r->>'staff_id')::uuid;
    insert into public.finish_daily_staff_attendance(business_date, shift_id, staff_id, attendance_status, absence_reason, notes, source)
    values ((v_r->>'business_date')::date, (v_r->>'shift_id')::uuid, (v_r->>'staff_id')::uuid, 'ABSENT', 'OTHER', v_r->>'notes', c_source)
    on conflict (business_date, shift_id, staff_id) do update
      set attendance_status='ABSENT', absence_reason='OTHER', notes=excluded.notes, source=c_source,
          updated_at=now(), updated_by_auth_user_id=null
    returning finish_daily_staff_attendance_id into v_att_id;
    update public.work_sessions ws
    set status='CANCELLED', notes=concat_ws(' | ', ws.notes, 'Absent: not working (legacy Finish).'),
        row_version=ws.row_version+1, updated_at=now()
    where ws.work_date=(v_r->>'business_date')::date and ws.shift_id=(v_r->>'shift_id')::uuid
      and ws.staff_id=(v_r->>'staff_id')::uuid and ws.status <> 'CANCELLED'
      and exists (select 1 from public.areas a where a.area_id=ws.area_id and a.area_code='FINISH');
    get diagnostics v_cancelled = row_count;
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (v_system, v_table, v_id, 'NOT_WORKING_TO_ATTENDANCE', 'public.finish_daily_staff_attendance', v_att_id,
      v_plan->>'fingerprint', p_sync_run_id, jsonb_build_object('cancelled_sessions', v_cancelled, 'warnings', v_plan->'warnings'));
    insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
    values ('IMPORT_LEGACY_NOT_WORKING', 'finish_daily_staff_attendance', v_att_id::text, v_att_old,
      (select to_jsonb(a) from public.finish_daily_staff_attendance a where a.finish_daily_staff_attendance_id=v_att_id)
        || jsonb_build_object('cancelled_sessions', v_cancelled),
      'Legacy sync: ' || (v_r->>'notes'), c_source, p_sync_run_id);
    return v_plan || jsonb_build_object('outcome','IMPORTED','imported',true,'finish_daily_staff_attendance_id',v_att_id,
      'cancelled_sessions', v_cancelled);
  end if;

  -- Attendance PRESENT (an ABSENT row is set back: the legacy session is newer evidence).
  if v_r->>'area' = 'FINISH' then
    insert into public.finish_daily_staff_attendance(business_date, shift_id, staff_id, attendance_status, notes, source)
    values ((v_r->>'business_date')::date, (v_r->>'shift_id')::uuid, (v_r->>'staff_id')::uuid, 'PRESENT',
      'Legacy Finish staff session.', c_source)
    on conflict (business_date, shift_id, staff_id) do update
      set attendance_status='PRESENT', absence_reason=null, source=c_source, updated_at=now(), updated_by_auth_user_id=null
      where public.finish_daily_staff_attendance.attendance_status='ABSENT';
  else
    insert into public.sorting_daily_staff_attendance(business_date, shift_id, staff_id, attendance_status, notes, source)
    values ((v_r->>'business_date')::date, (v_r->>'shift_id')::uuid, (v_r->>'staff_id')::uuid, 'PRESENT',
      'Legacy Sorting staff row.', c_source)
    on conflict (business_date, shift_id, staff_id) do update
      set attendance_status='PRESENT', absence_reason=null, source=c_source, updated_at=now(), updated_by_auth_user_id=null
      where public.sorting_daily_staff_attendance.attendance_status='ABSENT';
  end if;

  if v_action in ('UPDATE','ADOPT','ADOPT_AND_UPDATE') then
    select * into v_old from public.work_sessions where work_session_id=(v_plan#>>'{target,work_session_id}')::uuid for update;
    if v_old.status = 'CANCELLED' or v_old.row_version <> (v_plan#>>'{target,row_version}')::integer then
      raise exception using errcode='40001', message='The V2 work session changed during import. Retry.';
    end if;
    if v_action = 'ADOPT' then
      v_saved := v_old;
    else
      update public.work_sessions
      set station_id=(v_r->>'station_id')::uuid, actual_start_at=(v_r->>'actual_start_at')::timestamptz,
          actual_end_at=nullif(v_r->>'actual_end_at','')::timestamptz, break_minutes=(v_r->>'break_minutes')::integer,
          status=case when nullif(v_r->>'actual_end_at','') is null then 'OPEN' else 'CORRECTED' end,
          notes=v_r->>'notes', row_version=row_version+1, updated_at=now()
      where work_session_id=v_old.work_session_id returning * into v_saved;
      if v_r->>'area' = 'FINISH' then
        update public.finish_staff_table_segments
        set station_id=v_saved.station_id, started_at=v_saved.actual_start_at, ended_at=v_saved.actual_end_at, updated_at=now()
        where work_session_id=v_saved.work_session_id;
        if not found then
          insert into public.finish_staff_table_segments(work_session_id, station_id, started_at, ended_at, notes)
          values (v_saved.work_session_id, v_saved.station_id, v_saved.actual_start_at, v_saved.actual_end_at, v_r->>'notes');
        end if;
      end if;
    end if;
  else
    -- CREATE
    if v_r->>'area' = 'SORTING' then
      select pre.* into v_entry
      from public.production_roster_versions prv
      join public.roster_periods rp on rp.roster_period_id=prv.roster_period_id
       and rp.week_start=public.production_roster_week_start((v_r->>'business_date')::date)
      join public.production_roster_entries pre on pre.roster_version_id=prv.roster_version_id
       and pre.work_date=(v_r->>'business_date')::date and pre.staff_id=(v_r->>'staff_id')::uuid
      where prv.status='PUBLISHED' and prv.shift_id=(v_r->>'shift_id')::uuid
        and not exists (select 1 from public.work_sessions x where x.production_roster_entry_id=pre.roster_entry_id and x.status<>'CANCELLED')
      order by prv.published_at desc nulls last, prv.version_number desc
      limit 1;
    end if;
    insert into public.work_sessions(production_roster_entry_id, production_roster_version_id, work_date, staff_id, area_id,
      station_id, shift_id, actual_start_at, actual_end_at, break_minutes, extra_non_work_minutes, adjustment_reason,
      status, source, confirmed_by, notes, recorded_by_auth_user_id, row_version)
    values (v_entry.roster_entry_id, v_entry.roster_version_id, (v_r->>'business_date')::date, (v_r->>'staff_id')::uuid,
      (v_r->>'area_id')::uuid, (v_r->>'station_id')::uuid, (v_r->>'shift_id')::uuid,
      (v_r->>'actual_start_at')::timestamptz, nullif(v_r->>'actual_end_at','')::timestamptz, (v_r->>'break_minutes')::integer,
      0, 'NONE', case when nullif(v_r->>'actual_end_at','') is null then 'OPEN' else 'CONFIRMED' end,
      case v_r->>'area' when 'FINISH' then 'FINISH_V2' else 'SORTING_MANUAL_POSITION' end,
      null, v_r->>'notes', null, 1)
    returning * into v_saved;
    if v_r->>'area' = 'FINISH' then
      insert into public.finish_staff_table_segments(work_session_id, station_id, started_at, ended_at, notes)
      values (v_saved.work_session_id, v_saved.station_id, v_saved.actual_start_at, v_saved.actual_end_at, v_r->>'notes');
    end if;
  end if;

  if v_action in ('CREATE','ADOPT','ADOPT_AND_UPDATE') then
    insert into integration.legacy_sync_record_links(source_system, source_table, source_record_id, link_role,
      target_table, target_id, source_fingerprint, sync_run_id, link_metadata)
    values (v_system, v_table, v_id, 'STAFF_SESSION_TO_WORK_SESSION', 'public.work_sessions', v_saved.work_session_id,
      v_plan->>'fingerprint', p_sync_run_id,
      jsonb_build_object('action', v_action, 'adopted', v_action <> 'CREATE', 'warnings', v_plan->'warnings'));
  end if;
  insert into public.audit_log(action, entity_table, entity_id, old_data, new_data, reason, source_application, correlation_id)
  values (case v_action when 'CREATE' then 'IMPORT_LEGACY_STAFF_SESSION' when 'ADOPT' then 'ADOPT_LEGACY_STAFF_SESSION'
                        else 'CORRECT_LEGACY_STAFF_SESSION' end,
    'work_sessions', v_saved.work_session_id::text,
    case when v_old.work_session_id is not null then to_jsonb(v_old) end, to_jsonb(v_saved),
    'Legacy sync: ' || initcap(v_r->>'area') || ' staff ' || (v_r->>'staff_name') || '.', c_source, p_sync_run_id);

  return v_plan || jsonb_build_object('outcome', case v_action when 'CREATE' then 'IMPORTED' when 'UPDATE' then 'UPDATED'
      when 'ADOPT' then 'ADOPTED' else 'ADOPTED_AND_UPDATED' end,
    'imported', true, 'work_session_id', v_saved.work_session_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Dispatchers: add the kind "attendance".
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
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Access: service_role only
-- ---------------------------------------------------------------------
revoke all on function integration.legacy_sync_parse_clock(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_parse_minutes(text) from public, anon, authenticated;
revoke all on function integration.legacy_sync_plan_attendance(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_attendance_dry_run(jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_import_attendance(uuid, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_dry_run(text, jsonb) from public, anon, authenticated;
revoke all on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) from public, anon, authenticated;

grant execute on function integration.legacy_sync_attendance_dry_run(jsonb) to service_role;
grant execute on function integration.legacy_sync_import_attendance(uuid, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_dry_run(text, jsonb) to service_role;
grant execute on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) to service_role;

comment on function integration.legacy_sync_plan_attendance(jsonb) is
  'Read-only plan of one legacy attendance record (Finish StaffSessions / RosterNotWorking, Sorting Staff).';
comment on function integration.legacy_sync_attendance_dry_run(jsonb) is
  'Read-only dry run of 1-60 legacy attendance records.';
comment on function integration.legacy_sync_import_attendance(uuid, jsonb) is
  'Imports one legacy attendance record as V2 attendance and work session, behind ATTENDANCE_IMPORT. service_role only.';

commit;
