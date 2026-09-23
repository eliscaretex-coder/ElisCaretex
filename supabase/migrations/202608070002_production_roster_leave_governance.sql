-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608070002_production_roster_leave_governance.sql
--
-- Purpose:
--   1. Make the Holiday / Day Off queue planning-aware so future requests
--      become actionable when their roster week is being planned.
--   2. Auto-close missed Pending requests as EXPIRED once their start date
--      has passed, preserving a permanent history instead of leaving them
--      silently Pending forever.
--   3. Add configurable General Manager approval for long Holidays.
--      Default threshold: more than 20 calendar days.
--   4. Add secure email-review tokens and an immutable request event trail.
--   5. Expose Pending requests as a visual overlay in the Roster planner.
--
-- Important:
--   - This migration performs NO INSERT/UPDATE/DELETE on
--     public.production_roster_entries.
--   - Approvals are planning overlays only. A published Roster is changed
--     only through the normal Save -> Publish version lifecycle.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Configurable governance settings
-- ---------------------------------------------------------------------

insert into public.app_config (config_key, value_json, description)
values (
  'PRODUCTION_ROSTER_LEAVE_GOVERNANCE',
  jsonb_build_object(
    'general_manager_threshold_days', 20,
    'general_manager_email', '',
    'general_manager_token_ttl_hours', 168
  ),
  'Production Roster Holiday / Day Off governance. Holidays longer than the threshold require General Manager approval.'
)
on conflict (config_key) do nothing;

create or replace function public.production_roster_leave_governance_settings_value()
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select jsonb_build_object(
    'general_manager_threshold_days', greatest(1, least(120, coalesce((ac.value_json ->> 'general_manager_threshold_days')::integer, 20))),
    'general_manager_email', coalesce(ac.value_json ->> 'general_manager_email', ''),
    'general_manager_token_ttl_hours', greatest(24, least(720, coalesce((ac.value_json ->> 'general_manager_token_ttl_hours')::integer, 168)))
  )
  from public.app_config ac
  where ac.config_key = 'PRODUCTION_ROSTER_LEAVE_GOVERNANCE'
  union all
  select jsonb_build_object(
    'general_manager_threshold_days', 20,
    'general_manager_email', '',
    'general_manager_token_ttl_hours', 168
  )
  where not exists (
    select 1 from public.app_config where config_key = 'PRODUCTION_ROSTER_LEAVE_GOVERNANCE'
  )
  limit 1;
$$;

create or replace function public.get_production_roster_leave_governance_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_production_roster_manage_role();
  return public.production_roster_leave_governance_settings_value();
end;
$$;

create or replace function public.save_production_roster_leave_governance_settings(
  p_general_manager_threshold_days integer,
  p_general_manager_email text,
  p_general_manager_token_ttl_hours integer default 168
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_threshold integer := greatest(1, least(120, coalesce(p_general_manager_threshold_days, 20)));
  v_email text := trim(coalesce(p_general_manager_email, ''));
  v_ttl integer := greatest(24, least(720, coalesce(p_general_manager_token_ttl_hours, 168)));
  v_actor_staff uuid := public.current_staff_id();
begin
  perform public.require_production_roster_manage_role();

  if v_email <> '' and v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception using errcode = '22023', message = 'Enter a valid General Manager email address.';
  end if;

  insert into public.app_config (config_key, value_json, description, updated_by)
  values (
    'PRODUCTION_ROSTER_LEAVE_GOVERNANCE',
    jsonb_build_object(
      'general_manager_threshold_days', v_threshold,
      'general_manager_email', v_email,
      'general_manager_token_ttl_hours', v_ttl
    ),
    'Production Roster Holiday / Day Off governance. Holidays longer than the threshold require General Manager approval.',
    auth.uid()
  )
  on conflict (config_key) do update
  set value_json = excluded.value_json,
      description = excluded.description,
      updated_at = now(),
      updated_by = auth.uid();

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_LEAVE_GOVERNANCE_UPDATED',
    'app_config', 'PRODUCTION_ROSTER_LEAVE_GOVERNANCE',
    jsonb_build_object(
      'general_manager_threshold_days', v_threshold,
      'general_manager_email_configured', v_email <> '',
      'general_manager_token_ttl_hours', v_ttl
    ),
    'PRODUCTION_ROSTER'
  );

  return public.production_roster_leave_governance_settings_value();
end;
$$;

-- ---------------------------------------------------------------------
-- Extend the request record while preserving Snapshot 30 data
-- ---------------------------------------------------------------------

alter table public.production_roster_leave_requests
  add column if not exists requires_general_manager boolean not null default false,
  add column if not exists gm_threshold_days_snapshot integer,
  add column if not exists decision_source text,
  add column if not exists decision_actor text;

alter table public.production_roster_leave_requests
  drop constraint if exists production_roster_leave_status_check;

alter table public.production_roster_leave_requests
  add constraint production_roster_leave_status_check
  check (status in ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED', 'EXPIRED'));

alter table public.production_roster_leave_requests
  drop constraint if exists production_roster_leave_decision_source_check;

alter table public.production_roster_leave_requests
  add constraint production_roster_leave_decision_source_check
  check (decision_source is null or decision_source in ('MANAGER', 'GENERAL_MANAGER', 'SYSTEM'));

alter table public.production_roster_leave_requests
  drop constraint if exists production_roster_leave_gm_request_check;

alter table public.production_roster_leave_requests
  add constraint production_roster_leave_gm_request_check
  check (
    (not requires_general_manager or request_type = 'HOLIDAY')
    and (gm_threshold_days_snapshot is null or gm_threshold_days_snapshot between 1 and 120)
  );

-- Snapshot the default 20-day rule for requests that existed before this migration.
update public.production_roster_leave_requests
set gm_threshold_days_snapshot = coalesce(gm_threshold_days_snapshot, 20),
    requires_general_manager = case
      when request_type = 'HOLIDAY' and ((end_date - start_date) + 1) > coalesce(gm_threshold_days_snapshot, 20) then true
      else false
    end
where gm_threshold_days_snapshot is null;

-- ---------------------------------------------------------------------
-- Immutable event history for every request
-- ---------------------------------------------------------------------

create table if not exists public.production_roster_leave_request_events (
  leave_event_id uuid primary key default gen_random_uuid(),
  leave_request_id uuid not null references public.production_roster_leave_requests(leave_request_id) on delete restrict,
  event_type text not null,
  actor_auth_user_id uuid references auth.users(id) on delete set null,
  actor_label text,
  actor_role text,
  from_status text,
  to_status text,
  note text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create index if not exists production_roster_leave_request_events_request_idx
  on public.production_roster_leave_request_events (leave_request_id, occurred_at desc);

alter table public.production_roster_leave_request_events enable row level security;
revoke all on table public.production_roster_leave_request_events from public, anon, authenticated;

create or replace function public.protect_production_roster_leave_request_events()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using errcode = '55000', message = 'Production Roster leave request history is immutable.';
end;
$$;

drop trigger if exists trg_protect_production_roster_leave_request_events
  on public.production_roster_leave_request_events;
create trigger trg_protect_production_roster_leave_request_events
before update or delete on public.production_roster_leave_request_events
for each row execute function public.protect_production_roster_leave_request_events();

create or replace function public.record_production_roster_leave_event(
  p_leave_request_id uuid,
  p_event_type text,
  p_actor_label text default null,
  p_actor_role text default null,
  p_from_status text default null,
  p_to_status text default null,
  p_note text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_actor_auth_user_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into public.production_roster_leave_request_events (
    leave_request_id, event_type, actor_auth_user_id, actor_label, actor_role,
    from_status, to_status, note, metadata
  ) values (
    p_leave_request_id,
    upper(trim(coalesce(p_event_type, 'EVENT'))),
    p_actor_auth_user_id,
    nullif(trim(p_actor_label), ''),
    nullif(trim(p_actor_role), ''),
    nullif(trim(p_from_status), ''),
    nullif(trim(p_to_status), ''),
    nullif(trim(p_note), ''),
    coalesce(p_metadata, '{}'::jsonb)
  ) returning leave_event_id into v_id;
  return v_id;
end;
$$;

-- One explicit migration event keeps older requests visible in the new timeline.
insert into public.production_roster_leave_request_events (
  leave_request_id, event_type, actor_label, actor_role, from_status, to_status, metadata, occurred_at
)
select
  prlr.leave_request_id,
  'MIGRATED_STATE',
  'System',
  'SYSTEM',
  null,
  prlr.status,
  jsonb_build_object('migration', '202608070002'),
  coalesce(prlr.reviewed_at, prlr.submitted_at, now())
from public.production_roster_leave_requests prlr
where not exists (
  select 1
  from public.production_roster_leave_request_events e
  where e.leave_request_id = prlr.leave_request_id
);

-- ---------------------------------------------------------------------
-- Secure General Manager review state
-- ---------------------------------------------------------------------

create table if not exists public.production_roster_leave_gm_reviews (
  leave_request_id uuid primary key references public.production_roster_leave_requests(leave_request_id) on delete restrict,
  token_hash text unique,
  token_hint text,
  sent_to text,
  state text not null default 'NOT_SENT',
  sent_at timestamptz,
  expires_at timestamptz,
  decision text,
  decided_at timestamptz,
  decision_note text,
  last_error text,
  updated_at timestamptz not null default now(),
  constraint production_roster_leave_gm_state_check
    check (state in ('NOT_SENT', 'SENDING', 'AWAITING_GM', 'SEND_FAILED', 'DECIDED', 'CANCELLED')),
  constraint production_roster_leave_gm_decision_check
    check (decision is null or decision in ('APPROVED', 'REJECTED'))
);

create index if not exists production_roster_leave_gm_reviews_state_idx
  on public.production_roster_leave_gm_reviews (state, sent_at desc);

alter table public.production_roster_leave_gm_reviews enable row level security;
revoke all on table public.production_roster_leave_gm_reviews from public, anon, authenticated;

create or replace function public.production_roster_leave_gm_token_hash(p_token text)
returns text
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select md5('ELISCARETEXT-LEAVE-GM-A:' || p_token)
      || md5('ELISCARETEXT-LEAVE-GM-B:' || p_token);
$$;

-- ---------------------------------------------------------------------
-- Replace submission so the threshold is snapshotted at request time
-- ---------------------------------------------------------------------

create or replace function public.submit_production_roster_leave_request(
  p_token text,
  p_staff_id uuid,
  p_request_type text,
  p_start_date date,
  p_end_date date default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff public.staff_members%rowtype;
  v_type text := upper(trim(coalesce(p_request_type, '')));
  v_start date := p_start_date;
  v_end date;
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_next_monday date;
  v_request public.production_roster_leave_requests%rowtype;
  v_settings jsonb := public.production_roster_leave_governance_settings_value();
  v_threshold integer;
  v_duration integer;
  v_requires_gm boolean;
begin
  perform public.require_production_roster_staff_portal_token(p_token);

  if v_type not in ('DAY_OFF', 'HOLIDAY') then
    raise exception using errcode = '22023', message = 'Request type must be Day Off or Holiday.';
  end if;
  if v_start is null then
    raise exception using errcode = '22023', message = 'A request date is required.';
  end if;

  v_end := case when v_type = 'DAY_OFF' then v_start else coalesce(p_end_date, v_start) end;
  if v_end < v_start then
    raise exception using errcode = '22023', message = 'The end date cannot be before the start date.';
  end if;

  v_next_monday := public.production_roster_week_start(v_today) + 7;
  if v_start < v_next_monday then
    raise exception using errcode = '22023', message = 'Holiday and Day Off requests can only be submitted for next week or later.';
  end if;
  if extract(isodow from v_today) > 4 and v_start < v_next_monday + 7 then
    raise exception using errcode = '22023', message = 'Requests for next week close after Thursday. Please choose a later date.';
  end if;

  select * into v_staff
  from public.staff_members sm
  where sm.staff_id = p_staff_id
    and sm.production_staff = true
    and sm.active = true
    and sm.deleted_at is null;
  if not found then
    raise exception using errcode = '22023', message = 'The selected staff member is not available for leave requests.';
  end if;

  if exists (
    select 1
    from public.production_roster_leave_requests prlr
    where prlr.staff_id = v_staff.staff_id
      and prlr.status in ('PENDING', 'APPROVED')
      and daterange(prlr.start_date, prlr.end_date, '[]') && daterange(v_start, v_end, '[]')
  ) then
    raise exception using errcode = '23505', message = 'There is already a pending or approved request overlapping these dates.';
  end if;

  v_threshold := greatest(1, coalesce((v_settings ->> 'general_manager_threshold_days')::integer, 20));
  v_duration := (v_end - v_start) + 1;
  v_requires_gm := v_type = 'HOLIDAY' and v_duration > v_threshold;

  insert into public.production_roster_leave_requests (
    staff_id, staff_display_name_snapshot, request_type,
    start_date, end_date, reason, status, source_application,
    requires_general_manager, gm_threshold_days_snapshot
  ) values (
    v_staff.staff_id,
    v_staff.display_name,
    v_type,
    v_start,
    v_end,
    nullif(trim(p_reason), ''),
    'PENDING',
    'ROSTER_VIEW',
    v_requires_gm,
    v_threshold
  ) returning * into v_request;

  perform public.record_production_roster_leave_event(
    v_request.leave_request_id,
    'SUBMITTED',
    v_request.staff_display_name_snapshot,
    'STAFF',
    null,
    'PENDING',
    v_request.reason,
    jsonb_build_object(
      'request_type', v_request.request_type,
      'start_date', v_request.start_date,
      'end_date', v_request.end_date,
      'duration_days', v_duration,
      'requires_general_manager', v_requires_gm,
      'general_manager_threshold_days', v_threshold
    ),
    null
  );

  insert into public.audit_log (
    action, entity_table, entity_id, new_data, reason, source_application
  ) values (
    'PRODUCTION_ROSTER_LEAVE_REQUEST_SUBMITTED',
    'production_roster_leave_requests',
    v_request.leave_request_id::text,
    jsonb_build_object(
      'staff_id', v_request.staff_id,
      'request_type', v_request.request_type,
      'start_date', v_request.start_date,
      'end_date', v_request.end_date,
      'status', v_request.status,
      'requires_general_manager', v_requires_gm,
      'general_manager_threshold_days', v_threshold
    ),
    v_request.reason,
    'ROSTER_VIEW'
  );

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    'status', v_request.status,
    'request_type', v_request.request_type,
    'start_date', v_request.start_date,
    'end_date', v_request.end_date,
    'duration_days', v_duration,
    'requires_general_manager', v_requires_gm,
    'general_manager_threshold_days', v_threshold,
    'submitted_at', v_request.submitted_at,
    'message', case when v_requires_gm
      then 'Request submitted. This Holiday requires General Manager approval before it can be approved.'
      else 'Request submitted. A manager will review it.' end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Expire forgotten requests once their requested start date has passed
-- ---------------------------------------------------------------------

create or replace function public.expire_stale_production_roster_leave_requests()
returns integer
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_count integer := 0;
begin
  perform public.require_production_roster_manage_role();

  with expired as (
    update public.production_roster_leave_requests prlr
    set status = 'EXPIRED',
        reviewed_at = coalesce(prlr.reviewed_at, now()),
        decision_source = 'SYSTEM',
        decision_actor = 'System',
        review_note = coalesce(prlr.review_note, 'Request start date passed without a decision.')
    where prlr.status = 'PENDING'
      and prlr.start_date < v_today
    returning prlr.*
  ), events as (
    insert into public.production_roster_leave_request_events (
      leave_request_id, event_type, actor_label, actor_role,
      from_status, to_status, note, metadata
    )
    select
      e.leave_request_id,
      'AUTO_EXPIRED',
      'System',
      'SYSTEM',
      'PENDING',
      'EXPIRED',
      'Request start date passed without a decision.',
      jsonb_build_object('start_date', e.start_date, 'expired_on', v_today)
    from expired e
    returning 1
  )
  select count(*) into v_count from events;

  update public.production_roster_leave_gm_reviews gm
  set state = 'CANCELLED',
      updated_at = now(),
      last_error = coalesce(gm.last_error, 'Leave request expired before a General Manager decision.')
  from public.production_roster_leave_requests prlr
  where prlr.leave_request_id = gm.leave_request_id
    and prlr.status = 'EXPIRED'
    and gm.state in ('SENDING', 'AWAITING_GM', 'SEND_FAILED');

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- Planning-aware dashboard / history
-- ---------------------------------------------------------------------

create or replace function public.get_production_roster_leave_dashboard(
  p_week_start date default null,
  p_shift_code text default null,
  p_scope text default 'ACTION'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_current_week date := public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date);
  v_selected_week date := public.production_roster_week_start(coalesce(p_week_start, (now() at time zone 'Europe/Dublin')::date));
  v_shift_code text := upper(nullif(trim(coalesce(p_shift_code, '')), ''));
  v_scope text := upper(trim(coalesce(p_scope, 'ACTION')));
  v_requests jsonb;
  v_summary jsonb;
begin
  perform public.require_production_roster_manage_role();
  perform public.expire_stale_production_roster_leave_requests();

  if v_scope not in ('ACTION', 'UPCOMING', 'AWAITING_GM', 'HISTORY', 'ALL') then
    raise exception using errcode = '22023', message = 'Invalid leave request view.';
  end if;

  with base as (
    select
      prlr.*,
      ((prlr.end_date - prlr.start_date) + 1)::integer as duration_days,
      public.production_roster_week_start(prlr.start_date) as request_week_start,
      public.production_roster_week_start(prlr.start_date) - 7 as planning_week_start,
      public.production_roster_week_start(prlr.start_date) - 4 as decision_due_date,
      sh.shift_code as default_shift_code,
      sh.shift_name as default_shift_name,
      gm.state as gm_state,
      gm.sent_to as gm_sent_to,
      gm.sent_at as gm_sent_at,
      gm.expires_at as gm_expires_at,
      gm.decision as gm_decision,
      gm.decided_at as gm_decided_at,
      gm.updated_at as gm_updated_at,
      case
        when prlr.status <> 'PENDING' then prlr.status
        when gm.state = 'SEND_FAILED' then 'GM_SEND_FAILED'
        when gm.state = 'SENDING' then 'GM_SENDING'
        when gm.state = 'AWAITING_GM' then 'AWAITING_GM'
        when prlr.start_date = v_today then 'STARTS_TODAY'
        when (public.production_roster_week_start(prlr.start_date) - 4) < v_today then 'DECISION_OVERDUE'
        when daterange(prlr.start_date, prlr.end_date, '[]') && daterange(v_selected_week, v_selected_week + 6, '[]') then 'SELECTED_ROSTER_WEEK'
        when (public.production_roster_week_start(prlr.start_date) - 7) <= v_today then 'PLAN_THIS_WEEK'
        else 'UPCOMING'
      end as attention_state
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    left join public.shifts sh on sh.shift_id = sm.default_shift_id
    left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
  ), filtered as (
    select *
    from base b
    where (v_shift_code is null or upper(coalesce(b.default_shift_code, '')) = v_shift_code)
      and (
        v_scope = 'ALL'
        or (v_scope = 'HISTORY' and b.status <> 'PENDING')
        or (v_scope = 'AWAITING_GM' and b.status = 'PENDING' and b.gm_state in ('SENDING', 'AWAITING_GM', 'SEND_FAILED'))
        or (v_scope = 'UPCOMING' and b.status = 'PENDING' and b.attention_state = 'UPCOMING')
        or (v_scope = 'ACTION' and b.status = 'PENDING' and b.attention_state <> 'UPCOMING')
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'leave_request_id', f.leave_request_id,
    'staff_id', f.staff_id,
    'display_name', f.staff_display_name_snapshot,
    'request_type', f.request_type,
    'start_date', f.start_date,
    'end_date', f.end_date,
    'duration_days', f.duration_days,
    'reason', f.reason,
    'status', f.status,
    'submitted_at', f.submitted_at,
    'reviewed_at', f.reviewed_at,
    'review_note', f.review_note,
    'decision_source', f.decision_source,
    'decision_actor', f.decision_actor,
    'default_shift_code', f.default_shift_code,
    'default_shift_name', f.default_shift_name,
    'planning_week_start', f.planning_week_start,
    'decision_due_date', f.decision_due_date,
    'attention_state', f.attention_state,
    'requires_general_manager', f.requires_general_manager,
    'general_manager_threshold_days', f.gm_threshold_days_snapshot,
    'gm_state', f.gm_state,
    'gm_sent_to', f.gm_sent_to,
    'gm_sent_at', f.gm_sent_at,
    'gm_expires_at', f.gm_expires_at,
    'gm_decision', f.gm_decision,
    'gm_decided_at', f.gm_decided_at,
    'gm_updated_at', f.gm_updated_at
  ) order by
    case f.attention_state
      when 'STARTS_TODAY' then 1
      when 'DECISION_OVERDUE' then 2
      when 'GM_SEND_FAILED' then 3
      when 'GM_SENDING' then 4
      when 'AWAITING_GM' then 5
      when 'SELECTED_ROSTER_WEEK' then 6
      when 'PLAN_THIS_WEEK' then 7
      when 'UPCOMING' then 8
      else 20
    end,
    f.start_date,
    f.submitted_at), '[]'::jsonb)
  into v_requests
  from filtered f;

  with base as (
    select
      prlr.status,
      prlr.start_date,
      prlr.end_date,
      public.production_roster_week_start(prlr.start_date) - 7 as planning_week_start,
      gm.state as gm_state,
      sh.shift_code as default_shift_code
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    left join public.shifts sh on sh.shift_id = sm.default_shift_id
    left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
    where (v_shift_code is null or upper(coalesce(sh.shift_code, '')) = v_shift_code)
  )
  select jsonb_build_object(
    'action_count', count(*) filter (
      where status = 'PENDING'
        and (planning_week_start <= v_today or gm_state in ('SENDING', 'AWAITING_GM', 'SEND_FAILED'))
    ),
    'selected_week_pending_count', count(*) filter (
      where status = 'PENDING'
        and daterange(start_date, end_date, '[]') && daterange(v_selected_week, v_selected_week + 6, '[]')
    ),
    'awaiting_gm_count', count(*) filter (where status = 'PENDING' and gm_state = 'AWAITING_GM'),
    'upcoming_count', count(*) filter (where status = 'PENDING' and planning_week_start > v_today and coalesce(gm_state, '') not in ('SENDING', 'AWAITING_GM', 'SEND_FAILED')),
    'approved_count', count(*) filter (where status = 'APPROVED'),
    'rejected_count', count(*) filter (where status = 'REJECTED'),
    'expired_count', count(*) filter (where status = 'EXPIRED'),
    'history_count', count(*) filter (where status <> 'PENDING')
  ) into v_summary
  from base;

  return jsonb_build_object(
    'generated_at', now(),
    'today', v_today,
    'current_week_start', v_current_week,
    'selected_week_start', v_selected_week,
    'scope', v_scope,
    'settings', public.production_roster_leave_governance_settings_value(),
    'summary', coalesce(v_summary, '{}'::jsonb),
    'requests', coalesce(v_requests, '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_production_roster_leave_request_history(p_leave_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_production_roster_manage_role();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'leave_event_id', e.leave_event_id,
      'event_type', e.event_type,
      'actor_label', e.actor_label,
      'actor_role', e.actor_role,
      'from_status', e.from_status,
      'to_status', e.to_status,
      'note', e.note,
      'metadata', e.metadata,
      'occurred_at', e.occurred_at
    ) order by e.occurred_at desc, e.leave_event_id desc)
    from public.production_roster_leave_request_events e
    where e.leave_request_id = p_leave_request_id
  ), '[]'::jsonb);
end;
$$;



-- Compatibility queue RPC retained for existing clients. New UI uses the dashboard.
create or replace function public.get_production_roster_leave_requests(p_status text default 'PENDING')
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_status text := upper(nullif(trim(coalesce(p_status, '')), ''));
begin
  perform public.require_production_roster_manage_role();
  perform public.expire_stale_production_roster_leave_requests();

  if v_status is not null and v_status not in ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED', 'EXPIRED') then
    raise exception using errcode = '22023', message = 'Invalid leave request status.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'leave_request_id', prlr.leave_request_id,
      'staff_id', prlr.staff_id,
      'display_name', prlr.staff_display_name_snapshot,
      'request_type', prlr.request_type,
      'start_date', prlr.start_date,
      'end_date', prlr.end_date,
      'duration_days', (prlr.end_date - prlr.start_date) + 1,
      'reason', prlr.reason,
      'status', prlr.status,
      'submitted_at', prlr.submitted_at,
      'reviewed_at', prlr.reviewed_at,
      'review_note', prlr.review_note,
      'decision_source', prlr.decision_source,
      'decision_actor', prlr.decision_actor,
      'requires_general_manager', prlr.requires_general_manager,
      'general_manager_threshold_days', prlr.gm_threshold_days_snapshot,
      'gm_state', gm.state,
      'gm_decision', gm.decision,
      'default_shift_code', sh.shift_code,
      'default_shift_name', sh.shift_name
    ) order by prlr.start_date, prlr.submitted_at)
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    left join public.shifts sh on sh.shift_id = sm.default_shift_id
    left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
    where v_status is null or prlr.status = v_status
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- Pending request overlay for the week being planned
-- ---------------------------------------------------------------------

create or replace function public.get_production_roster_pending_leave(
  p_week_start date,
  p_shift_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
begin
  perform public.require_production_roster_manage_role();
  if v_shift_code not in ('MORNING', 'EVENING') then
    raise exception using errcode = '22023', message = 'Invalid shift.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'leave_request_id', q.leave_request_id,
      'staff_id', q.staff_id,
      'display_name', q.staff_display_name_snapshot,
      'request_type', q.request_type,
      'work_date', q.work_date,
      'reason', q.reason,
      'status', 'PENDING',
      'requires_general_manager', q.requires_general_manager,
      'gm_state', q.gm_state,
      'roster_shift_code', v_shift_code
    ) order by q.work_date, lower(q.staff_display_name_snapshot))
    from (
      select
        prlr.leave_request_id,
        prlr.staff_id,
        prlr.staff_display_name_snapshot,
        prlr.request_type,
        gs::date as work_date,
        prlr.reason,
        prlr.requires_general_manager,
        gm.state as gm_state
      from public.production_roster_leave_requests prlr
      left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
      cross join lateral generate_series(prlr.start_date, prlr.end_date, interval '1 day') gs
      where prlr.status = 'PENDING'
        and prlr.start_date >= (now() at time zone 'Europe/Dublin')::date
        and gs::date between v_week_start and v_week_start + 6
    ) q
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- Replace direct manager decision with long-Holiday guard + event history
-- ---------------------------------------------------------------------

create or replace function public.decide_production_roster_leave_request(
  p_leave_request_id uuid,
  p_decision text,
  p_review_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_decision text := upper(trim(coalesce(p_decision, '')));
  v_request public.production_roster_leave_requests%rowtype;
  v_actor_staff uuid := public.current_staff_id();
  v_actor_label text := coalesce(auth.jwt() ->> 'email', auth.uid()::text, 'Roster manager');
  v_gm public.production_roster_leave_gm_reviews%rowtype;
begin
  perform public.require_production_roster_manage_role();

  if v_decision not in ('APPROVED', 'REJECTED') then
    raise exception using errcode = '22023', message = 'Decision must be APPROVED or REJECTED.';
  end if;

  select * into v_request
  from public.production_roster_leave_requests
  where leave_request_id = p_leave_request_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Leave request not found.';
  end if;
  if v_request.status <> 'PENDING' then
    raise exception using errcode = '55000', message = 'Only pending leave requests can be reviewed.';
  end if;

  select * into v_gm
  from public.production_roster_leave_gm_reviews
  where leave_request_id = p_leave_request_id;

  if found and v_gm.state in ('SENDING', 'AWAITING_GM') then
    raise exception using errcode = '55000', message = 'This Holiday is awaiting the General Manager decision.';
  end if;

  if v_decision = 'APPROVED' and v_request.requires_general_manager then
    raise exception using errcode = '55000', message = 'This Holiday requires General Manager approval. Send it to the General Manager from the Requests queue.';
  end if;

  update public.production_roster_leave_requests
  set status = v_decision,
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = nullif(trim(p_review_note), ''),
      decision_source = 'MANAGER',
      decision_actor = v_actor_label
  where leave_request_id = v_request.leave_request_id
  returning * into v_request;

  if v_decision = 'REJECTED' then
    update public.production_roster_leave_gm_reviews
    set state = 'CANCELLED',
        decision = 'REJECTED',
        decided_at = now(),
        decision_note = nullif(trim(p_review_note), ''),
        updated_at = now()
    where leave_request_id = v_request.leave_request_id
      and state not in ('DECIDED', 'CANCELLED');
  end if;

  perform public.record_production_roster_leave_event(
    v_request.leave_request_id,
    'MANAGER_DECISION',
    v_actor_label,
    'ROSTER_MANAGER',
    'PENDING',
    v_decision,
    p_review_note,
    jsonb_build_object('decision', v_decision),
    auth.uid()
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(), v_actor_staff,
    case when v_decision = 'APPROVED' then 'PRODUCTION_ROSTER_LEAVE_REQUEST_APPROVED' else 'PRODUCTION_ROSTER_LEAVE_REQUEST_REJECTED' end,
    'production_roster_leave_requests', v_request.leave_request_id::text,
    jsonb_build_object(
      'staff_id', v_request.staff_id,
      'request_type', v_request.request_type,
      'start_date', v_request.start_date,
      'end_date', v_request.end_date,
      'status', v_request.status,
      'decision_source', 'MANAGER'
    ),
    v_request.review_note,
    'PRODUCTION_ROSTER'
  );

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    'status', v_request.status,
    'reviewed_at', v_request.reviewed_at,
    'decision_source', 'MANAGER',
    'message', case when v_decision = 'APPROVED'
      then 'Request approved. The approved dates will be protected in the Roster planner and require Save/Publish when applicable.'
      else 'Request rejected.' end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- General Manager email workflow
-- ---------------------------------------------------------------------

create or replace function public.prepare_production_roster_gm_review(p_leave_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_request public.production_roster_leave_requests%rowtype;
  v_settings jsonb := public.production_roster_leave_governance_settings_value();
  v_email text;
  v_ttl integer;
  v_token text;
  v_expires timestamptz;
  v_actor_label text := coalesce(auth.jwt() ->> 'email', auth.uid()::text, 'Roster manager');
begin
  perform public.require_production_roster_manage_role();

  select * into v_request
  from public.production_roster_leave_requests
  where leave_request_id = p_leave_request_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Leave request not found.';
  end if;
  if v_request.status <> 'PENDING' then
    raise exception using errcode = '55000', message = 'Only pending requests can be sent to the General Manager.';
  end if;
  if not v_request.requires_general_manager then
    raise exception using errcode = '55000', message = 'This Holiday does not require General Manager approval.';
  end if;

  v_email := trim(coalesce(v_settings ->> 'general_manager_email', ''));
  if v_email = '' then
    raise exception using errcode = '55000', message = 'General Manager email is not configured. Open Requests > Settings.';
  end if;
  v_ttl := greatest(24, coalesce((v_settings ->> 'general_manager_token_ttl_hours')::integer, 168));
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_expires := now() + make_interval(hours => v_ttl);

  insert into public.production_roster_leave_gm_reviews (
    leave_request_id, token_hash, token_hint, sent_to, state,
    sent_at, expires_at, decision, decided_at, decision_note, last_error, updated_at
  ) values (
    v_request.leave_request_id,
    public.production_roster_leave_gm_token_hash(v_token),
    left(v_token, 4) || '…' || right(v_token, 4),
    v_email,
    'SENDING',
    null,
    v_expires,
    null,
    null,
    null,
    null,
    now()
  )
  on conflict (leave_request_id) do update
  set token_hash = excluded.token_hash,
      token_hint = excluded.token_hint,
      sent_to = excluded.sent_to,
      state = 'SENDING',
      sent_at = null,
      expires_at = excluded.expires_at,
      decision = null,
      decided_at = null,
      decision_note = null,
      last_error = null,
      updated_at = now();

  perform public.record_production_roster_leave_event(
    v_request.leave_request_id,
    'GM_EMAIL_PREPARED',
    v_actor_label,
    'ROSTER_MANAGER',
    'PENDING',
    'PENDING',
    null,
    jsonb_build_object('sent_to', v_email, 'expires_at', v_expires),
    auth.uid()
  );

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    'review_token', v_token,
    'sent_to', v_email,
    'expires_at', v_expires,
    'display_name', v_request.staff_display_name_snapshot,
    'request_type', v_request.request_type,
    'start_date', v_request.start_date,
    'end_date', v_request.end_date,
    'duration_days', (v_request.end_date - v_request.start_date) + 1,
    'reason', v_request.reason,
    'general_manager_threshold_days', v_request.gm_threshold_days_snapshot
  );
end;
$$;

create or replace function public.mark_production_roster_gm_email_result(
  p_leave_request_id uuid,
  p_success boolean,
  p_error_message text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_gm public.production_roster_leave_gm_reviews%rowtype;
  v_actor_label text := coalesce(auth.jwt() ->> 'email', auth.uid()::text, 'Roster manager');
begin
  perform public.require_production_roster_manage_role();

  select * into v_gm
  from public.production_roster_leave_gm_reviews
  where leave_request_id = p_leave_request_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'General Manager review state not found.';
  end if;

  update public.production_roster_leave_gm_reviews
  set state = case when p_success then 'AWAITING_GM' else 'SEND_FAILED' end,
      sent_at = case when p_success then now() else sent_at end,
      last_error = case when p_success then null else left(coalesce(p_error_message, 'Email delivery failed.'), 1000) end,
      updated_at = now()
  where leave_request_id = p_leave_request_id
  returning * into v_gm;

  perform public.record_production_roster_leave_event(
    p_leave_request_id,
    case when p_success then 'FORWARDED_TO_GM' else 'GM_EMAIL_SEND_FAILED' end,
    v_actor_label,
    'ROSTER_MANAGER',
    'PENDING',
    'PENDING',
    case when p_success then null else p_error_message end,
    jsonb_build_object('sent_to', v_gm.sent_to, 'expires_at', v_gm.expires_at),
    auth.uid()
  );

  return jsonb_build_object(
    'leave_request_id', p_leave_request_id,
    'gm_state', v_gm.state,
    'sent_to', v_gm.sent_to,
    'sent_at', v_gm.sent_at,
    'expires_at', v_gm.expires_at
  );
end;
$$;

create or replace function public.get_production_roster_gm_review(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_gm public.production_roster_leave_gm_reviews%rowtype;
  v_request public.production_roster_leave_requests%rowtype;
begin
  if nullif(trim(p_token), '') is null then
    raise exception using errcode = '42501', message = 'This General Manager review link is invalid.';
  end if;

  select * into v_gm
  from public.production_roster_leave_gm_reviews gm
  where gm.token_hash = public.production_roster_leave_gm_token_hash(trim(p_token));
  if not found then
    raise exception using errcode = '42501', message = 'This General Manager review link is invalid.';
  end if;

  select * into v_request
  from public.production_roster_leave_requests
  where leave_request_id = v_gm.leave_request_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'The Holiday request no longer exists.';
  end if;

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    'display_name', v_request.staff_display_name_snapshot,
    'request_type', v_request.request_type,
    'start_date', v_request.start_date,
    'end_date', v_request.end_date,
    'duration_days', (v_request.end_date - v_request.start_date) + 1,
    'reason', v_request.reason,
    'status', v_request.status,
    'gm_state', v_gm.state,
    'gm_decision', v_gm.decision,
    'sent_to', v_gm.sent_to,
    'sent_at', v_gm.sent_at,
    'expires_at', v_gm.expires_at,
    'expired', v_gm.expires_at is not null and v_gm.expires_at < now(),
    'decided_at', v_gm.decided_at,
    'decision_note', v_gm.decision_note
  );
end;
$$;

create or replace function public.decide_production_roster_gm_review(
  p_token text,
  p_decision text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_decision text := upper(trim(coalesce(p_decision, '')));
  v_hash text;
  v_gm public.production_roster_leave_gm_reviews%rowtype;
  v_request public.production_roster_leave_requests%rowtype;
begin
  if v_decision not in ('APPROVED', 'REJECTED') then
    raise exception using errcode = '22023', message = 'Decision must be Approved or Rejected.';
  end if;
  if nullif(trim(p_token), '') is null then
    raise exception using errcode = '42501', message = 'This General Manager review link is invalid.';
  end if;

  v_hash := public.production_roster_leave_gm_token_hash(trim(p_token));
  select * into v_gm
  from public.production_roster_leave_gm_reviews gm
  where gm.token_hash = v_hash
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'This General Manager review link is invalid.';
  end if;

  if v_gm.state = 'DECIDED' then
    return jsonb_build_object(
      'leave_request_id', v_gm.leave_request_id,
      'status', v_gm.decision,
      'gm_state', v_gm.state,
      'message', 'This Holiday request was already ' || lower(coalesce(v_gm.decision, 'decided')) || '.'
    );
  end if;
  if v_gm.expires_at is not null and v_gm.expires_at < now() then
    raise exception using errcode = '55000', message = 'This General Manager review link has expired. Ask the Roster Manager to send a new email.';
  end if;
  if v_gm.state not in ('AWAITING_GM', 'SENDING') then
    raise exception using errcode = '55000', message = 'This General Manager review is not currently awaiting a decision.';
  end if;

  select * into v_request
  from public.production_roster_leave_requests
  where leave_request_id = v_gm.leave_request_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'The Holiday request no longer exists.';
  end if;

  if v_request.status <> 'PENDING' then
    update public.production_roster_leave_gm_reviews
    set state = 'DECIDED',
        decision = v_request.status,
        decided_at = coalesce(decided_at, now()),
        decision_note = coalesce(decision_note, v_request.review_note),
        updated_at = now()
    where leave_request_id = v_request.leave_request_id;

    return jsonb_build_object(
      'leave_request_id', v_request.leave_request_id,
      'status', v_request.status,
      'gm_state', 'DECIDED',
      'message', 'This Holiday request was already ' || lower(v_request.status) || '.'
    );
  end if;

  update public.production_roster_leave_requests
  set status = v_decision,
      reviewed_at = now(),
      reviewed_by = null,
      review_note = nullif(trim(p_note), ''),
      decision_source = 'GENERAL_MANAGER',
      decision_actor = coalesce(v_gm.sent_to, 'General Manager')
  where leave_request_id = v_request.leave_request_id
  returning * into v_request;

  update public.production_roster_leave_gm_reviews
  set state = 'DECIDED',
      decision = v_decision,
      decided_at = now(),
      decision_note = nullif(trim(p_note), ''),
      last_error = null,
      updated_at = now()
  where leave_request_id = v_request.leave_request_id
  returning * into v_gm;

  perform public.record_production_roster_leave_event(
    v_request.leave_request_id,
    'GENERAL_MANAGER_DECISION',
    coalesce(v_gm.sent_to, 'General Manager'),
    'GENERAL_MANAGER',
    'PENDING',
    v_decision,
    p_note,
    jsonb_build_object('sent_to', v_gm.sent_to),
    null
  );

  insert into public.audit_log (
    action, entity_table, entity_id, new_data, reason, source_application
  ) values (
    case when v_decision = 'APPROVED'
      then 'PRODUCTION_ROSTER_LEAVE_REQUEST_GM_APPROVED'
      else 'PRODUCTION_ROSTER_LEAVE_REQUEST_GM_REJECTED'
    end,
    'production_roster_leave_requests',
    v_request.leave_request_id::text,
    jsonb_build_object(
      'staff_id', v_request.staff_id,
      'request_type', v_request.request_type,
      'start_date', v_request.start_date,
      'end_date', v_request.end_date,
      'status', v_request.status,
      'decision_source', 'GENERAL_MANAGER'
    ),
    v_request.review_note,
    'PRODUCTION_ROSTER_GM_REVIEW'
  );

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    'status', v_request.status,
    'gm_state', v_gm.state,
    'decided_at', v_gm.decided_at,
    'message', 'Holiday request ' || case when v_decision = 'APPROVED' then 'approved' else 'rejected' end || '.'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Staff-side recent request status, now including GM workflow state
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
      order by submitted_at desc
      limit 20
    ) prlr
    left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- Grants: all tables remain private; clients use explicit RPCs only
-- ---------------------------------------------------------------------

revoke all on function public.production_roster_leave_governance_settings_value() from public, anon, authenticated;
revoke all on function public.get_production_roster_leave_governance_settings() from public, anon, authenticated;
revoke all on function public.save_production_roster_leave_governance_settings(integer, text, integer) from public, anon, authenticated;
revoke all on function public.protect_production_roster_leave_request_events() from public, anon, authenticated;
revoke all on function public.record_production_roster_leave_event(uuid, text, text, text, text, text, text, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.expire_stale_production_roster_leave_requests() from public, anon, authenticated;
revoke all on function public.get_production_roster_leave_dashboard(date, text, text) from public, anon, authenticated;
revoke all on function public.get_production_roster_leave_request_history(uuid) from public, anon, authenticated;
revoke all on function public.get_production_roster_pending_leave(date, text) from public, anon, authenticated;
revoke all on function public.prepare_production_roster_gm_review(uuid) from public, anon, authenticated;
revoke all on function public.mark_production_roster_gm_email_result(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.production_roster_leave_gm_token_hash(text) from public, anon, authenticated;
revoke all on function public.get_production_roster_gm_review(text) from public, anon, authenticated;
revoke all on function public.decide_production_roster_gm_review(text, text, text) from public, anon, authenticated;

-- Internal helper is callable only by definer functions.
-- Governance/queue management is authenticated and role-checked inside RPCs.
grant execute on function public.get_production_roster_leave_governance_settings() to authenticated;
grant execute on function public.save_production_roster_leave_governance_settings(integer, text, integer) to authenticated;
grant execute on function public.expire_stale_production_roster_leave_requests() to authenticated;
grant execute on function public.get_production_roster_leave_dashboard(date, text, text) to authenticated;
grant execute on function public.get_production_roster_leave_request_history(uuid) to authenticated;
grant execute on function public.get_production_roster_pending_leave(date, text) to authenticated;
grant execute on function public.prepare_production_roster_gm_review(uuid) to authenticated;
grant execute on function public.mark_production_roster_gm_email_result(uuid, boolean, text) to authenticated;

-- Existing direct decision and submission grants remain, but function bodies were replaced.
grant execute on function public.submit_production_roster_leave_request(text, uuid, text, date, date, text) to anon, authenticated;
grant execute on function public.get_my_production_roster_leave_requests(text, uuid) to anon, authenticated;
grant execute on function public.decide_production_roster_leave_request(uuid, text, text) to authenticated;

-- General Manager link is bearer-token protected and intentionally anonymous.
grant execute on function public.get_production_roster_gm_review(text) to anon, authenticated;
grant execute on function public.decide_production_roster_gm_review(text, text, text) to anon, authenticated;

comment on table public.production_roster_leave_request_events is
  'Immutable event trail for Holiday / Day Off requests, including submission, manager decisions, General Manager routing and expiry.';
comment on table public.production_roster_leave_gm_reviews is
  'Secure one-time General Manager review state. Only token hashes are stored; the raw token exists only while preparing the email.';
comment on function public.get_production_roster_leave_dashboard(date, text, text) is
  'Planning-aware leave queue. Future requests become actionable during their planning week and missed requests are closed as EXPIRED.';
comment on function public.get_production_roster_pending_leave(date, text) is
  'Returns unresolved requests as a non-locking planner overlay so the Roster Manager sees requested leave while balancing staffing.';
comment on function public.decide_production_roster_gm_review(text, text, text) is
  'Records an idempotent General Manager decision from a secure bearer link without modifying published Production Roster entries.';

commit;
