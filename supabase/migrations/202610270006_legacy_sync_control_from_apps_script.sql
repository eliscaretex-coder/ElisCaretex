-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270006_legacy_sync_control_from_apps_script
--
-- Owner decision 2026-10-27: the on/off switch and "Sync now" live in the
-- Apps Script admin page, not in V2. Depends on 202610270005.
--
--   * integration.legacy_sync_control(p_action, p_changed_by): service_role
--     only (the legacy-sync-finish Edge Function, HMAC-signed requests from
--     the Apps Script). STATUS returns the state and the last runs; ON / OFF
--     switch the schedule and both import switches together, exactly as
--     legacy_sync_set_auto did (ON sets the run limit to 300).
--   * The V2 administrator RPCs from 202610270005 are dropped, with their
--     helper: legacy_sync_control_status(), legacy_sync_set_auto(boolean),
--     legacy_sync_request_now(), integration.legacy_sync_require_admin().
--   * "Sync now" no longer goes through the database: the Apps Script page
--     runs the import itself. The nightly claim is unchanged.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

create or replace function integration.legacy_sync_control(p_action text, p_changed_by text)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_action text := upper(btrim(coalesce(p_action, '')));
  v_who text := nullif(btrim(coalesce(p_changed_by, '')), '');
  s integration.legacy_sync_schedule%rowtype;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync control is not available to accounts.';
  end if;
  if v_action not in ('STATUS','ON','OFF') then
    raise exception using errcode='22023', message='Action must be STATUS, ON or OFF.';
  end if;

  if v_action in ('ON','OFF') then
    if v_who is null or length(v_who) > 200 then
      raise exception using errcode='22023', message='changed_by is required.';
    end if;
    update integration.legacy_sync_schedule
    set auto_enabled=(v_action='ON'), changed_at=now(), changed_by=v_who
    where schedule_key='FINISH_AREA';
    update integration.legacy_sync_settings
    set enabled=(v_action='ON'),
        max_entries_per_run=case when v_action='ON' then 300 else max_entries_per_run end,
        changed_at=now(), changed_by=v_who,
        note=case when v_action='ON' then 'Enabled from the Apps Script admin page.' else 'Disabled from the Apps Script admin page.' end
    where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT');
  end if;

  select * into s from integration.legacy_sync_schedule where schedule_key='FINISH_AREA';
  if not found then
    raise exception using errcode='P0002', message='Legacy sync schedule is missing.';
  end if;

  return jsonb_build_object(
    'auto_enabled', s.auto_enabled,
    'window_days', s.window_days,
    'night_from', to_char(s.night_from, 'HH24:MI'),
    'night_until', to_char(s.night_until, 'HH24:MI'),
    'today', to_char((now() at time zone 'Europe/Dublin')::date, 'YYYY-MM-DD'),
    'date_from', to_char((now() at time zone 'Europe/Dublin')::date - (s.window_days - 1), 'YYYY-MM-DD'),
    'last_poll_at', s.last_poll_at,
    'changed_at', s.changed_at,
    'changed_by', s.changed_by,
    'open_review_items', (select count(*) from integration.legacy_sync_review_items ri
                          where ri.source_system='FINISH_AREA' and ri.status='OPEN'),
    'runs', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.started_at desc)
      from (
        select r.sync_run_id, r.status, r.requested_by, r.date_from, r.date_to,
               r.started_at, r.finished_at, r.summary
        from integration.legacy_sync_runs r
        where r.source_system='FINISH_AREA' and r.mode='COMMIT'
        order by r.started_at desc
        limit 8
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function integration.legacy_sync_control(text,text) from public, anon, authenticated;
grant execute on function integration.legacy_sync_control(text,text) to service_role;

drop function if exists public.legacy_sync_request_now();
drop function if exists public.legacy_sync_set_auto(boolean);
drop function if exists public.legacy_sync_control_status();
drop function if exists integration.legacy_sync_require_admin();

comment on function integration.legacy_sync_control(text,text) is
  'Service-role control from the Apps Script admin page: STATUS, or ON/OFF for the schedule and both Finish import switches (ON sets limit 300).';

commit;
