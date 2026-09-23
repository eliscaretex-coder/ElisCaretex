-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608070001_production_roster_staff_portal_and_leave_requests.sql
--
-- Purpose:
--   1. Replace the normal staff-link workflow with one fixed, shared
--      Production Roster portal link for both Morning and Evening.
--   2. Return Morning and Evening published rosters through that same link.
--   3. Add governed Holiday / Day Off requests from RosterView.
--   4. Add an ADMIN / MANAGER / ROSTER_MANAGER review queue.
--   5. Expose approved leave as a planning overlay without ever modifying
--      published Production Roster entries.
--
-- Important:
--   - Existing per-shift revocable links/functions are retained for backward
--     compatibility; the V2 frontend stops rotating them.
--   - The fixed portal token is stored only in a protected table so managers
--     can retrieve the same link later. Browser roles have no table access.
--   - This migration performs NO UPDATE or DELETE on production_roster_entries.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Fixed shared staff portal link
-- ---------------------------------------------------------------------

create table if not exists public.production_roster_staff_portal_links (
  scope_code text primary key,
  token_value text not null unique,
  token_hash text not null unique,
  token_hint text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  last_used_at timestamptz,
  constraint production_roster_staff_portal_scope_check
    check (scope_code = 'STAFF_PORTAL')
);

alter table public.production_roster_staff_portal_links enable row level security;
revoke all on table public.production_roster_staff_portal_links from public, anon, authenticated;

create or replace function public.production_roster_staff_portal_token_hash(p_token text)
returns text
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select md5('ELISCARETEXT-ROSTER-PORTAL-A:' || p_token)
      || md5('ELISCARETEXT-ROSTER-PORTAL-B:' || p_token);
$$;

create or replace function public.require_production_roster_staff_portal_token(p_token text)
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if nullif(trim(p_token), '') is null or not exists (
    select 1
    from public.production_roster_staff_portal_links prspl
    where prspl.scope_code = 'STAFF_PORTAL'
      and prspl.active = true
      and prspl.token_hash = public.production_roster_staff_portal_token_hash(trim(p_token))
  ) then
    raise exception using errcode = '42501', message = 'This Production Roster staff link is invalid.';
  end if;
end;
$$;

create or replace function public.get_or_create_production_roster_staff_portal_link()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_link public.production_roster_staff_portal_links%rowtype;
  v_token text;
  v_actor_staff uuid := public.current_staff_id();
begin
  perform public.require_production_roster_manage_role();
  perform pg_advisory_xact_lock(hashtext('ELISCARETEXT_PRODUCTION_ROSTER_STAFF_PORTAL'));

  select * into v_link
  from public.production_roster_staff_portal_links
  where scope_code = 'STAFF_PORTAL'
    and active = true;

  if not found then
    v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

    insert into public.production_roster_staff_portal_links (
      scope_code, token_value, token_hash, token_hint, active, created_by
    ) values (
      'STAFF_PORTAL',
      v_token,
      public.production_roster_staff_portal_token_hash(v_token),
      left(v_token, 4) || '…' || right(v_token, 4),
      true,
      auth.uid()
    )
    returning * into v_link;

    insert into public.audit_log (
      actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
      new_data, source_application
    ) values (
      auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_STAFF_PORTAL_LINK_CREATED',
      'production_roster_staff_portal_links', v_link.scope_code,
      jsonb_build_object('token_hint', v_link.token_hint, 'shared_shifts', jsonb_build_array('MORNING', 'EVENING')),
      'PRODUCTION_ROSTER'
    );
  end if;

  return jsonb_build_object(
    'token', v_link.token_value,
    'token_hint', v_link.token_hint,
    'scope_code', v_link.scope_code,
    'created_at', v_link.created_at,
    'shared_shifts', jsonb_build_array('MORNING', 'EVENING'),
    'fixed', true
  );
end;
$$;

-- ---------------------------------------------------------------------
-- One token -> Morning + Evening current/next published roster
-- ---------------------------------------------------------------------

create or replace function public.get_published_production_roster_portal(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_current_week date;
begin
  perform public.require_production_roster_staff_portal_token(p_token);
  v_current_week := public.production_roster_week_start(v_today);

  update public.production_roster_staff_portal_links
  set last_used_at = now()
  where scope_code = 'STAFF_PORTAL'
    and active = true;

  return jsonb_build_object(
    'generated_at', now(),
    'fixed_link', true,
    'shifts', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'shift_code', s.shift_code,
          'shift_name', s.shift_name,
          'weeks', coalesce((
            select jsonb_agg(week_json order by (week_json ->> 'week_start')::date)
            from (
              select jsonb_build_object(
                'week_start', rp.week_start,
                'week_end', rp.week_start + 6,
                'version_number', prv.version_number,
                'published_at', prv.published_at,
                'week_note', prv.week_note,
                'include_sunday', prv.include_sunday,
                'entries', coalesce((
                  select jsonb_agg(jsonb_build_object(
                    'staff_id', pre.staff_id,
                    'display_name', pre.staff_display_name_snapshot,
                    'work_date', pre.work_date,
                    'day_status', pre.day_status,
                    'assignment_type', pre.assignment_type,
                    'operational_role_code', pre.operational_role_code_snapshot,
                    'operational_role_name', pre.operational_role_name_snapshot,
                    'area_code', pre.area_code_snapshot,
                    'area_name', pre.area_name_snapshot,
                    'station_code', pre.station_code_snapshot,
                    'station_name', pre.station_name_snapshot,
                    'display_section_code', coalesce(
                      pre.display_section_code,
                      public.production_roster_default_display_section(
                        pre.staff_primary_role_code_snapshot,
                        pre.staff_default_station_code_snapshot
                      )
                    ),
                    'staff_primary_role_code', pre.staff_primary_role_code_snapshot,
                    'staff_primary_role_name', pre.staff_primary_role_name_snapshot,
                    'staff_default_area_code', pre.staff_default_area_code_snapshot,
                    'staff_default_area_name', pre.staff_default_area_name_snapshot,
                    'staff_default_station_code', pre.staff_default_station_code_snapshot,
                    'staff_default_station_name', pre.staff_default_station_name_snapshot,
                    'staff_default_shift_code', coalesce(pre.staff_default_shift_code_snapshot, pre.shift_code_snapshot),
                    'staff_default_shift_name', coalesce(pre.staff_default_shift_name_snapshot, pre.shift_name_snapshot),
                    'roster_shift_code', pre.shift_code_snapshot,
                    'roster_shift_name', pre.shift_name_snapshot,
                    'fire_training', pre.fire_training_snapshot,
                    'first_aid_training', pre.first_aid_training_snapshot,
                    'eod_capable', pre.eod_capable_snapshot,
                    'notes', pre.notes
                  ) order by
                    public.production_roster_display_section_sort(coalesce(
                      pre.display_section_code,
                      public.production_roster_default_display_section(
                        pre.staff_primary_role_code_snapshot,
                        pre.staff_default_station_code_snapshot
                      )
                    )),
                    lower(pre.staff_display_name_snapshot),
                    pre.work_date)
                  from public.production_roster_entries pre
                  where pre.roster_version_id = prv.roster_version_id
                ), '[]'::jsonb)
              ) as week_json
              from public.production_roster_versions prv
              join public.roster_periods rp
                on rp.roster_period_id = prv.roster_period_id
              where prv.shift_id = s.shift_id
                and prv.status = 'PUBLISHED'
                and rp.week_start in (v_current_week, v_current_week + 7)
            ) published_weeks
          ), '[]'::jsonb)
        )
        order by case upper(s.shift_code) when 'MORNING' then 1 when 'EVENING' then 2 else 99 end
      )
      from public.shifts s
      where upper(s.shift_code) in ('MORNING', 'EVENING')
        and s.active = true
        and s.deleted_at is null
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Holiday / Day Off request lifecycle
-- ---------------------------------------------------------------------

create table if not exists public.production_roster_leave_requests (
  leave_request_id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  staff_display_name_snapshot text not null,
  request_type text not null,
  start_date date not null,
  end_date date not null,
  reason text,
  status text not null default 'PENDING',
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_note text,
  source_application text not null default 'ROSTER_VIEW',
  constraint production_roster_leave_type_check
    check (request_type in ('DAY_OFF', 'HOLIDAY')),
  constraint production_roster_leave_status_check
    check (status in ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')),
  constraint production_roster_leave_date_check
    check (end_date >= start_date),
  constraint production_roster_day_off_single_date_check
    check (request_type <> 'DAY_OFF' or end_date = start_date),
  constraint production_roster_leave_reason_length_check
    check (reason is null or length(reason) <= 280),
  constraint production_roster_leave_review_note_length_check
    check (review_note is null or length(review_note) <= 500)
);

create index if not exists production_roster_leave_requests_staff_idx
  on public.production_roster_leave_requests (staff_id, submitted_at desc);

create index if not exists production_roster_leave_requests_queue_idx
  on public.production_roster_leave_requests (status, start_date, submitted_at);

alter table public.production_roster_leave_requests enable row level security;
revoke all on table public.production_roster_leave_requests from public, anon, authenticated;

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

  insert into public.production_roster_leave_requests (
    staff_id, staff_display_name_snapshot, request_type,
    start_date, end_date, reason, status, source_application
  ) values (
    v_staff.staff_id,
    v_staff.display_name,
    v_type,
    v_start,
    v_end,
    nullif(trim(p_reason), ''),
    'PENDING',
    'ROSTER_VIEW'
  )
  returning * into v_request;

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
      'status', v_request.status
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
    'submitted_at', v_request.submitted_at,
    'message', 'Request submitted. A manager will review it.'
  );
end;
$$;

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
      'submitted_at', prlr.submitted_at,
      'reviewed_at', prlr.reviewed_at
    ) order by prlr.submitted_at desc)
    from (
      select *
      from public.production_roster_leave_requests
      where staff_id = p_staff_id
      order by submitted_at desc
      limit 12
    ) prlr
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_production_roster_leave_requests(p_status text default 'PENDING')
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_status text := upper(nullif(trim(coalesce(p_status, '')), ''));
begin
  perform public.require_production_roster_manage_role();

  if v_status is not null and v_status not in ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED') then
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
      'reason', prlr.reason,
      'status', prlr.status,
      'submitted_at', prlr.submitted_at,
      'reviewed_at', prlr.reviewed_at,
      'review_note', prlr.review_note,
      'default_shift_code', sh.shift_code,
      'default_shift_name', sh.shift_name
    ) order by prlr.start_date, prlr.submitted_at)
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    left join public.shifts sh on sh.shift_id = sm.default_shift_id
    where v_status is null or prlr.status = v_status
  ), '[]'::jsonb);
end;
$$;

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

  update public.production_roster_leave_requests
  set status = v_decision,
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = nullif(trim(p_review_note), '')
  where leave_request_id = v_request.leave_request_id
  returning * into v_request;

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
      'status', v_request.status
    ),
    v_request.review_note,
    'PRODUCTION_ROSTER'
  );

  return jsonb_build_object(
    'leave_request_id', v_request.leave_request_id,
    'status', v_request.status,
    'reviewed_at', v_request.reviewed_at,
    'message', case when v_decision = 'APPROVED'
      then 'Request approved. The approved dates will be protected in the Roster planner and require Save/Publish when applicable.'
      else 'Request rejected.' end
  );
end;
$$;

create or replace function public.get_production_roster_approved_leave(
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
      'status', 'APPROVED',
      'roster_shift_code', v_shift_code
    ) order by q.work_date, lower(q.staff_display_name_snapshot))
    from (
      select
        prlr.leave_request_id,
        prlr.staff_id,
        prlr.staff_display_name_snapshot,
        prlr.request_type,
        gs::date as work_date,
        prlr.reason
      from public.production_roster_leave_requests prlr
      cross join lateral generate_series(prlr.start_date, prlr.end_date, interval '1 day') gs
      where prlr.status = 'APPROVED'
        and gs::date between v_week_start and v_week_start + 6
    ) q
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------

revoke all on function public.production_roster_staff_portal_token_hash(text) from public, anon, authenticated;
revoke all on function public.require_production_roster_staff_portal_token(text) from public, anon, authenticated;
revoke all on function public.get_or_create_production_roster_staff_portal_link() from public, anon, authenticated;
revoke all on function public.get_published_production_roster_portal(text) from public, anon, authenticated;
revoke all on function public.submit_production_roster_leave_request(text, uuid, text, date, date, text) from public, anon, authenticated;
revoke all on function public.get_my_production_roster_leave_requests(text, uuid) from public, anon, authenticated;
revoke all on function public.get_production_roster_leave_requests(text) from public, anon, authenticated;
revoke all on function public.decide_production_roster_leave_request(uuid, text, text) from public, anon, authenticated;
revoke all on function public.get_production_roster_approved_leave(date, text) from public, anon, authenticated;

grant execute on function public.get_or_create_production_roster_staff_portal_link() to authenticated;
grant execute on function public.get_published_production_roster_portal(text) to anon, authenticated;
grant execute on function public.submit_production_roster_leave_request(text, uuid, text, date, date, text) to anon, authenticated;
grant execute on function public.get_my_production_roster_leave_requests(text, uuid) to anon, authenticated;
grant execute on function public.get_production_roster_leave_requests(text) to authenticated;
grant execute on function public.decide_production_roster_leave_request(uuid, text, text) to authenticated;
grant execute on function public.get_production_roster_approved_leave(date, text) to authenticated;

comment on table public.production_roster_staff_portal_links is
  'Protected singleton bearer link used by staff to open one fixed RosterView for both Morning and Evening.';

comment on table public.production_roster_leave_requests is
  'Governed Holiday and Day Off requests submitted from the fixed staff RosterView and reviewed by Production Roster managers.';

comment on function public.get_or_create_production_roster_staff_portal_link() is
  'Returns the existing fixed Morning+Evening staff portal token, creating it only once when absent.';

comment on function public.get_published_production_roster_portal(text) is
  'Returns current and next published Morning and Evening Production Rosters through the fixed protected staff portal token.';

comment on function public.get_production_roster_approved_leave(date, text) is
  'Returns approved Holiday and Day Off dates as a planning overlay. It never modifies published Production Roster entries.';
