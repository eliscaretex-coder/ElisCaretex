-- ElisCaretex V2 - Validation - 202610280005_stock_control_locker_requests_and_leavers
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- Fixtures are created inside the block and the block always ends with an
-- exception, which rolls everything back:
--   success: ERROR "PASSED: all locker request checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_admin uuid:=gen_random_uuid(); v_super uuid:=gen_random_uuid(); v_staff_user uuid:=gen_random_uuid();
  v_staff uuid; v_free uuid; v_taken uuid; v jsonb; v_req uuid; v_version int;
begin
  -- Fixtures ------------------------------------------------------------
  insert into auth.users(id,email) values
    (v_admin,'locker-admin@validation.invalid'),(v_super,'locker-super@validation.invalid'),(v_staff_user,'locker-staff@validation.invalid');
  insert into public.account_access_profiles(auth_user_id,account_type,job_title_code,display_name) values
    (v_admin,'USER','ADMINISTRATOR','Validation Admin'),(v_super,'USER','PRODUCTION_SUPERVISOR','Validation Supervisor'),
    (v_staff_user,'USER','GENERAL_OPERATIVE','Validation Staff');
  insert into public.account_permission_grants(auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage) values
    (v_admin,'STOCK','ALL',true,true,true,true,true),
    (v_super,'STOCK','ALL',true,false,false,true,false),
    (v_staff_user,'MY_ROSTER','ALL',true,false,false,false,false);
  insert into public.staff_members(auth_user_id,employee_code,display_name,active) values (v_staff_user,'VAL-LOCKER','Validation Locker Staff',true) returning staff_id into v_staff;
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  perform public.add_stock_lockers(array['VAL-L1','VAL-L2']);
  select locker_id into v_free from public.stock_lockers where label='VAL-L1';
  select locker_id into v_taken from public.stock_lockers where label='VAL-L2';
  perform public.record_locker_action(v_taken,'OUT_OF_SERVICE',null,null,'Broken lock',1);

  -- 1. Staff without a key asks for one, once -----------------------------
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff_user,'role','authenticated')::text, true);
  v:=public.submit_my_locker_request(null);
  v_req:=(v->>'request_id')::uuid; v_version:=(v->>'row_version')::int;
  if v->>'request_kind'<>'LOCKER_KEY' or v->>'request_status'<>'REQUESTED' or jsonb_array_length(v->'lines')<>0 then raise exception 'FAIL 1: locker request not saved'; end if;
  begin perform public.submit_my_locker_request('again'); raise exception 'FAIL 1: second open locker request accepted'; exception when invalid_parameter_value then null; end;
  if not exists(select 1 from jsonb_array_elements(public.get_my_stock()->'requests') x where x->>'request_kind'='LOCKER_KEY') then raise exception 'FAIL 1: request not shown to staff'; end if;
  begin perform public.resolve_locker_request(v_req,'ASSIGN',v_free,null,v_version); raise exception 'FAIL 1: staff assigned own locker'; exception when insufficient_privilege then null; end;

  -- 2. Supervisor answers with a free locker -------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub',v_super,'role','authenticated')::text, true);
  begin perform public.decide_stock_request(v_req,'ISSUE',null,null,v_version); raise exception 'FAIL 2: locker request handed over as items'; exception when invalid_parameter_value then null; end;
  begin perform public.resolve_locker_request(v_req,'ASSIGN',v_taken,null,v_version); raise exception 'FAIL 2: locker out of service assigned'; exception when invalid_parameter_value then null; end;
  begin perform public.resolve_locker_request(v_req,'SOLVED',null,' ',v_version); raise exception 'FAIL 2: solved without a note'; exception when invalid_parameter_value then null; end;
  v:=public.resolve_locker_request(v_req,'ASSIGN',v_free,null,v_version);
  if v->>'request_status'<>'ISSUED' or v->>'locker_label'<>'VAL-L1' then raise exception 'FAIL 2: request not closed with the locker'; end if;
  if (select staff_id from public.stock_lockers where locker_id=v_free) is distinct from v_staff then raise exception 'FAIL 2: locker not assigned'; end if;
  if not exists(select 1 from public.stock_locker_events where locker_id=v_free and locker_action='ASSIGNED' and staff_id=v_staff) then raise exception 'FAIL 2: locker event missing'; end if;

  -- 3. With a key, a request needs a reason; solved with a note ------------
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff_user,'role','authenticated')::text, true);
  if (public.get_my_stock()->'lockers'->0->>'label')<>'VAL-L1' then raise exception 'FAIL 3: staff do not see their key'; end if;
  begin perform public.submit_my_locker_request(null); raise exception 'FAIL 3: problem without a reason accepted'; exception when invalid_parameter_value then null; end;
  v:=public.submit_my_locker_request('I lost my key');
  v_req:=(v->>'request_id')::uuid;
  if (v->'current_lockers'->>0)<>'VAL-L1' then raise exception 'FAIL 3: current key not shown with the request'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_super,'role','authenticated')::text, true);
  v:=public.resolve_locker_request(v_req,'SOLVED',null,'Spare key handed over',(v->>'row_version')::int);
  if v->>'request_status'<>'ISSUED' or v->>'decision_note'<>'Spare key handed over' or v->>'locker_id' is not null then raise exception 'FAIL 3: not solved'; end if;
  begin perform public.resolve_locker_request(v_req,'SOLVED',null,'again',(v->>'row_version')::int); raise exception 'FAIL 3: answered twice'; exception when invalid_parameter_value then null; end;

  -- Wrong locker: the new key replaces the one held.
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  perform public.record_locker_action(v_taken,'BACK_IN_SERVICE',null,null,null,2);
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff_user,'role','authenticated')::text, true);
  v:=public.submit_my_locker_request('This is not my locker: mine is VAL-L2');
  perform set_config('request.jwt.claims', json_build_object('sub',v_super,'role','authenticated')::text, true);
  v:=public.resolve_locker_request((v->>'request_id')::uuid,'ASSIGN',v_taken,null,(v->>'row_version')::int,true);
  if (select locker_status from public.stock_lockers where locker_id=v_free)<>'AVAILABLE' then raise exception 'FAIL 3: old key not returned'; end if;
  if (select staff_id from public.stock_lockers where locker_id=v_taken) is distinct from v_staff then raise exception 'FAIL 3: new key not assigned'; end if;
  if not exists(select 1 from public.stock_locker_events where locker_id=v_free and locker_action='RETURNED' and notes like 'Replaced by locker VAL-L2%') then raise exception 'FAIL 3: return not logged'; end if;

  -- 4. Last working day: staff are told, the store sees the return due -----
  perform set_config('request.jwt.claims','{}',true);
  update public.staff_members set deactivated_on=current_date+7 where staff_id=v_staff;
  perform set_config('request.jwt.claims', json_build_object('sub',v_staff_user,'role','authenticated')::text, true);
  if (public.get_my_stock()->>'leaving_on')::date<>current_date+7 then raise exception 'FAIL 4: leaving date not shown to staff'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_super,'role','authenticated')::text, true);
  if not exists(select 1 from jsonb_array_elements(public.get_stock_workspace()->'pending_returns') x
                where (x->>'staff_id')::uuid=v_staff and (x->>'leaving_on')::date=current_date+7 and (x->>'is_active')::boolean) then
    raise exception 'FAIL 4: leaver with a key not listed under returns due';
  end if;

  raise exception 'PASSED: all locker request checks (nothing was kept)';
end $$;
