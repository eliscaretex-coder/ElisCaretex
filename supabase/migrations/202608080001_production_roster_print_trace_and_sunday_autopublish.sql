-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608080001_production_roster_print_trace_and_sunday_autopublish.sql
-- Purpose:
--   - Add a governed Sunday safety publication for the next Production Roster week.
--   - From Sunday 12:00 Europe/Dublin, automatically publish the latest SAVED
--     draft for Morning and/or Evening only when that shift has no published
--     roster for the incoming week.
--   - Preserve saved data exactly: this automation never creates assignments,
--     applies unsaved browser changes, or rewrites already-published entries.
--   - Keep an internal status record for operational traceability.
-- =====================================================================

create extension if not exists pg_cron;

create table if not exists public.production_roster_autopublish_state (
  week_start date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  status text not null,
  roster_version_id uuid references public.production_roster_versions(roster_version_id) on delete set null,
  version_number integer,
  last_checked_at timestamptz not null default now(),
  published_at timestamptz,
  detail text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (week_start, shift_id),
  constraint production_roster_autopublish_state_status_check
    check (status in ('ALREADY_PUBLISHED', 'AUTO_PUBLISHED', 'NO_SAVED_DRAFT', 'EMPTY_DRAFT', 'ERROR'))
);

create index if not exists production_roster_autopublish_state_lookup_idx
  on public.production_roster_autopublish_state (week_start desc, status, shift_id);

alter table public.production_roster_autopublish_state enable row level security;
revoke all on table public.production_roster_autopublish_state from public, anon, authenticated;

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
  v_local_time time := (p_now at time zone 'Europe/Dublin')::time;
  v_target_week date;
  v_shift record;
  v_period_id uuid;
  v_published public.production_roster_versions%rowtype;
  v_draft public.production_roster_versions%rowtype;
  v_entry_count integer;
  v_results jsonb := '[]'::jsonb;
  v_item jsonb;
begin
  -- Sunday is ISO day 7. The database remains UTC; the business rule is Dublin local time.
  if extract(isodow from v_local_date) <> 7 or v_local_time < time '12:00' then
    return jsonb_build_object(
      'status', 'NOT_DUE',
      'checked_at', p_now,
      'dublin_local_time', v_local,
      'message', 'Automatic publication is only due from Sunday 12:00 Europe/Dublin.'
    );
  end if;

  -- On Sunday, the incoming roster week starts the following day (Monday).
  v_target_week := v_local_date + 1;

  for v_shift in
    select s.shift_id, s.shift_code, s.shift_name
    from public.shifts s
    where s.active = true
      and s.deleted_at is null
      and upper(s.shift_code) in ('MORNING', 'EVENING')
    order by case upper(s.shift_code) when 'MORNING' then 1 when 'EVENING' then 2 else 99 end
  loop
    begin
    -- Serialize this specific incoming week + shift with normal save/publish activity.
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
        p_now, null, 'No saved roster period exists for the incoming week.', now()
      )
      on conflict (week_start, shift_id) do update
      set status = excluded.status,
          roster_version_id = null,
          version_number = null,
          last_checked_at = excluded.last_checked_at,
          published_at = null,
          detail = excluded.detail,
          updated_at = now();

      v_item := jsonb_build_object(
        'shift_code', v_shift.shift_code,
        'status', 'NO_SAVED_DRAFT',
        'week_start', v_target_week
      );
      v_results := v_results || jsonb_build_array(v_item);
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
        p_now, v_published.published_at, 'A published roster already exists; no automatic action was required.', now()
      )
      on conflict (week_start, shift_id) do update
      set status = excluded.status,
          roster_version_id = excluded.roster_version_id,
          version_number = excluded.version_number,
          last_checked_at = excluded.last_checked_at,
          published_at = excluded.published_at,
          detail = excluded.detail,
          updated_at = now();

      v_item := jsonb_build_object(
        'shift_code', v_shift.shift_code,
        'status', 'ALREADY_PUBLISHED',
        'week_start', v_target_week,
        'version_number', v_published.version_number
      );
      v_results := v_results || jsonb_build_array(v_item);
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
        p_now, null, 'The incoming week exists, but this shift has no saved draft.', now()
      )
      on conflict (week_start, shift_id) do update
      set status = excluded.status,
          roster_version_id = null,
          version_number = null,
          last_checked_at = excluded.last_checked_at,
          published_at = null,
          detail = excluded.detail,
          updated_at = now();

      v_item := jsonb_build_object(
        'shift_code', v_shift.shift_code,
        'status', 'NO_SAVED_DRAFT',
        'week_start', v_target_week
      );
      v_results := v_results || jsonb_build_array(v_item);
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
        p_now, null, 'The saved draft is empty and was not published automatically.', now()
      )
      on conflict (week_start, shift_id) do update
      set status = excluded.status,
          roster_version_id = excluded.roster_version_id,
          version_number = excluded.version_number,
          last_checked_at = excluded.last_checked_at,
          published_at = null,
          detail = excluded.detail,
          updated_at = now();

      v_item := jsonb_build_object(
        'shift_code', v_shift.shift_code,
        'status', 'EMPTY_DRAFT',
        'week_start', v_target_week,
        'version_number', v_draft.version_number
      );
      v_results := v_results || jsonb_build_array(v_item);
      continue;
    end if;

    -- Publish the exact saved draft. Entries are not rewritten or regenerated.
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
      raise exception using errcode = '40001', message = 'The saved roster changed during automatic publication; it will be retried by the next scheduled check.';
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
      'Automatic Sunday safety publication after 12:00 Europe/Dublin.',
      jsonb_build_object(
        'automatic', true,
        'source_application', 'PRODUCTION_ROSTER_SUNDAY_AUTOPUBLISH',
        'scheduled_rule', 'Sunday from 12:00 Europe/Dublin',
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
        'entry_count', v_entry_count
      ),
      'Incoming roster was still unpublished after Sunday 12:00 Europe/Dublin; the latest saved draft was published automatically.',
      'PRODUCTION_ROSTER_SUNDAY_AUTOPUBLISH'
    );

    insert into public.production_roster_autopublish_state (
      week_start, shift_id, status, roster_version_id, version_number,
      last_checked_at, published_at, detail, updated_at
    ) values (
      v_target_week, v_shift.shift_id, 'AUTO_PUBLISHED',
      v_draft.roster_version_id, v_draft.version_number,
      p_now, p_now, 'Latest saved draft published automatically.', now()
    )
    on conflict (week_start, shift_id) do update
    set status = excluded.status,
        roster_version_id = excluded.roster_version_id,
        version_number = excluded.version_number,
        last_checked_at = excluded.last_checked_at,
        published_at = excluded.published_at,
        detail = excluded.detail,
        updated_at = now();

    v_item := jsonb_build_object(
      'shift_code', v_shift.shift_code,
      'status', 'AUTO_PUBLISHED',
      'week_start', v_target_week,
      'roster_version_id', v_draft.roster_version_id,
      'version_number', v_draft.version_number,
      'saved_at', v_draft.saved_at,
      'published_at', p_now,
      'entry_count', v_entry_count
    );
    v_results := v_results || jsonb_build_array(v_item);
    exception
      when others then
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

        v_item := jsonb_build_object(
          'shift_code', v_shift.shift_code,
          'status', 'ERROR',
          'week_start', v_target_week,
          'message', left(sqlerrm, 1000)
        );
        v_results := v_results || jsonb_build_array(v_item);
    end;
  end loop;

  return jsonb_build_object(
    'status', 'CHECKED',
    'checked_at', p_now,
    'dublin_local_time', v_local,
    'week_start', v_target_week,
    'results', v_results
  );
end;
$$;

revoke all on function public.run_production_roster_sunday_autopublish(timestamptz) from public, anon, authenticated;
grant execute on function public.run_production_roster_sunday_autopublish(timestamptz) to service_role;

comment on function public.run_production_roster_sunday_autopublish(timestamptz) is
  'Internal Sunday safety publication. From 12:00 Europe/Dublin, publishes only an existing saved draft for the incoming week when that shift has no published roster. Never rewrites roster entries.';

-- pg_cron runs in UTC/GMT. Run every 10 minutes on Sunday; the database
-- function itself enforces Europe/Dublin Sunday >= 12:00, so DST is handled
-- by the business-time check rather than a fixed UTC hour.
select cron.schedule(
  'production-roster-sunday-autopublish',
  '*/10 * * * 0',
  $cron$select public.run_production_roster_sunday_autopublish();$cron$
);
