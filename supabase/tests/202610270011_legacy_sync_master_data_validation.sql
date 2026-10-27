-- ElisCaretex V2 - Validation - 202610270011_legacy_sync_master_data
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all 17 legacy sync register checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_old public.staff_members%rowtype;
  v_new public.staff_members%rowtype;
  v_cust public.customers%rowtype;
  v_trolley public.trolleys%rowtype;
  v_busy public.trolleys%rowtype;
  v_type text;
  v_run uuid;
  v_old_rec jsonb;
  v_new_rec jsonb;
  v_cust_rec jsonb;
  v_trolley_rec jsonb;
  v_busy_rec jsonb;
  v_driver_rec jsonb;
  v_vehicle_rec jsonb;
  v_name_rec jsonb;
  v_named uuid;
  v jsonb;
  v_state text;
  v_audits integer;
  n integer := 0;
begin
  perform set_config('request.jwt.claims', '', true);

  -- Fixtures: an existing person with a legacy id, an available trolley and a trolley at a customer.
  select sm.* into v_old from public.staff_members sm
  where sm.deleted_at is null and sm.active and sm.production_staff and sm.legacy_user_id is not null
    and sm.default_shift_id is not null
  order by sm.legacy_user_id limit 1;
  select t.* into v_trolley from public.trolleys t
  where t.deleted_at is null and t.active and t.status in ('AVAILABLE','LOCATION_UNCONFIRMED','IN_PRODUCTION')
    and not exists (select 1 from public.trolley_customer_stays s where s.trolley_id=t.trolley_id and s.received_on is null)
    and t.trolley_type_id is not null
  order by t.trolley_code limit 1;
  select t.* into v_busy from public.trolleys t
  where t.deleted_at is null and t.trolley_type_id is not null
    and exists (select 1 from public.trolley_customer_stays s where s.trolley_id=t.trolley_id and s.received_on is null)
  order by t.trolley_code limit 1;
  if v_old.staff_id is null or v_trolley.trolley_id is null or v_busy.trolley_id is null then
    raise exception 'FAIL: fixtures (a staff member with a legacy id, a free trolley, a trolley at a customer)'; end if;
  if exists (select 1 from public.staff_members where legacy_user_id in (99001, 99002))
     or exists (select 1 from public.customers where customer_code='CID-VALM-00001')
     or exists (select 1 from public.trolleys where trolley_code='TVALM0001')
     or exists (select 1 from public.distribution_drivers where driver_code='DRV-9901' or legacy_driver_id='9901')
     or exists (select 1 from public.fleet_vehicles where registration_number='VALM901') then
    raise exception 'FAIL: validation ids are free'; end if;

  -- The existing person as the legacy sheet sends it, with fire training opposite to V2.
  v_old_rec := jsonb_build_object('record_type','STAFF','source_record_id',v_old.legacy_user_id::text,'row',jsonb_build_object(
    'UserID', v_old.legacy_user_id::text, 'Name', v_old.display_name,
    'Shift', (select initcap(shift_code) || ' Shift' from public.shifts where shift_id=v_old.default_shift_id),
    'Position', 'General Operative - Table 1', 'Roster', 'Yes', 'Active', 'Yes',
    'FireTraining', case when v_old.fire_training then 'No' else 'Yes' end));
  v_new_rec := jsonb_build_object('record_type','STAFF','source_record_id','99001','row',jsonb_build_object(
    'UserID','99001','Name','Valm New  Person','Shift','Morning Shift','Position','Sorting Area',
    'Cover','Team Leader, Label','Roster','Yes','Active','Yes','JoinedAt','2026-10-20'));
  v_cust_rec := jsonb_build_object('record_type','CUSTOMER','source_record_id','CID-VALM-00001','row',jsonb_build_object(
    'CustomerID','CID-VALM-00001','CustomerName','VALIDATION NURSING HOME','ServiceType','CLOTHES + MOP',
    'Eircode','H91 X000','KGEstimated','42.5','Stops','2','Information','Validation only','Active','Yes'));
  select tt.trolley_type_code into v_type from public.trolley_types tt where tt.trolley_type_id=v_trolley.trolley_type_id;
  v_trolley_rec := jsonb_build_object('record_type','TROLLEY','source_record_id',v_trolley.trolley_code,'row',jsonb_build_object(
    'TrolleyID', v_trolley.trolley_code, 'Type', initcap(v_type), 'Status', 'Available'));
  select tt.trolley_type_code into v_type from public.trolley_types tt where tt.trolley_type_id=v_busy.trolley_type_id;
  v_busy_rec := jsonb_build_object('record_type','TROLLEY','source_record_id',v_busy.trolley_code,'row',jsonb_build_object(
    'TrolleyID', v_busy.trolley_code, 'Type', initcap(v_type), 'Status', 'Available'));
  v_driver_rec := jsonb_build_object('record_type','DRIVER','source_record_id','9901','row',jsonb_build_object(
    'DriverID','9901','Name','Valm Driver','LicenseType','B/C','Active','Yes','JoinedDate','2026-10-01','RosterHidden','No'));
  v_vehicle_rec := jsonb_build_object('record_type','VEHICLE','source_record_id','VALM901','row',jsonb_build_object(
    'Plate','VALM901','Type','TRUCK','Status','available','Active','Yes','VehicleDescription','Validation truck',
    'LastKmRecorded','1000','ServiceNext','2026-12-01','RoadFundLicenceNext','2027-01-01'));

  -- 1. Access surface
  if has_function_privilege('authenticated','integration.legacy_sync_import_master(uuid,jsonb)','execute')
     or has_function_privilege('anon','integration.legacy_sync_master_dry_run(jsonb)','execute')
     or has_function_privilege('authenticated','integration.legacy_sync_master_apply(text,text,uuid,text[],jsonb)','execute')
     or not has_function_privilege('service_role','integration.legacy_sync_import_master(uuid,jsonb)','execute') then
    raise exception 'FAIL: only the service role calls the register importer'; end if;
  n := n + 1;

  -- 2. Dry run: creates and adoptions; an adoption lists today's differences.
  v := integration.legacy_sync_dispatch_dry_run('master', jsonb_build_array(v_old_rec, v_new_rec, v_cust_rec, v_trolley_rec,
         v_busy_rec, v_driver_rec, v_vehicle_rec));
  if not ((v->>'ready')::int = 7 and (v->>'writes_performed')::int = 0
          and v->'actions' @> '{"STAFF:ADOPT":1,"STAFF:CREATE":1,"CUSTOMER:CREATE":1,"TROLLEY:ADOPT":2,"DRIVER:CREATE":1,"VEHICLE:CREATE":1}'
          and (v->'warning_counts'->>'V2_DIFFERS')::int >= 1) then
    raise exception 'FAIL: dry run plans (got %)', v - 'plans'; end if;
  n := n + 1;

  -- 3. Switch OFF refuses writes
  v_run := integration.legacy_sync_start_run('FINISH_AREA', 'COMMIT', v_today, v_today, 'validation');
  begin perform integration.legacy_sync_import_master(v_run, v_new_rec); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '55000' then raise exception 'FAIL: switch OFF refuses the import (got %)', v_state; end if;
  n := n + 1;
  update integration.legacy_sync_settings set enabled=true, max_entries_per_run=300 where setting_key='MASTER_DATA_IMPORT';

  -- 4. One batch: each record in its own subtransaction.
  v := integration.legacy_sync_import_master(v_run, jsonb_build_object('records', jsonb_build_array(v_old_rec, v_new_rec,
         v_cust_rec, v_trolley_rec, v_busy_rec, v_driver_rec, v_vehicle_rec)));
  if not (v->>'outcome' = 'BATCH' and v->'counts' = '{"IMPORTED":4,"ADOPTED":3}'::jsonb) then
    raise exception 'FAIL: batch import (got %)', v->'counts'; end if;
  n := n + 1;

  -- 5. New person as typed in V2: shift, Sorting position, cover roles V2 allows, linked to the legacy id.
  select * into v_new from public.staff_members where legacy_user_id=99001;
  if not (v_new.display_name = 'Valm New Person' and v_new.active and v_new.roster_eligible and v_new.production_staff
          and v_new.joined_on = date '2026-10-20'
          and v_new.default_shift_id = (select shift_id from public.shifts where shift_code='MORNING')
          and v_new.default_station_id = (select station_id from public.stations where station_code='SORTING_MAIN')
          and v_new.primary_operational_role_id = (select operational_role_id from public.operational_roles where role_code='GENERAL_OPERATIVE')
          and (select array_agg(r.role_code) from public.staff_cover_capabilities c join public.operational_roles r using (operational_role_id)
               where c.staff_id=v_new.staff_id and c.active and c.effective_until is null) = array['TEAM_LEADER']) then
    raise exception 'FAIL: new person (got %)', to_jsonb(v_new); end if;
  n := n + 1;

  -- 6. Adoption changes nothing in V2 (owner decision: differences are listed, not applied).
  if (select fire_training from public.staff_members where staff_id=v_old.staff_id) is distinct from v_old.fire_training
     or not exists (select 1 from integration.legacy_sync_record_links l where l.link_role='STAFF_MASTER'
                    and l.source_record_id=v_old.legacy_user_id::text and l.target_id=v_old.staff_id) then
    raise exception 'FAIL: adoption keeps V2 values and links the record'; end if;
  n := n + 1;

  -- 7. The same rows again: nothing to do.
  v := integration.legacy_sync_dispatch_dry_run('master', jsonb_build_array(v_old_rec, v_new_rec, v_cust_rec, v_trolley_rec,
         v_driver_rec, v_vehicle_rec));
  if (v->>'already_imported')::int <> 6 then raise exception 'FAIL: unchanged rows are already imported (got %)', v - 'plans'; end if;
  n := n + 1;

  -- 8. A field changed in the legacy app is written; a field it did not change keeps the V2 value.
  v_old_rec := jsonb_set(v_old_rec, '{row,Position}', '"General Operative - Table 3"');
  v := integration.legacy_sync_import_master(v_run, v_old_rec);
  if not (v->>'outcome' = 'UPDATED'
          and (select default_station_id from public.staff_members where staff_id=v_old.staff_id)
              = (select station_id from public.stations where station_code='FINISH_TABLE_3')
          and (select fire_training from public.staff_members where staff_id=v_old.staff_id) is not distinct from v_old.fire_training) then
    raise exception 'FAIL: only the legacy change is written (got %)', v; end if;
  n := n + 1;

  -- 9. A V2 edit survives a later legacy change to another field.
  update public.staff_members set eod_capable=true where staff_id=v_new.staff_id;
  v_new_rec := jsonb_set(v_new_rec, '{row,Shift}', '"Evening Shift"');
  v := integration.legacy_sync_import_master(v_run, v_new_rec);
  select * into v_new from public.staff_members where staff_id=v_new.staff_id;
  if not (v->>'outcome' = 'UPDATED' and v_new.eod_capable
          and v_new.default_shift_id = (select shift_id from public.shifts where shift_code='EVENING')) then
    raise exception 'FAIL: V2 edit kept, legacy shift written (got %)', v; end if;
  n := n + 1;

  -- 10. Deactivated in the legacy app; a cover role removed there ends in V2.
  v_new_rec := jsonb_set(jsonb_set(jsonb_set(v_new_rec, '{row,Active}', '"No"'), '{row,DeactivatedAt}', '"2026-10-26"'), '{row,Cover}', '""');
  v := integration.legacy_sync_import_master(v_run, v_new_rec);
  select * into v_new from public.staff_members where staff_id=v_new.staff_id;
  if not (v->>'outcome' = 'UPDATED' and not v_new.active and not v_new.roster_eligible and v_new.deactivated_on = date '2026-10-26'
          and v_new.deactivation_reason like 'Deactivated in the legacy CentralDB%'
          and not exists (select 1 from public.staff_cover_capabilities c where c.staff_id=v_new.staff_id and c.active and c.effective_until is null)) then
    raise exception 'FAIL: legacy deactivation (got %)', to_jsonb(v_new); end if;
  n := n + 1;

  -- 11. A person typed in V2 without a legacy id is found by name and gets the id.
  insert into public.staff_members(display_name, production_staff, roster_eligible) values ('Valm Named Person', true, true)
  returning staff_id into v_named;
  v_name_rec := jsonb_build_object('record_type','STAFF','source_record_id','99002','row',jsonb_build_object(
    'UserID','99002','Name','VALM NAMED PERSON','Shift','Morning Shift','Position','General Operative - Table 1',
    'Roster','Yes','Active','Yes'));
  v := integration.legacy_sync_import_master(v_run, v_name_rec);
  if not (v->>'outcome' = 'ADOPTED' and v->>'action' = 'ADOPT_BY_NAME'
          and (select legacy_user_id from public.staff_members where staff_id=v_named) = 99002
          and (select display_name from public.staff_members where staff_id=v_named) = 'Valm Named Person') then
    raise exception 'FAIL: adoption by name (got %)', v; end if;
  n := n + 1;

  -- 12. Customer created as in V2, with product services from the service type; later only MOP.
  select * into v_cust from public.customers where customer_code='CID-VALM-00001';
  if not (v_cust.customer_name = 'VALIDATION NURSING HOME' and v_cust.active and v_cust.distribution_estimated_kg = 42.5
          and v_cust.distribution_stop_count = 2 and v_cust.notes = 'Validation only'
          and (select array_agg(pt.product_code order by pt.product_code) from public.customer_product_services ps
               join public.product_types pt using (product_type_id)
               where ps.customer_id=v_cust.customer_id and ps.active and ps.effective_until is null) = array['CLOTHES','MOP']) then
    raise exception 'FAIL: new customer (got %)', to_jsonb(v_cust); end if;
  v_cust_rec := jsonb_set(v_cust_rec, '{row,ServiceType}', '"MOP"');
  v := integration.legacy_sync_import_master(v_run, v_cust_rec);
  if not (v->>'outcome' = 'UPDATED'
          and (select array_agg(pt.product_code) from public.customer_product_services ps join public.product_types pt using (product_type_id)
               where ps.customer_id=v_cust.customer_id and ps.active and ps.effective_until is null) = array['MOP']) then
    raise exception 'FAIL: service type change (got %)', v; end if;
  n := n + 1;

  -- 13. Customer deactivated in the legacy app: as the V2 deactivation.
  v_cust_rec := jsonb_set(v_cust_rec, '{row,Active}', '"No"');
  v := integration.legacy_sync_import_master(v_run, v_cust_rec);
  select * into v_cust from public.customers where customer_id=v_cust.customer_id;
  if not (v->>'outcome' = 'UPDATED' and not v_cust.active and v_cust.deactivated_at is not null
          and not exists (select 1 from public.customer_product_services ps where ps.customer_id=v_cust.customer_id and ps.active)) then
    raise exception 'FAIL: customer deactivation (got %)', to_jsonb(v_cust); end if;
  n := n + 1;

  -- 14. Trolley out of service and back, with events; a trolley at a customer goes to review.
  v_trolley_rec := jsonb_set(v_trolley_rec, '{row,Status}', '"Out of Service"');
  v := integration.legacy_sync_import_master(v_run, v_trolley_rec);
  if not (v->>'outcome' = 'UPDATED'
          and (select status from public.trolleys where trolley_id=v_trolley.trolley_id) = 'OUT_OF_SERVICE'
          and (select status_before_service_hold from public.trolleys where trolley_id=v_trolley.trolley_id) = v_trolley.status) then
    raise exception 'FAIL: trolley out of service (got %)', v; end if;
  v_trolley_rec := jsonb_set(v_trolley_rec, '{row,Status}', '"Available"');
  v := integration.legacy_sync_import_master(v_run, v_trolley_rec);
  if not (v->>'outcome' = 'UPDATED'
          and (select status from public.trolleys where trolley_id=v_trolley.trolley_id)
              = case when v_trolley.status in ('LOCATION_UNCONFIRMED','AVAILABLE') then v_trolley.status else 'AVAILABLE' end
          and (select count(*) from public.trolley_events e where e.trolley_id=v_trolley.trolley_id
               and e.event_type in ('MARKED_OUT_OF_SERVICE','RETURNED_TO_SERVICE') and e.source_application='LEGACY_SYNC_MASTER') = 2) then
    raise exception 'FAIL: trolley back in service (got %)', v; end if;
  v_busy_rec := jsonb_set(v_busy_rec, '{row,Status}', '"Out of Service"');
  v := integration.legacy_sync_import_master(v_run, v_busy_rec);
  if not (v->>'outcome' = 'BLOCKED' and v->'blockers' @> '[{"code":"TROLLEY_AT_CUSTOMER"}]'
          and (select status from public.trolleys where trolley_id=v_busy.trolley_id) = v_busy.status
          and exists (select 1 from integration.legacy_sync_review_items ri where ri.source_table='Trolley'
                      and ri.source_record_id=v_busy.trolley_code and ri.reason_code='TROLLEY_AT_CUSTOMER' and ri.status='OPEN')) then
    raise exception 'FAIL: trolley at a customer is held for review (got %)', v; end if;
  n := n + 1;

  -- 15. Driver and vehicle: created, then deactivated / returned.
  if not exists (select 1 from public.distribution_drivers d where d.driver_code='DRV-9901' and d.legacy_driver_id='9901'
                 and d.licence_categories @> array['B','C'] and d.employment_status='ACTIVE' and d.joined_on = date '2026-10-01')
     or not exists (select 1 from public.fleet_vehicles fv where fv.registration_number='VALM901' and fv.active
                    and fv.operational_status='AVAILABLE' and fv.odometer_km=1000 and fv.service_due_on = date '2026-12-01'
                    and fv.display_name='Validation truck') then
    raise exception 'FAIL: new driver and vehicle'; end if;
  v := integration.legacy_sync_import_master(v_run, jsonb_set(v_driver_rec, '{row,Active}', '"No"'));
  v := integration.legacy_sync_import_master(v_run, jsonb_set(jsonb_set(v_vehicle_rec, '{row,Status}', '"returned"'), '{row,LastKmRecorded}', '"1500"'));
  if not exists (select 1 from public.distribution_drivers d where d.driver_code='DRV-9901' and d.employment_status='INACTIVE'
                 and d.availability_status='UNAVAILABLE' and d.deactivated_on is not null)
     or not exists (select 1 from public.fleet_vehicles fv where fv.registration_number='VALM901' and not fv.active
                    and fv.operational_status='OUT_OF_SERVICE' and fv.odometer_km=1500 and fv.legacy_status='returned') then
    raise exception 'FAIL: driver deactivation and vehicle return'; end if;
  n := n + 1;

  -- 16. A legacy change V2 already has: relinked, no V2 write; every write is audited.
  update public.fleet_vehicles set notes='Same note' where registration_number='VALM901';
  select count(*) into v_audits from public.audit_log where correlation_id=v_run;
  v := integration.legacy_sync_import_master(v_run, jsonb_set(jsonb_set(jsonb_set(v_vehicle_rec, '{row,Status}', '"returned"'),
         '{row,LastKmRecorded}', '"1500"'), '{row,Notes}', '"Same note"'));
  if not (v->>'outcome' = 'RELINKED' and (select count(*) from public.audit_log where correlation_id=v_run) = v_audits
          and v_audits = (select count(*) from public.audit_log where correlation_id=v_run
                          and action in ('IMPORT_LEGACY_MASTER','UPDATE_LEGACY_MASTER','ADOPT_LEGACY_MASTER'))) then
    raise exception 'FAIL: relink without a V2 write (got %)', v; end if;
  n := n + 1;

  -- 17. Control switches it, accounts are refused
  v := integration.legacy_sync_control('OFF', 'validation');
  if (v->'imports'->>'MASTER_DATA_IMPORT')::boolean then raise exception 'FAIL: OFF also disables the register import'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  begin perform integration.legacy_sync_import_master(v_run, v_new_rec); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: an account is refused (got %)', v_state; end if;
  n := n + 1;

  raise exception 'PASSED: all % legacy sync register checks (nothing was kept)', n;
end;
$$;
