-- Validation for 202611060015_mop_queue_admin_cleanup.sql.
-- Run in the SQL Editor after the migration. It ends with an error that starts with
-- "PASSED": the error rolls back every change (clearances, audit rows), so nothing is kept.
do $$
declare
  v_admin uuid;
  v_super uuid;
  v_terminal uuid;
  v_item uuid;
  v_r jsonb;
  v_ctx jsonb;
  v_clearance uuid;
  v_failed boolean;
begin
  select auth_user_id into v_admin from public.account_access_profiles
  where account_type='USER' and job_title_code='ADMINISTRATOR' limit 1;
  select auth_user_id into v_super from public.account_access_profiles
  where account_type='USER' and job_title_code='PRODUCTION_SUPERVISOR' limit 1;
  select ap.auth_user_id into v_terminal from public.account_access_profiles ap
  join public.account_roles ar on ar.auth_user_id=ap.auth_user_id and ar.active
  join public.roles r on r.role_id=ar.role_id and r.role_code='SORTING_OPERATOR'
  where ap.account_type='TERMINAL' limit 1;
  if v_admin is null then raise exception 'FAILED 0: no ADMINISTRATOR account to test with'; end if;

  -- 1. Grants: anon cannot call any of the new functions; the internal guard is not callable.
  if has_function_privilege('anon','public.get_sorting_mop_queue_cleanup(integer)','execute')
     or has_function_privilege('anon','public.clear_sorting_mop_queue_items(uuid[],text)','execute')
     or has_function_privilege('anon','public.restore_sorting_mop_queue_item(uuid,text)','execute')
     or has_function_privilege('authenticated','public.require_sorting_mop_queue_cleanup_access()','execute')
     or has_table_privilege('authenticated','public.sorting_mop_queue_clearances','select') then
    raise exception 'FAILED 1: grants';
  end if;

  -- 2. Without a login: refused.
  perform set_config('request.jwt.claims', '{}', true);
  v_failed := false;
  begin perform public.get_sorting_mop_queue_cleanup(10); exception when insufficient_privilege then v_failed := true; end;
  if not v_failed then raise exception 'FAILED 2: anonymous call was allowed'; end if;

  -- 3. Supervisor (no MANAGE on MOP) and the Sorting terminal: refused.
  foreach v_item in array array_remove(array[v_super, v_terminal], null) loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_item, 'role', 'authenticated')::text, true);
    if public.can_clear_sorting_mop_queue() then raise exception 'FAILED 3a: % may clear', v_item; end if;
    v_failed := false;
    begin perform public.clear_sorting_mop_queue_items(array[gen_random_uuid()], 'test reason'); exception when insufficient_privilege then v_failed := true; end;
    if not v_failed then raise exception 'FAILED 3b: % could clear', v_item; end if;
  end loop;

  -- 4. Administrator: sees the clean-up list and the flag in the MOP context.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  if not public.can_clear_sorting_mop_queue() then raise exception 'FAILED 4a: admin cannot clear'; end if;
  v_r := public.get_sorting_mop_queue_cleanup(10);
  if jsonb_typeof(v_r->'open_items') <> 'array' or jsonb_typeof(v_r->'cleared') <> 'array' then
    raise exception 'FAILED 4b: %', v_r;
  end if;
  v_ctx := public.get_sorting_mop_production_context('MORNING', null);
  if coalesce((v_ctx->>'can_clear_open_items')::boolean, false) is not true then
    raise exception 'FAILED 4c: context flag missing';
  end if;

  v_item := (v_r->'open_items'->0->>'production_flow_item_id')::uuid;
  if v_item is null then
    raise exception 'PASSED (partial): no open MOP item to clear, checks 1-4 passed';
  end if;
  if not exists(select 1 from jsonb_array_elements(v_ctx->'queue') q where (q->>'production_flow_item_id')::uuid = v_item) then
    raise exception 'FAILED 4d: open item % is not in the MOP queue', v_item;
  end if;

  -- 5. A reason is required.
  v_failed := false;
  begin perform public.clear_sorting_mop_queue_items(array[v_item], ' x '); exception when invalid_parameter_value then v_failed := true; end;
  if not v_failed then raise exception 'FAILED 5: cleared without a reason'; end if;

  -- 6. Clearing hides the item from the queue and is audited.
  v_r := public.clear_sorting_mop_queue_items(array[v_item], 'Validation: washed but never entered');
  if (v_r->>'cleared_count')::int <> 1 then raise exception 'FAILED 6a: %', v_r; end if;
  select clearance_id into v_clearance from public.sorting_mop_queue_clearances
  where production_flow_item_id = v_item and restored_at is null;
  v_ctx := public.get_sorting_mop_production_context('MORNING', null);
  if exists(select 1 from jsonb_array_elements(v_ctx->'queue') q where (q->>'production_flow_item_id')::uuid = v_item) then
    raise exception 'FAILED 6b: cleared item still in the queue';
  end if;
  if not exists(select 1 from public.audit_log where entity_id = v_clearance::text and action = 'MOP_QUEUE_ITEM_CLEARED') then
    raise exception 'FAILED 6c: no audit row';
  end if;
  if not exists(select 1 from public.production_flow_items where production_flow_item_id = v_item and flow_status = 'OPEN') then
    raise exception 'FAILED 6d: the Production Flow item was changed';
  end if;

  -- 7. Clearing it again is skipped, not duplicated.
  v_r := public.clear_sorting_mop_queue_items(array[v_item], 'Validation again');
  if (v_r->>'cleared_count')::int <> 0 or jsonb_array_length(v_r->'skipped') <> 1 then raise exception 'FAILED 7: %', v_r; end if;

  -- 8. Restore puts it back in the queue.
  perform public.restore_sorting_mop_queue_item(v_clearance, 'Validation restore');
  v_ctx := public.get_sorting_mop_production_context('MORNING', null);
  if not exists(select 1 from jsonb_array_elements(v_ctx->'queue') q where (q->>'production_flow_item_id')::uuid = v_item) then
    raise exception 'FAILED 8: restored item is not back in the queue';
  end if;

  -- 9. The LIVE save no longer counts cleared items as overdue.
  if pg_get_functiondef('public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time without time zone,text,text)'::regprocedure)
     not like '%sorting_mop_queue_clearances%' then
    raise exception 'FAILED 9: save_sorting_mop_production does not exclude cleared items';
  end if;

  raise exception 'PASSED: MOP queue clean-up validated (item %)', v_item;
end;
$$;
