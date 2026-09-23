-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608070003_production_roster_capacity_and_staff_history.sql
--
-- Purpose:
--   1. Add extensible production targets for Roster planning.
--   2. Store the confirmed Morning / Evening working-hour profiles used by
--      Finish Table capacity calculations.
--   3. Add governed Bank Holiday dates so Monday Bank Holidays use the
--      Saturday production profile.
--   4. Add scalable staff-specific leave history search.
--   5. Add a lightweight leave revision RPC for near-real-time Roster refresh.
--
-- Security / history:
--   - Direct client access to configuration tables is revoked.
--   - All client access is through role-checked SECURITY DEFINER RPCs.
--   - Target and Bank Holiday changes are written to audit_log.
--   - This migration does not mutate production_roster_entries.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Extensible operational production targets
-- ---------------------------------------------------------------------

create table if not exists public.production_targets (
  target_code text primary key,
  target_name text not null,
  area_code text,
  metric_code text not null,
  unit_code text not null,
  target_value numeric(12,3) not null,
  description text,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint production_targets_code_check check (target_code ~ '^[A-Z0-9_]+$'),
  constraint production_targets_positive_value_check check (target_value > 0)
);

alter table public.production_targets enable row level security;
revoke all on table public.production_targets from public, anon, authenticated;

insert into public.production_targets (
  target_code, target_name, area_code, metric_code, unit_code,
  target_value, description, active, sort_order
) values (
  'FINISH_TABLE_KG_PER_STAFF_HOUR',
  'Finish table productivity',
  'FINISH',
  'PRODUCTIVITY_PER_STAFF_HOUR',
  'KG_PER_STAFF_HOUR',
  23.5,
  'Target kilograms per productive staff hour for Finish Tables 1, 2 and 3.',
  true,
  10
)
on conflict (target_code) do nothing;

-- ---------------------------------------------------------------------
-- Confirmed Roster working-hour profiles
--
-- Net productive minutes already exclude the confirmed break.
-- Morning has two equivalent start patterns on Mon-Wed / Thu-Fri; both
-- have the same gross and net duration, so capacity is unaffected by which
-- of the two start times an individual staff member follows.
-- ---------------------------------------------------------------------

create table if not exists public.production_roster_work_profiles (
  profile_code text primary key,
  shift_code text not null,
  profile_name text not null,
  iso_days smallint[] not null default '{}'::smallint[],
  applies_to_bank_holiday boolean not null default false,
  schedule_label text not null,
  break_minutes integer not null,
  net_minutes integer not null,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint production_roster_work_profiles_shift_check check (shift_code in ('MORNING', 'EVENING')),
  constraint production_roster_work_profiles_break_check check (break_minutes between 0 and 180),
  constraint production_roster_work_profiles_net_check check (net_minutes between 1 and 900),
  constraint production_roster_work_profiles_iso_days_check check (
    iso_days <@ array[1,2,3,4,5,6,7]::smallint[]
  )
);

alter table public.production_roster_work_profiles enable row level security;
revoke all on table public.production_roster_work_profiles from public, anon, authenticated;

insert into public.production_roster_work_profiles (
  profile_code, shift_code, profile_name, iso_days, applies_to_bank_holiday,
  schedule_label, break_minutes, net_minutes, active, sort_order
) values
  ('MORNING_MON_WED', 'MORNING', 'Monday to Wednesday', array[1,2,3]::smallint[], false,
    '06:00-15:00 or 07:00-16:00', 45, 495, true, 10),
  ('MORNING_THU_FRI', 'MORNING', 'Thursday and Friday', array[4,5]::smallint[], false,
    '06:00-14:00 or 07:00-15:00', 45, 435, true, 20),
  ('MORNING_SAT_BANK', 'MORNING', 'Saturday / Bank Holiday Monday', array[6]::smallint[], true,
    '07:00-15:00', 45, 435, true, 30),
  ('EVENING_MON_WED', 'EVENING', 'Monday to Wednesday', array[1,2,3]::smallint[], false,
    '15:00-23:20', 30, 470, true, 40),
  ('EVENING_THU_FRI', 'EVENING', 'Thursday and Friday', array[4,5]::smallint[], false,
    '14:00-23:20', 45, 515, true, 50),
  ('EVENING_SAT_BANK', 'EVENING', 'Saturday / Bank Holiday Monday', array[6]::smallint[], true,
    '15:00-22:30', 30, 420, true, 60)
on conflict (profile_code) do update
set shift_code = excluded.shift_code,
    profile_name = excluded.profile_name,
    iso_days = excluded.iso_days,
    applies_to_bank_holiday = excluded.applies_to_bank_holiday,
    schedule_label = excluded.schedule_label,
    break_minutes = excluded.break_minutes,
    net_minutes = excluded.net_minutes,
    active = true,
    sort_order = excluded.sort_order,
    updated_at = now();

-- ---------------------------------------------------------------------
-- Production calendar exceptions
-- ---------------------------------------------------------------------

create table if not exists public.production_roster_calendar_exceptions (
  work_date date primary key,
  exception_type text not null,
  label text not null default 'Bank Holiday',
  use_saturday_profile boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint production_roster_calendar_exception_type_check
    check (exception_type in ('BANK_HOLIDAY'))
);

alter table public.production_roster_calendar_exceptions enable row level security;
revoke all on table public.production_roster_calendar_exceptions from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Controlled read / write settings API
-- ---------------------------------------------------------------------

create or replace function public.get_production_roster_operational_settings(
  p_from_date date default null,
  p_to_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_from date := coalesce(p_from_date, (now() at time zone 'Europe/Dublin')::date - 31);
  v_to date := coalesce(p_to_date, (now() at time zone 'Europe/Dublin')::date + 730);
begin
  perform public.require_production_roster_read_role();

  if v_to < v_from then
    raise exception using errcode = '22023', message = 'Operational settings date range is invalid.';
  end if;
  if (v_to - v_from) > 1461 then
    raise exception using errcode = '22023', message = 'Operational settings date range cannot exceed four years.';
  end if;

  return jsonb_build_object(
    'targets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'target_code', pt.target_code,
        'target_name', pt.target_name,
        'area_code', pt.area_code,
        'metric_code', pt.metric_code,
        'unit_code', pt.unit_code,
        'target_value', pt.target_value,
        'description', pt.description,
        'sort_order', pt.sort_order,
        'updated_at', pt.updated_at
      ) order by pt.sort_order, pt.target_name)
      from public.production_targets pt
      where pt.active = true
    ), '[]'::jsonb),
    'work_profiles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'profile_code', p.profile_code,
        'shift_code', p.shift_code,
        'profile_name', p.profile_name,
        'iso_days', to_jsonb(p.iso_days),
        'applies_to_bank_holiday', p.applies_to_bank_holiday,
        'schedule_label', p.schedule_label,
        'break_minutes', p.break_minutes,
        'net_minutes', p.net_minutes,
        'net_hours', round((p.net_minutes::numeric / 60.0), 3),
        'sort_order', p.sort_order
      ) order by p.sort_order, p.profile_code)
      from public.production_roster_work_profiles p
      where p.active = true
    ), '[]'::jsonb),
    'bank_holidays', coalesce((
      select jsonb_agg(jsonb_build_object(
        'work_date', e.work_date,
        'label', e.label,
        'use_saturday_profile', e.use_saturday_profile
      ) order by e.work_date)
      from public.production_roster_calendar_exceptions e
      where e.active = true
        and e.exception_type = 'BANK_HOLIDAY'
        and e.work_date between v_from and v_to
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.save_production_roster_target(
  p_target_code text,
  p_target_value numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_code text := upper(trim(coalesce(p_target_code, '')));
  v_value numeric := round(coalesce(p_target_value, 0)::numeric, 3);
  v_target public.production_targets%rowtype;
  v_old_value numeric;
  v_actor_staff uuid := public.current_staff_id();
begin
  perform public.require_production_roster_manage_role();

  if v_code = '' then
    raise exception using errcode = '22023', message = 'Target code is required.';
  end if;
  if v_value <= 0 or v_value > 100000 then
    raise exception using errcode = '22023', message = 'Target value must be greater than zero.';
  end if;

  select * into v_target
  from public.production_targets
  where target_code = v_code and active = true
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Production target not found.';
  end if;

  v_old_value := v_target.target_value;

  update public.production_targets
  set target_value = v_value,
      updated_at = now(),
      updated_by = auth.uid()
  where target_code = v_code
  returning * into v_target;

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_TARGET_UPDATED',
    'production_targets', v_code,
    jsonb_build_object('target_value', v_old_value),
    jsonb_build_object('target_value', v_target.target_value, 'unit_code', v_target.unit_code),
    'PRODUCTION_ROSTER'
  );

  return jsonb_build_object(
    'target_code', v_target.target_code,
    'target_name', v_target.target_name,
    'target_value', v_target.target_value,
    'unit_code', v_target.unit_code,
    'updated_at', v_target.updated_at
  );
end;
$$;

create or replace function public.save_production_roster_bank_holiday(
  p_work_date date,
  p_label text default 'Bank Holiday'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_label text := left(trim(coalesce(p_label, 'Bank Holiday')), 120);
  v_actor_staff uuid := public.current_staff_id();
begin
  perform public.require_production_roster_manage_role();
  if p_work_date is null then
    raise exception using errcode = '22023', message = 'Bank Holiday date is required.';
  end if;
  if extract(isodow from p_work_date) <> 1 then
    raise exception using errcode = '22023', message = 'The current Roster Bank Holiday rule applies to Monday dates only.';
  end if;
  if v_label = '' then v_label := 'Bank Holiday'; end if;

  insert into public.production_roster_calendar_exceptions (
    work_date, exception_type, label, use_saturday_profile, active,
    created_by, updated_by
  ) values (
    p_work_date, 'BANK_HOLIDAY', v_label, true, true,
    auth.uid(), auth.uid()
  )
  on conflict (work_date) do update
  set exception_type = 'BANK_HOLIDAY',
      label = excluded.label,
      use_saturday_profile = true,
      active = true,
      updated_at = now(),
      updated_by = auth.uid();

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, source_application
  ) values (
    auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_BANK_HOLIDAY_SAVED',
    'production_roster_calendar_exceptions', p_work_date::text,
    jsonb_build_object('work_date', p_work_date, 'label', v_label, 'use_saturday_profile', true),
    'PRODUCTION_ROSTER'
  );

  return jsonb_build_object('work_date', p_work_date, 'label', v_label, 'use_saturday_profile', true);
end;
$$;

create or replace function public.remove_production_roster_bank_holiday(p_work_date date)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_actor_staff uuid := public.current_staff_id();
  v_found boolean := false;
begin
  perform public.require_production_roster_manage_role();

  update public.production_roster_calendar_exceptions
  set active = false,
      updated_at = now(),
      updated_by = auth.uid()
  where work_date = p_work_date
    and exception_type = 'BANK_HOLIDAY'
    and active = true;
  v_found := found;

  if v_found then
    insert into public.audit_log (
      actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
      new_data, source_application
    ) values (
      auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_BANK_HOLIDAY_REMOVED',
      'production_roster_calendar_exceptions', p_work_date::text,
      jsonb_build_object('work_date', p_work_date, 'active', false),
      'PRODUCTION_ROSTER'
    );
  end if;

  return jsonb_build_object('work_date', p_work_date, 'removed', v_found);
end;
$$;

-- ---------------------------------------------------------------------
-- Staff-specific leave history search
-- ---------------------------------------------------------------------

create or replace function public.search_production_roster_staff_leave_history(
  p_staff_search text default null,
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_search text := trim(coalesce(p_staff_search, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 500));
  v_requests jsonb;
  v_staff jsonb;
begin
  perform public.require_production_roster_manage_role();
  perform public.expire_stale_production_roster_leave_requests();

  if length(v_search) > 120 then
    raise exception using errcode = '22023', message = 'Staff search is too long.';
  end if;

  with matched as (
    select
      prlr.*,
      ((prlr.end_date - prlr.start_date) + 1)::integer as duration_days,
      sh.shift_code as default_shift_code,
      sh.shift_name as default_shift_name,
      gm.state as gm_state,
      gm.sent_to as gm_sent_to,
      gm.sent_at as gm_sent_at,
      gm.expires_at as gm_expires_at,
      gm.decision as gm_decision,
      gm.decided_at as gm_decided_at,
      gm.updated_at as gm_updated_at
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    left join public.shifts sh on sh.shift_id = sm.default_shift_id
    left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id = prlr.leave_request_id
    where v_search = ''
       or prlr.staff_display_name_snapshot ilike '%' || v_search || '%'
       or coalesce(sm.display_name, '') ilike '%' || v_search || '%'
    order by prlr.submitted_at desc
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'leave_request_id', m.leave_request_id,
    'staff_id', m.staff_id,
    'display_name', m.staff_display_name_snapshot,
    'request_type', m.request_type,
    'start_date', m.start_date,
    'end_date', m.end_date,
    'duration_days', m.duration_days,
    'reason', m.reason,
    'status', m.status,
    'submitted_at', m.submitted_at,
    'reviewed_at', m.reviewed_at,
    'review_note', m.review_note,
    'requires_general_manager', m.requires_general_manager,
    'general_manager_threshold_days', coalesce(m.gm_threshold_days_snapshot, 20),
    'decision_source', m.decision_source,
    'decision_actor', m.decision_actor,
    'default_shift_code', m.default_shift_code,
    'default_shift_name', m.default_shift_name,
    'gm_state', m.gm_state,
    'gm_sent_to', m.gm_sent_to,
    'gm_sent_at', m.gm_sent_at,
    'gm_expires_at', m.gm_expires_at,
    'gm_decision', m.gm_decision,
    'gm_decided_at', m.gm_decided_at,
    'gm_updated_at', m.gm_updated_at,
    'attention_state', case when m.status = 'PENDING' then 'PENDING' else m.status end
  ) order by m.submitted_at desc), '[]'::jsonb)
  into v_requests
  from matched m;

  with staff_summary as (
    select
      prlr.staff_id,
      max(coalesce(sm.display_name, prlr.staff_display_name_snapshot)) as display_name,
      count(*)::integer as total_requests,
      count(*) filter (where prlr.status = 'PENDING')::integer as pending_count,
      count(*) filter (where prlr.status = 'APPROVED')::integer as approved_count,
      count(*) filter (where prlr.status = 'REJECTED')::integer as rejected_count,
      count(*) filter (where prlr.status = 'EXPIRED')::integer as expired_count,
      count(*) filter (where prlr.status = 'CANCELLED')::integer as cancelled_count,
      max(prlr.submitted_at) as last_request_at
    from public.production_roster_leave_requests prlr
    left join public.staff_members sm on sm.staff_id = prlr.staff_id
    where v_search = ''
       or prlr.staff_display_name_snapshot ilike '%' || v_search || '%'
       or coalesce(sm.display_name, '') ilike '%' || v_search || '%'
    group by prlr.staff_id
    order by max(prlr.submitted_at) desc, max(prlr.staff_display_name_snapshot)
    limit 50
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id', s.staff_id,
    'display_name', s.display_name,
    'total_requests', s.total_requests,
    'pending_count', s.pending_count,
    'approved_count', s.approved_count,
    'rejected_count', s.rejected_count,
    'expired_count', s.expired_count,
    'cancelled_count', s.cancelled_count,
    'last_request_at', s.last_request_at
  ) order by s.last_request_at desc, s.display_name), '[]'::jsonb)
  into v_staff
  from staff_summary s;

  return jsonb_build_object(
    'query', v_search,
    'staff', v_staff,
    'requests', v_requests,
    'limit', v_limit
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Lightweight revision token for safe polling
-- ---------------------------------------------------------------------

create or replace function public.get_production_roster_leave_revision()
returns text
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_revision timestamptz;
begin
  perform public.require_production_roster_manage_role();

  select max(v.ts) into v_revision
  from (
    select max(prlr.submitted_at) as ts from public.production_roster_leave_requests prlr
    union all
    select max(prlr.reviewed_at) as ts from public.production_roster_leave_requests prlr
    union all
    select max(e.occurred_at) as ts from public.production_roster_leave_request_events e
    union all
    select max(gm.updated_at) as ts from public.production_roster_leave_gm_reviews gm
  ) v;

  return coalesce(to_char(v_revision at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '0');
end;
$$;

-- ---------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------

revoke all on function public.get_production_roster_operational_settings(date, date) from public, anon, authenticated;
revoke all on function public.save_production_roster_target(text, numeric) from public, anon, authenticated;
revoke all on function public.save_production_roster_bank_holiday(date, text) from public, anon, authenticated;
revoke all on function public.remove_production_roster_bank_holiday(date) from public, anon, authenticated;
revoke all on function public.search_production_roster_staff_leave_history(text, integer) from public, anon, authenticated;
revoke all on function public.get_production_roster_leave_revision() from public, anon, authenticated;

grant execute on function public.get_production_roster_operational_settings(date, date) to authenticated;
grant execute on function public.save_production_roster_target(text, numeric) to authenticated;
grant execute on function public.save_production_roster_bank_holiday(date, text) to authenticated;
grant execute on function public.remove_production_roster_bank_holiday(date) to authenticated;
grant execute on function public.search_production_roster_staff_leave_history(text, integer) to authenticated;
grant execute on function public.get_production_roster_leave_revision() to authenticated;

comment on table public.production_targets is
  'Extensible operational targets. Client access is controlled through role-checked RPCs.';
comment on table public.production_roster_work_profiles is
  'Confirmed net working-hour profiles used by Production Roster capacity planning.';
comment on table public.production_roster_calendar_exceptions is
  'Governed production calendar exceptions such as Monday Bank Holidays that use the Saturday work profile.';
comment on function public.search_production_roster_staff_leave_history(text, integer) is
  'Manager-only staff-name search across current and historical Holiday / Day Off requests.';
comment on function public.get_production_roster_leave_revision() is
  'Manager-only lightweight change token used for safe near-real-time leave refresh without exposing private tables.';

commit;
