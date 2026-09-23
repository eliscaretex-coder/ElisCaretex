-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608070003_production_roster_capacity_and_staff_history_validation.sql
--
-- Validates:
--   - Finish capacity target is present, positive and controlled;
--   - confirmed Morning / Evening net work profiles;
--   - Monday Bank Holiday -> Saturday-profile configuration;
--   - controlled target/calendar changes and audit;
--   - staff-specific leave history search;
--   - private-table access remains denied to authenticated clients;
--   - published/superseded Production Roster entries remain unchanged.
--
-- All writes are rolled back.
-- =====================================================================

begin;

select set_config(
  'eliscaretex.validation.published_before',
  coalesce((
    select md5(string_agg(to_jsonb(pre)::text, '|' order by pre.roster_entry_id))
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id = pre.roster_version_id
    where prv.status in ('PUBLISHED', 'SUPERSEDED')
  ), md5('')),
  true
);

select set_config(
  'request.jwt.claim.sub',
  admin_user.auth_user_id::text,
  true
)
from (
  select sm.auth_user_id
  from public.staff_members sm
  join public.staff_roles sr
    on sr.staff_id = sm.staff_id
   and sr.active = true
   and sr.effective_from <= current_date
   and (sr.effective_until is null or sr.effective_until >= current_date)
  join public.roles r
    on r.role_id = sr.role_id
   and r.active = true
   and r.role_code = 'ADMIN'
  where sm.active = true
    and sm.deleted_at is null
    and sm.auth_user_id is not null
  order by sm.created_at
  limit 1
) admin_user;

select set_config(
  'eliscaretex.validation.staff_id',
  candidate.staff_id::text,
  true
), set_config(
  'eliscaretex.validation.staff_name',
  candidate.display_name,
  true
)
from (
  select sm.staff_id, sm.display_name
  from public.staff_members sm
  where sm.production_staff = true
    and sm.active = true
    and sm.deleted_at is null
  order by sm.created_at
  limit 1
) candidate;

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex.validation.staff_id', true), '') is null then
    raise exception 'No active production staff member was found.';
  end if;
end;
$$;

-- Owner-side fixture for staff-history search. It is rolled back.
insert into public.production_roster_leave_requests (
  staff_id,
  staff_display_name_snapshot,
  request_type,
  start_date,
  end_date,
  reason,
  status,
  reviewed_at,
  review_note,
  source_application,
  requires_general_manager,
  gm_threshold_days_snapshot,
  decision_source,
  decision_actor
) values (
  current_setting('eliscaretex.validation.staff_id')::uuid,
  current_setting('eliscaretex.validation.staff_name'),
  'DAY_OFF',
  public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 84,
  public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 84,
  'Snapshot 35 staff history validation',
  'REJECTED',
  now(),
  'Validation decision',
  'PRODUCTION_ROSTER',
  false,
  20,
  'MANAGER',
  'Validation Admin'
);

select set_config(
  'eliscaretex.validation.test_leave_id',
  prlr.leave_request_id::text,
  true
)
from public.production_roster_leave_requests prlr
where prlr.staff_id = current_setting('eliscaretex.validation.staff_id')::uuid
  and prlr.reason = 'Snapshot 35 staff history validation'
order by prlr.submitted_at desc
limit 1;

select set_config(
  'eliscaretex.validation.bank_holiday',
  (public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 70)::text,
  true
);

set local role authenticated;

-- Private tables must remain private.
do $$
begin
  begin
    perform count(*) from public.production_targets;
    raise exception 'authenticated unexpectedly has direct SELECT on production_targets';
  exception when insufficient_privilege then
    perform set_config('eliscaretex.validation.targets_private', 'true', true);
  end;

  begin
    perform count(*) from public.production_roster_work_profiles;
    raise exception 'authenticated unexpectedly has direct SELECT on production_roster_work_profiles';
  exception when insufficient_privilege then
    perform set_config('eliscaretex.validation.work_profiles_private', 'true', true);
  end;

  begin
    perform count(*) from public.production_roster_calendar_exceptions;
    raise exception 'authenticated unexpectedly has direct SELECT on production_roster_calendar_exceptions';
  exception when insufficient_privilege then
    perform set_config('eliscaretex.validation.calendar_private', 'true', true);
  end;
end;
$$;

select set_config(
  'eliscaretex.validation.settings_before',
  public.get_production_roster_operational_settings(
    current_setting('eliscaretex.validation.bank_holiday')::date - 7,
    current_setting('eliscaretex.validation.bank_holiday')::date + 7
  )::text,
  true
);

select set_config(
  'eliscaretex.validation.target_update',
  public.save_production_roster_target('FINISH_TABLE_KG_PER_STAFF_HOUR', 24.250)::text,
  true
);

select set_config(
  'eliscaretex.validation.bank_saved',
  public.save_production_roster_bank_holiday(
    current_setting('eliscaretex.validation.bank_holiday')::date,
    'Validation Bank Holiday'
  )::text,
  true
);

select set_config(
  'eliscaretex.validation.settings_after',
  public.get_production_roster_operational_settings(
    current_setting('eliscaretex.validation.bank_holiday')::date - 7,
    current_setting('eliscaretex.validation.bank_holiday')::date + 7
  )::text,
  true
);

select set_config(
  'eliscaretex.validation.staff_history',
  public.search_production_roster_staff_leave_history(
    current_setting('eliscaretex.validation.staff_name'),
    200
  )::text,
  true
);

select set_config(
  'eliscaretex.validation.leave_revision',
  public.get_production_roster_leave_revision(),
  true
);

reset role;

do $$
declare
  before_settings jsonb := current_setting('eliscaretex.validation.settings_before')::jsonb;
  after_settings jsonb := current_setting('eliscaretex.validation.settings_after')::jsonb;
  history jsonb := current_setting('eliscaretex.validation.staff_history')::jsonb;
  target_before numeric;
  morning_mon_wed integer;
  morning_thu_fri integer;
  evening_mon_wed integer;
  evening_thu_fri integer;
  evening_sat integer;
  bank_found boolean;
  history_found boolean;
  audit_target boolean;
  audit_bank boolean;
  published_after text;
begin
  select (item ->> 'target_value')::numeric into target_before
  from jsonb_array_elements(before_settings -> 'targets') item
  where item ->> 'target_code' = 'FINISH_TABLE_KG_PER_STAFF_HOUR';

  if target_before is null or target_before <= 0 then
    raise exception 'Finish Table kg/staff-hour target is missing or invalid: %.', target_before;
  end if;

  select (item ->> 'net_minutes')::integer into morning_mon_wed
  from jsonb_array_elements(before_settings -> 'work_profiles') item
  where item ->> 'profile_code' = 'MORNING_MON_WED';
  select (item ->> 'net_minutes')::integer into morning_thu_fri
  from jsonb_array_elements(before_settings -> 'work_profiles') item
  where item ->> 'profile_code' = 'MORNING_THU_FRI';
  select (item ->> 'net_minutes')::integer into evening_mon_wed
  from jsonb_array_elements(before_settings -> 'work_profiles') item
  where item ->> 'profile_code' = 'EVENING_MON_WED';
  select (item ->> 'net_minutes')::integer into evening_thu_fri
  from jsonb_array_elements(before_settings -> 'work_profiles') item
  where item ->> 'profile_code' = 'EVENING_THU_FRI';
  select (item ->> 'net_minutes')::integer into evening_sat
  from jsonb_array_elements(before_settings -> 'work_profiles') item
  where item ->> 'profile_code' = 'EVENING_SAT_BANK';

  if morning_mon_wed <> 495 or morning_thu_fri <> 435
     or evening_mon_wed <> 470 or evening_thu_fri <> 515 or evening_sat <> 420 then
    raise exception 'Confirmed working-hour net minutes do not match the expected schedule.';
  end if;

  if (current_setting('eliscaretex.validation.target_update')::jsonb ->> 'target_value')::numeric <> 24.250 then
    raise exception 'Target controlled update did not return the expected value.';
  end if;

  select exists (
    select 1 from jsonb_array_elements(after_settings -> 'bank_holidays') item
    where item ->> 'work_date' = current_setting('eliscaretex.validation.bank_holiday')
      and coalesce((item ->> 'use_saturday_profile')::boolean, false) = true
  ) into bank_found;
  if not bank_found then
    raise exception 'Saved Bank Holiday is not exposed through the controlled settings RPC.';
  end if;

  select exists (
    select 1 from jsonb_array_elements(history -> 'requests') item
    where item ->> 'leave_request_id' = current_setting('eliscaretex.validation.test_leave_id')
      and item ->> 'display_name' = current_setting('eliscaretex.validation.staff_name')
      and item ->> 'status' = 'REJECTED'
  ) into history_found;
  if not history_found then
    raise exception 'Staff-specific leave history did not return the validation request.';
  end if;

  select exists (
    select 1 from public.audit_log al
    where al.action = 'PRODUCTION_TARGET_UPDATED'
      and al.entity_id = 'FINISH_TABLE_KG_PER_STAFF_HOUR'
  ) into audit_target;
  select exists (
    select 1 from public.audit_log al
    where al.action = 'PRODUCTION_ROSTER_BANK_HOLIDAY_SAVED'
      and al.entity_id = current_setting('eliscaretex.validation.bank_holiday')
  ) into audit_bank;

  if not audit_target or not audit_bank then
    raise exception 'Configuration audit events were not recorded.';
  end if;

  if current_setting('eliscaretex.validation.targets_private') <> 'true'
     or current_setting('eliscaretex.validation.work_profiles_private') <> 'true'
     or current_setting('eliscaretex.validation.calendar_private') <> 'true' then
    raise exception 'One or more private configuration tables are directly readable by authenticated.';
  end if;

  if nullif(current_setting('eliscaretex.validation.leave_revision', true), '') is null then
    raise exception 'Leave revision RPC returned no token.';
  end if;

  select coalesce((
    select md5(string_agg(to_jsonb(pre)::text, '|' order by pre.roster_entry_id))
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id = pre.roster_version_id
    where prv.status in ('PUBLISHED', 'SUPERSEDED')
  ), md5('')) into published_after;

  if published_after <> current_setting('eliscaretex.validation.published_before') then
    raise exception 'Published/Superseded Production Roster entries changed during validation.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608070003_production_roster_capacity_and_staff_history_validation',
  'finish_target_configured', true,
  'confirmed_work_profiles', true,
  'bank_holiday_saturday_profile', true,
  'staff_leave_history_search', true,
  'leave_revision_polling', true,
  'private_configuration_tables', true,
  'configuration_audit', true,
  'published_entries_unchanged', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
