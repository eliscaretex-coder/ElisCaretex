-- Validation for 202610270013_legacy_sync_staff_user_alias.sql.
-- Run in the SQL Editor. It ends with an error that starts with "PASSED": the error
-- rolls back every change, so nothing is kept.
do $$
declare
  v_staff uuid;
  v_r jsonb;
  v_row jsonb := jsonb_build_object('Shift','Morning Shift','Position','Sorting Area','Roster','Yes',
                   'FireTraining','No','FirstAidTraining','No','EODCapable','No','JoinedAt','2026-10-13');
begin
  if integration.legacy_sync_map_value('CENTRALDB','STAFF_USER_ALIAS','111') is distinct from '112' then
    raise exception 'FAILED 1: alias 111 -> 112 is missing';
  end if;

  select staff_id into v_staff from public.staff_members
  where legacy_user_id = 112 and display_name = 'Ryotaro Kawauchi' and deleted_at is null;
  if v_staff is null or exists (select 1 from public.staff_members where legacy_user_id = 111) then
    raise exception 'FAILED 2: the V2 person is not on legacy user 112 as "Ryotaro Kawauchi"';
  end if;

  v_r := integration.legacy_sync_resolve_staff('111', 'Ryotaro');
  if (v_r->>'staff_id')::uuid is distinct from v_staff then
    raise exception 'FAILED 3: legacy user 111 does not reach the V2 person: %', v_r;
  end if;
  v_r := integration.legacy_sync_resolve_staff('112', 'Ryotaro Kawauchi');
  if (v_r->>'staff_id')::uuid is distinct from v_staff then
    raise exception 'FAILED 4: legacy user 112 does not reach the V2 person: %', v_r;
  end if;

  v_r := integration.legacy_sync_plan_master(jsonb_build_object('record_type','STAFF','source_record_id','111',
    'row', v_row || jsonb_build_object('UserID','111','Name','Ryotaro','Active','No','DeactivatedAt','2026-10-24')));
  if v_r->>'outcome' <> 'SKIPPED' or v_r->>'skip_reason' <> 'LEGACY_USER_ALIAS' then
    raise exception 'FAILED 5: register user 111 is not skipped as an alias: %', v_r;
  end if;

  v_r := integration.legacy_sync_plan_master(jsonb_build_object('record_type','STAFF','source_record_id','112',
    'row', v_row || jsonb_build_object('UserID','112','Name','Ryotaro Kawauchi','Active','Yes','Cover','Sorting Area')));
  if v_r->>'outcome' not in ('READY','ALREADY_IMPORTED') or v_r->>'action' = 'CREATE'
     or (v_r->>'target_id')::uuid is distinct from v_staff then
    raise exception 'FAILED 6: register user 112 does not link to the V2 person: %', v_r;
  end if;

  begin
    insert into integration.legacy_sync_value_maps(source_system, value_domain, raw_value, canonical_value, approved_by)
    values ('CENTRALDB','STAFF_USER_ALIAS','abc','112','validation');
    raise exception 'FAILED 7: a non-numeric alias was accepted';
  exception when check_violation then null;
  end;
  begin
    insert into integration.legacy_sync_value_maps(source_system, value_domain, raw_value, canonical_value, approved_by)
    values ('CENTRALDB','STAFF_USER_ALIAS','113','113','validation');
    raise exception 'FAILED 8: an alias to itself was accepted';
  exception when check_violation then null;
  end;

  raise exception 'PASSED: all 8 legacy sync staff alias checks (nothing was kept)';
end;
$$;
