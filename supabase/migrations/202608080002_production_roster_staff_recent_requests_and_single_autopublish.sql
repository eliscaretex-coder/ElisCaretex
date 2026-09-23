-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608080002_production_roster_staff_recent_requests_and_single_autopublish.sql
-- Purpose:
--   1. Keep the shared staff portal concise: expose at most the three most
--      recent Holiday / Day Off requests submitted within the last month.
--      Manager history remains complete through the governed admin RPCs.
--   2. Replace the repeated Sunday safety publication checks with one actual
--      publication attempt at 12:00 Europe/Dublin for the incoming week.
--      The attempt is not retried that Sunday whether it succeeds, finds no
--      saved draft, or records an operational error.
--
-- Important:
--   - No direct browser SELECT is granted on leave-request or automation tables.
--   - Published Production Roster entries are never rewritten by this migration.
--   - Two lightweight UTC cron candidates are required because Dublin changes
--     between GMT and Irish Standard Time. The function itself allows an actual
--     attempt only when the local Dublin hour is 12, and a week-level claim
--     prevents a second actual attempt.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Staff portal: only three requests from the last month
-- ---------------------------------------------------------------------

create or replace function public.get_my_production_roster_leave_requests(
  p_token text,
  p_staff_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_production_roster_staff_portal_token(p_token);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'leave_request_id', prlr.leave_request_id,
      'request_type', prlr.request_type,
      'start_date', prlr.start_date,
      'end_date', prlr.end_date,
      'status', prlr.status,
      'workflow_status', case
        when prlr.status = 'PENDING' and gm.state = 'AWAITING_GM' then 'AWAITING_GENERAL_MANAGER'
        when prlr.status = 'PENDING' and gm.state = 'SEND_FAILED' then 'GENERAL_MANAGER_EMAIL_FAILED'
        else prlr.status
      end,
      'requires_general_manager', prlr.requires_general_manager,
      'submitted_at', prlr.submitted_at,
      'reviewed_at', prlr.reviewed_at,
      'decision_source', prlr.decision_source
    ) order by prlr.submitted_at desc)
    from (
      select *
      from public.production_roster_leave_requests
      where staff_id = p_staff_id
        and submitted_at >= now() - interval '1 month'
      order by submitted_at desc
      limit 3
    ) prlr
    left join public.production_roster_leave_gm_reviews gm
      on gm.leave_request_id = prlr.leave_request_id
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.get_my_production_roster_leave_requests(text, uuid) from public;
grant execute on function public.get_my_production_roster_leave_requests(text, uuid) to anon, authenticated;

comment on function public.get_my_production_roster_leave_requests(text, uuid) is
  'Shared staff portal status view. Returns at most the three newest requests submitted within the last month. Full historical management visibility is intentionally provided by separate manager-only RPCs.';

-- ---------------------------------------------------------------------
-- One actual Sunday publication attempt per incoming week
-- ---------------------------------------------------------------------

create table if not exists public.production_roster_autopublish_runs (
  week_start date primary key,
  attempted_at timestamptz not null,
  dublin_local_time timestamp not null,
  completed_at timestamptz,
  status text not null,
  results jsonb not null default '[]'::jsonb,
  detail text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint production_roster_autopublish_runs_status_check
    check (status in ('ATTEMPTED', 'COMPLETED'))
);

alter table public.production_roster_autopublish_runs enable row level security;
revoke all on table public.production_roster_autopublish_runs from public, anon, authenticated;

create or replace function public.run_production_roster_sunday_autopublish(
  p_now timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_local timestamp := p_now at time zone 'Europe/Dublin';
  v_local_date date := (p_now at time zone 'Europe/Dublin')::date;
  v_local_hour integer := extract(hour from (p_now at time zone 'Europe/Dublin'))::integer;
  v_target_week date;
  v_claimed_week date;
  v_previous public.production_roster_autopublish_runs%rowtype;
  v_shift record;
  v_period_id uuid;
  v_published public.production_roster_versions%rowtype;
  v_draft public.production_roster_versions%rowtype;
  v_entry_count integer;
  v_results jsonb := '[]'::jsonb;
  v_item jsonb;
begin
  -- Exactly one local-hour window is eligible. Candidate cron calls at another
  -- UTC hour are not publication attempts and do not claim the week.
  if extract(isodow from v_local_date) <> 7 or v_local_hour <> 12 then
    return jsonb_build_object(
      'status', 'NOT_DUE',
      'checked_at', p_now,
      'dublin_local_time', v_local,
      'message', 'Automatic publication is attempted only once during the Sunday 12:00 Europe/Dublin hour.'
    );
  end if;

  v_target_week := v_local_date + 1;

  -- A single row is the irreversible business-level claim for this Sunday.
  -- Once claimed, later calls during the same local noon do not retry, even if
  -- the first attempt produced NO_SAVED_DRAFT / EMPTY_DRAFT / ERROR results.
  insert into public.production_roster_autopublish_runs (
    week_start, attempted_at, dublin_local_time, status, results, detail
  ) values (
    v_target_week, p_now, v_local, 'ATTEMPTED', '[]'::jsonb,
    'Sunday 12:00 Europe/Dublin safety publication attempt claimed.'
  )
  on conflict (week_start) do nothing
  returning week_start into v_claimed_week;

  if v_claimed_week is null then
    select * into v_previous
    from public.production_roster_autopublish_runs r
    where r.week_start = v_target_week;

    return jsonb_build_object(
      'status', 'ALREADY_ATTEMPTED',
      'checked_at', p_now,
      'dublin_local_time', v_local,
      'week_start', v_target_week,
      'attempted_at', v_previous.attempted_at,
      'attempt_status', v_previous.status,
      'results', coalesce(v_previous.results, '[]'::jsonb),
      'message', 'The Sunday safety publication has already been attempted for this incoming week. No retry is allowed.'
    );
  end if;

  for v_shift in
    select s.shift_id, s.shift_code, s.shift_name
    from public.shifts s
    where s.active = true
      and s.deleted_at is null
      and upper(s.shift_code) in ('MORNING', 'EVENING')
    order by case upper(s.shift_code) when 'MORNING' then 1 when 'EVENING' then 2 else 99 end
  loop
    begin
      perform pg_advisory_xact_lock(
        hashtextextended('production-roster-sunday-autopublish:' || v_target_week::text || ':' || v_shift.shift_code, 0)
      );

      v_period_id := null;
      v_published.roster_version_id := null;
      v_draft.roster_version_id := null;
      v_entry_count := 0;

      select rp.roster_period_id
        into v_period_id
      from public.roster_periods rp
      where rp.week_start = v_target_week
      for update;

      if v_period_id is null then
        insert into public.production_roster_autopublish_state (
          week_start, shift_id, status, roster_version_id, version_number,
          last_checked_at, published_at, detail, updated_at
        ) values (
          v_target_week, v_shift.shift_id, 'NO_SAVED_DRAFT', null, null,
          p_now, null, 'No saved roster period existed at the one Sunday noon attempt.', now()
        )
        on conflict (week_start, shift_id) do update
        set status = excluded.status,
            roster_version_id = null,
            version_number = null,
            last_checked_at = excluded.last_checked_at,
            published_at = null,
            detail = excluded.detail,
            updated_at = now();

        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'shift_code', v_shift.shift_code,
          'status', 'NO_SAVED_DRAFT',
          'week_start', v_target_week
        ));
        continue;
      end if;

      select prv.*
        into v_published
      from public.production_roster_versions prv
      where prv.roster_period_id = v_period_id
        and prv.shift_id = v_shift.shift_id
        and prv.status = 'PUBLISHED'
      limit 1
      for update;

      if v_published.roster_version_id is not null then
        insert into public.production_roster_autopublish_state (
          week_start, shift_id, status, roster_version_id, version_number,
          last_checked_at, published_at, detail, updated_at
        ) values (
          v_target_week, v_shift.shift_id, 'ALREADY_PUBLISHED',
          v_published.roster_version_id, v_published.version_number,
          p_now, v_published.published_at,
          'A published roster already existed at the scheduled Sunday noon attempt.', now()
        )
        on conflict (week_start, shift_id) do update
        set status = excluded.status,
            roster_version_id = excluded.roster_version_id,
            version_number = excluded.version_number,
            last_checked_at = excluded.last_checked_at,
            published_at = excluded.published_at,
            detail = excluded.detail,
            updated_at = now();

        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'shift_code', v_shift.shift_code,
          'status', 'ALREADY_PUBLISHED',
          'week_start', v_target_week,
          'version_number', v_published.version_number
        ));
        continue;
      end if;

      select prv.*
        into v_draft
      from public.production_roster_versions prv
      where prv.roster_period_id = v_period_id
        and prv.shift_id = v_shift.shift_id
        and prv.status = 'DRAFT'
        and prv.saved_at is not null
      order by prv.version_number desc
      limit 1
      for update;

      if v_draft.roster_version_id is null then
        insert into public.production_roster_autopublish_state (
          week_start, shift_id, status, roster_version_id, version_number,
          last_checked_at, published_at, detail, updated_at
        ) values (
          v_target_week, v_shift.shift_id, 'NO_SAVED_DRAFT', null, null,
          p_now, null, 'This shift had no saved draft at the one Sunday noon attempt.', now()
        )
        on conflict (week_start, shift_id) do update
        set status = excluded.status,
            roster_version_id = null,
            version_number = null,
            last_checked_at = excluded.last_checked_at,
            published_at = null,
            detail = excluded.detail,
            updated_at = now();

        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'shift_code', v_shift.shift_code,
          'status', 'NO_SAVED_DRAFT',
          'week_start', v_target_week
        ));
        continue;
      end if;

      select count(*)
        into v_entry_count
      from public.production_roster_entries pre
      where pre.roster_version_id = v_draft.roster_version_id;

      if v_entry_count = 0 then
        insert into public.production_roster_autopublish_state (
          week_start, shift_id, status, roster_version_id, version_number,
          last_checked_at, published_at, detail, updated_at
        ) values (
          v_target_week, v_shift.shift_id, 'EMPTY_DRAFT',
          v_draft.roster_version_id, v_draft.version_number,
          p_now, null, 'The saved draft was empty at the one Sunday noon attempt.', now()
        )
        on conflict (week_start, shift_id) do update
        set status = excluded.status,
            roster_version_id = excluded.roster_version_id,
            version_number = excluded.version_number,
            last_checked_at = excluded.last_checked_at,
            published_at = null,
            detail = excluded.detail,
            updated_at = now();

        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'shift_code', v_shift.shift_code,
          'status', 'EMPTY_DRAFT',
          'week_start', v_target_week,
          'version_number', v_draft.version_number
        ));
        continue;
      end if;

      -- Publish the exact saved draft. No Production Roster entry is rewritten.
      update public.production_roster_versions
      set status = 'PUBLISHED',
          published_at = p_now,
          published_by = null,
          updated_by = null,
          row_version = row_version + 1
      where roster_version_id = v_draft.roster_version_id
        and status = 'DRAFT'
      returning * into v_draft;

      if v_draft.roster_version_id is null then
        raise exception using errcode = '40001', message = 'The saved roster changed during the one automatic publication attempt.';
      end if;

      update public.roster_periods
      set status = 'PUBLISHED',
          published_at = coalesce(published_at, p_now),
          updated_at = now()
      where roster_period_id = v_period_id;

      insert into public.production_roster_events (
        roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason, metadata
      ) values (
        v_draft.roster_version_id,
        'PUBLISHED',
        null,
        null,
        'Single Sunday 12:00 Europe/Dublin safety publication.',
        jsonb_build_object(
          'automatic', true,
          'source_application', 'PRODUCTION_ROSTER_SUNDAY_AUTOPUBLISH',
          'scheduled_rule', 'One attempt at Sunday 12:00 Europe/Dublin',
          'saved_at', v_draft.saved_at,
          'entry_count', v_entry_count
        )
      );

      insert into public.audit_log (
        actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
        new_data, reason, source_application
      ) values (
        null,
        null,
        'PRODUCTION_ROSTER_AUTO_PUBLISHED',
        'production_roster_versions',
        v_draft.roster_version_id::text,
        jsonb_build_object(
          'week_start', v_target_week,
          'shift_code', v_shift.shift_code,
          'version_number', v_draft.version_number,
          'saved_at', v_draft.saved_at,
          'published_at', p_now,
          'entry_count', v_entry_count,
          'attempt_policy', 'ONCE_AT_SUNDAY_NOON_DUBLIN'
        ),
        'Incoming roster was unpublished at the single Sunday noon safety attempt; the latest saved draft was published.',
        'PRODUCTION_ROSTER_SUNDAY_AUTOPUBLISH'
      );

      insert into public.production_roster_autopublish_state (
        week_start, shift_id, status, roster_version_id, version_number,
        last_checked_at, published_at, detail, updated_at
      ) values (
        v_target_week, v_shift.shift_id, 'AUTO_PUBLISHED',
        v_draft.roster_version_id, v_draft.version_number,
        p_now, p_now, 'Latest saved draft published during the single Sunday noon attempt.', now()
      )
      on conflict (week_start, shift_id) do update
      set status = excluded.status,
          roster_version_id = excluded.roster_version_id,
          version_number = excluded.version_number,
          last_checked_at = excluded.last_checked_at,
          published_at = excluded.published_at,
          detail = excluded.detail,
          updated_at = now();

      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'shift_code', v_shift.shift_code,
        'status', 'AUTO_PUBLISHED',
        'week_start', v_target_week,
        'roster_version_id', v_draft.roster_version_id,
        'version_number', v_draft.version_number,
        'saved_at', v_draft.saved_at,
        'published_at', p_now,
        'entry_count', v_entry_count
      ));
    exception
      when others then
        -- The error is recorded as the result of this one attempt. It is not
        -- raised for retry by a later scheduler call.
        insert into public.production_roster_autopublish_state (
          week_start, shift_id, status, roster_version_id, version_number,
          last_checked_at, published_at, detail, updated_at
        ) values (
          v_target_week, v_shift.shift_id, 'ERROR', null, null,
          p_now, null, left(sqlerrm, 1000), now()
        )
        on conflict (week_start, shift_id) do update
        set status = excluded.status,
            roster_version_id = null,
            version_number = null,
            last_checked_at = excluded.last_checked_at,
            published_at = null,
            detail = excluded.detail,
            updated_at = now();

        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'shift_code', v_shift.shift_code,
          'status', 'ERROR',
          'week_start', v_target_week,
          'message', left(sqlerrm, 1000)
        ));
    end;
  end loop;

  update public.production_roster_autopublish_runs
  set status = 'COMPLETED',
      completed_at = now(),
      results = v_results,
      detail = 'Single Sunday noon attempt completed. Results are final for this week; automatic retry is disabled.',
      updated_at = now()
  where week_start = v_target_week;

  return jsonb_build_object(
    'status', 'ATTEMPT_COMPLETED',
    'checked_at', p_now,
    'dublin_local_time', v_local,
    'week_start', v_target_week,
    'results', v_results,
    'retry_allowed', false
  );
end;
$$;

revoke all on function public.run_production_roster_sunday_autopublish(timestamptz) from public, anon, authenticated;
grant execute on function public.run_production_roster_sunday_autopublish(timestamptz) to service_role;

comment on table public.production_roster_autopublish_runs is
  'One immutable business-level Sunday safety-publication attempt claim per incoming Production Roster week. Browser roles have no direct access.';

comment on function public.run_production_roster_sunday_autopublish(timestamptz) is
  'Internal Sunday safety publication. Makes at most one actual attempt for the incoming week during the Sunday 12:00 Europe/Dublin hour. Any result is final for that Sunday; there is no automatic retry.';

-- ---------------------------------------------------------------------
-- Scheduler
-- ---------------------------------------------------------------------
-- pg_cron schedules use the server cron timezone (commonly GMT/UTC on managed
-- Supabase). Dublin local noon is 11:00 UTC during Irish Standard Time and
-- 12:00 UTC during GMT. Therefore two candidate invocations are scheduled.
-- Exactly one sees local hour 12 and can claim/attempt the week; the other
-- returns NOT_DUE before touching automation state or roster data.

do $$
declare
  v_job record;
begin
  for v_job in
    select jobid
    from cron.job
    where jobname in (
      'production-roster-sunday-autopublish',
      'production-roster-sunday-autopublish-11utc',
      'production-roster-sunday-autopublish-12utc'
    )
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;
end;
$$;

select cron.schedule(
  'production-roster-sunday-autopublish-11utc',
  '0 11 * * 0',
  $cron$select public.run_production_roster_sunday_autopublish();$cron$
);

select cron.schedule(
  'production-roster-sunday-autopublish-12utc',
  '0 12 * * 0',
  $cron$select public.run_production_roster_sunday_autopublish();$cron$
);
