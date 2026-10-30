-- Validation for 202610300002_legacy_sync_rosters.sql.
-- Run in the SQL Editor. It ends with an error that starts with "PASSED": the error
-- rolls back every change (test people, drivers, vehicle, rosters, runs), so nothing is kept.
-- The test weeks are in 2030, far from any real roster.
do $$
declare
  v_run uuid;
  v_morning uuid := (select shift_id from public.shifts where shift_code = 'MORNING');
  v_go uuid := (select operational_role_id from public.operational_roles where role_code = 'GENERAL_OPERATIVE');
  v_tl uuid := (select operational_role_id from public.operational_roles where role_code = 'TEAM_LEADER');
  v_finish uuid := (select area_id from public.areas where area_code = 'FINISH');
  v_sorting uuid := (select area_id from public.areas where area_code = 'SORTING');
  v_a uuid; v_b uuid; v_c uuid; v_d uuid;
  v_dr1 uuid; v_dr2 uuid;
  v_week date := date '2030-01-07';
  v_week2 date := date '2030-01-14';
  v_users jsonb := '[{"id":"990001","user":"Val A","position":"General Operative - Table 1"},
                     {"id":"990002","user":"Val B","position":"Sorting Area"},
                     {"id":"990003","user":"Val C","position":"Team Leader - Table 2"}]';
  v_cells jsonb := '{"2030-01-08::990001":{"status":"Off","position":"General Operative - Table 1","notes":""},
                     "2030-01-07::990002":{"status":"Working","position":"Sorting Area","notes":"svc=MOP"},
                     "2030-01-09::990001":{"status":"Working","position":"General Operative - Table 3","notes":""},
                     "2030-01-10::Val C":{"status":"Holiday","position":"Team Leader - Table 2","notes":""}}';
  v_rec jsonb;
  v_r jsonb;
  v_have jsonb;
  v_v1 uuid;
  v_v2 uuid;
  v_n int;
begin
  update integration.legacy_sync_settings set enabled=true, max_entries_per_run=40 where setting_key='ROSTER_IMPORT';
  v_run := integration.legacy_sync_start_run('FINISH_AREA','COMMIT',current_date,current_date,'validation 0002 rosters');

  insert into public.staff_members(display_name, legacy_user_id, production_staff, active, roster_eligible, default_shift_id,
    primary_operational_role_id, default_area_id, default_station_id)
  values ('Val A', 990001, true, true, true, v_morning, v_go, v_finish,
          (select station_id from public.stations where station_code='FINISH_TABLE_1')) returning staff_id into v_a;
  insert into public.staff_members(display_name, legacy_user_id, production_staff, active, roster_eligible, default_shift_id,
    primary_operational_role_id, default_area_id, default_station_id)
  values ('Val B', 990002, true, true, true, v_morning, v_go, v_sorting,
          (select station_id from public.stations where station_code='SORTING_MAIN')) returning staff_id into v_b;
  insert into public.staff_members(display_name, legacy_user_id, production_staff, active, roster_eligible, default_shift_id,
    primary_operational_role_id, default_area_id, default_station_id)
  values ('Val C', 990003, true, true, true, v_morning, v_tl, v_finish,
          (select station_id from public.stations where station_code='FINISH_TABLE_2')) returning staff_id into v_c;
  insert into public.staff_members(display_name, production_staff, active, roster_eligible, default_shift_id,
    primary_operational_role_id, default_area_id, default_station_id)
  values ('Val D (V2 only)', true, true, true, v_morning, v_go, v_finish,
          (select station_id from public.stations where station_code='FINISH_TABLE_3')) returning staff_id into v_d;

  v_rec := jsonb_build_object('record_type','PRODUCTION_ROSTER','source_record_id','2030-01-07|Morning',
    'row', jsonb_build_object('HasSunday','No','data', jsonb_build_object('meta', '{"saveMode":"selected_shift_snapshot"}'::jsonb,
      'usersSnapshot', v_users, 'cells', v_cells)));

  -- 1. A week the legacy app saved and V2 does not have: version 1, published, equal to the
  --    legacy week (default cells, a cell keyed by name, a day on another table, Sorting MOP).
  v_r := integration.legacy_sync_import_roster(v_run, v_rec);
  select prv.roster_version_id into v_v1 from public.production_roster_versions prv
  join public.roster_periods rp using (roster_period_id)
  where rp.week_start = v_week and prv.shift_id = v_morning and prv.status = 'PUBLISHED' and prv.version_number = 1;
  if v_r->>'outcome' <> 'IMPORTED' or v_v1 is null then raise exception 'FAILED 1: %', v_r; end if;
  v_have := integration.legacy_sync_roster_production_have(v_v1);
  if v_have <> (integration.legacy_sync_roster_production_want(v_rec->'row', v_week))->'want'
     or (select count(*) from public.production_roster_entries where roster_version_id = v_v1) <> 18 then
    raise exception 'FAILED 1b: %', v_have;
  end if;
  if v_have->>'2030-01-08|990001' <> 'OFF|BASE||||'
     or v_have->>'2030-01-09|990001' <> 'WORKING|BASE|GENERAL_OPERATIVE|FINISH|FINISH_TABLE_3|'
     or v_have->>'2030-01-10|990003' <> 'HOLIDAY|BASE||||'
     or v_have->>'2030-01-11|990003' <> 'WORKING|BASE|TEAM_LEADER|FINISH|FINISH_TABLE_2|'
     or v_have->>'2030-01-07|990002' <> 'WORKING|BASE|SORTING_AREA|SORTING|SORTING_MAIN|MOP'
     or v_have->>'S|990003' <> 'FINISH_TABLE_2' then
    raise exception 'FAILED 1c: legacy reading rule %', v_have;
  end if;

  -- 2. The same week again: nothing to do.
  if integration.legacy_sync_plan_roster(v_rec)->>'outcome' <> 'ALREADY_IMPORTED' then raise exception 'FAILED 2'; end if;

  -- 3. V2 changed Wednesday of A by hand; the legacy app changed Friday of C.
  --    The legacy change is a new version; the V2 change is kept; the previous one is superseded.
  v_v2 := integration.legacy_sync_roster_publish_production(v_week, v_morning, v_v1,
            integration.legacy_sync_roster_production_have(v_v1) || '{"2030-01-09|990001":"OFF|BASE||||"}'::jsonb, 'validation manual edit');
  v_rec := jsonb_set(v_rec, '{row,data,cells,2030-01-11::990003}', '{"status":"Off","position":"Team Leader - Table 2","notes":""}');
  v_r := integration.legacy_sync_import_roster(v_run, v_rec);
  v_have := integration.legacy_sync_roster_production_have((v_r->>'target_id')::uuid);
  if v_r->>'outcome' <> 'UPDATED' or v_have->>'2030-01-11|990003' <> 'OFF|BASE||||'
     or v_have->>'2030-01-09|990001' <> 'OFF|BASE||||' then
    raise exception 'FAILED 3: % / %', v_r - 'changes', v_have;
  end if;
  if (select status from public.production_roster_versions where roster_version_id = v_v2) <> 'SUPERSEDED'
     or (select status from public.production_roster_versions where roster_version_id = (v_r->>'target_id')::uuid) <> 'PUBLISHED' then
    raise exception 'FAILED 3b: versions not superseded/published';
  end if;

  -- 4. First meeting with a week V2 already has: the legacy roster wins, a V2-only person goes.
  v_v1 := integration.legacy_sync_roster_publish_production(v_week2, v_morning, null,
            jsonb_build_object('sunday', false, 'S|staff:' || v_d, 'FINISH_TABLE_3')
            || (select jsonb_object_agg((v_week2 + d)::text || '|staff:' || v_d, 'WORKING|BASE|GENERAL_OPERATIVE|FINISH|FINISH_TABLE_3|')
                from generate_series(0, 5) d), 'validation V2 week');
  v_r := integration.legacy_sync_import_roster(v_run, jsonb_set(jsonb_set(v_rec, '{source_record_id}', '"2030-01-14|MORNING"'),
           '{row,data,cells}', '{}'));
  v_have := integration.legacy_sync_roster_production_have((v_r->>'target_id')::uuid);
  if v_r->>'outcome' <> 'UPDATED' or v_r->>'baseline' <> 'LEGACY_WINS_FIRST_TIME' or v_have ? ('S|staff:' || v_d)
     or not v_have ? 'S|990001' then
    raise exception 'FAILED 4: % / %', v_r - 'changes', v_have;
  end if;

  -- 5. An open draft in the Production Roster holds the week for review.
  insert into public.production_roster_versions(roster_period_id, shift_id, version_number, status, include_sunday)
  select rp.roster_period_id, v_morning, 99, 'DRAFT', false from public.roster_periods rp where rp.week_start = v_week;
  v_r := integration.legacy_sync_import_roster(v_run, jsonb_set(v_rec, '{row,data,cells,2030-01-12::990001}',
           '{"status":"Off","position":"General Operative - Table 1","notes":""}'));
  if v_r->>'outcome' <> 'BLOCKED' or not (v_r->'blockers') @> '[{"code":"ROSTER_DRAFT_OPEN_IN_V2"}]'
     or not exists (select 1 from integration.legacy_sync_review_items where source_table='RosterStoreV2'
                    and source_record_id='2030-01-07|MORNING' and reason_code='ROSTER_DRAFT_OPEN_IN_V2' and status='OPEN') then
    raise exception 'FAILED 5: %', v_r;
  end if;

  -- 6. Weeks the sync cannot take are held or skipped, never guessed.
  v_r := integration.legacy_sync_plan_roster(jsonb_set(jsonb_set(v_rec, '{source_record_id}', '"2030-01-21|MORNING"'),
           '{row,data,usersSnapshot}', v_users || '[{"id":"990099","user":"Nobody","position":"Label"}]'));
  if not (v_r->'blockers') @> '[{"code":"STAFF_NOT_IN_V2"}]' then raise exception 'FAILED 6a: %', v_r; end if;
  v_r := integration.legacy_sync_plan_roster(jsonb_set(jsonb_set(v_rec, '{source_record_id}', '"2030-01-21|MORNING"'),
           '{row,data,cells,2030-01-22::990002}', '{"status":"Working","position":"Sorting Area","notes":"svc=CLO"}'));
  if not (v_r->'blockers') @> '[{"code":"SORTING_MOP_UNDECIDED"}]' then raise exception 'FAILED 6b: %', v_r; end if;
  v_r := integration.legacy_sync_plan_roster(jsonb_set(jsonb_set(v_rec, '{source_record_id}', '"2030-01-21|MORNING"'),
           '{row,data,cells,2030-01-23::990003}', '{"status":"Cover","position":"Team Leader - Table 2","notes":"cover=SP"}'));
  if not (v_r->'blockers') @> '[{"code":"COVER_NOT_AUTHORISED"}]' then raise exception 'FAILED 6c: %', v_r; end if;
  if integration.legacy_sync_plan_roster(jsonb_set(v_rec, '{row,data,meta}', '{}'))->>'skip_reason' <> 'NOT_PLANNED_IN_LEGACY'
     or integration.legacy_sync_plan_roster(jsonb_set(v_rec, '{source_record_id}', '"2020-01-06|MORNING"'))->>'skip_reason' <> 'PAST_WEEK' then
    raise exception 'FAILED 6d: skips';
  end if;

  -- 7. Distribution: a new week is published and its daily route runs follow it.
  insert into public.distribution_drivers(driver_code, display_name, legacy_driver_id, employment_status, availability_status)
  values ('VAL-990001', 'Val Driver 1', '990001', 'ACTIVE', 'AVAILABLE') returning driver_id into v_dr1;
  insert into public.distribution_drivers(driver_code, display_name, legacy_driver_id, employment_status, availability_status)
  values ('VAL-990002', 'Val Driver 2', '990002', 'ACTIVE', 'AVAILABLE') returning driver_id into v_dr2;
  insert into public.fleet_vehicles(registration_number, display_name, vehicle_type, operational_status, active)
  values ('VAL0300002', 'Validation truck', 'TRUCK', 'AVAILABLE', true);
  v_rec := jsonb_build_object('record_type','DISTRIBUTION_ROSTER','source_record_id','2030-01-07',
    'row', jsonb_build_object('data', jsonb_build_object(
      'assignments', '[{"driverId":"990001","mon":"Route 610|VAL0300002","tue":"Off","wed":"Hols","thu":"","fri":"","sat":"","sun":""},
                       {"driverId":"990002","mon":"Training","tue":"Route 610|VAL0300002","wed":"","thu":"","fri":"","sat":"","sun":""}]'::jsonb,
      'requiredRoutes', '{"mon":1,"tue":1,"wed":0,"thu":0,"fri":0,"sat":0,"sun":0}'::jsonb)));
  v_r := integration.legacy_sync_import_roster(v_run, v_rec);
  if v_r->>'outcome' <> 'IMPORTED'
     or integration.legacy_sync_roster_distribution_have((v_r->>'target_id')::uuid)
        <> (integration.legacy_sync_roster_distribution_want(v_rec->'row', v_week))->'want'
     or not exists (select 1 from public.distribution_route_runs rr join public.distribution_routes r using (route_id)
                    where rr.business_date = v_week and r.route_code = '610' and rr.run_status = 'READY' and rr.primary_driver_id = v_dr1) then
    raise exception 'FAILED 7: %', v_r;
  end if;

  -- 8. The legacy app moves Monday to driver 2: new version, the run follows.
  v_rec := jsonb_set(jsonb_set(v_rec, '{row,data,assignments,0,mon}', '"Off"'), '{row,data,assignments,1,mon}', '"Route 610|VAL0300002"');
  v_r := integration.legacy_sync_import_roster(v_run, v_rec);
  if v_r->>'outcome' <> 'UPDATED' or not exists (
       select 1 from public.distribution_route_runs rr join public.distribution_routes r using (route_id)
       where rr.business_date = v_week and r.route_code = '610' and rr.primary_driver_id = v_dr2)
     or (select count(*) from public.distribution_roster_versions where week_start = v_week and roster_status = 'SUPERSEDED') <> 1 then
    raise exception 'FAILED 8: %', v_r;
  end if;

  -- 9. Driver leave approved in V2 and an unknown vehicle are held for review.
  insert into public.distribution_driver_absences(driver_id, absence_type, starts_on, ends_on, absence_status)
  values (v_dr2, 'HOLIDAY', v_week + 3, v_week + 3, 'APPROVED');
  v_r := integration.legacy_sync_plan_roster(jsonb_set(jsonb_set(v_rec, '{row,data,assignments,1,thu}', '"Route 611|VAL0300002"'),
           '{row,data,assignments,0,fri}', '"Route 612|NOPLATE1"'));
  if not (v_r->'blockers') @> '[{"code":"DRIVER_ON_LEAVE_IN_V2"},{"code":"VEHICLE_NOT_IN_V2"}]' then
    raise exception 'FAILED 9: %', v_r->'blockers';
  end if;

  -- 10. Switch off: refused. No client role can call the importer.
  update integration.legacy_sync_settings set enabled=false where setting_key='ROSTER_IMPORT';
  begin
    perform integration.legacy_sync_import_roster(v_run, v_rec);
    raise exception 'FAILED 10: imported with the switch off';
  exception when object_not_in_prerequisite_state then null; end;
  if has_function_privilege('authenticated','integration.legacy_sync_import_roster(uuid,jsonb)','execute')
     or has_function_privilege('anon','integration.legacy_sync_roster_dry_run(jsonb)','execute')
     or has_function_privilege('authenticated','integration.legacy_sync_roster_publish_production(date,uuid,uuid,jsonb,text)','execute')
     or has_function_privilege('authenticated','integration.legacy_sync_roster_publish_distribution(date,uuid,jsonb,text)','execute') then
    raise exception 'FAILED 10b: a client role can call the roster sync';
  end if;

  -- 11. Every version written by the sync is audited with the run.
  select count(*) into v_n from public.audit_log where correlation_id=v_run and source_application='LEGACY_SYNC_ROSTER';
  if v_n <> 5 then raise exception 'FAILED 11: % audit rows', v_n; end if;

  raise exception 'PASSED: 202610300002 legacy sync rosters (11 checks)';
end;
$$;
