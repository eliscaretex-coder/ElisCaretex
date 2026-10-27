-- ElisCaretex V2 - Validation - 202610270010_legacy_sync_attendance
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all 16 legacy sync attendance checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_day date := (now() at time zone 'Europe/Dublin')::date - 2;
  v_s1 public.staff_members%rowtype;
  v_s2 public.staff_members%rowtype;
  v_morning uuid;
  v_sorting_area uuid;
  v_sorting_station uuid;
  v_session jsonb;
  v_sorting jsonb;
  v_run uuid;
  v_ws uuid;
  v jsonb;
  v_state text;
  n integer := 0;
begin
  perform set_config('request.jwt.claims', '', true);
  if v_day = date '2026-10-25' then v_day := v_day - 1; end if;

  -- Fixtures: two active production staff with a unique display name and no V2 work or
  -- attendance on the day.
  select sm.* into v_s1 from public.staff_members sm
  where sm.deleted_at is null and sm.active and sm.production_staff and sm.roster_eligible
    and (select count(*) from public.staff_members x where x.deleted_at is null
         and lower(btrim(x.display_name)) = lower(btrim(sm.display_name))) = 1
    and not exists (select 1 from public.work_sessions ws where ws.staff_id=sm.staff_id and ws.work_date=v_day)
    and not exists (select 1 from public.finish_daily_staff_attendance a where a.staff_id=sm.staff_id and a.business_date=v_day)
    and not exists (select 1 from public.sorting_daily_staff_attendance a where a.staff_id=sm.staff_id and a.business_date=v_day)
    and not exists (select 1 from public.finish_production_entries e where e.processed_by_staff_id=sm.staff_id and e.production_business_date=v_day)
  order by sm.display_name limit 1;
  select sm.* into v_s2 from public.staff_members sm
  where sm.deleted_at is null and sm.active and sm.production_staff and sm.roster_eligible and sm.staff_id <> v_s1.staff_id
    and (select count(*) from public.staff_members x where x.deleted_at is null
         and lower(btrim(x.display_name)) = lower(btrim(sm.display_name))) = 1
    and not exists (select 1 from public.work_sessions ws where ws.staff_id=sm.staff_id and ws.work_date=v_day)
    and not exists (select 1 from public.sorting_daily_staff_attendance a where a.staff_id=sm.staff_id and a.business_date=v_day)
  order by sm.display_name desc limit 1;
  select shift_id into v_morning from public.shifts where shift_code='MORNING' and deleted_at is null;
  select area_id into v_sorting_area from public.areas where area_code='SORTING' and deleted_at is null;
  select st.station_id into v_sorting_station from public.stations st where st.station_code='SORTING_MAIN' and st.deleted_at is null;
  if v_s2.staff_id is null or v_morning is null or v_sorting_area is null then
    raise exception 'FAIL: fixtures (two staff, shift, Sorting area)'; end if;

  v_session := jsonb_build_object('record_type', 'FINISH_SESSION', 'source_record_id', 'SS-VALATT-1', 'row', jsonb_build_object(
    'SessionID', 'SS-VALATT-1', 'CreatedAt', to_char(v_day, 'YYYY-MM-DD') || 'T07:05:00', 'BusinessDate', to_char(v_day, 'YYYY-MM-DD'),
    'Shift', 'Morning', 'TableID', 'Table 2', 'UserName', v_s1.display_name, 'StartTime', '07:00:00', 'EndTime', '15:00:00',
    'BreakMin', '45', 'SessionType', 'Regular', 'Status', 'OPEN'));
  v_sorting := jsonb_build_object('record_type', 'SORTING_STAFF',
    'source_record_id', to_char(v_day, 'YYYY-MM-DD') || '|Morning|' || lower(v_s2.display_name), 'row', jsonb_build_object(
    'BusinessDate', to_char(v_day, 'YYYY-MM-DD'), 'Shift', 'Morning', 'Name', v_s2.display_name, 'StartShift', '07:00:00',
    'EndShift', '15:00:00', 'Break', '00:45:00', 'WorkPosition', 'MOPs', 'EnteredAt', to_char(v_day, 'YYYY-MM-DD') || 'T07:20:00'));

  -- 1. Access surface
  if has_function_privilege('authenticated','integration.legacy_sync_import_attendance(uuid,jsonb)','execute')
     or has_function_privilege('anon','integration.legacy_sync_attendance_dry_run(jsonb)','execute')
     or not has_function_privilege('service_role','integration.legacy_sync_import_attendance(uuid,jsonb)','execute') then
    raise exception 'FAIL: only the service role calls the attendance importer'; end if;
  n := n + 1;

  -- 2. Dry run
  v := integration.legacy_sync_dispatch_dry_run('attendance', jsonb_build_array(v_session, v_sorting));
  if not ((v->>'ready')::int = 2 and (v->>'writes_performed')::int = 0
          and v->'actions' @> '{"FINISH_SESSION:CREATE":1,"SORTING_STAFF:CREATE":1}') then
    raise exception 'FAIL: dry run plans two CREATE (got %)', v; end if;
  n := n + 1;

  -- 3. Switch OFF refuses writes
  v_run := integration.legacy_sync_start_run('FINISH_AREA', 'COMMIT', v_day, v_day, 'validation');
  begin perform integration.legacy_sync_import_attendance(v_run, v_session); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '55000' then raise exception 'FAIL: switch OFF refuses the import (got %)', v_state; end if;
  n := n + 1;
  update integration.legacy_sync_settings set enabled=true where setting_key='ATTENDANCE_IMPORT';

  -- 4. Finish session: attendance, work session at the table, segment.
  v := integration.legacy_sync_dispatch_import('attendance', v_run, v_session);
  if v->>'outcome' <> 'IMPORTED' then raise exception 'FAIL: Finish session import (got %)', v; end if;
  v_ws := (v->>'work_session_id')::uuid;
  if not exists (select 1 from public.work_sessions ws join public.stations st on st.station_id=ws.station_id
                 join public.finish_staff_table_segments sg on sg.work_session_id=ws.work_session_id
                 where ws.work_session_id=v_ws and ws.status='CONFIRMED' and ws.source='FINISH_V2' and st.station_code='FINISH_TABLE_2'
                   and ws.break_minutes=45 and ws.actual_start_at=public.operational_timestamp_for_shift(v_day,'MORNING',time '07:00')
                   and ws.actual_end_at=public.operational_timestamp_for_shift(v_day,'MORNING',time '15:00'))
     or not exists (select 1 from public.finish_daily_staff_attendance a where a.staff_id=v_s1.staff_id and a.business_date=v_day
                    and a.shift_id=v_morning and a.attendance_status='PRESENT') then
    raise exception 'FAIL: Finish session writes attendance, work session and segment'; end if;
  n := n + 1;

  -- 5. Idempotent
  if integration.legacy_sync_import_attendance(v_run, v_session)->>'outcome' <> 'ALREADY_IMPORTED' then
    raise exception 'FAIL: a second import does nothing'; end if;
  n := n + 1;

  -- 6. A changed legacy session corrects the work session.
  v := integration.legacy_sync_import_attendance(v_run, jsonb_set(v_session, '{row,EndTime}', '"14:00:00"'));
  if v->>'outcome' <> 'UPDATED' or not exists (select 1 from public.work_sessions ws
       join public.finish_staff_table_segments sg on sg.work_session_id=ws.work_session_id
       where ws.work_session_id=v_ws and ws.status='CORRECTED'
         and ws.actual_end_at=public.operational_timestamp_for_shift(v_day,'MORNING',time '14:00') and sg.ended_at=ws.actual_end_at) then
    raise exception 'FAIL: legacy change corrects the session (got %)', v; end if;
  n := n + 1;

  -- 7. A cancelled legacy session cancels it.
  v := integration.legacy_sync_import_attendance(v_run, jsonb_set(v_session, '{row,Status}', '"CANCELLED"'));
  if v->>'outcome' <> 'CANCELLED' or (select status from public.work_sessions where work_session_id=v_ws) <> 'CANCELLED' then
    raise exception 'FAIL: legacy cancellation (got %)', v; end if;
  n := n + 1;

  -- 8. Sorting staff row: attendance and work session with the legacy break.
  v := integration.legacy_sync_import_attendance(v_run, v_sorting);
  if v->>'outcome' <> 'IMPORTED' or not exists (select 1 from public.work_sessions ws
       where ws.work_session_id=(v->>'work_session_id')::uuid and ws.area_id=v_sorting_area and ws.source='SORTING_MANUAL_POSITION'
         and ws.break_minutes=45 and ws.status='CONFIRMED' and ws.notes like '%MOPs%')
     or not exists (select 1 from public.sorting_daily_staff_attendance a where a.staff_id=v_s2.staff_id and a.business_date=v_day
                    and a.shift_id=v_morning and a.attendance_status='PRESENT') then
    raise exception 'FAIL: Sorting staff row (got %)', v; end if;
  n := n + 1;

  -- 9. A Sorting work session typed in V2 is adopted and takes the legacy times.
  insert into public.work_sessions(work_date, staff_id, area_id, station_id, shift_id, actual_start_at, actual_end_at, status, source)
  values (v_day, v_s1.staff_id, v_sorting_area, v_sorting_station, v_morning,
    public.operational_timestamp_for_shift(v_day,'MORNING',time '15:00'), public.operational_timestamp_for_shift(v_day,'MORNING',time '18:00'),
    'CONFIRMED', 'SORTING_MANUAL_POSITION') returning work_session_id into v_ws;
  v := integration.legacy_sync_import_attendance(v_run, jsonb_build_object('record_type', 'SORTING_STAFF',
    'source_record_id', to_char(v_day, 'YYYY-MM-DD') || '|Morning|' || lower(v_s1.display_name), 'row', jsonb_build_object(
    'BusinessDate', to_char(v_day, 'YYYY-MM-DD'), 'Shift', 'Morning', 'Name', v_s1.display_name, 'StartShift', '15:00',
    'EndShift', '19:00', 'Break', '0')));
  if v->>'outcome' <> 'ADOPTED_AND_UPDATED' or (v->>'work_session_id')::uuid <> v_ws
     or not (v->'warnings' @> '[{"code":"V2_TIMES_REPLACED"}]')
     or (select actual_end_at from public.work_sessions where work_session_id=v_ws)
        <> public.operational_timestamp_for_shift(v_day,'MORNING',time '19:00') then
    raise exception 'FAIL: V2 session adopted with legacy times (got %)', v; end if;
  n := n + 1;

  -- 10. More than 13 hours in one day is held.
  v := integration.legacy_sync_plan_attendance(jsonb_build_object('record_type', 'SORTING_STAFF',
    'source_record_id', to_char(v_day, 'YYYY-MM-DD') || '|Evening|' || lower(v_s1.display_name), 'row', jsonb_build_object(
    'BusinessDate', to_char(v_day, 'YYYY-MM-DD'), 'Shift', 'Evening', 'Name', v_s1.display_name, 'StartShift', '12:00',
    'EndShift', '23:30', 'Break', '30')));
  if not (v->'blockers' @> '[{"code":"WORK_OVER_13_HOURS"}]') then raise exception 'FAIL: 13-hour day is held (got %)', v; end if;
  n := n + 1;

  -- 11. Not working: Finish ABSENT and the Finish sessions of the shift cancelled.
  v := integration.legacy_sync_import_attendance(v_run, jsonb_set(jsonb_set(v_session, '{source_record_id}', '"SS-VALATT-2"'),
         '{row,SessionID}', '"SS-VALATT-2"'));
  v_ws := (v->>'work_session_id')::uuid;
  v := integration.legacy_sync_import_attendance(v_run, jsonb_build_object('record_type', 'FINISH_NOT_WORKING',
    'source_record_id', 'RNW-VALATT-1', 'row', jsonb_build_object('DismissalID', 'RNW-VALATT-1',
    'CreatedAt', to_char(v_day, 'YYYY-MM-DD') || 'T08:00:00', 'BusinessDate', to_char(v_day, 'YYYY-MM-DD'), 'Shift', 'Morning',
    'TableID', 'Table 2', 'UserName', v_s1.display_name, 'Reason', 'Not working', 'Status', 'NOT_WORKING')));
  if v->>'outcome' <> 'IMPORTED' or not (v->'warnings' @> '[{"code":"PRESENT_REPLACED"}]')
     or not exists (select 1 from public.finish_daily_staff_attendance a where a.staff_id=v_s1.staff_id and a.business_date=v_day
                    and a.shift_id=v_morning and a.attendance_status='ABSENT' and a.absence_reason='OTHER')
     or (select status from public.work_sessions where work_session_id=v_ws) <> 'CANCELLED' then
    raise exception 'FAIL: not working marks ABSENT and cancels the session (got %)', v; end if;
  n := n + 1;

  -- 12. A session typed after it sets PRESENT again.
  v := integration.legacy_sync_import_attendance(v_run, jsonb_set(jsonb_set(v_session, '{source_record_id}', '"SS-VALATT-3"'),
         '{row,SessionID}', '"SS-VALATT-3"'));
  if v->>'outcome' <> 'IMPORTED' or not (v->'warnings' @> '[{"code":"ABSENCE_REPLACED"}]')
     or not exists (select 1 from public.finish_daily_staff_attendance a where a.staff_id=v_s1.staff_id and a.business_date=v_day
                    and a.shift_id=v_morning and a.attendance_status='PRESENT') then
    raise exception 'FAIL: a newer session sets PRESENT again (got %)', v; end if;
  n := n + 1;

  -- 13. Unknown person goes to the review queue.
  v := integration.legacy_sync_import_attendance(v_run, jsonb_set(jsonb_set(jsonb_set(v_session, '{source_record_id}', '"SS-VALATT-4"'),
         '{row,SessionID}', '"SS-VALATT-4"'), '{row,UserName}', '"Nobody Validation Person"'));
  if v->>'outcome' <> 'BLOCKED' or not exists (select 1 from integration.legacy_sync_review_items
       where source_system='FINISH_AREA' and source_table='StaffSessions' and source_record_id='SS-VALATT-4'
         and reason_code='STAFF_UNMATCHED' and status='OPEN') then
    raise exception 'FAIL: unknown person is held (got %)', v; end if;
  n := n + 1;

  -- 14. Unknown table and owner test day.
  v := integration.legacy_sync_plan_attendance(jsonb_set(jsonb_set(jsonb_set(v_session, '{source_record_id}', '"SS-VALATT-5"'),
         '{row,SessionID}', '"SS-VALATT-5"'), '{row,TableID}', '"Table 9"'));
  if not (v->'blockers' @> '[{"code":"TABLE_UNMAPPED"}]') then raise exception 'FAIL: unknown table is held (got %)', v; end if;
  v := integration.legacy_sync_plan_attendance(jsonb_set(jsonb_set(jsonb_set(v_session, '{source_record_id}', '"SS-VALATT-6"'),
         '{row,SessionID}', '"SS-VALATT-6"'), '{row,BusinessDate}', '"2026-10-25"'));
  if v->>'skip_reason' is distinct from 'OWNER_TEST_DAY' then raise exception 'FAIL: 2026-10-25 is skipped (got %)', v; end if;
  n := n + 1;

  -- 15. Parsers of legacy times and breaks.
  if integration.legacy_sync_parse_clock('07:20') <> time '07:20' or integration.legacy_sync_parse_clock('7:05:30') <> time '07:05:30'
     or integration.legacy_sync_parse_minutes('00:45:00') <> 45 or integration.legacy_sync_parse_minutes('30.0') <> 30
     or integration.legacy_sync_parse_clock('late') is not null then
    raise exception 'FAIL: time and break parsers'; end if;
  n := n + 1;

  -- 16. Control switches it, accounts are refused
  v := integration.legacy_sync_control('OFF', 'validation');
  if (v->'imports'->>'ATTENDANCE_IMPORT')::boolean then raise exception 'FAIL: OFF also disables the attendance import'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  begin perform integration.legacy_sync_import_attendance(v_run, v_session); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: an account is refused (got %)', v_state; end if;
  n := n + 1;

  raise exception 'PASSED: all % legacy sync attendance checks (nothing was kept)', n;
end;
$$;
