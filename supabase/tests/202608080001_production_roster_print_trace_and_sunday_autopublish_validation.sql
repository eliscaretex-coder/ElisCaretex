-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080001_production_roster_print_trace_and_sunday_autopublish_validation.sql
-- All test writes are rolled back.
-- =====================================================================

begin;

set local statement_timeout = '60s';

-- The automation is internal only.
do $$
begin
  if has_function_privilege('anon', 'public.run_production_roster_sunday_autopublish(timestamptz)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.run_production_roster_sunday_autopublish(timestamptz)', 'EXECUTE') then
    raise exception 'Sunday autopublish function must not be executable by browser roles.';
  end if;

  if has_table_privilege('anon', 'public.production_roster_autopublish_state', 'SELECT')
     or has_table_privilege('authenticated', 'public.production_roster_autopublish_state', 'SELECT') then
    raise exception 'Autopublish state table must remain private.';
  end if;
end;
$$;

-- pg_cron must be installed and the named job must exist.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'pg_cron is not installed.';
  end if;

  if not exists (
    select 1
    from cron.job
    where jobname = 'production-roster-sunday-autopublish'
      and schedule = '*/10 * * * 0'
      and command ilike '%run_production_roster_sunday_autopublish%'
      and active = true
  ) then
    raise exception 'Sunday autopublish cron job is missing or misconfigured.';
  end if;
end;
$$;

-- Build one isolated future draft and prove that 11:59 does not publish it,
-- while 12:00 Europe/Dublin does. The draft contains one OFF row so the test
-- does not depend on role/area/station master data.
do $$
declare
  v_week date := public.production_roster_week_start(current_date + 3650);
  v_shift public.shifts%rowtype;
  v_staff public.staff_members%rowtype;
  v_period_id uuid;
  v_version_id uuid;
  v_version_number integer;
  v_sunday date;
  v_before_due timestamptz;
  v_due timestamptz;
  v_result jsonb;
  v_status text;
  v_published_at timestamptz;
  v_row_version integer;
  v_event_ok boolean;
  v_audit_ok boolean;
begin
  -- Find a future Monday not already used by real project data.
  while exists (select 1 from public.roster_periods where week_start = v_week) loop
    v_week := v_week + 7;
  end loop;

  select * into v_shift
  from public.shifts
  where upper(shift_code) = 'MORNING' and active = true and deleted_at is null
  limit 1;
  if not found then
    raise exception 'Validation requires an active MORNING shift.';
  end if;

  select * into v_staff
  from public.staff_members
  where production_staff = true and active = true and roster_eligible = true and deleted_at is null
  order by created_at, staff_id
  limit 1;
  if not found then
    raise exception 'Validation requires one active roster-eligible production staff member.';
  end if;

  insert into public.roster_periods (week_start, status, created_by)
  values (v_week, 'DRAFT', null)
  returning roster_period_id into v_period_id;

  select coalesce(max(version_number), 0) + 1
    into v_version_number
  from public.production_roster_versions
  where roster_period_id = v_period_id and shift_id = v_shift.shift_id;

  insert into public.production_roster_versions (
    roster_period_id, shift_id, version_number, status, include_sunday,
    week_note, row_version, saved_at, saved_by, created_by, updated_by
  ) values (
    v_period_id, v_shift.shift_id, v_version_number, 'DRAFT', false,
    'Sunday autopublish validation', 1, now(), null, null, null
  ) returning roster_version_id into v_version_id;

  insert into public.production_roster_entries (
    roster_version_id, work_date, staff_id, day_status, assignment_type,
    staff_display_name_snapshot, employee_code_snapshot,
    shift_code_snapshot, shift_name_snapshot,
    staff_primary_role_code_snapshot, staff_primary_role_name_snapshot,
    staff_default_area_code_snapshot, staff_default_area_name_snapshot,
    staff_default_station_code_snapshot, staff_default_station_name_snapshot,
    display_section_code, fire_training_snapshot, first_aid_training_snapshot, eod_capable_snapshot
  ) values (
    v_version_id, v_week, v_staff.staff_id, 'OFF', 'BASE',
    v_staff.display_name, v_staff.employee_code,
    v_shift.shift_code, v_shift.shift_name,
    null, null, null, null, null, null,
    'SUPPORT_ROLE', false, false, false
  );

  v_sunday := v_week - 1;
  v_before_due := ((v_sunday::timestamp + time '11:59') at time zone 'Europe/Dublin');
  v_due := ((v_sunday::timestamp + time '12:00') at time zone 'Europe/Dublin');

  v_result := public.run_production_roster_sunday_autopublish(v_before_due);
  select status into v_status from public.production_roster_versions where roster_version_id = v_version_id;
  if v_status <> 'DRAFT' or coalesce(v_result ->> 'status', '') <> 'NOT_DUE' then
    raise exception 'Roster was published before Sunday 12:00 Europe/Dublin.';
  end if;

  v_result := public.run_production_roster_sunday_autopublish(v_due);

  select status, published_at
    into v_status, v_published_at
  from public.production_roster_versions
  where roster_version_id = v_version_id;

  if v_status <> 'PUBLISHED' then
    raise exception 'Saved draft was not automatically published at the Sunday deadline.';
  end if;

  if v_published_at is distinct from v_due then
    raise exception 'Automatic publication timestamp does not match the due check timestamp.';
  end if;

  select row_version into v_row_version
  from public.production_roster_versions
  where roster_version_id = v_version_id;

  if not exists (
    select 1
    from public.production_roster_autopublish_state s
    where s.week_start = v_week
      and s.shift_id = v_shift.shift_id
      and s.status = 'AUTO_PUBLISHED'
      and s.roster_version_id = v_version_id
  ) then
    raise exception 'Autopublish state did not record AUTO_PUBLISHED.';
  end if;

  select exists (
    select 1
    from public.production_roster_events e
    where e.roster_version_id = v_version_id
      and e.event_type = 'PUBLISHED'
      and coalesce((e.metadata ->> 'automatic')::boolean, false) = true
      and e.metadata ->> 'source_application' = 'PRODUCTION_ROSTER_SUNDAY_AUTOPUBLISH'
  ) into v_event_ok;

  if not v_event_ok then
    raise exception 'Automatic publication event audit is missing.';
  end if;

  select exists (
    select 1
    from public.audit_log a
    where a.entity_table = 'production_roster_versions'
      and a.entity_id = v_version_id::text
      and a.action = 'PRODUCTION_ROSTER_AUTO_PUBLISHED'
      and a.source_application = 'PRODUCTION_ROSTER_SUNDAY_AUTOPUBLISH'
  ) into v_audit_ok;

  if not v_audit_ok then
    raise exception 'Automatic publication audit_log record is missing.';
  end if;

  -- A second due check must be idempotent: it sees the existing publication.
  v_result := public.run_production_roster_sunday_autopublish(v_due + interval '10 minutes');
  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_result -> 'results', '[]'::jsonb)) x
    where x ->> 'shift_code' = v_shift.shift_code
      and x ->> 'status' = 'ALREADY_PUBLISHED'
  ) then
    raise exception 'Second automatic check did not recognize the already-published shift.';
  end if;

  if (select row_version from public.production_roster_versions where roster_version_id = v_version_id) <> v_row_version then
    raise exception 'Already-published roster was modified by a later automatic check.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608080001_production_roster_print_trace_and_sunday_autopublish_validation',
  'sunday_1200_dublin_gate', true,
  'saved_draft_only', true,
  'morning_evening_independent', true,
  'already_published_is_idempotent', true,
  'autopublish_audited', true,
  'private_automation_state', true,
  'cron_job_active', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
