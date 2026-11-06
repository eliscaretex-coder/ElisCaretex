-- Validation for 202611060016_finish_delivery_check_admin_cleanup.sql.
-- Run in the SQL Editor after the migration. It ends with an error that starts with
-- "PASSED": the error rolls back every change (clearances, audit rows), so nothing is kept.
do $$
declare
  v_admin uuid;
  v_super uuid;
  v_terminal uuid;
  v_user uuid;
  v_item uuid;
  v_r jsonb;
  v_ctx jsonb;
  v_clearance uuid;
  v_failed boolean;
  v_in_check boolean;
begin
  select auth_user_id into v_admin from public.account_access_profiles
  where account_type='USER' and job_title_code='ADMINISTRATOR' limit 1;
  select auth_user_id into v_super from public.account_access_profiles
  where account_type='USER' and job_title_code='PRODUCTION_SUPERVISOR' limit 1;
  select ap.auth_user_id into v_terminal from public.account_access_profiles ap
  join public.account_roles ar on ar.auth_user_id=ap.auth_user_id and ar.active
  join public.roles r on r.role_id=ar.role_id and r.role_code='FINISH_OPERATOR'
  where ap.account_type='TERMINAL' limit 1;
  if v_admin is null then raise exception 'FAILED 0: no ADMINISTRATOR account to test with'; end if;

  -- 1. Grants.
  if has_function_privilege('anon','public.get_finish_delivery_check_cleanup(integer)','execute')
     or has_function_privilege('anon','public.clear_finish_delivery_check_items(uuid[],text)','execute')
     or has_function_privilege('anon','public.restore_finish_delivery_check_item(uuid,text)','execute')
     or has_function_privilege('authenticated','public.require_finish_delivery_check_cleanup_access()','execute')
     or has_function_privilege('authenticated','public.finish_delivery_check_item_open(uuid,timestamptz)','execute')
     or has_table_privilege('authenticated','public.finish_delivery_check_clearances','select') then
    raise exception 'FAILED 1: grants';
  end if;

  -- 2. Without a login: refused.
  perform set_config('request.jwt.claims', '{}', true);
  v_failed := false;
  begin perform public.get_finish_delivery_check_cleanup(10); exception when insufficient_privilege then v_failed := true; end;
  if not v_failed then raise exception 'FAILED 2: anonymous call was allowed'; end if;

  -- 3. Supervisor and the Finish terminal: refused.
  foreach v_user in array array_remove(array[v_super, v_terminal], null) loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    if public.can_clear_finish_delivery_check() then raise exception 'FAILED 3a: % may clear', v_user; end if;
    v_failed := false;
    begin perform public.clear_finish_delivery_check_items(array[gen_random_uuid()], 'test reason'); exception when insufficient_privilege then v_failed := true; end;
    if not v_failed then raise exception 'FAILED 3b: % could clear', v_user; end if;
  end loop;

  -- 4. Administrator: list and flag.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  if not public.can_clear_finish_delivery_check() then raise exception 'FAILED 4a: admin cannot clear'; end if;
  v_r := public.get_finish_delivery_check_cleanup(10);
  if jsonb_typeof(v_r->'open_items') <> 'array' or jsonb_typeof(v_r->'cleared') <> 'array' then
    raise exception 'FAILED 4b: %', v_r;
  end if;
  v_ctx := public.get_finish_delivery_reconciliation_context(null);
  if coalesce((v_ctx->>'can_clear_open_items')::boolean, false) is not true then
    raise exception 'FAILED 4c: context flag missing';
  end if;

  v_item := (v_r->'open_items'->0->>'production_flow_item_id')::uuid;
  if v_item is null then
    raise exception 'PASSED (partial): no Finish customer waiting for a delivery check, checks 1-4 passed';
  end if;

  -- 5. A reason is required.
  v_failed := false;
  begin perform public.clear_finish_delivery_check_items(array[v_item], ' x '); exception when invalid_parameter_value then v_failed := true; end;
  if not v_failed then raise exception 'FAILED 5: cleared without a reason'; end if;

  -- 6. Clearing removes it from the delivery check (even when its next prompt is due) and is audited.
  update public.finish_delivery_reconciliations set next_prompt_at = now() - interval '1 minute'
  where production_flow_item_id = v_item;
  v_r := public.clear_finish_delivery_check_items(array[v_item], 'Validation: washed but never entered');
  if (v_r->>'cleared_count')::int <> 1 then raise exception 'FAILED 6a: %', v_r; end if;
  select clearance_id into v_clearance from public.finish_delivery_check_clearances
  where production_flow_item_id = v_item and restored_at is null;
  v_ctx := public.get_finish_delivery_reconciliation_context(null);
  if exists(select 1 from jsonb_array_elements(v_ctx->'items') q where (q->>'production_flow_item_id')::uuid = v_item) then
    raise exception 'FAILED 6b: cleared customer still prompts';
  end if;
  if not exists(select 1 from public.audit_log where entity_id = v_clearance::text and action = 'FINISH_DELIVERY_CHECK_CLEARED') then
    raise exception 'FAILED 6c: no audit row';
  end if;
  if not exists(select 1 from public.production_flow_items where production_flow_item_id = v_item and flow_status = 'OPEN') then
    raise exception 'FAILED 6d: the Production Flow item was changed';
  end if;

  -- 7. Clearing it again is skipped.
  v_r := public.clear_finish_delivery_check_items(array[v_item], 'Validation again');
  if (v_r->>'cleared_count')::int <> 0 or jsonb_array_length(v_r->'skipped') <> 1 then raise exception 'FAILED 7: %', v_r; end if;

  -- 8. Restore brings it back.
  perform public.restore_finish_delivery_check_item(v_clearance, 'Validation restore');
  v_ctx := public.get_finish_delivery_reconciliation_context(null);
  select exists(select 1 from jsonb_array_elements(v_ctx->'items') q where (q->>'production_flow_item_id')::uuid = v_item) into v_in_check;
  if not v_in_check then raise exception 'FAILED 8: restored customer is not back in the delivery check'; end if;

  raise exception 'PASSED: Finish delivery check clean-up validated (item %)', v_item;
end;
$$;
