-- ElisCaretex V2 - Validation - 202610270006_legacy_sync_control_from_apps_script
-- One DO block, so it runs the same way in the Supabase SQL Editor, psql or the MCP.
-- It always ends with an exception, which rolls everything back:
--   success: ERROR "PASSED: all 12 legacy sync control checks (nothing was kept)"
--   failure: ERROR "FAIL: <check>"

do $$
declare
  v jsonb;
  v_state text;
  n integer := 0;
begin
  -- Access surface
  if has_function_privilege('authenticated','integration.legacy_sync_control(text,text)','execute')
     or has_function_privilege('anon','integration.legacy_sync_control(text,text)','execute') then
    raise exception 'FAIL: accounts cannot call the control'; end if;
  n := n + 1;
  if to_regprocedure('public.legacy_sync_set_auto(boolean)') is not null
     or to_regprocedure('public.legacy_sync_request_now()') is not null
     or to_regprocedure('public.legacy_sync_control_status()') is not null
     or to_regprocedure('integration.legacy_sync_require_admin()') is not null then
    raise exception 'FAIL: the V2 control RPCs are gone'; end if;
  n := n + 1;

  -- Service role (no auth.uid)
  perform set_config('request.jwt.claims', '', true);
  v := integration.legacy_sync_control('off', 'validation');
  if (v->>'auto_enabled')::boolean then raise exception 'FAIL: OFF switches the schedule off'; end if;
  n := n + 1;
  if not (select bool_and(not enabled) from integration.legacy_sync_settings
          where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT')) then
    raise exception 'FAIL: OFF disables both import switches'; end if;
  n := n + 1;
  if integration.legacy_sync_claim_run()->>'reason' <> 'OFF' then raise exception 'FAIL: the claim answers OFF'; end if;
  n := n + 1;

  v := integration.legacy_sync_control('ON', 'validation');
  if not (v->>'auto_enabled')::boolean then raise exception 'FAIL: ON switches the schedule on'; end if;
  n := n + 1;
  if not (select bool_and(enabled and max_entries_per_run=300 and changed_by='validation') from integration.legacy_sync_settings
          where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT')) then
    raise exception 'FAIL: ON enables both import switches with limit 300'; end if;
  n := n + 1;

  v := integration.legacy_sync_control('STATUS', null);
  if not (v ? 'runs' and v ? 'last_poll_at' and v ? 'open_review_items'
          and (v->>'today')::date - (v->>'date_from')::date = (v->>'window_days')::int - 1) then
    raise exception 'FAIL: STATUS returns the state, the window and the runs (got %)', v; end if;
  n := n + 1;

  begin perform integration.legacy_sync_control('ON', ' '); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '22023' then raise exception 'FAIL: ON needs changed_by (got %)', v_state; end if;
  n := n + 1;
  begin perform integration.legacy_sync_control('DELETE', 'x'); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '22023' then raise exception 'FAIL: unknown action refused (got %)', v_state; end if;
  n := n + 1;

  -- A caller with auth.uid() is refused even through a definer path
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  begin perform integration.legacy_sync_control('STATUS', null); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: the control refuses a caller with auth.uid() (got %)', v_state; end if;
  n := n + 1;
  begin perform integration.legacy_sync_control('OFF', 'x'); v_state := null; exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'FAIL: an account cannot switch it off (got %)', v_state; end if;
  n := n + 1;

  raise exception 'PASSED: all % legacy sync control checks (nothing was kept)', n;
end;
$$;
