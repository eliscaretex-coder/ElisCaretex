-- Validation for 202611060016_production_computer_sign_in_by_name.sql.
-- Run in the SQL Editor after the migration. It ends with an error that starts with
-- "PASSED": the error rolls back every change (renames, emails), so nothing is kept.
do $$
declare
  v_device uuid;
  v_user uuid;
  v_other uuid;
  v_personal uuid;
  v_personal_email text;
  v_email text;
  v_failed boolean;
begin
  select station_device_id, device_auth_user_id into v_device, v_user
  from public.production_station_devices where device_code = 'FINISH-T2-PC01';
  if v_device is null then raise exception 'FAILED 0: FINISH-T2-PC01 not found'; end if;
  select station_device_id into v_other from public.production_station_devices
  where device_code <> 'FINISH-T2-PC01' and device_auth_user_id is not null limit 1;

  -- 1. Grants: nothing new is callable from the browser.
  if has_function_privilege('anon','public.production_computer_sign_in_name(text)','execute')
     or has_function_privilege('authenticated','public.production_computer_sign_in_name(text)','execute')
     or has_function_privilege('anon','public.sync_production_computer_sign_in_email(uuid,text)','execute')
     or has_function_privilege('authenticated','public.sync_production_computer_sign_in_email(uuid,text)','execute')
     or has_function_privilege('authenticated','public.production_station_devices_sync_sign_in()','execute')
     or has_table_privilege('anon','public.production_station_devices','select')
     or has_table_privilege('authenticated','public.production_station_devices','update') then
    raise exception 'FAILED 1: browser roles can reach the new functions or the devices table';
  end if;

  -- 2. Normalisation rule.
  if public.production_computer_sign_in_name('TABLE2_PC1') <> 'table2-pc1'
     or public.production_computer_sign_in_name('  Table2 PC1 ') <> 'table2-pc1'
     or public.production_computer_sign_in_name('FINISH-T2-PC01') <> 'finish-t2-pc01' then
    raise exception 'FAILED 2: sign-in name normalisation is wrong';
  end if;

  -- 3. Backfill: the Table 2 computer now signs in as table2-pc1.
  select email into v_email from auth.users where id = v_user;
  if v_email <> 'table2-pc1@terminal.eliscaretex.local' then
    raise exception 'FAILED 3: expected table2-pc1@terminal.eliscaretex.local, got %', v_email;
  end if;

  -- 4. Every computer's email matches its Computer name.
  if exists (
    select 1 from public.production_station_devices d join auth.users u on u.id = d.device_auth_user_id
    where u.email <> public.production_computer_sign_in_name(d.device_name) || '@terminal.eliscaretex.local'
  ) then
    raise exception 'FAILED 4: a computer email does not follow its Computer name';
  end if;

  -- 5. Renaming (as the account service does, with service_role) moves the sign-in name.
  set local role service_role;
  update public.production_station_devices set device_name = 'Table2 Test PC' where station_device_id = v_device;
  reset role;
  select email into v_email from auth.users where id = v_user;
  if v_email <> 'table2-test-pc@terminal.eliscaretex.local' then
    raise exception 'FAILED 5: rename did not move the email (got %)', v_email;
  end if;
  if not exists (select 1 from auth.identities where user_id = v_user and provider = 'email'
                 and identity_data->>'email' = 'table2-test-pc@terminal.eliscaretex.local') then
    raise exception 'FAILED 5b: identity email not updated';
  end if;

  -- 6. Two computers cannot share a sign-in name.
  if v_other is not null then
    v_failed := false;
    begin
      update public.production_station_devices set device_name = 'TABLE2_TEST_PC' where station_device_id = v_other;
    exception when unique_violation then v_failed := true;
    end;
    if not v_failed then raise exception 'FAILED 6: duplicate sign-in name accepted'; end if;
  end if;

  -- 7. A name with no letters or digits is refused.
  v_failed := false;
  begin
    update public.production_station_devices set device_name = '___' where station_device_id = v_device;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'FAILED 7: empty sign-in name accepted'; end if;

  -- 8. A personal account is never renamed, even if the sync is pointed at it.
  select id, email into v_personal, v_personal_email from auth.users
  where email not like '%@terminal.eliscaretex.local' limit 1;
  if v_personal is not null then
    perform public.sync_production_computer_sign_in_email(v_personal, 'Hijack PC');
    if (select email from auth.users where id = v_personal) is distinct from v_personal_email then
      raise exception 'FAILED 8: a personal account email was changed';
    end if;
  end if;

  raise exception 'PASSED: 8 checks. Every change was rolled back.';
end;
$$;
