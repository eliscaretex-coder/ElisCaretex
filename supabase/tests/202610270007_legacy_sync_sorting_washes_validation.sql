-- ElisCaretex V2 - Validation - 202610270007_legacy_sync_sorting_washes
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all 16 legacy sync Sorting wash checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_day date := (now() at time zone 'Europe/Dublin')::date - 1;
  v_customer public.customers%rowtype;
  v_staff public.staff_members%rowtype;
  v_washer public.sorting_washers%rowtype;
  v_wash_id text := 'W' || to_char((now() at time zone 'Europe/Dublin')::date - 1, 'YYYYMMDD') || '-100500-VALID001';
  v_record jsonb;
  v_run uuid;
  v jsonb;
  v_state text;
  n integer := 0;
begin
  perform set_config('request.jwt.claims', '', true);

  -- Fixtures from live data: a customer with a published CLOTHES day yesterday,
  -- a production staff member with a unique display name, a Clothes washer.
  select c.* into v_customer
  from public.customers c
  where c.active and c.deleted_at is null and c.legacy_metadata ? 'legacy_customer_id'
    and exists (select 1 from public.customer_schedule_versions csv
                join public.customer_schedule_days sd on sd.schedule_version_id=csv.schedule_version_id and sd.active
                  and sd.production_weekday=extract(isodow from v_day)::smallint
                join public.customer_schedule_products sp on sp.schedule_day_id=sd.schedule_day_id and sp.active
                join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.active
                  and pt.deleted_at is null and pt.product_code='CLOTHES'
                where csv.customer_id=c.customer_id and csv.status='PUBLISHED' and csv.effective_from<=v_day
                  and (csv.effective_until is null or csv.effective_until>=v_day))
    and (select count(*) from public.customers x where x.deleted_at is null
         and x.legacy_metadata->>'legacy_customer_id' = c.legacy_metadata->>'legacy_customer_id') = 1
  limit 1;
  if v_customer.customer_id is null then raise exception 'FAIL: fixture customer with a CLOTHES schedule yesterday'; end if;
  select sm.* into v_staff
  from public.staff_members sm
  where sm.deleted_at is null and sm.active and sm.production_staff
    and (select count(*) from public.staff_members x where x.deleted_at is null
         and lower(btrim(x.display_name)) = lower(btrim(sm.display_name))) = 1
    and not exists (select 1 from public.sorting_daily_staff_attendance a
                    where a.staff_id=sm.staff_id and a.business_date=v_day and a.attendance_status='ABSENT')
  limit 1;
  select w.* into v_washer from public.sorting_washers w
  where w.deleted_at is null and w.active and w.capacity_kg >= 80 order by w.washer_code limit 1;
  if v_staff.staff_id is null or v_washer.washer_id is null then raise exception 'FAIL: fixture staff and washer'; end if;

  v_record := jsonb_build_object(
    'source_record_id', v_wash_id,
    'wash', jsonb_build_object('WashID', v_wash_id, 'StartTime', '10:05:00',
      'RegisterTime', to_char(v_day, 'YYYY-MM-DD') || 'T10:06:00', 'Machine', v_washer.washer_name,
      'Who', v_staff.display_name, 'Type', 'CLOTHES', 'Kg', '60'),
    'items', jsonb_build_array(jsonb_build_object('WashItemID', 'WI-VALID-1', 'WashID', v_wash_id,
      'CustomerID', v_customer.legacy_metadata->>'legacy_customer_id', 'ScheduledDate', to_char(v_day, 'YYYY-MM-DD'),
      'Type', 'CLOTHES', 'KGShare', '60')),
    'staff_shifts', jsonb_build_array('Morning'));

  -- Access surface
  if has_function_privilege('authenticated','integration.legacy_sync_import_wash(uuid,jsonb)','execute')
     or has_function_privilege('anon','integration.legacy_sync_wash_dry_run(jsonb)','execute') then
    raise exception 'FAIL: accounts cannot call the wash importer'; end if;
  n := n + 1;
  if not exists (select 1 from integration.legacy_sync_settings where setting_key='SORTING_WASH_IMPORT') then
    raise exception 'FAIL: SORTING_WASH_IMPORT switch exists'; end if;
  n := n + 1;

  -- Dry run
  v := integration.legacy_sync_wash_dry_run(jsonb_build_array(v_record));
  if not ((v->>'ready')::int = 1 and v#>>'{plans,0,action}' = 'CREATE' and (v->>'writes_performed')::int = 0) then
    raise exception 'FAIL: dry run plans one CREATE (got %)', v - 'plans'; end if;
  n := n + 1;
  if v#>>'{plans,0,resolved,shift_code}' <> 'MORNING' or v#>>'{plans,0,customers,0,schedule_relation}' <> 'TODAY' then
    raise exception 'FAIL: dry run resolves the shift and the schedule (got %)', v->'plans'; end if;
  n := n + 1;

  -- Switch OFF refuses writes
  update integration.legacy_sync_settings set enabled=false where setting_key='SORTING_WASH_IMPORT';
  v_run := integration.legacy_sync_start_run('FINISH_AREA', 'COMMIT', v_day, v_day, 'validation');
  begin perform integration.legacy_sync_import_wash(v_run, v_record); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '55000' then raise exception 'FAIL: switch OFF refuses the import (got %)', v_state; end if;
  n := n + 1;

  -- Import
  update integration.legacy_sync_settings set enabled=true where setting_key='SORTING_WASH_IMPORT';
  v := integration.legacy_sync_import_wash(v_run, v_record);
  if not (v->>'imported')::boolean or v->>'wash_code' <> v_wash_id then raise exception 'FAIL: import writes the wash (got %)', v; end if;
  n := n + 1;
  if not exists (select 1 from public.sorting_wash_runs wr
                 join public.sorting_wash_run_customers c on c.wash_run_id=wr.wash_run_id
                 where wr.wash_code=v_wash_id and wr.source_application='LEGACY_SYNC_SORTING' and wr.status='RECORDED'
                   and wr.business_date=v_day and wr.operator_staff_id=v_staff.staff_id
                   and c.customer_id=v_customer.customer_id and c.schedule_relation='TODAY'
                   and c.scheduled_for_date=v_day and c.allocated_weight_kg=60) then
    raise exception 'FAIL: the wash and its customer row are written as Sorting does'; end if;
  n := n + 1;
  if not exists (select 1 from public.sorting_wash_runs wr
                 join public.sorting_wash_run_customers c on c.wash_run_id=wr.wash_run_id
                 join public.production_flow_items f on f.production_flow_item_id=c.production_flow_item_id
                 join public.production_flow_events e on e.production_flow_item_id=f.production_flow_item_id
                   and e.event_type='WASH_RECORDED' and e.source_entity_id=c.wash_run_customer_id::text
                 where wr.wash_code=v_wash_id and f.product_code='CLOTHES' and f.scheduled_for_date=v_day) then
    raise exception 'FAIL: the customer is linked to its Production Flow with WASH_RECORDED'; end if;
  n := n + 1;

  if integration.legacy_sync_import_wash(v_run, v_record)->>'outcome' <> 'ALREADY_IMPORTED' then
    raise exception 'FAIL: a second import does nothing'; end if;
  n := n + 1;

  -- A changed legacy load becomes a correction
  v := integration.legacy_sync_import_wash(v_run, jsonb_set(v_record, '{wash,Kg}', '"65"'));
  if v->>'outcome' <> 'UPDATED' or v->>'wash_code' <> v_wash_id || '-R2' then raise exception 'FAIL: change is a correction (got %)', v; end if;
  n := n + 1;
  if not exists (select 1 from public.sorting_wash_runs o join public.sorting_wash_runs r on r.replaces_wash_run_id=o.wash_run_id
                 where o.wash_code=v_wash_id and o.status='CANCELLED' and r.status='RECORDED'
                   and r.entry_mode='CORRECTION' and r.total_weight_kg=65) then
    raise exception 'FAIL: the old run is cancelled and replaced'; end if;
  n := n + 1;

  -- Review queue and skips
  v := integration.legacy_sync_import_wash(v_run, jsonb_set(jsonb_set(jsonb_set(v_record, '{source_record_id}', '"W-VALID-BAD"'),
         '{wash,WashID}', '"W-VALID-BAD"'), '{items,0}', jsonb_build_object('WashItemID','WI-BAD','WashID','W-VALID-BAD','CustomerID','CID-NOPE-00000','ScheduledDate',to_char(v_day,'YYYY-MM-DD'),'Type','CLOTHES')));
  if v->>'outcome' <> 'BLOCKED' or not exists (select 1 from integration.legacy_sync_review_items
     where source_system='SORTING_AREA' and source_record_id='W-VALID-BAD' and reason_code='CUSTOMER_NOT_FOUND' and status='OPEN') then
    raise exception 'FAIL: an unknown customer goes to the review queue (got %)', v; end if;
  n := n + 1;
  v := integration.legacy_sync_plan_wash(jsonb_set(v_record, '{wash,RegisterTime}', '"2026-10-25T10:06:00"'));
  if v->>'skip_reason' is distinct from 'OWNER_TEST_DAY' then raise exception 'FAIL: 2026-10-25 is skipped (got %)', v->>'outcome'; end if;
  n := n + 1;

  -- Control switches every import, accounts are refused
  v := integration.legacy_sync_control('OFF', 'validation');
  if (select enabled from integration.legacy_sync_settings where setting_key='SORTING_WASH_IMPORT')
     or (v->'imports'->>'SORTING_WASH_IMPORT')::boolean then
    raise exception 'FAIL: OFF also disables the Sorting wash import'; end if;
  n := n + 1;
  v := integration.legacy_sync_control('ON', 'validation');
  if not (v->'imports'->>'SORTING_WASH_IMPORT')::boolean then raise exception 'FAIL: ON also enables the Sorting wash import'; end if;
  n := n + 1;
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  begin perform integration.legacy_sync_import_wash(v_run, v_record); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: an account is refused (got %)', v_state; end if;
  n := n + 1;

  raise exception 'PASSED: all % legacy sync Sorting wash checks (nothing was kept)', n;
end;
$$;
