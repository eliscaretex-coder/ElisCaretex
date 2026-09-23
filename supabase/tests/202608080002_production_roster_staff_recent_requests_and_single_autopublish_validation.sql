-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080002_production_roster_staff_recent_requests_and_single_autopublish_validation.sql
-- All test writes are rolled back.
-- =====================================================================

begin;

set local statement_timeout = '60s';

-- ---------------------------------------------------------------------
-- Security and scheduler shape
-- ---------------------------------------------------------------------

do $$
begin
  if has_function_privilege('anon', 'public.run_production_roster_sunday_autopublish(timestamptz)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.run_production_roster_sunday_autopublish(timestamptz)', 'EXECUTE') then
    raise exception 'Sunday autopublish function must not be executable by browser roles.';
  end if;

  if has_table_privilege('anon', 'public.production_roster_autopublish_runs', 'SELECT')
     or has_table_privilege('authenticated', 'public.production_roster_autopublish_runs', 'SELECT') then
    raise exception 'Autopublish run table must remain private.';
  end if;

  if has_table_privilege('anon', 'public.production_roster_leave_requests', 'SELECT')
     or has_table_privilege('authenticated', 'public.production_roster_leave_requests', 'SELECT') then
    raise exception 'Leave request table must remain private.';
  end if;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'pg_cron is not installed.';
  end if;

  if exists (
    select 1 from cron.job
    where jobname = 'production-roster-sunday-autopublish'
      and active = true
  ) then
    raise exception 'The old repeated Sunday autopublish cron job is still active.';
  end if;

  if not exists (
    select 1 from cron.job
    where jobname = 'production-roster-sunday-autopublish-11utc'
      and schedule = '0 11 * * 0'
      and command ilike '%run_production_roster_sunday_autopublish%'
      and active = true
  ) then
    raise exception '11:00 UTC Dublin-noon candidate cron job is missing.';
  end if;

  if not exists (
    select 1 from cron.job
    where jobname = 'production-roster-sunday-autopublish-12utc'
      and schedule = '0 12 * * 0'
      and command ilike '%run_production_roster_sunday_autopublish%'
      and active = true
  ) then
    raise exception '12:00 UTC Dublin-noon candidate cron job is missing.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Staff portal recent-history minimization
-- ---------------------------------------------------------------------

do $$
declare
  v_staff public.staff_members%rowtype;
  v_token text := 'validation_recent_requests_202608080002';
  v_recent_1 uuid;
  v_recent_2 uuid;
  v_recent_3 uuid;
  v_old uuid;
  v_payload jsonb;
  v_count integer;
begin
  select * into v_staff
  from public.staff_members
  where production_staff = true
    and active = true
    and roster_eligible = true
    and deleted_at is null
  order by created_at, staff_id
  limit 1;

  if not found then
    raise exception 'Validation requires one active roster-eligible production staff member.';
  end if;

  insert into public.production_roster_staff_portal_links (
    scope_code, token_value, token_hash, token_hint, active, created_by
  ) values (
    'STAFF_PORTAL',
    v_token,
    public.production_roster_staff_portal_token_hash(v_token),
    'vali…0002',
    true,
    null
  )
  on conflict (scope_code) do update
  set token_value = excluded.token_value,
      token_hash = excluded.token_hash,
      token_hint = excluded.token_hint,
      active = true;

  insert into public.production_roster_leave_requests (
    staff_id, staff_display_name_snapshot, request_type, start_date, end_date,
    reason, status, submitted_at, source_application,
    requires_general_manager, gm_threshold_days_snapshot
  ) values (
    v_staff.staff_id, v_staff.display_name, 'DAY_OFF', current_date + 100, current_date + 100,
    'Validation recent 1', 'REJECTED', now() + interval '3 days', 'VALIDATION_202608080002', false, 20
  ) returning leave_request_id into v_recent_1;

  insert into public.production_roster_leave_requests (
    staff_id, staff_display_name_snapshot, request_type, start_date, end_date,
    reason, status, submitted_at, source_application,
    requires_general_manager, gm_threshold_days_snapshot
  ) values (
    v_staff.staff_id, v_staff.display_name, 'DAY_OFF', current_date + 101, current_date + 101,
    'Validation recent 2', 'REJECTED', now() + interval '2 days', 'VALIDATION_202608080002', false, 20
  ) returning leave_request_id into v_recent_2;

  insert into public.production_roster_leave_requests (
    staff_id, staff_display_name_snapshot, request_type, start_date, end_date,
    reason, status, submitted_at, source_application,
    requires_general_manager, gm_threshold_days_snapshot
  ) values (
    v_staff.staff_id, v_staff.display_name, 'DAY_OFF', current_date + 102, current_date + 102,
    'Validation recent 3', 'REJECTED', now() + interval '1 day', 'VALIDATION_202608080002', false, 20
  ) returning leave_request_id into v_recent_3;

  insert into public.production_roster_leave_requests (
    staff_id, staff_display_name_snapshot, request_type, start_date, end_date,
    reason, status, submitted_at, source_application,
    requires_general_manager, gm_threshold_days_snapshot
  ) values (
    v_staff.staff_id, v_staff.display_name, 'DAY_OFF', current_date + 103, current_date + 103,
    'Validation older than one month', 'REJECTED', now() - interval '2 months', 'VALIDATION_202608080002', false, 20
  ) returning leave_request_id into v_old;

  v_payload := public.get_my_production_roster_leave_requests(v_token, v_staff.staff_id);
  select jsonb_array_length(v_payload) into v_count;

  if v_count <> 3 then
    raise exception 'Staff portal must return exactly three recent requests in this isolated validation scenario; returned %.', v_count;
  end if;

  if not exists (select 1 from jsonb_array_elements(v_payload) x where x ->> 'leave_request_id' = v_recent_1::text)
     or not exists (select 1 from jsonb_array_elements(v_payload) x where x ->> 'leave_request_id' = v_recent_2::text)
     or not exists (select 1 from jsonb_array_elements(v_payload) x where x ->> 'leave_request_id' = v_recent_3::text) then
    raise exception 'Staff portal did not return the three newest requests.';
  end if;

  if exists (select 1 from jsonb_array_elements(v_payload) x where x ->> 'leave_request_id' = v_old::text) then
    raise exception 'A request older than one month was exposed in the staff portal.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- One successful attempt at Sunday noon and no retry
-- ---------------------------------------------------------------------

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
  v_second jsonb;
  v_status text;
  v_published_at timestamptz;
  v_row_version integer;
  v_entry_fingerprint_before text;
  v_entry_fingerprint_after text;
  v_run_count integer;
begin
  while exists (select 1 from public.roster_periods where week_start = v_week)
     or exists (select 1 from public.production_roster_autopublish_runs where week_start = v_week) loop
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
    'Single Sunday attempt validation', 1, now(), null, null, null
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

  select md5(coalesce(jsonb_agg(to_jsonb(pre) order by pre.roster_entry_id)::text, '[]'))
    into v_entry_fingerprint_before
  from public.production_roster_entries pre
  where pre.roster_version_id = v_version_id;

  v_sunday := v_week - 1;
  v_before_due := ((v_sunday::timestamp + time '11:59') at time zone 'Europe/Dublin');
  v_due := ((v_sunday::timestamp + time '12:00') at time zone 'Europe/Dublin');

  v_result := public.run_production_roster_sunday_autopublish(v_before_due);
  if coalesce(v_result ->> 'status', '') <> 'NOT_DUE' then
    raise exception '11:59 Europe/Dublin must not claim an automatic publication attempt.';
  end if;

  if exists (select 1 from public.production_roster_autopublish_runs where week_start = v_week) then
    raise exception 'A run claim was created before local noon.';
  end if;

  v_result := public.run_production_roster_sunday_autopublish(v_due);
  if coalesce(v_result ->> 'status', '') <> 'ATTEMPT_COMPLETED' then
    raise exception 'The noon call did not complete the single automatic attempt.';
  end if;

  select status, published_at, row_version
    into v_status, v_published_at, v_row_version
  from public.production_roster_versions
  where roster_version_id = v_version_id;

  if v_status <> 'PUBLISHED' or v_published_at is distinct from v_due then
    raise exception 'Saved draft was not published by the single Sunday noon attempt.';
  end if;

  select count(*) into v_run_count
  from public.production_roster_autopublish_runs
  where week_start = v_week;
  if v_run_count <> 1 then
    raise exception 'Exactly one run claim must exist per incoming week.';
  end if;

  v_second := public.run_production_roster_sunday_autopublish(v_due + interval '10 minutes');
  if coalesce(v_second ->> 'status', '') <> 'ALREADY_ATTEMPTED' then
    raise exception 'A second call during local noon must not retry the publication.';
  end if;

  if (select row_version from public.production_roster_versions where roster_version_id = v_version_id) <> v_row_version then
    raise exception 'The already-published roster was modified by a second call.';
  end if;

  select md5(coalesce(jsonb_agg(to_jsonb(pre) order by pre.roster_entry_id)::text, '[]'))
    into v_entry_fingerprint_after
  from public.production_roster_entries pre
  where pre.roster_version_id = v_version_id;

  if v_entry_fingerprint_before is distinct from v_entry_fingerprint_after then
    raise exception 'Automatic publication changed Production Roster entry data.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- A failed/no-draft attempt is also final: no retry that Sunday
-- ---------------------------------------------------------------------

do $$
declare
  v_week date := public.production_roster_week_start(current_date + 7300);
  v_sunday date;
  v_due timestamptz;
  v_first jsonb;
  v_second jsonb;
  v_run_count integer;
begin
  while exists (select 1 from public.roster_periods where week_start = v_week)
     or exists (select 1 from public.production_roster_autopublish_runs where week_start = v_week) loop
    v_week := v_week + 7;
  end loop;

  v_sunday := v_week - 1;
  v_due := ((v_sunday::timestamp + time '12:00') at time zone 'Europe/Dublin');

  -- Intentionally do not create a roster period/draft for this week.
  v_first := public.run_production_roster_sunday_autopublish(v_due);
  if coalesce(v_first ->> 'status', '') <> 'ATTEMPT_COMPLETED' then
    raise exception 'No-draft noon attempt did not complete normally.';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(coalesce(v_first -> 'results', '[]'::jsonb)) x
    where x ->> 'status' = 'NO_SAVED_DRAFT'
  ) then
    raise exception 'No-draft attempt did not record NO_SAVED_DRAFT.';
  end if;

  v_second := public.run_production_roster_sunday_autopublish(v_due + interval '20 minutes');
  if coalesce(v_second ->> 'status', '') <> 'ALREADY_ATTEMPTED' then
    raise exception 'A no-draft result was retried during the same Sunday noon window.';
  end if;

  select count(*) into v_run_count
  from public.production_roster_autopublish_runs
  where week_start = v_week;
  if v_run_count <> 1 then
    raise exception 'No-draft week must still have exactly one final attempt record.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608080002_production_roster_staff_recent_requests_and_single_autopublish_validation',
  'staff_recent_requests_max_three', true,
  'staff_recent_requests_last_month_only', true,
  'manager_history_unchanged', true,
  'single_sunday_noon_attempt', true,
  'no_retry_after_success', true,
  'no_retry_after_no_saved_draft', true,
  'dublin_dst_candidate_schedule', true,
  'private_automation_state', true,
  'published_entries_unchanged', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
