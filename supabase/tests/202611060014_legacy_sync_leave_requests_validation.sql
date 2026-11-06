-- Validation for 202611060014_legacy_sync_leave_requests.sql.
-- Run in the SQL Editor. It ends with an error that starts with "PASSED": the error
-- rolls back every change (test staff, driver, requests, sync run), so nothing is kept.
do $$
declare
  v_run uuid;
  v_staff uuid;
  v_driver uuid;
  v_abs uuid;
  v_req uuid;
  v_r jsonb;
  v_n int;
  v_a jsonb := jsonb_build_object('RequestID','VAL-LR-A','UserID','990101.0','Name','Val Leave','Type','Holiday',
                 'StartDate','2030-03-04','EndDate','2030-03-08','Reason','Family trip','Status','Pending',
                 'SubmittedAt','2030-01-02 10:00:00');
  v_b jsonb := jsonb_build_object('RequestID','VAL-LR-B','UserID','990101','Name','Val Leave','Type','Day Off',
                 'StartDate','2030-04-01','EndDate','2030-04-01','Status','Pending','SubmittedAt','2030-01-03 10:00:00');
  v_d jsonb := jsonb_build_object('RequestID','VAL-DLR-1','DriverID','990101.0','DriverName','Val Driver','LeaveType','Holiday',
                 'StartDate','2030-05-06','EndDate','2030-05-10','Status','Pending','Source','Driver Link');
begin
  update integration.legacy_sync_settings set enabled=true, max_entries_per_run=100 where setting_key='LEAVE_IMPORT';
  v_run := integration.legacy_sync_start_run('FINISH_AREA','COMMIT',current_date,current_date,'validation 202611060014');
  insert into public.staff_members(display_name, legacy_user_id, production_staff, active, roster_eligible)
  values ('Val Leave', 990101, true, true, true) returning staff_id into v_staff;
  insert into public.distribution_drivers(driver_code, display_name, legacy_driver_id, employment_status, availability_status)
  values ('VAL-990101', 'Val Driver', '990101', 'ACTIVE', 'AVAILABLE') returning driver_id into v_driver;

  -- 1. A legacy request V2 does not have is created, pending, with its history event.
  v_r := integration.legacy_sync_import_leave(v_run, jsonb_build_object('record_type','PRODUCTION_LEAVE','source_record_id','VAL-LR-A','row',v_a));
  select leave_request_id into v_req from public.production_roster_leave_requests
  where staff_id = v_staff and request_type = 'HOLIDAY' and start_date = '2030-03-04' and end_date = '2030-03-08'
    and status = 'PENDING' and source_application = 'LEGACY_SYNC' and reason = 'Family trip';
  if v_r->>'outcome' <> 'IMPORTED' or v_req is null
     or not exists (select 1 from public.production_roster_leave_request_events e
                    where e.leave_request_id = v_req and e.event_type = 'LEGACY_SYNC_IMPORTED') then
    raise exception 'FAILED 1: %', v_r;
  end if;

  -- 2. The same row again: nothing to do.
  if integration.legacy_sync_plan_leave(jsonb_build_object('record_type','PRODUCTION_LEAVE','source_record_id','VAL-LR-A','row',v_a))->>'outcome'
     <> 'ALREADY_IMPORTED' then
    raise exception 'FAILED 2';
  end if;

  -- 3. Approved in the legacy app: V2 takes the decision; an email is never stored in clear.
  v_a := v_a || '{"Status":"Approved","DecidedAt":"2030-01-05 09:00:00","DecidedBy":"val.manager@example.com"}';
  v_r := integration.legacy_sync_import_leave(v_run, jsonb_build_object('record_type','PRODUCTION_LEAVE','source_record_id','VAL-LR-A','row',v_a));
  if v_r->>'outcome' <> 'UPDATED' or not exists (
       select 1 from public.production_roster_leave_requests where leave_request_id = v_req and status = 'APPROVED'
         and decision_source = 'MANAGER' and decision_actor = 'va***@e***.com' and reviewed_at is not null) then
    raise exception 'FAILED 3: %', v_r;
  end if;

  -- 4. A reason changed in the legacy app is written; the decision taken in V2 is kept.
  update public.production_roster_leave_requests set status = 'REJECTED' where leave_request_id = v_req;
  v_a := v_a || '{"Reason":"Family trip abroad"}';
  v_r := integration.legacy_sync_import_leave(v_run, jsonb_build_object('record_type','PRODUCTION_LEAVE','source_record_id','VAL-LR-A','row',v_a));
  if v_r->>'outcome' <> 'UPDATED' or not exists (
       select 1 from public.production_roster_leave_requests where leave_request_id = v_req and status = 'REJECTED'
         and reason = 'Family trip abroad') then
    raise exception 'FAILED 4: %', v_r;
  end if;

  -- 5. New dates in the legacy app for a request V2 decided differently: held for review.
  v_a := v_a || '{"EndDate":"2030-03-11"}';
  v_r := integration.legacy_sync_import_leave(v_run, jsonb_build_object('record_type','PRODUCTION_LEAVE','source_record_id','VAL-LR-A','row',v_a));
  if v_r->>'outcome' <> 'BLOCKED' or not (v_r->'blockers') @> '[{"code":"LEAVE_DECIDED_DIFFERENTLY_IN_V2"}]'
     or not exists (select 1 from integration.legacy_sync_review_items where source_table = 'LeaveRequests'
                    and source_record_id = 'VAL-LR-A' and reason_code = 'LEAVE_DECIDED_DIFFERENTLY_IN_V2' and status = 'OPEN')
     or (select end_date from public.production_roster_leave_requests where leave_request_id = v_req) <> '2030-03-08' then
    raise exception 'FAILED 5: %', v_r;
  end if;

  -- 6. A request still pending in the legacy app never reopens one approved in V2.
  v_r := integration.legacy_sync_import_leave(v_run, jsonb_build_object('record_type','PRODUCTION_LEAVE','source_record_id','VAL-LR-B','row',v_b));
  update public.production_roster_leave_requests set status = 'APPROVED'
  where staff_id = v_staff and start_date = '2030-04-01';
  v_b := v_b || '{"Reason":"Appointment"}';
  v_r := integration.legacy_sync_import_leave(v_run, jsonb_build_object('record_type','PRODUCTION_LEAVE','source_record_id','VAL-LR-B','row',v_b));
  if v_r->>'outcome' <> 'UPDATED' or (v_r->'changes') ? 'status'
     or not exists (select 1 from public.production_roster_leave_requests where staff_id = v_staff
                    and start_date = '2030-04-01' and status = 'APPROVED' and reason = 'Appointment') then
    raise exception 'FAILED 6: %', v_r;
  end if;

  -- 6b. First sync (no baseline): an absence approved in V2 stays approved, with a warning.
  insert into public.distribution_driver_absences(driver_id, absence_type, starts_on, ends_on, absence_status, notes)
  values (v_driver, 'HOLIDAY', '2030-06-03', '2030-06-04', 'APPROVED', '[Legacy request: VAL-DLR-2; Reviewed by: n/a; Source: Driver Link]');
  v_r := integration.legacy_sync_plan_leave(jsonb_build_object('record_type','DRIVER_LEAVE','source_record_id','VAL-DLR-2',
           'row', v_d || '{"RequestID":"VAL-DLR-2","StartDate":"2030-06-03","EndDate":"2030-06-04"}'));
  if not (v_r->'warnings') @> '[{"code":"DECIDED_IN_V2_FIRST"}]' or (v_r->'changes') ? 'status' then
    raise exception 'FAILED 6b: %', v_r;
  end if;

  -- 7. Held, never guessed: overlap with an approved request, unknown person, Day Off over several days.
  v_r := integration.legacy_sync_plan_leave(jsonb_build_object('record_type','PRODUCTION_LEAVE','source_record_id','VAL-LR-C',
           'row', v_b || '{"RequestID":"VAL-LR-C"}'));
  if not (v_r->'blockers') @> '[{"code":"LEAVE_OVERLAPS_IN_V2"}]' then raise exception 'FAILED 7a: %', v_r; end if;
  v_r := integration.legacy_sync_plan_leave(jsonb_build_object('record_type','PRODUCTION_LEAVE','source_record_id','VAL-LR-D',
           'row', v_b || '{"UserID":"990199","EndDate":"2030-04-03"}'));
  if not (v_r->'blockers') @> '[{"code":"STAFF_NOT_IN_V2"},{"code":"INVALID_LEAVE_DATES"}]' then raise exception 'FAILED 7b: %', v_r; end if;

  -- 8. A driver absence imported earlier is adopted by its "[Legacy request: …" note.
  insert into public.distribution_driver_absences(driver_id, absence_type, starts_on, ends_on, absence_status, notes)
  values (v_driver, 'HOLIDAY', '2030-05-06', '2030-05-10', 'REQUESTED', '[Legacy request: VAL-DLR-1; Reviewed by: n/a; Source: Driver Link]')
  returning absence_id into v_abs;
  v_r := integration.legacy_sync_import_leave(v_run, jsonb_build_object('record_type','DRIVER_LEAVE','source_record_id','VAL-DLR-1','row',v_d));
  if v_r->>'outcome' <> 'ADOPTED' or (v_r->>'target_id')::uuid <> v_abs then raise exception 'FAILED 8: %', v_r; end if;

  -- 9. Approved in the legacy app: the absence is approved; its note keeps the legacy reference.
  v_d := v_d || '{"Status":"Approved","ReviewedBy":"Claudia"}';
  v_r := integration.legacy_sync_import_leave(v_run, jsonb_build_object('record_type','DRIVER_LEAVE','source_record_id','VAL-DLR-1','row',v_d));
  if v_r->>'outcome' <> 'UPDATED' or not exists (select 1 from public.distribution_driver_absences where absence_id = v_abs
       and absence_status = 'APPROVED' and notes = '[Legacy request: VAL-DLR-1; Reviewed by: Claudia; Source: Driver Link]') then
    raise exception 'FAILED 9: % %', v_r, (select notes || '|' || absence_status from public.distribution_driver_absences where absence_id = v_abs);
  end if;

  -- 10. Switch off: refused. No client role can call the importer.
  update integration.legacy_sync_settings set enabled=false where setting_key='LEAVE_IMPORT';
  begin
    perform integration.legacy_sync_import_leave(v_run, jsonb_build_object('record_type','DRIVER_LEAVE','source_record_id','VAL-DLR-1','row',v_d));
    raise exception 'FAILED 10: imported with the switch off';
  exception when object_not_in_prerequisite_state then null; end;
  if has_function_privilege('authenticated','integration.legacy_sync_import_leave(uuid,jsonb)','execute')
     or has_function_privilege('anon','integration.legacy_sync_leave_dry_run(jsonb)','execute')
     or has_function_privilege('authenticated','integration.legacy_sync_leave_write_production(uuid,uuid,jsonb,jsonb,text)','execute') then
    raise exception 'FAILED 10b: a client role can call the leave sync';
  end if;

  -- 11. Every write is audited with the run: A created, approved, reason; B created, reason; driver approved.
  select count(*) into v_n from public.audit_log where correlation_id = v_run and source_application = 'LEGACY_SYNC_LEAVE';
  if v_n <> 6 then raise exception 'FAILED 11: % audit rows', v_n; end if;

  raise exception 'PASSED: 202611060014 legacy sync leave requests (11 checks)';
end;
$$;
