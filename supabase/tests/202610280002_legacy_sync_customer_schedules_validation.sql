-- Validation for 202610280002_legacy_sync_customer_schedules.sql.
-- Run in the SQL Editor. It ends with an error that starts with "PASSED": the error
-- rolls back every change (test customers, route, revisions, run), so nothing is kept.
do $$
declare
  v_run uuid;
  v_route_id uuid;
  v_a uuid;
  v_b uuid;
  v_v1 uuid;
  v_v2 uuid;
  v_r jsonb;
  v_have jsonb;
  v_n int;
  v_day jsonb := jsonb_build_object('ProductionDay','Monday','Route','VAL2','DeliveryTime','8:30 - 9:00',
                   'ClothesOrder','3','QtyClothes','2M','DeliveryOrder','4');
  v_wed jsonb := jsonb_build_object('ProductionDay','Wednesday','Route','VAL2','ClothesOrder','5','QtyClothes','1M+1S',
                   'MopOrder','6','TrolleyMop','1S','MopProducts','STANDARD POCKET MOPS; CLEANING CLOTHS');
  v_rec jsonb;
begin
  update integration.legacy_sync_settings set enabled=true, max_entries_per_run=200 where setting_key='SCHEDULE_IMPORT';
  v_run := integration.legacy_sync_start_run('FINISH_AREA','COMMIT',current_date,current_date,'validation 0002');

  -- 1. A new legacy route is created and linked; the same row again changes nothing.
  v_r := integration.legacy_sync_import_schedule(v_run, '{"record_type":"ROUTE","source_record_id":"val2","row":{"RouteID":"VAL2","DisplayName":"Route VAL2","Colour":"#123456"}}');
  select route_id into v_route_id from public.distribution_routes where route_code='VAL2' and route_color='#123456' and active and allow_as_default;
  if v_r->>'outcome' <> 'IMPORTED' or v_route_id is null then raise exception 'FAILED 1: %', v_r; end if;
  if integration.legacy_sync_plan_route('{"record_type":"ROUTE","source_record_id":"VAL2","row":{"RouteID":"VAL2","DisplayName":"Route VAL2","Colour":"#123456"}}')->>'outcome' <> 'ALREADY_IMPORTED' then
    raise exception 'FAILED 1b: route planned again';
  end if;

  -- 2. A colour changed in the legacy app is written; the name is kept.
  update public.distribution_routes set display_name='Renamed in V2' where route_id=v_route_id;
  v_r := integration.legacy_sync_import_schedule(v_run, '{"record_type":"ROUTE","source_record_id":"VAL2","row":{"RouteID":"VAL2","DisplayName":"Route VAL2","Colour":"#654321"}}');
  if v_r->>'outcome' <> 'UPDATED' or not exists (select 1 from public.distribution_routes where route_id=v_route_id
       and route_color='#654321' and display_name='Renamed in V2') then
    raise exception 'FAILED 2: %', v_r;
  end if;

  -- Test customers with Clothes and MOP.
  insert into public.customers(customer_code, customer_name, active) values ('VALIDATION-0002A','Validation 0002 A',true) returning customer_id into v_a;
  insert into public.customers(customer_code, customer_name, active) values ('VALIDATION-0002B','Validation 0002 B',true) returning customer_id into v_b;
  insert into public.customer_product_services(customer_id, product_type_id, effective_from, active)
  select c, pt.product_type_id, current_date - 30, true from unnest(array[v_a, v_b]) c, public.product_types pt where pt.product_code in ('CLOTHES','MOP');

  -- 3. A customer with no schedule gets revision 1, published, equal to the legacy rows.
  v_rec := jsonb_build_object('record_type','SCHEDULE','source_record_id','VALIDATION-0002A',
             'row', jsonb_build_object('CustomerID','VALIDATION-0002A','days', jsonb_build_array(v_day, v_wed)));
  v_r := integration.legacy_sync_import_schedule(v_run, v_rec);
  select schedule_version_id into v_v1 from public.customer_schedule_versions
  where customer_id=v_a and status='PUBLISHED' and source_code='LEGACY_IMPORT' and version_number=1;
  if v_r->>'outcome' <> 'IMPORTED' or v_v1 is null then raise exception 'FAILED 3: %', v_r; end if;
  if integration.legacy_sync_schedule_have(v_v1) <> (integration.legacy_sync_schedule_want(v_rec->'row'))->'want' then
    raise exception 'FAILED 3b: revision % differs from the legacy rows', integration.legacy_sync_schedule_have(v_v1);
  end if;
  if (integration.legacy_sync_schedule_have(v_v1))->'3.trolleys' <> '["CLOTHES:MEDIUM:1", "CLOTHES:SMALL:1", "MOP:SMALL:1"]'::jsonb
     or (integration.legacy_sync_schedule_have(v_v1))->'3.MOP.variants' <> '["CLEANING_CLOTHS", "STANDARD_POCKET_MOPS"]'::jsonb then
    raise exception 'FAILED 3c: trolleys or MOP products not built';
  end if;
  if (select delivery_weekday from public.customer_schedule_days where schedule_version_id=v_v1 and production_weekday=1) <> 2 then
    raise exception 'FAILED 3d: delivery weekday is not the V2 automatic one';
  end if;

  -- 4. The same rows again: nothing to do.
  if integration.legacy_sync_plan_schedule(v_rec)->>'outcome' <> 'ALREADY_IMPORTED' then raise exception 'FAILED 4'; end if;

  -- 5. V2 changed Monday's delivery order by hand; the legacy app changed Wednesday's window.
  --    The legacy change is written in a new revision; the V2 change is kept.
  v_v2 := integration.legacy_sync_schedule_publish(v_a, v_v1, array['1.delivery_order'],
            integration.legacy_sync_schedule_have(v_v1) || '{"1.delivery_order": 9}'::jsonb, 'validation manual edit');
  update public.customer_schedule_versions set source_code='MANUAL' where schedule_version_id=v_v2;
  v_rec := jsonb_set(v_rec, '{row,days,1}', v_wed || '{"DeliveryTime":"10:00-10:30"}');
  v_r := integration.legacy_sync_import_schedule(v_run, v_rec);
  v_have := integration.legacy_sync_schedule_have((integration.legacy_sync_schedule_versions(v_a)->>'current')::uuid);
  if v_r->>'outcome' <> 'UPDATED' or v_have->>'3.window' <> '10:00-10:30' or (v_have->>'1.delivery_order')::int <> 9 then
    raise exception 'FAILED 5: % / %', v_r, v_have;
  end if;
  if (select status from public.customer_schedule_versions where schedule_version_id=v_v2) <> 'SUPERSEDED' then
    raise exception 'FAILED 5b: the previous revision was not superseded';
  end if;

  -- 6. Wednesday removed and Friday added in the legacy app.
  v_rec := jsonb_set(v_rec, '{row,days}', jsonb_build_array(v_day, v_day || '{"ProductionDay":"Friday","QtyClothes":"0"}'));
  v_r := integration.legacy_sync_import_schedule(v_run, v_rec);
  v_have := integration.legacy_sync_schedule_have((integration.legacy_sync_schedule_versions(v_a)->>'current')::uuid);
  if v_r->>'outcome' <> 'UPDATED' or v_have ? '3' or not v_have ? '5' or v_have->'5.trolleys' <> '[]'::jsonb then
    raise exception 'FAILED 6: % / %', v_r, v_have;
  end if;

  -- 7. An open draft in Customer Studio holds the change for review.
  insert into public.customer_schedule_versions(customer_id, version_number, status, effective_from, source_code)
  values (v_a, 99, 'DRAFT', current_date, 'MANUAL');
  v_r := integration.legacy_sync_import_schedule(v_run, jsonb_set(v_rec, '{row,days,0,DeliveryOrder}', '"5"'));
  if v_r->>'outcome' <> 'BLOCKED' or not (v_r->'blockers') @> '[{"code":"SCHEDULE_DRAFT_OPEN_IN_V2"}]'
     or not exists (select 1 from integration.legacy_sync_review_items where source_table='CustomerSchedule'
                    and source_record_id='VALIDATION-0002A' and reason_code='SCHEDULE_DRAFT_OPEN_IN_V2' and status='OPEN') then
    raise exception 'FAILED 7: %', v_r;
  end if;

  -- 8. First meeting: the baseline is the latest LEGACY_IMPORT revision. A value changed by
  --    hand in V2 since then is kept and listed; a value the legacy app changed is written.
  v_v1 := integration.legacy_sync_schedule_publish(v_b, null, array['1','1.route','1.window','1.delivery_order','1.alert',
            '1.delivery_notes','1.products','1.CLOTHES.order','1.CLOTHES.instructions','1.trolleys'],
            (integration.legacy_sync_schedule_want(jsonb_build_object('days', jsonb_build_array(v_day))))->'want', 'validation import');
  v_v2 := integration.legacy_sync_schedule_publish(v_b, v_v1, array['1.route'],
            integration.legacy_sync_schedule_have(v_v1) || '{"1.route": null}'::jsonb, 'validation manual route');
  update public.customer_schedule_versions set source_code='MANUAL' where schedule_version_id=v_v2;
  v_rec := jsonb_build_object('record_type','SCHEDULE','source_record_id','VALIDATION-0002B',
             'row', jsonb_build_object('days', jsonb_build_array(v_day || '{"QtyClothes":"3M"}')));
  v_r := integration.legacy_sync_plan_schedule(v_rec);
  if v_r->>'outcome' <> 'READY' or v_r->>'action' <> 'UPDATE' or v_r->>'baseline' <> 'LEGACY_IMPORT'
     or (select array_agg(k) from jsonb_object_keys(v_r->'changes') k) <> array['1.trolleys']
     or not (v_r->'warnings') @> '[{"code":"V2_DIFFERS"}]' or (v_r->'warnings'->0->>'detail') not like 'Mon route: V2 - / legacy VAL2%' then
    raise exception 'FAILED 8: %', v_r - 'want' - 'merged';
  end if;

  -- 9. Rows the sync cannot read are held, never guessed.
  v_r := integration.legacy_sync_plan_schedule(jsonb_build_object('record_type','SCHEDULE','source_record_id','VALIDATION-0002B',
           'row', jsonb_build_object('days', jsonb_build_array(
             v_day || '{"QtyClothes":"2X"}', v_day, v_wed || '{"MopProducts":"GOLDEN MOP"}', v_day || '{"ProductionDay":"Someday"}'))));
  if not (v_r->'blockers') @> '[{"code":"INVALID_TROLLEY_TEXT"},{"code":"DUPLICATE_PRODUCTION_DAY"},{"code":"UNKNOWN_MOP_PRODUCT"},{"code":"INVALID_PRODUCTION_DAY"}]' then
    raise exception 'FAILED 9: %', v_r->'blockers';
  end if;
  v_r := integration.legacy_sync_plan_schedule(jsonb_build_object('record_type','SCHEDULE','source_record_id','VALIDATION-NO-SUCH',
           'row', jsonb_build_object('days', jsonb_build_array(v_day))));
  if not (v_r->'blockers') @> '[{"code":"CUSTOMER_NOT_IN_V2"}]' then raise exception 'FAILED 9b: %', v_r; end if;

  -- 10. Switch off: refused. No client role can call the importer.
  update integration.legacy_sync_settings set enabled=false where setting_key='SCHEDULE_IMPORT';
  begin
    perform integration.legacy_sync_import_schedule(v_run, v_rec);
    raise exception 'FAILED 10: imported with the switch off';
  exception when object_not_in_prerequisite_state then null; end;
  if has_function_privilege('authenticated','integration.legacy_sync_import_schedule(uuid,jsonb)','execute')
     or has_function_privilege('anon','integration.legacy_sync_schedule_dry_run(jsonb)','execute')
     or has_function_privilege('authenticated','integration.legacy_sync_schedule_publish(uuid,uuid,text[],jsonb,text)','execute') then
    raise exception 'FAILED 10b: a client role can call the schedule sync';
  end if;

  -- 11. Every revision written by the sync is audited with the run.
  select count(*) into v_n from public.audit_log where correlation_id=v_run and source_application='LEGACY_SYNC_SCHEDULE';
  if v_n <> 5 then raise exception 'FAILED 11: % audit rows', v_n; end if;

  raise exception 'PASSED: 202610280002 legacy sync customer schedules (11 checks)';
end;
$$;
