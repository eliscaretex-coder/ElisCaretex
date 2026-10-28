-- ElisCaretex V2 - Validation - 202610280003_stock_control
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- Fixtures (accounts, staff, items) are created inside the block and the block
-- always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all stock control checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_admin uuid:=gen_random_uuid(); v_super uuid:=gen_random_uuid(); v_staff_user uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid(); v_auditor uuid:=gen_random_uuid();
  v_staff uuid; v_customer uuid;
  v_uniform uuid; v_chemical uuid; v_packing uuid; v_tool uuid; v_locker uuid;
  v jsonb; v_req uuid; v_req_version int; v_line bigint; v_qty numeric;
begin
  -- Fixtures ------------------------------------------------------------
  insert into auth.users(id,email) values
    (v_admin,'stock-admin@validation.invalid'),(v_super,'stock-super@validation.invalid'),
    (v_staff_user,'stock-staff@validation.invalid'),(v_outsider,'stock-outsider@validation.invalid'),
    (v_auditor,'stock-auditor@validation.invalid');
  insert into public.account_access_profiles(auth_user_id,account_type,job_title_code,display_name) values
    (v_admin,'USER','ADMINISTRATOR','Validation Admin'),(v_super,'USER','PRODUCTION_SUPERVISOR','Validation Supervisor'),
    (v_staff_user,'USER','GENERAL_OPERATIVE','Validation Staff'),(v_outsider,'USER','CUSTOMER_SERVICE','Validation Outsider'),
    (v_auditor,'USER','AUDITOR','Validation Auditor');
  insert into public.account_permission_grants(auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage) values
    (v_admin,'STOCK','ALL',true,true,true,true,true),
    (v_super,'STOCK','ALL',true,false,false,true,false),
    (v_staff_user,'MY_ROSTER','ALL',true,false,false,false,false),
    (v_auditor,'STOCK','ALL',true,false,false,false,false);
  insert into public.staff_members(auth_user_id,employee_code,display_name,active) values (v_staff_user,'VAL-STOCK','Validation Stock Staff',true) returning staff_id into v_staff;
  insert into public.customers(customer_code,customer_name,active) values ('VAL-STOCK','Validation Stock Customer',true) returning customer_id into v_customer;

  -- 1. No access without a grant ---------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub',v_outsider,'role','authenticated')::text, true);
  begin perform public.get_stock_workspace(); raise exception 'FAIL 1: outsider opened the workspace'; exception when insufficient_privilege then null; end;
  begin perform public.get_my_stock(); raise exception 'FAIL 1: account without Staff Master link opened My PPE'; exception when insufficient_privilege then null; end;

  -- 2. Only MANAGE maintains the catalogue -------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub',v_super,'role','authenticated')::text, true);
  begin perform public.save_stock_item(jsonb_build_object('item_name','x','category_code','UNIFORM')); raise exception 'FAIL 2: supervisor created an item'; exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  v_uniform:=(public.save_stock_item(jsonb_build_object('item_name','Validation Polo','category_code','UNIFORM','requestable',true,'size_options',jsonb_build_array('M','S','L','M'),'stock_qty',5,'min_stock',2))->>'item_id')::uuid;
  v_chemical:=(public.save_stock_item(jsonb_build_object('item_name','Validation Detergent','category_code','CHEMICAL','stock_qty',10,'unit_price',2.5))->>'item_id')::uuid;
  v_packing:=(public.save_stock_item(jsonb_build_object('item_name','Validation Bags','category_code','PACKING','stock_qty',100))->>'item_id')::uuid;
  v_tool:=(public.save_stock_item(jsonb_build_object('item_name','Validation Tool','category_code','OTHER','stock_qty',3))->>'item_id')::uuid;
  if (select size_options from public.stock_items where item_id=v_uniform)<>array['L','M','S'] then raise exception 'FAIL 2: sizes not cleaned'; end if;
  if (select track_by from public.stock_items where item_id=v_chemical)<>'NONE' or (select requestable from public.stock_items where item_id=v_chemical) then raise exception 'FAIL 2: chemical defaults'; end if;
  if (select stock_qty from public.stock_items where item_id=v_uniform)<>5 or not exists(select 1 from public.stock_movements where item_id=v_uniform and movement_type='IN' and qty_change=5) then raise exception 'FAIL 2: opening stock not booked'; end if;
  begin perform public.save_stock_item(jsonb_build_object('item_name','validation polo','category_code','UNIFORM')); raise exception 'FAIL 2: duplicate name accepted'; exception when unique_violation then null; end;

  -- 3. Staff with roster access request PPE --------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff_user,'role','authenticated')::text, true);
  v:=public.get_my_stock();
  if not exists(select 1 from jsonb_array_elements(v->'items') x where (x->>'item_id')::uuid=v_uniform) then raise exception 'FAIL 3: requestable item not listed'; end if;
  if exists(select 1 from jsonb_array_elements(v->'items') x where (x->>'item_id')::uuid=v_chemical) then raise exception 'FAIL 3: chemical listed for staff'; end if;
  if exists(select 1 from jsonb_array_elements(v->'items') x where x ? 'stock_qty') then raise exception 'FAIL 3: staff see stock quantities'; end if;
  begin perform public.submit_my_stock_request(jsonb_build_array(jsonb_build_object('item_id',v_uniform,'qty',2,'size','XXL')),null); raise exception 'FAIL 3: invalid size accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.submit_my_stock_request(jsonb_build_array(jsonb_build_object('item_id',v_chemical,'qty',1)),null); raise exception 'FAIL 3: chemical requested'; exception when invalid_parameter_value then null; end;
  v:=public.submit_my_stock_request(jsonb_build_array(jsonb_build_object('item_id',v_uniform,'qty',2,'size','M')),'Lost my polo');
  v_req:=(v->>'request_id')::uuid;
  if v->>'request_status'<>'REQUESTED' or jsonb_array_length(v->'lines')<>1 then raise exception 'FAIL 3: request not saved'; end if;
  begin perform public.get_stock_workspace(); raise exception 'FAIL 3: staff opened the workspace'; exception when insufficient_privilege then null; end;
  begin perform public.decide_stock_request(v_req,'ISSUE',null,null,1); raise exception 'FAIL 3: staff issued own request'; exception when insufficient_privilege then null; end;
  begin perform public.record_stock_movement(jsonb_build_object('item_id',v_packing,'movement_type','IN','qty',1)); raise exception 'FAIL 3: staff moved stock'; exception when insufficient_privilege then null; end;

  -- 4. Supervisor hands it over: stock goes down, the person holds it -----
  perform set_config('request.jwt.claims', json_build_object('sub',v_super,'role','authenticated')::text, true);
  if (public.get_stock_attention()->>'pending_requests')::int<1 then raise exception 'FAIL 4: request not in the queue'; end if;
  begin perform public.decide_stock_request(v_req,'REJECT','',null,1); raise exception 'FAIL 4: decline without reason'; exception when invalid_parameter_value then null; end;
  begin perform public.decide_stock_request(v_req,'ISSUE',null,null,9); raise exception 'FAIL 4: stale version accepted'; exception when serialization_failure then null; end;
  v:=public.decide_stock_request(v_req,'ISSUE','Handed over at the store',null,1);
  if v->>'request_status'<>'ISSUED' then raise exception 'FAIL 4: not issued'; end if;
  if (select stock_qty from public.stock_items where item_id=v_uniform)<>3 then raise exception 'FAIL 4: stock not reduced'; end if;
  if (select qty from public.stock_ppe_balances(v_staff,null) where description='Validation Polo' and size='M')<>2 then raise exception 'FAIL 4: balance not recorded'; end if;
  begin perform public.decide_stock_request(v_req,'ISSUE',null,null,(v->>'row_version')::int); raise exception 'FAIL 4: issued twice'; exception when invalid_parameter_value then null; end;

  -- Staff cancels an open request; an answered one cannot be cancelled.
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff_user,'role','authenticated')::text, true);
  begin perform public.cancel_my_stock_request(v_req); raise exception 'FAIL 4: issued request cancelled'; exception when invalid_parameter_value then null; end;
  v:=public.submit_my_stock_request(jsonb_build_array(jsonb_build_object('item_id',v_uniform,'qty',1,'size','L')),null);
  if public.cancel_my_stock_request((v->>'request_id')::uuid)->>'request_status'<>'CANCELLED' then raise exception 'FAIL 4: cancel failed'; end if;
  if (select jsonb_array_length(public.get_my_stock()->'holding'))<>1 then raise exception 'FAIL 4: staff does not see what they hold'; end if;

  -- 5. Takes: by person, by customer, never more than in stock -----------
  perform set_config('request.jwt.claims', json_build_object('sub',v_super,'role','authenticated')::text, true);
  begin perform public.record_stock_movement(jsonb_build_object('item_id',v_packing,'movement_type','OUT','qty',5)); raise exception 'FAIL 5: packing taken without customer'; exception when invalid_parameter_value then null; end;
  perform public.record_stock_movement(jsonb_build_object('item_id',v_packing,'movement_type','OUT','qty',5,'customer_id',v_customer));
  if (select customer_name from public.stock_movements where item_id=v_packing and movement_type='OUT')<>'Validation Stock Customer' then raise exception 'FAIL 5: customer not booked'; end if;
  begin perform public.record_stock_movement(jsonb_build_object('item_id',v_tool,'movement_type','OUT','qty',4,'staff_id',v_staff)); raise exception 'FAIL 5: more than stock taken'; exception when invalid_parameter_value then null; end;
  begin perform public.record_stock_movement(jsonb_build_object('item_id',v_tool,'movement_type','ADJUST','qty',1)); raise exception 'FAIL 5: adjust without reason'; exception when invalid_parameter_value then null; end;

  -- 6. Count: a chemical drop is consumption, other differences are COUNT --
  v:=public.save_stock_count(jsonb_build_array(jsonb_build_object('item_id',v_chemical,'counted_qty',7),jsonb_build_object('item_id',v_uniform,'counted_qty',4),jsonb_build_object('item_id',v_packing,'counted_qty',null)),'Weekly count');
  if (v->>'items_counted')::int<>2 or (v->>'consumption_lines')::int<>1 or (v->>'items_adjusted')::int<>1 or (v->>'consumption_value')::numeric<>7.5 then raise exception 'FAIL 6: count summary %',v; end if;
  if not exists(select 1 from public.stock_movements where item_id=v_chemical and movement_type='CONSUMPTION' and qty_change=-3 and stock_after=7) then raise exception 'FAIL 6: consumption not booked'; end if;
  if (select stock_qty from public.stock_items where item_id=v_uniform)<>4 then raise exception 'FAIL 6: count not applied'; end if;
  if (select last_counted_at from public.stock_items where item_id=v_chemical) is null then raise exception 'FAIL 6: last count not set'; end if;

  -- 7. Returns: never more than held; restock puts it back -----------------
  begin perform public.record_ppe_event(jsonb_build_object('staff_id',v_staff,'item_id',v_uniform,'size','M','qty',3,'ppe_action','RETURNED')); raise exception 'FAIL 7: returned more than held'; exception when invalid_parameter_value then null; end;
  perform public.record_ppe_event(jsonb_build_object('staff_id',v_staff,'item_id',v_uniform,'size','M','qty',1,'ppe_action','RETURNED','restock',true));
  if (select stock_qty from public.stock_items where item_id=v_uniform)<>5 then raise exception 'FAIL 7: restock not booked'; end if;
  if (select qty from public.stock_ppe_balances(v_staff,null) where description='Validation Polo')<>1 then raise exception 'FAIL 7: balance after return'; end if;

  -- 8. Lockers ------------------------------------------------------------
  begin perform public.add_stock_lockers(array['VAL-01']); raise exception 'FAIL 8: supervisor added a locker'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  if (public.add_stock_lockers(array['val-01','VAL-01',' '])->>'added')::int<>1 then raise exception 'FAIL 8: locker labels not deduplicated'; end if;
  select locker_id into v_locker from public.stock_lockers where label='VAL-01';
  perform set_config('request.jwt.claims', json_build_object('sub',v_super,'role','authenticated')::text, true);
  perform public.record_locker_action(v_locker,'ASSIGN',v_staff,null,null,1);
  begin perform public.record_locker_action(v_locker,'ASSIGN',v_staff,null,null,2); raise exception 'FAIL 8: locker assigned twice'; exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff_user,'role','authenticated')::text, true);
  if not exists(select 1 from jsonb_array_elements(public.get_my_stock()->'lockers') x where x->>'label'='VAL-01') then raise exception 'FAIL 8: staff does not see the locker'; end if;

  -- 9. Leavers still holding items are listed ---------------------------
  -- Staff Master changes run without an end-user identity (trusted maintenance).
  perform set_config('request.jwt.claims','{}',true);
  update public.staff_members set active=false,deactivated_on=current_date-1 where staff_id=v_staff;
  perform set_config('request.jwt.claims', json_build_object('sub',v_auditor,'role','authenticated')::text, true);
  v:=public.get_stock_workspace();
  if not exists(select 1 from jsonb_array_elements(v->'pending_returns') x where (x->>'staff_id')::uuid=v_staff and x->'locker_labels' ? 'VAL-01' and jsonb_array_length(x->'ppe')=1) then raise exception 'FAIL 9: leaver not listed'; end if;
  if (v->>'can_operate')::boolean then raise exception 'FAIL 9: auditor can operate'; end if;
  begin perform public.record_locker_action(v_locker,'RETURN',null,null,null,2); raise exception 'FAIL 9: auditor returned a key'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub',v_super,'role','authenticated')::text, true);
  begin perform public.record_ppe_event(jsonb_build_object('staff_id',v_staff,'item_id',v_uniform,'size','M','qty',1,'ppe_action','ISSUED')); raise exception 'FAIL 9: issued to a leaver'; exception when invalid_parameter_value then null; end;
  perform public.record_locker_action(v_locker,'RETURN',null,null,'Collected on exit',2);
  if (select locker_status from public.stock_lockers where locker_id=v_locker)<>'AVAILABLE' then raise exception 'FAIL 9: key not returned'; end if;

  -- 10. Grants --------------------------------------------------------------
  if has_function_privilege('anon','public.get_my_stock()','execute') or has_function_privilege('anon','public.get_stock_workspace()','execute') then raise exception 'FAIL 10: anon can call stock RPCs'; end if;
  if has_function_privilege('authenticated','public.stock_apply_movement(uuid,text,numeric,uuid,uuid,uuid,text,text,uuid,uuid)','execute')
     or has_function_privilege('authenticated','public.stock_people()','execute') then raise exception 'FAIL 10: internal helper callable'; end if;
  if has_table_privilege('authenticated','public.stock_items','select') or has_table_privilege('authenticated','public.stock_movements','insert') then raise exception 'FAIL 10: direct table access'; end if;

  raise exception 'PASSED: all stock control checks (nothing was kept)';
end;
$$;
