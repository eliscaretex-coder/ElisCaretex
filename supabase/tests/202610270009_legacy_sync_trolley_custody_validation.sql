-- ElisCaretex V2 - Validation - 202610270009_legacy_sync_trolley_custody
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- Needs 202610270007 and 202610270008 (the MOP wash and production give the trolley its production).
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all 16 legacy sync trolley custody checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_day date := (now() at time zone 'Europe/Dublin')::date - 3;
  v_customer public.customers%rowtype;
  v_customer2 public.customers%rowtype;
  v_staff public.staff_members%rowtype;
  v_washer public.sorting_washers%rowtype;
  v_t1 public.trolleys%rowtype;
  v_t2 public.trolleys%rowtype;
  v_t3 public.trolleys%rowtype;
  v_wash_id text;
  v_item_id text;
  v_wash jsonb;
  v_mop jsonb;
  v_out jsonb;
  v_ret jsonb;
  v_ret2 jsonb;
  v_run uuid;
  v_stay public.trolley_customer_stays%rowtype;
  v_intake uuid;
  v_old_stay uuid;
  v_ret_day date;
  v jsonb;
  v_state text;
  n integer := 0;
begin
  perform set_config('request.jwt.claims', '', true);
  if v_day = date '2026-10-25' then v_day := v_day - 1; end if;
  v_wash_id := 'W' || to_char(v_day, 'YYYYMMDD') || '-090000-VALTRL01';
  v_item_id := 'WI' || to_char(v_day, 'YYYYMMDD') || '-01-VALTRL01';

  -- Fixtures from live data: two customers with a unique legacy id (the first with MOP on its
  -- published schedule that day), a production staff member with a unique display name, a washer
  -- of 60 KG or more, three free trolleys.
  select c.* into v_customer from public.customers c
  where c.active and c.deleted_at is null and c.legacy_metadata ? 'legacy_customer_id'
    and exists (select 1 from public.customer_schedule_versions csv
                join public.customer_schedule_days sd on sd.schedule_version_id=csv.schedule_version_id and sd.active
                 and sd.production_weekday=extract(isodow from v_day)::smallint
                join public.customer_schedule_products sp on sp.schedule_day_id=sd.schedule_day_id and sp.active
                join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.product_code='MOP'
                where csv.customer_id=c.customer_id and csv.status='PUBLISHED' and csv.effective_from<=v_day
                  and (csv.effective_until is null or csv.effective_until>=v_day))
    and (select count(*) from public.customers x where x.deleted_at is null
         and x.legacy_metadata->>'legacy_customer_id' = c.legacy_metadata->>'legacy_customer_id') = 1
  order by c.customer_code limit 1;
  select c.* into v_customer2 from public.customers c
  where c.active and c.deleted_at is null and c.legacy_metadata ? 'legacy_customer_id' and c.customer_id <> v_customer.customer_id
    and (select count(*) from public.customers x where x.deleted_at is null
         and x.legacy_metadata->>'legacy_customer_id' = c.legacy_metadata->>'legacy_customer_id') = 1
  order by c.customer_code desc limit 1;
  select sm.* into v_staff from public.staff_members sm
  where sm.deleted_at is null and sm.active and sm.production_staff
    and (select count(*) from public.staff_members x where x.deleted_at is null
         and lower(btrim(x.display_name)) = lower(btrim(sm.display_name))) = 1
    and not exists (select 1 from public.sorting_daily_staff_attendance a
                    where a.staff_id=sm.staff_id and a.business_date between v_day and v_day + 4 and a.attendance_status='ABSENT')
    and not exists (select 1 from public.work_sessions ws where ws.staff_id=sm.staff_id and ws.work_date between v_day and v_day + 4
                    and ws.source='SORTING_AREA_TRANSFER' and ws.status<>'CANCELLED')
  limit 1;
  select w.* into v_washer from public.sorting_washers w
  where w.deleted_at is null and w.active and w.capacity_kg >= 60 order by w.washer_code limit 1;
  select t.* into v_t1 from public.trolleys t
  where t.deleted_at is null and t.active and t.status in ('AVAILABLE','LOCATION_UNCONFIRMED') and t.trolley_code ~ '^T[0-9]{1,10}T$'
    and not exists (select 1 from public.trolley_customer_stays s where s.trolley_id=t.trolley_id and (s.received_on is null or s.received_on >= v_day))
    and not exists (select 1 from public.sorting_trolley_intakes i where i.trolley_id=t.trolley_id and i.business_date >= v_day - 1)
  order by t.trolley_code limit 1;
  select t.* into v_t2 from public.trolleys t
  where t.deleted_at is null and t.active and t.status in ('AVAILABLE','LOCATION_UNCONFIRMED') and t.trolley_code ~ '^T[0-9]{1,10}T$'
    and t.trolley_id <> v_t1.trolley_id
    and not exists (select 1 from public.trolley_customer_stays s where s.trolley_id=t.trolley_id and (s.received_on is null or s.received_on >= v_day))
    and not exists (select 1 from public.sorting_trolley_intakes i where i.trolley_id=t.trolley_id and i.business_date >= v_day - 1)
  order by t.trolley_code limit 1;
  select t.* into v_t3 from public.trolleys t
  where t.deleted_at is null and t.active and t.status in ('AVAILABLE','LOCATION_UNCONFIRMED') and t.trolley_code ~ '^T[0-9]{1,10}T$'
    and t.trolley_id not in (v_t1.trolley_id, v_t2.trolley_id)
    and not exists (select 1 from public.trolley_customer_stays s where s.trolley_id=t.trolley_id and (s.received_on is null or s.received_on >= v_day))
    and not exists (select 1 from public.sorting_trolley_intakes i where i.trolley_id=t.trolley_id and i.business_date >= v_day - 1)
  order by t.trolley_code limit 1;
  if v_customer.customer_id is null or v_customer2.customer_id is null or v_staff.staff_id is null
     or v_washer.washer_id is null or v_t3.trolley_id is null then
    raise exception 'FAIL: fixtures (customers, staff, washer, trolleys)'; end if;

  -- The MOP wash and production of the customer (parts 0007 and 0008), trolley T1 typed on it.
  v_wash := jsonb_build_object('source_record_id', v_wash_id,
    'wash', jsonb_build_object('WashID', v_wash_id, 'StartTime', '09:00:00',
      'RegisterTime', to_char(v_day, 'YYYY-MM-DD') || 'T09:01:00', 'Machine', v_washer.washer_name,
      'Who', v_staff.display_name, 'Type', 'MOP', 'Kg', '40'),
    'items', jsonb_build_array(jsonb_build_object('WashItemID', v_item_id, 'WashID', v_wash_id,
      'CustomerID', v_customer.legacy_metadata->>'legacy_customer_id', 'ScheduledDate', to_char(v_day, 'YYYY-MM-DD'),
      'Type', 'MOP', 'KGShare', '40')),
    'staff_shifts', jsonb_build_array('Morning'));
  v_mop := jsonb_build_object('source_record_id', v_item_id,
    'item', jsonb_build_object('WashItemID', v_item_id, 'WashID', v_wash_id,
      'CustomerID', v_customer.legacy_metadata->>'legacy_customer_id', 'ScheduledDate', to_char(v_day, 'YYYY-MM-DD'), 'Type', 'MOP'),
    'events', jsonb_build_array(jsonb_build_object('MopEventID', 'MP-VALTRL-1', 'WashItemID', v_item_id, 'WashID', v_wash_id,
      'CustomerID', v_customer.legacy_metadata->>'legacy_customer_id', 'BusinessDate', to_char(v_day, 'YYYY-MM-DD'),
      'Shift', 'Morning', 'EventType', 'PRODUCTION', 'QtyKgDelta', '12.4', 'QtyUnitsDelta', '103',
      'MopModel', 'STANDARD POCKET MOPS', 'Trolleys', v_t1.trolley_code,
      'ProcessedBy', v_staff.display_name, 'ProcessedAt', to_char(v_day, 'YYYY-MM-DD') || ' 11:30:00',
      'CreatedAt', to_char(v_day, 'YYYY-MM-DD') || ' 11:30:20', 'ABSStatus', 'PENDING', 'Status', 'ACTIVE')));
  v_out := jsonb_build_object('record_type', 'OUT', 'area', 'MOP', 'source_id', v_item_id,
    'source_record_id', v_item_id || ':' || v_t1.trolley_code, 'trolley_code', v_t1.trolley_code,
    'customer_id', v_customer.legacy_metadata->>'legacy_customer_id', 'business_date', to_char(v_day, 'YYYY-MM-DD'),
    'at', to_char(v_day, 'YYYY-MM-DD') || ' 11:30:00');

  -- 1. Access surface
  if has_function_privilege('authenticated','integration.legacy_sync_import_trolley(uuid,jsonb)','execute')
     or has_function_privilege('anon','integration.legacy_sync_trolley_dry_run(jsonb)','execute')
     or not has_function_privilege('service_role','integration.legacy_sync_import_trolley(uuid,jsonb)','execute') then
    raise exception 'FAIL: only the service role calls the trolley importer'; end if;
  n := n + 1;

  -- 2. Without the MOP production in V2 the trolley waits in review.
  v := integration.legacy_sync_dispatch_dry_run('trolley', jsonb_build_array(v_out));
  if not ((v->>'blocked')::int = 1 and v->'blocker_counts' ? 'MOP_NOT_IN_V2' and (v->>'writes_performed')::int = 0) then
    raise exception 'FAIL: dry run waits for the MOP production (got %)', v - 'plans'; end if;
  n := n + 1;

  update integration.legacy_sync_settings set enabled=true
  where setting_key in ('SORTING_WASH_IMPORT','MOP_PRODUCTION_IMPORT','TROLLEY_CUSTODY_IMPORT');
  v_run := integration.legacy_sync_start_run('FINISH_AREA', 'COMMIT', v_day, v_day + 3, 'validation');
  if not coalesce((integration.legacy_sync_import_wash(v_run, v_wash)->>'imported')::boolean, false)
     or integration.legacy_sync_import_mop(v_run, v_mop)->>'outcome' <> 'IMPORTED' then
    raise exception 'FAIL: fixture MOP wash and production import'; end if;

  -- 3. Now the OUT is ready.
  v := integration.legacy_sync_trolley_dry_run(jsonb_build_array(v_out));
  if not ((v->>'ready')::int = 1 and v#>>'{plans,0,action}' = 'CREATE') then
    raise exception 'FAIL: dry run plans one CREATE (got %)', v; end if;
  n := n + 1;

  -- 4. Switch OFF refuses writes
  update integration.legacy_sync_settings set enabled=false where setting_key='TROLLEY_CUSTODY_IMPORT';
  begin perform integration.legacy_sync_import_trolley(v_run, v_out); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '55000' then raise exception 'FAIL: switch OFF refuses the import (got %)', v_state; end if;
  n := n + 1;
  update integration.legacy_sync_settings set enabled=true where setting_key='TROLLEY_CUSTODY_IMPORT';

  -- 5. OUT: open stay, trolley in production, event, trolley on the MOP production.
  v := integration.legacy_sync_dispatch_import('trolley', v_run, v_out);
  if v->>'outcome' <> 'IMPORTED' then raise exception 'FAIL: OUT import (got %)', v; end if;
  select * into v_stay from public.trolley_customer_stays where stay_id=(v->>'stay_id')::uuid;
  if not (v_stay.status='OPEN' and v_stay.outbound_customer_id=v_customer.customer_id and v_stay.production_area_code='MOP'
          and v_stay.sent_on=public.next_distribution_business_date(v_day) and v_stay.production_recorded_by=v_staff.staff_id
          and (select status from public.trolleys where trolley_id=v_t1.trolley_id)='IN_PRODUCTION'
          and exists (select 1 from public.trolley_events e where e.stay_id=v_stay.stay_id and e.event_type='ASSIGNED_IN_PRODUCTION'
                      and e.source_application='LEGACY_SYNC_TROLLEY')
          and exists (select 1 from public.sorting_mop_production_trolleys t where t.stay_id=v_stay.stay_id
                      and t.trolley_code_snapshot=v_t1.trolley_code)) then
    raise exception 'FAIL: OUT writes the open stay, trolley status, event and production link'; end if;
  n := n + 1;

  -- 6. Idempotent
  if integration.legacy_sync_import_trolley(v_run, v_out)->>'outcome' <> 'ALREADY_IMPORTED' then
    raise exception 'FAIL: a second OUT import does nothing'; end if;
  n := n + 1;

  -- 7. RETURN on the delivery day closes the stay.
  v_ret_day := v_stay.sent_on;
  v_ret := jsonb_build_object('record_type', 'RETURN', 'source_record_id', 'TR-VALTRL-1', 'row', jsonb_build_object(
    'ReturnID', 'TR-VALTRL-1', 'TrolleyID', v_t1.trolley_code, 'ReturnedAt', to_char(v_ret_day, 'YYYY-MM-DD') || ' 10:00:00',
    'FromCustomerID', v_customer.legacy_metadata->>'legacy_customer_id', 'ReceivedBy', v_staff.display_name,
    'BusinessDate', to_char(v_ret_day, 'YYYY-MM-DD'), 'Shift', 'Morning', 'ServiceType', 'MOP', 'Content', 'WITH_ITEMS',
    'ScheduledDate', to_char(v_day, 'YYYY-MM-DD'), 'CustomerMatch', 'MATCH', 'ClientEventID', 'S-VALTRL-1'));
  v := integration.legacy_sync_trolley_dry_run(jsonb_build_array(v_ret));
  if not (v#>>'{plans,0,action}' = 'CREATE' and v#>>'{plans,0,resolved,custody}' = 'CLOSE_OPEN_STAY'
          and v#>>'{plans,0,resolved,custody_tracking_status}' = 'TRACKED_MATCH') then
    raise exception 'FAIL: RETURN plans to close the tracked stay (got %)', v; end if;
  n := n + 1;

  -- 8. RETURN writes the intake like the Sorting screen.
  v := integration.legacy_sync_import_trolley(v_run, v_ret);
  if v->>'outcome' <> 'IMPORTED' then raise exception 'FAIL: RETURN import (got %)', v; end if;
  v_intake := (v->>'sorting_trolley_intake_id')::uuid;
  if not exists (select 1 from public.sorting_trolley_intakes i
                 join public.trolley_customer_stays s on s.stay_id=i.stay_id
                 join public.sorting_trolley_intake_products p on p.sorting_trolley_intake_id=i.sorting_trolley_intake_id
                 where i.sorting_trolley_intake_id=v_intake and s.stay_id=v_stay.stay_id and s.status='RECEIVED'
                   and s.received_on=v_ret_day and s.exception_type is null
                   and i.custody_tracking_status='TRACKED_MATCH' and i.contents_status='CONTENTS' and i.product_scope='MOP'
                   and i.operator_staff_id=v_staff.staff_id and i.business_date=v_ret_day and i.shift_code_snapshot='MORNING'
                   and p.product_code='MOP')
     or (select status from public.trolleys where trolley_id=v_t1.trolley_id) <> 'AVAILABLE'
     or not exists (select 1 from public.production_flow_events e where e.event_type='TROLLEY_RECEIVED_CONTENTS'
                    and e.event_data->>'sorting_trolley_intake_id'=v_intake::text)
     or not exists (select 1 from public.trolley_events e where e.stay_id=v_stay.stay_id and e.event_type='SORTING_CONTENTS_CONFIRMED')
     or not exists (select 1 from public.sorting_daily_staff_attendance a where a.staff_id=v_staff.staff_id
                    and a.business_date=v_ret_day and a.attendance_status='PRESENT') then
    raise exception 'FAIL: RETURN writes stay, intake, products, flow event, trolley event and presence'; end if;
  n := n + 1;

  -- 9. Idempotent
  if integration.legacy_sync_import_trolley(v_run, v_ret)->>'outcome' <> 'ALREADY_IMPORTED' then
    raise exception 'FAIL: a second RETURN import does nothing'; end if;
  n := n + 1;

  -- 10. Washed trolley: contents cannot change.
  v := integration.legacy_sync_import_trolley(v_run, jsonb_set(v_ret, '{row,Content}', '"EMPTY"'));
  if v->>'outcome' <> 'BLOCKED' or not (v->'blockers' @> '[{"code":"INTAKE_ALREADY_WASHED"}]') then
    raise exception 'FAIL: a washed intake keeps its contents (got %)', v; end if;
  n := n + 1;

  -- 11. A legacy customer correction is a revision.
  v := integration.legacy_sync_import_trolley(v_run, jsonb_set(v_ret, '{row,FromCustomerID}',
         to_jsonb(v_customer2.legacy_metadata->>'legacy_customer_id')));
  if v->>'outcome' <> 'UPDATED' or not exists (select 1 from public.sorting_trolley_intakes i
       join public.sorting_trolley_intake_revisions r on r.sorting_trolley_intake_id=i.sorting_trolley_intake_id
       where i.sorting_trolley_intake_id=v_intake and i.customer_id=v_customer2.customer_id and i.revision_no=2
         and r.action_type='CORRECTED') then
    raise exception 'FAIL: legacy correction writes a revision (got %)', v; end if;
  n := n + 1;

  -- 12. A legacy void cancels the intake.
  v := integration.legacy_sync_import_trolley(v_run, jsonb_set(jsonb_set(v_ret, '{row,FromCustomerID}',
         to_jsonb(v_customer2.legacy_metadata->>'legacy_customer_id')), '{row,Voided}', '"YES"'));
  if v->>'outcome' <> 'CANCELLED' or not exists (select 1 from public.sorting_trolley_intakes i
       where i.sorting_trolley_intake_id=v_intake and i.record_status='CANCELLED') then
    raise exception 'FAIL: legacy void cancels the intake (got %)', v; end if;
  n := n + 1;

  -- 13. A trolley with nothing open arrives without outbound record; a second scan within 4 hours is held.
  v_ret2 := jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_ret, '{source_record_id}', '"TR-VALTRL-2"'),
              '{row,ReturnID}', '"TR-VALTRL-2"'), '{row,TrolleyID}', to_jsonb(v_t2.trolley_code)), '{row,ClientEventID}', '"S-VALTRL-2"');
  v := integration.legacy_sync_import_trolley(v_run, v_ret2);
  if v->>'outcome' <> 'IMPORTED' or not exists (select 1 from public.sorting_trolley_intakes i
       join public.trolley_customer_stays s on s.stay_id=i.stay_id
       where i.sorting_trolley_intake_id=(v->>'sorting_trolley_intake_id')::uuid
         and i.custody_tracking_status='MISSING_OUTBOUND_RECORD' and s.exception_type='MISSING_OUTBOUND_RECORD'
         and s.sent_on is null) then
    raise exception 'FAIL: arrival without outbound record (got %)', v; end if;
  v := integration.legacy_sync_import_trolley(v_run, jsonb_set(jsonb_set(jsonb_set(v_ret2, '{source_record_id}', '"TR-VALTRL-3"'),
         '{row,ReturnID}', '"TR-VALTRL-3"'), '{row,ReturnedAt}', to_jsonb(to_char(v_ret_day, 'YYYY-MM-DD') || ' 11:00:00')));
  if v->>'outcome' <> 'BLOCKED' or not exists (select 1 from integration.legacy_sync_review_items
       where source_system='CENTRALDB' and source_table='TrolleyReturns' and source_record_id='TR-VALTRL-3'
         and reason_code='DUPLICATE_SCAN_WITHIN_4H' and status='OPEN') then
    raise exception 'FAIL: a second scan within 4 hours goes to review (got %)', v; end if;
  n := n + 1;

  -- 14. A stay left open since before the sync window is closed when legacy production fills the trolley again.
  insert into public.trolley_customer_stays(trolley_id, outbound_customer_id, sent_on, status, review_status, notes)
  values (v_t3.trolley_id, v_customer2.customer_id, date '2026-09-20', 'OPEN', 'NOT_REQUIRED', 'validation inferred stay')
  returning stay_id into v_old_stay;
  v := integration.legacy_sync_import_trolley(v_run, v_out || jsonb_build_object('source_record_id', v_item_id || ':' || v_t3.trolley_code,
         'trolley_code', v_t3.trolley_code));
  if v->>'outcome' <> 'IMPORTED' or not exists (select 1 from public.trolley_customer_stays s
       where s.stay_id=v_old_stay and s.status='RECEIVED' and s.exception_type='OTHER' and s.review_status='NOT_REQUIRED')
     or not exists (select 1 from public.trolley_customer_stays s where s.trolley_id=v_t3.trolley_id and s.status='OPEN'
                    and s.outbound_customer_id=v_customer.customer_id) then
    raise exception 'FAIL: the old open stay is closed and the new one opened (got %)', v; end if;
  n := n + 1;

  -- 15. Unknown trolley and owner test day.
  v := integration.legacy_sync_plan_trolley(jsonb_set(jsonb_set(v_ret2, '{row,TrolleyID}', '"T9999999999T"'), '{row,ClientEventID}', 'null'));
  if not (v->'blockers' @> '[{"code":"TROLLEY_NOT_IN_V2"}]') then raise exception 'FAIL: unknown trolley is held (got %)', v; end if;
  v := integration.legacy_sync_plan_trolley(jsonb_set(jsonb_set(jsonb_set(v_ret2, '{source_record_id}', '"TR-VALTRL-4"'),
         '{row,ReturnID}', '"TR-VALTRL-4"'), '{row,BusinessDate}', '"2026-10-25"'));
  if v->>'skip_reason' is distinct from 'OWNER_TEST_DAY' then raise exception 'FAIL: 2026-10-25 is skipped (got %)', v; end if;
  n := n + 1;

  -- 16. Control switches it, accounts are refused
  v := integration.legacy_sync_control('OFF', 'validation');
  if (v->'imports'->>'TROLLEY_CUSTODY_IMPORT')::boolean then raise exception 'FAIL: OFF also disables the trolley import'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  begin perform integration.legacy_sync_import_trolley(v_run, v_out); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: an account is refused (got %)', v_state; end if;
  n := n + 1;

  raise exception 'PASSED: all % legacy sync trolley custody checks (nothing was kept)', n;
end;
$$;
