-- =====================================================================
-- ElisCaretex V2
-- Migration: 202610270005_legacy_sync_schedule
--
-- Nightly Legacy Sync for the Finish Area, with an on/off switch and a
-- "Sync now" request in V2. Depends on 202610270001 to 202610270004.
--
-- How it runs: the Apps Script (LegacySyncFinish.gs) has a time trigger
-- every 5 minutes that asks the legacy-sync-finish Edge Function "poll".
-- The poll calls integration.legacy_sync_claim_run(), which answers:
--   * run=false while the sync is OFF, while a run is still RUNNING, or
--     when there is nothing to do;
--   * run=true, reason REQUEST, once after an administrator pressed
--     "Sync now";
--   * run=true, reason NIGHTLY, once per Dublin night between
--     night_from and night_until.
-- The Apps Script then imports the last window_days days (today included).
--
-- One switch: legacy_sync_set_auto(true) enables the schedule and both
-- import switches (FINISH_HISTORICAL_IMPORT, FINISH_REWASH_HISTORICAL_IMPORT)
-- with a run limit of 300; legacy_sync_set_auto(false) disables all three.
-- OFF means nothing is written, by the schedule, by "Sync now" or by a
-- manual run from the Apps Script editor.
--
-- Access: the claim is service_role only (Edge Function). The three
-- public RPCs are for enabled ADMIN accounts only; other callers get 42501.
-- Temporary: drop with the rest of the legacy sync scaffolding.
-- =====================================================================

begin;

create table if not exists integration.legacy_sync_schedule (
  schedule_key text primary key check (schedule_key = 'FINISH_AREA'),
  auto_enabled boolean not null default false,
  window_days integer not null default 3 check (window_days between 1 and 7),
  night_from time not null default '02:00',
  night_until time not null default '05:00',
  requested_at timestamptz,
  requested_by text,
  claimed_at timestamptz,
  claimed_reason text check (claimed_reason in ('NIGHTLY','REQUEST')),
  last_nightly_date date,
  last_poll_at timestamptz,
  changed_at timestamptz not null default now(),
  changed_by text not null,
  constraint legacy_sync_schedule_night check (night_from < night_until)
);

insert into integration.legacy_sync_schedule(schedule_key, changed_by)
values ('FINISH_AREA', 'migration 202610270005')
on conflict (schedule_key) do nothing;

alter table integration.legacy_sync_schedule enable row level security;
revoke all on integration.legacy_sync_schedule from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Claim (Edge Function, service_role)
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_claim_run()
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  s integration.legacy_sync_schedule%rowtype;
  v_local timestamp := now() at time zone 'Europe/Dublin';
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_reason text;
begin
  if auth.uid() is not null then
    raise exception using errcode='42501', message='The legacy sync claim is not available to accounts.';
  end if;

  select * into s from integration.legacy_sync_schedule where schedule_key='FINISH_AREA' for update;
  if not found then
    raise exception using errcode='P0002', message='Legacy sync schedule is missing.';
  end if;
  update integration.legacy_sync_schedule set last_poll_at=now() where schedule_key='FINISH_AREA';

  if not s.auto_enabled then
    return jsonb_build_object('run', false, 'reason', 'OFF');
  end if;
  if exists (
    select 1 from integration.legacy_sync_runs r
    where r.source_system='FINISH_AREA' and r.mode='COMMIT' and r.status in ('CREATED','RUNNING')
      and r.started_at > now() - interval '15 minutes'
  ) then
    return jsonb_build_object('run', false, 'reason', 'BUSY');
  end if;

  if s.requested_at is not null and (s.claimed_at is null or s.claimed_at < s.requested_at) then
    v_reason := 'REQUEST';
  elsif v_local::time >= s.night_from and v_local::time < s.night_until
        and s.last_nightly_date is distinct from v_today then
    v_reason := 'NIGHTLY';
  else
    return jsonb_build_object('run', false, 'reason', 'IDLE');
  end if;

  update integration.legacy_sync_schedule
  set claimed_at=now(), claimed_reason=v_reason,
      last_nightly_date=case when v_reason='NIGHTLY' then v_today else last_nightly_date end
  where schedule_key='FINISH_AREA';

  return jsonb_build_object(
    'run', true,
    'reason', v_reason,
    'dateFrom', to_char(v_today - (s.window_days - 1), 'YYYY-MM-DD'),
    'dateTo', to_char(v_today, 'YYYY-MM-DD')
  );
end;
$$;

revoke all on function integration.legacy_sync_claim_run() from public, anon, authenticated;
grant execute on function integration.legacy_sync_claim_run() to service_role;

-- ---------------------------------------------------------------------
-- Administrator RPCs (V2 screen)
-- ---------------------------------------------------------------------
create or replace function integration.legacy_sync_require_admin()
returns text
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
begin
  if auth.uid() is null or not public.has_any_role(array['ADMIN']) then
    raise exception using errcode='42501', message='Only an administrator can control the legacy sync.';
  end if;
  return 'account:' || auth.uid()::text;
end;
$$;

revoke all on function integration.legacy_sync_require_admin() from public, anon, authenticated;

create or replace function public.legacy_sync_control_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, integration, pg_temp
as $$
declare s integration.legacy_sync_schedule%rowtype;
begin
  perform integration.legacy_sync_require_admin();
  select * into s from integration.legacy_sync_schedule where schedule_key='FINISH_AREA';
  return jsonb_build_object(
    'auto_enabled', coalesce(s.auto_enabled, false),
    'window_days', s.window_days,
    'night_from', to_char(s.night_from, 'HH24:MI'),
    'night_until', to_char(s.night_until, 'HH24:MI'),
    'request_pending', s.requested_at is not null and (s.claimed_at is null or s.claimed_at < s.requested_at),
    'requested_at', s.requested_at,
    'last_poll_at', s.last_poll_at,
    'changed_at', s.changed_at,
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

create or replace function public.legacy_sync_set_auto(p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare v_who text := integration.legacy_sync_require_admin();
begin
  if p_enabled is null then
    raise exception using errcode='22023', message='Choose on or off.';
  end if;
  update integration.legacy_sync_schedule
  set auto_enabled=p_enabled, changed_at=now(), changed_by=v_who
  where schedule_key='FINISH_AREA';
  update integration.legacy_sync_settings
  set enabled=p_enabled,
      max_entries_per_run=case when p_enabled then 300 else max_entries_per_run end,
      changed_at=now(), changed_by=v_who,
      note=case when p_enabled then 'Enabled from the V2 Legacy Sync control.' else 'Disabled from the V2 Legacy Sync control.' end
  where setting_key in ('FINISH_HISTORICAL_IMPORT','FINISH_REWASH_HISTORICAL_IMPORT');
  return public.legacy_sync_control_status();
end;
$$;

create or replace function public.legacy_sync_request_now()
returns jsonb
language plpgsql
security definer
set search_path = public, integration, pg_temp
as $$
declare
  v_who text := integration.legacy_sync_require_admin();
  s integration.legacy_sync_schedule%rowtype;
begin
  select * into s from integration.legacy_sync_schedule where schedule_key='FINISH_AREA' for update;
  if not s.auto_enabled then
    raise exception using errcode='55000', message='Turn the legacy sync on first.';
  end if;
  if s.requested_at is null or (s.claimed_at is not null and s.claimed_at >= s.requested_at) then
    update integration.legacy_sync_schedule
    set requested_at=now(), requested_by=v_who
    where schedule_key='FINISH_AREA';
  end if;
  return public.legacy_sync_control_status();
end;
$$;

revoke all on function public.legacy_sync_control_status() from public, anon;
revoke all on function public.legacy_sync_set_auto(boolean) from public, anon;
revoke all on function public.legacy_sync_request_now() from public, anon;
grant execute on function public.legacy_sync_control_status() to authenticated;
grant execute on function public.legacy_sync_set_auto(boolean) to authenticated;
grant execute on function public.legacy_sync_request_now() to authenticated;

comment on table integration.legacy_sync_schedule is
  'Nightly Legacy Sync schedule and the pending "Sync now" request. One row, FINISH_AREA. Temporary.';
comment on function integration.legacy_sync_claim_run() is
  'Service-role poll from the Apps Script: claims at most one REQUEST or NIGHTLY run and returns its date window.';
comment on function public.legacy_sync_set_auto(boolean) is
  'ADMIN only: turns the schedule and both Finish import switches on (limit 300) or off.';
comment on function public.legacy_sync_request_now() is
  'ADMIN only: asks the Apps Script to run on its next poll (at most 5 minutes). Refused while OFF.';

commit;
