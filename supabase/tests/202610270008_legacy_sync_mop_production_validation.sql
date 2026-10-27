-- ElisCaretex V2 - Validation - 202610270008_legacy_sync_mop_production
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all 16 legacy sync MOP production checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_day date := (now() at time zone 'Europe/Dublin')::date - 1;
  v_customer public.customers%rowtype;
  v_staff public.staff_members%rowtype;
  v_washer public.sorting_washers%rowtype;
  v_tag text := to_char((now() at time zone 'Europe/Dublin')::date - 1, 'YYYYMMDD');
  v_wash_id text := 'W' || to_char((now() at time zone 'Europe/Dublin')::date - 1, 'YYYYMMDD') || '-090000-VALMOP01';
  v_item_id text := 'WI' || to_char((now() at time zone 'Europe/Dublin')::date - 1, 'YYYYMMDD') || '-01-VALMOP01';
  v_wash jsonb;
  v_event jsonb;
  v_record jsonb;
  v_run uuid;
  v_batch uuid;
  v jsonb;
  v_state text;
  n integer := 0;
begin
  perform set_config('request.jwt.claims', '', true);

  -- Fixtures from live data: an active customer with a unique legacy id, a production
  -- staff member with a unique display name, a washer of 60 KG or more.
  select c.* into v_customer
  from public.customers c
  where c.active and c.deleted_at is null and c.legacy_metadata ? 'legacy_customer_id'
    and (select count(*) from public.customers x where x.deleted_at is null
         and x.legacy_metadata->>'legacy_customer_id' = c.legacy_metadata->>'legacy_customer_id') = 1
  order by c.customer_code limit 1;
  select sm.* into v_staff
  from public.staff_members sm
  where sm.deleted_at is null and sm.active and sm.production_staff
    and (select count(*) from public.staff_members x where x.deleted_at is null
         and lower(btrim(x.display_name)) = lower(btrim(sm.display_name))) = 1
    and not exists (select 1 from public.sorting_daily_staff_attendance a
                    where a.staff_id=sm.staff_id and a.business_date=v_day and a.attendance_status='ABSENT')
    and not exists (select 1 from public.work_sessions ws where ws.staff_id=sm.staff_id and ws.work_date=v_day
                    and ws.source='SORTING_AREA_TRANSFER' and ws.status<>'CANCELLED')
  limit 1;
  select w.* into v_washer from public.sorting_washers w
  where w.deleted_at is null and w.active and w.capacity_kg >= 60 order by w.washer_code limit 1;
  if v_customer.customer_id is null or v_staff.staff_id is null or v_washer.washer_id is null then
    raise exception 'FAIL: fixtures (customer, staff, washer)'; end if;

  -- The MOP wash first (Sorting washes part), then its MOP production.
  v_wash := jsonb_build_object(
    'source_record_id', v_wash_id,
    'wash', jsonb_build_object('WashID', v_wash_id, 'StartTime', '09:00:00',
      'RegisterTime', to_char(v_day, 'YYYY-MM-DD') || 'T09:01:00', 'Machine', v_washer.washer_name,
      'Who', v_staff.display_name, 'Type', 'MOP', 'Kg', '40'),
    'items', jsonb_build_array(jsonb_build_object('WashItemID', v_item_id, 'WashID', v_wash_id,
      'CustomerID', v_customer.legacy_metadata->>'legacy_customer_id', 'ScheduledDate', to_char(v_day, 'YYYY-MM-DD'),
      'Type', 'MOP', 'KGShare', '40')),
    'staff_shifts', jsonb_build_array('Morning'));
  v_event := jsonb_build_object('MopEventID', 'MP-VALID-1', 'WashItemID', v_item_id, 'WashID', v_wash_id,
    'CustomerID', v_customer.legacy_metadata->>'legacy_customer_id', 'BusinessDate', to_char(v_day, 'YYYY-MM-DD'),
    'Shift', 'Morning', 'EventType', 'PRODUCTION', 'QtyKgDelta', '12.4', 'QtyUnitsDelta', '103',
    'BatchNo', 'MOPBATCH_VALID', 'MopModel', 'STANDARD POCKET MOPS', 'Trolleys', 'T0012025T',
    'ProcessedBy', v_staff.display_name, 'ProcessedAt', to_char(v_day, 'YYYY-MM-DD') || ' 11:30:00',
    'CreatedAt', to_char(v_day, 'YYYY-MM-DD') || ' 11:30:20', 'ABSStatus', 'PENDING', 'Status', 'ACTIVE');
  v_record := jsonb_build_object('source_record_id', v_item_id,
    'item', jsonb_build_object('WashItemID', v_item_id, 'WashID', v_wash_id,
      'CustomerID', v_customer.legacy_metadata->>'legacy_customer_id', 'ScheduledDate', to_char(v_day, 'YYYY-MM-DD'), 'Type', 'MOP'),
    'events', jsonb_build_array(v_event));

  -- Access surface
  if has_function_privilege('authenticated','integration.legacy_sync_import_mop(uuid,jsonb)','execute')
     or has_function_privilege('anon','integration.legacy_sync_mop_dry_run(jsonb)','execute') then
    raise exception 'FAIL: accounts cannot call the MOP importer'; end if;
  n := n + 1;

  -- Without the wash in V2 the MOP row waits in review.
  v := integration.legacy_sync_mop_dry_run(jsonb_build_array(v_record));
  if not ((v->>'blocked')::int = 1 and v->'blocker_counts' ? 'WASH_NOT_IN_V2' and (v->>'writes_performed')::int = 0) then
    raise exception 'FAIL: dry run waits for the wash (got %)', v - 'plans'; end if;
  n := n + 1;

  update integration.legacy_sync_settings set enabled=true where setting_key in ('SORTING_WASH_IMPORT','MOP_PRODUCTION_IMPORT');
  v_run := integration.legacy_sync_start_run('FINISH_AREA', 'COMMIT', v_day, v_day, 'validation');
  v := integration.legacy_sync_import_wash(v_run, v_wash);
  if not coalesce((v->>'imported')::boolean, false) then raise exception 'FAIL: fixture MOP wash imports (got %)', v; end if;

  v := integration.legacy_sync_mop_dry_run(jsonb_build_array(v_record));
  if not ((v->>'ready')::int = 1 and v#>>'{plans,0,action}' = 'CREATE' and v#>>'{plans,0,resolved,flow_via}' = 'V2_WASH') then
    raise exception 'FAIL: dry run plans one CREATE on the wash flow (got %)', v - 'plans'; end if;
  n := n + 1;

  -- Switch OFF refuses writes
  update integration.legacy_sync_settings set enabled=false where setting_key='MOP_PRODUCTION_IMPORT';
  begin perform integration.legacy_sync_import_mop(v_run, v_record); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '55000' then raise exception 'FAIL: switch OFF refuses the import (got %)', v_state; end if;
  n := n + 1;
  update integration.legacy_sync_settings set enabled=true where setting_key='MOP_PRODUCTION_IMPORT';

  -- Import
  v := integration.legacy_sync_import_mop(v_run, v_record);
  if v->>'outcome' <> 'IMPORTED' then raise exception 'FAIL: import writes the MOP production (got %)', v; end if;
  v_batch := (v->>'mop_production_batch_id')::uuid;
  n := n + 1;
  if not exists (select 1 from public.sorting_mop_production_batches mb
                 join public.sorting_mop_production_lines l on l.mop_production_batch_id=mb.mop_production_batch_id
                 join public.sorting_mop_production_trolleys t on t.mop_production_batch_id=mb.mop_production_batch_id
                 join public.sorting_wash_run_customers wrc on wrc.production_flow_item_id=mb.production_flow_item_id
                 join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id and wr.wash_code=v_wash_id
                 where mb.mop_production_batch_id=v_batch and mb.status='RECORDED' and mb.entry_mode='LIVE'
                   and mb.business_date=v_day and mb.shift_code_snapshot='MORNING' and mb.operator_staff_id=v_staff.staff_id
                   and mb.total_weight_kg=12.4 and mb.total_units=103 and mb.physical_processed_time='11:30:00'
                   and l.variant_code_snapshot='STANDARD_POCKET_MOPS' and l.weight_kg=12.4 and l.units=103
                   and t.trolley_code_snapshot='T0012025T' and t.lifecycle_action='LATE_REFERENCE_ONLY') then
    raise exception 'FAIL: the batch, line and trolley reference are written on the wash flow'; end if;
  n := n + 1;
  if not exists (select 1 from public.production_flow_events e
                 where e.source_entity_id=v_batch::text and e.event_type='MOP_PRODUCTION_RECORDED') then
    raise exception 'FAIL: MOP_PRODUCTION_RECORDED on the Production Flow'; end if;
  n := n + 1;
  if integration.legacy_sync_import_mop(v_run, v_record)->>'outcome' <> 'ALREADY_IMPORTED' then
    raise exception 'FAIL: a second import does nothing'; end if;
  n := n + 1;

  -- The legacy ABS posting adds the ABS batch only.
  v_record := jsonb_set(v_record, '{events,0}', v_event || jsonb_build_object('ABSStatus','POSTED','ABSBatchID','174',
    'ABSLoggedAt', to_char(v_day, 'YYYY-MM-DD') || ' 22:00:00', 'ABSLoggedBy', v_staff.display_name));
  v := integration.legacy_sync_import_mop(v_run, v_record);
  if v->>'outcome' <> 'ABS_UPDATED' or not exists (select 1 from public.production_flow_external_batches b
       join public.sorting_mop_production_batches mb on mb.production_flow_item_id=b.production_flow_item_id
       where mb.mop_production_batch_id=v_batch and b.status='ACTIVE' and b.batch_reference='174'
         and b.quantity=12.4 and b.unit_code='KG') then
    raise exception 'FAIL: ABS POSTED writes the ABS batch (got %)', v; end if;
  n := n + 1;

  -- A changed legacy row becomes a new revision; the ABS batch follows.
  v := integration.legacy_sync_import_mop(v_run, jsonb_set(v_record, '{events,0,QtyKgDelta}', '"13"'));
  if v->>'outcome' <> 'UPDATED' then raise exception 'FAIL: change is a correction (got %)', v; end if;
  if not exists (select 1 from public.sorting_mop_production_batches o
                 join public.sorting_mop_production_batches r on r.supersedes_mop_production_batch_id=o.mop_production_batch_id
                 where o.mop_production_batch_id=v_batch and o.status='CANCELLED' and o.cancellation_kind='CORRECTED'
                   and r.status='RECORDED' and r.revision_no=2 and r.total_weight_kg=13)
     or not exists (select 1 from public.production_flow_external_batches b
                    join public.sorting_mop_production_batches mb on mb.production_flow_item_id=b.production_flow_item_id
                    where mb.mop_production_batch_id=v_batch and b.status='ACTIVE' and b.quantity=13
                      and b.supersedes_external_batch_id is not null) then
    raise exception 'FAIL: the old revision is corrected and the ABS batch follows'; end if;
  n := n + 1;

  -- A legacy cancellation cancels the V2 production and its ABS batch.
  v := integration.legacy_sync_import_mop(v_run, jsonb_set(jsonb_set(v_record, '{events,0,QtyKgDelta}', '"13"'),
         '{events,0,Status}', '"CANCELLED"'));
  if v->>'outcome' <> 'CANCELLED' or exists (select 1 from public.sorting_mop_production_batches mb
       where mb.production_flow_item_id=(select production_flow_item_id from public.sorting_mop_production_batches where mop_production_batch_id=v_batch)
         and mb.status='RECORDED')
     or exists (select 1 from public.production_flow_external_batches b
       where b.production_flow_item_id=(select production_flow_item_id from public.sorting_mop_production_batches where mop_production_batch_id=v_batch)
         and b.status='ACTIVE') then
    raise exception 'FAIL: legacy cancellation cancels the production and ABS (got %)', v; end if;
  n := n + 1;

  -- Review queue and skips
  v := integration.legacy_sync_import_mop(v_run, jsonb_build_object('source_record_id','WI-VALID-BAD',
    'item', jsonb_build_object('WashItemID','WI-VALID-BAD','WashID',v_wash_id,'CustomerID',v_customer.legacy_metadata->>'legacy_customer_id','ScheduledDate',to_char(v_day,'YYYY-MM-DD')),
    'events', jsonb_build_array(v_event || jsonb_build_object('WashItemID','WI-VALID-BAD','MopEventID','MP-VALID-BAD','MopModel','GOLDEN MOP'))));
  if v->>'outcome' <> 'BLOCKED' or not exists (select 1 from integration.legacy_sync_review_items
     where source_system='CENTRALDB' and source_table='MopProduction' and source_record_id='WI-VALID-BAD'
       and reason_code='MOP_MODEL_UNMAPPED' and status='OPEN') then
    raise exception 'FAIL: an unknown MOP model goes to the review queue (got %)', v; end if;
  n := n + 1;
  if integration.legacy_sync_mop_variant('Grey mop with white stripe') is distinct from
     (select product_variant_id from public.product_variants where variant_code='GREY_STRIPED_WHITE_MOP' and deleted_at is null limit 1) then
    raise exception 'FAIL: the accepted legacy spelling maps to its variant'; end if;
  n := n + 1;
  v := integration.legacy_sync_plan_mop(jsonb_set(v_record, '{events,0,BusinessDate}', '"2026-10-25"'));
  if v->>'skip_reason' is distinct from 'OWNER_TEST_DAY' then raise exception 'FAIL: 2026-10-25 is skipped (got %)', v->>'outcome'; end if;
  n := n + 1;

  -- Control switches it, accounts are refused
  v := integration.legacy_sync_control('OFF', 'validation');
  if (v->'imports'->>'MOP_PRODUCTION_IMPORT')::boolean then raise exception 'FAIL: OFF also disables the MOP import'; end if;
  n := n + 1;
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  begin perform integration.legacy_sync_import_mop(v_run, v_record); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: an account is refused (got %)', v_state; end if;
  n := n + 1;

  raise exception 'PASSED: all % legacy sync MOP production checks (nothing was kept)', n;
end;
$$;
