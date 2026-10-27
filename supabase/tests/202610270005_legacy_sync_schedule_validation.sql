-- ElisCaretex V2 - Validation - 202610270005_legacy_sync_schedule
-- Runs entirely inside one transaction and ends with ROLLBACK: nothing is kept.
-- Plain SQL assertions (pgTAP is not installed on the remote project).
-- Every failed assertion raises an exception and aborts the run.

begin;

create function pg_temp.check(p_ok boolean, p_label text) returns void language plpgsql as $$
begin
  if p_ok is distinct from true then
    raise exception 'FAIL: %', p_label;
  end if;
  raise notice 'ok - %', p_label;
end;
$$;

-- SQLSTATE raised by a statement, or null when it succeeds.
create function pg_temp.sqlstate_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlstate;
end;
$$;
grant execute on function pg_temp.sqlstate_of(text) to authenticated;

create temp table t_admin as
select ar.auth_user_id
from public.account_roles ar
join public.roles r on r.role_id=ar.role_id and r.role_code='ADMIN' and r.active
join public.account_access_profiles ap on ap.auth_user_id=ar.auth_user_id
where ar.active
limit 1;
grant select on t_admin to authenticated;

select pg_temp.check((select count(*) from t_admin)=1, 'an ADMIN account exists for the positive checks');

-- Access surface
select pg_temp.check(not has_table_privilege('authenticated','integration.legacy_sync_schedule','select'),
  'authenticated cannot read the schedule table');
select pg_temp.check(not has_function_privilege('authenticated','integration.legacy_sync_claim_run()','execute'),
  'authenticated cannot call the claim');
select pg_temp.check(not has_function_privilege('anon','public.legacy_sync_control_status()','execute')
  and not has_function_privilege('anon','public.legacy_sync_set_auto(boolean)','execute')
  and not has_function_privilege('anon','public.legacy_sync_request_now()','execute'),
  'anon cannot call the control RPCs');

-- A non-admin account is refused
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.check(pg_temp.sqlstate_of('select public.legacy_sync_control_status()')='42501', 'non-admin: status refused');
select pg_temp.check(pg_temp.sqlstate_of('select public.legacy_sync_set_auto(true)')='42501', 'non-admin: switch refused');
select pg_temp.check(pg_temp.sqlstate_of('select public.legacy_sync_request_now()')='42501', 'non-admin: Sync now refused');
reset role;

-- Admin turns it on and asks for a run
select set_config('request.jwt.claims', json_build_object('sub', (select auth_user_id from t_admin)::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.check((public.legacy_sync_set_auto(false)->>'auto_enabled')::boolean = false, 'admin: switch off');
select pg_temp.check(pg_temp.sqlstate_of('select public.legacy_sync_request_now()')='55000', 'admin: Sync now refused while off');
select pg_temp.check((public.legacy_sync_set_auto(true)->>'auto_enabled')::boolean, 'admin: switch on');
select pg_temp.check((public.legacy_sync_request_now()->>'request_pending')::boolean, 'admin: Sync now is pending');
reset role;

select pg_temp.check((select bool_and(enabled and max_entries_per_run=300) from integration.legacy_sync_settings
  where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT')), 'switch on enables both import switches with limit 300');

-- The Edge Function (service role: no auth.uid) claims it
select set_config('request.jwt.claims', '', true);
update integration.legacy_sync_schedule set night_from='00:00', night_until='00:01', last_nightly_date=null;
create temp table t_claim as select integration.legacy_sync_claim_run() c;
select pg_temp.check((select (c->>'run')::boolean and c->>'reason'='REQUEST' from t_claim), 'claim: REQUEST first');
select pg_temp.check((select c->>'dateTo' = to_char((now() at time zone 'Europe/Dublin')::date,'YYYY-MM-DD')
  and (c->>'dateTo')::date - (c->>'dateFrom')::date = 2 from t_claim), 'claim: window is the last 3 Dublin days');
select pg_temp.check(integration.legacy_sync_claim_run()->>'reason'='IDLE', 'claim: a request is claimed only once');

-- Nightly window covering now: claimed once per night
update integration.legacy_sync_schedule set night_from='00:00', night_until='23:59:59';
select pg_temp.check(integration.legacy_sync_claim_run()->>'reason'='NIGHTLY', 'claim: NIGHTLY inside the night window');
select pg_temp.check(integration.legacy_sync_claim_run()->>'reason'='IDLE', 'claim: NIGHTLY only once per night');

-- A run in progress blocks a new claim
update integration.legacy_sync_schedule set requested_at=now() + interval '1 second';
insert into integration.legacy_sync_runs(source_system, mode, requested_by, status) values ('FINISH_AREA','COMMIT','validation','RUNNING');
select pg_temp.check(integration.legacy_sync_claim_run()->>'reason'='BUSY', 'claim: BUSY while a run is RUNNING');

-- Off means nothing runs
select set_config('request.jwt.claims', json_build_object('sub', (select auth_user_id from t_admin)::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select public.legacy_sync_set_auto(false);
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.check(integration.legacy_sync_claim_run()->>'reason'='OFF', 'claim: OFF when switched off');
select pg_temp.check((select bool_and(not enabled) from integration.legacy_sync_settings
  where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT')), 'switch off disables both import switches');
select pg_temp.check((select last_poll_at is not null from integration.legacy_sync_schedule), 'claim records the last poll');

-- An account cannot claim even through a definer path
select set_config('request.jwt.claims', json_build_object('sub', (select auth_user_id from t_admin)::text, 'role', 'authenticated')::text, true);
select pg_temp.check(pg_temp.sqlstate_of('select integration.legacy_sync_claim_run()')='42501', 'claim refuses a caller with auth.uid()');

select 'ALL CHECKS PASSED' as result;
rollback;
