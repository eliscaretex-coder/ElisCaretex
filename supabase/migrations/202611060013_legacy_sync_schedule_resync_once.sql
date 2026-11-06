-- Legacy sync: Distribution runs are synchronised once per schedule batch, not once per statement.
--
-- Problem (checked 06/11/2026): since 202611050003 every insert or status/date update on
-- customer_schedule_versions re-synchronises every Draft/Ready route run from today onwards
-- (statement trigger, 0.3 to 0.6 s each time). A legacy schedule change writes several such
-- statements per customer, so a batch of changed customers ran past the 8 s statement timeout
-- of the Data API. Every nightly run and "Sync now" since 05/11 21:05 failed with
-- "legacy-sync-finish HTTP 500: Database call failed" (Edge Function log: 57014 statement timeout).
--
-- Change:
--   1. The trigger skips the resync while the transaction-local setting
--      app.defer_distribution_resync is 'on'. Every other caller (Customer Studio, manual
--      publish) behaves as before.
--   2. The legacy sync dispatcher sets it for the 'schedule' kind and runs the resync once at
--      the end of the call, so the driver's stop list still follows the schedule.

create or replace function public.customer_schedule_versions_resync_distribution_runs()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if coalesce(current_setting('app.defer_distribution_resync', true), '') = 'on' then
    return null;
  end if;
  perform public.distribution_resync_open_runs();
  return null;
exception when others then
  raise warning 'Distribution runs were not synchronised after the schedule change: %', sqlerrm;
  return null;
end;
$$;

revoke all on function public.customer_schedule_versions_resync_distribution_runs() from public, anon, authenticated;

create or replace function integration.legacy_sync_dispatch_import(p_kind text, p_sync_run_id uuid, p_record jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_result jsonb;
begin
  case p_kind
    when 'wash' then return integration.legacy_sync_import_wash(p_sync_run_id, p_record);
    when 'mop' then return integration.legacy_sync_import_mop(p_sync_run_id, p_record);
    when 'trolley' then return integration.legacy_sync_import_trolley(p_sync_run_id, p_record);
    when 'attendance' then return integration.legacy_sync_import_attendance(p_sync_run_id, p_record);
    when 'master' then return integration.legacy_sync_import_master(p_sync_run_id, p_record);
    when 'schedule' then
      -- One resync of the open route runs for the whole batch (see header).
      perform set_config('app.defer_distribution_resync', 'on', true);
      v_result := integration.legacy_sync_import_schedule(p_sync_run_id, p_record);
      perform set_config('app.defer_distribution_resync', '', true);
      perform public.distribution_resync_open_runs();
      return v_result;
    when 'roster' then return integration.legacy_sync_import_roster(p_sync_run_id, p_record);
    else raise exception using errcode='22023', message=format('Unknown legacy sync kind: %s.', p_kind);
  end case;
end;
$$;

revoke all on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) from public, anon, authenticated;
grant execute on function integration.legacy_sync_dispatch_import(text, uuid, jsonb) to service_role;
