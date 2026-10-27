-- ElisCaretex V2 - Validation - 202610270005_legacy_sync_schedule
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all 22 legacy sync schedule checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v_admin uuid;
  v_claim jsonb;
  v_state text;
  n integer := 0;
begin
  select ar.auth_user_id into v_admin
  from public.account_roles ar
  join public.roles r on r.role_id=ar.role_id and r.role_code='ADMIN' and r.active
  join public.account_access_profiles ap on ap.auth_user_id=ar.auth_user_id
  where ar.active
  limit 1;
  if v_admin is null then raise exception 'FAIL: an ADMIN account exists for the positive checks'; end if;
  n := n + 1;

  -- Access surface
  if has_table_privilege('authenticated','integration.legacy_sync_schedule','select') then
    raise exception 'FAIL: authenticated cannot read the schedule table'; end if;
  n := n + 1;
  if has_function_privilege('authenticated','integration.legacy_sync_claim_run()','execute') then
    raise exception 'FAIL: authenticated cannot call the claim'; end if;
  n := n + 1;
  if has_function_privilege('anon','public.legacy_sync_control_status()','execute')
     or has_function_privilege('anon','public.legacy_sync_set_auto(boolean)','execute')
     or has_function_privilege('anon','public.legacy_sync_request_now()','execute') then
    raise exception 'FAIL: anon cannot call the control RPCs'; end if;
  n := n + 1;

  -- A non-admin account is refused
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform public.legacy_sync_control_status(); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: non-admin: status refused (got %)', v_state; end if;
  n := n + 1;
  begin perform public.legacy_sync_set_auto(true); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: non-admin: switch refused (got %)', v_state; end if;
  n := n + 1;
  begin perform public.legacy_sync_request_now(); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: non-admin: Sync now refused (got %)', v_state; end if;
  n := n + 1;
  execute 'reset role';

  -- Admin turns it off, on, and asks for a run
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if (public.legacy_sync_set_auto(false)->>'auto_enabled')::boolean then raise exception 'FAIL: admin: switch off'; end if;
  n := n + 1;
  begin perform public.legacy_sync_request_now(); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '55000' then raise exception 'FAIL: admin: Sync now refused while off (got %)', v_state; end if;
  n := n + 1;
  if not (public.legacy_sync_set_auto(true)->>'auto_enabled')::boolean then raise exception 'FAIL: admin: switch on'; end if;
  n := n + 1;
  if not (public.legacy_sync_request_now()->>'request_pending')::boolean then raise exception 'FAIL: admin: Sync now is pending'; end if;
  n := n + 1;
  execute 'reset role';

  if not (select bool_and(enabled and max_entries_per_run=300) from integration.legacy_sync_settings
          where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT')) then
    raise exception 'FAIL: switch on enables both import switches with limit 300'; end if;
  n := n + 1;

  -- The Edge Function (service role: no auth.uid) claims it
  perform set_config('request.jwt.claims', '', true);
  update integration.legacy_sync_schedule set night_from='00:00', night_until='00:01', last_nightly_date=null;
  v_claim := integration.legacy_sync_claim_run();
  if not ((v_claim->>'run')::boolean and v_claim->>'reason'='REQUEST') then raise exception 'FAIL: claim: REQUEST first (got %)', v_claim; end if;
  n := n + 1;
  if not (v_claim->>'dateTo' = to_char((now() at time zone 'Europe/Dublin')::date,'YYYY-MM-DD')
          and (v_claim->>'dateTo')::date - (v_claim->>'dateFrom')::date = 2) then
    raise exception 'FAIL: claim: window is the last 3 Dublin days (got %)', v_claim; end if;
  n := n + 1;
  if integration.legacy_sync_claim_run()->>'reason' <> 'IDLE' then raise exception 'FAIL: claim: a request is claimed only once'; end if;
  n := n + 1;

  -- Nightly window covering now: claimed once per night
  update integration.legacy_sync_schedule set night_from='00:00', night_until='23:59:59';
  if integration.legacy_sync_claim_run()->>'reason' <> 'NIGHTLY' then raise exception 'FAIL: claim: NIGHTLY inside the night window'; end if;
  n := n + 1;
  if integration.legacy_sync_claim_run()->>'reason' <> 'IDLE' then raise exception 'FAIL: claim: NIGHTLY only once per night'; end if;
  n := n + 1;

  -- A run in progress blocks a new claim
  update integration.legacy_sync_schedule set requested_at=now() + interval '1 second';
  insert into integration.legacy_sync_runs(source_system, mode, requested_by, status) values ('FINISH_AREA','COMMIT','validation','RUNNING');
  if integration.legacy_sync_claim_run()->>'reason' <> 'BUSY' then raise exception 'FAIL: claim: BUSY while a run is RUNNING'; end if;
  n := n + 1;

  -- Off means nothing runs
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.legacy_sync_set_auto(false);
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  if integration.legacy_sync_claim_run()->>'reason' <> 'OFF' then raise exception 'FAIL: claim: OFF when switched off'; end if;
  n := n + 1;
  if not (select bool_and(not enabled) from integration.legacy_sync_settings
          where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT')) then
    raise exception 'FAIL: switch off disables both import switches'; end if;
  n := n + 1;
  if (select last_poll_at is null from integration.legacy_sync_schedule) then raise exception 'FAIL: claim records the last poll'; end if;
  n := n + 1;

  -- An account cannot claim even through a definer path
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  begin perform integration.legacy_sync_claim_run(); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: claim refuses a caller with auth.uid() (got %)', v_state; end if;
  n := n + 1;

  raise exception 'PASSED: all % legacy sync schedule checks (nothing was kept)', n;
end;
$$;
