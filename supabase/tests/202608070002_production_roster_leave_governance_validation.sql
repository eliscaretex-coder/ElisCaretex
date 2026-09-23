-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608070002_production_roster_leave_governance_validation_v2.sql
--
-- Validates planning-aware leave management, configurable >20-day General
-- Manager routing, secure GM decision, event history, expiry, and the rule
-- that published Production Roster entries are never mutated. All writes
-- are rolled back.
-- V2 fix: validates expiry through the protected dashboard RPC; it never
-- grants or depends on direct authenticated SELECT access to private leave tables.
-- =====================================================================

begin;

select set_config(
  'eliscaretex_validation.published_fingerprint_before',
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
  'eliscaretex_validation.staff_id',
  candidate.staff_id::text,
  true
)
from (
  select sm.staff_id
  from public.staff_members sm
  where sm.production_staff = true
    and sm.active = true
    and sm.deleted_at is null
  order by sm.created_at
  limit 1
) candidate;

select set_config(
  'eliscaretex_validation.long_start',
  candidate.start_date::text,
  true
)
from (
  select public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + (series.week_offset * 7) + 1 as start_date
  from generate_series(12, 80) as series(week_offset)
  where not exists (
    select 1
    from public.production_roster_leave_requests prlr
    where prlr.staff_id = current_setting('eliscaretex_validation.staff_id')::uuid
      and prlr.status in ('PENDING', 'APPROVED')
      and daterange(prlr.start_date, prlr.end_date, '[]') && daterange(
        public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + (series.week_offset * 7) + 1,
        public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + (series.week_offset * 7) + 21,
        '[]'
      )
  )
  order by series.week_offset
  limit 1
) candidate;

select set_config(
  'eliscaretex_validation.portal_token',
  replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.staff_id', true), '') is null then
    raise exception 'No active production staff member was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.long_start', true), '') is null then
    raise exception 'No safe future 21-day Holiday range was found.';
  end if;
end;
$$;

insert into public.production_roster_staff_portal_links (
  scope_code, token_value, token_hash, token_hint, active
) values (
  'STAFF_PORTAL',
  current_setting('eliscaretex_validation.portal_token'),
  public.production_roster_staff_portal_token_hash(current_setting('eliscaretex_validation.portal_token')),
  'TEST…LINK',
  true
)
on conflict (scope_code) do update
set token_value = excluded.token_value,
    token_hash = excluded.token_hash,
    token_hint = excluded.token_hint,
    active = true;

set local role authenticated;

select set_config(
  'eliscaretex_validation.settings',
  public.save_production_roster_leave_governance_settings(20, 'general.manager@example.com', 168)::text,
  true
);

reset role;
set local role anon;

select set_config(
  'eliscaretex_validation.submission',
  public.submit_production_roster_leave_request(
    current_setting('eliscaretex_validation.portal_token'),
    current_setting('eliscaretex_validation.staff_id')::uuid,
    'HOLIDAY',
    current_setting('eliscaretex_validation.long_start')::date,
    current_setting('eliscaretex_validation.long_start')::date + 20,
    'Long Holiday governance validation'
  )::text,
  true
);

reset role;
set local role authenticated;

select set_config(
  'eliscaretex_validation.dashboard',
  public.get_production_roster_leave_dashboard(
    public.production_roster_week_start(current_setting('eliscaretex_validation.long_start')::date),
    null,
    'ALL'
  )::text,
  true
);

do $$
begin
  perform public.decide_production_roster_leave_request(
    (current_setting('eliscaretex_validation.submission')::jsonb ->> 'leave_request_id')::uuid,
    'APPROVED',
    'This direct approval must be blocked'
  );
  raise exception 'Direct manager approval unexpectedly succeeded for a GM-required Holiday.';
exception
  when sqlstate '55000' then
    perform set_config('eliscaretex_validation.direct_manager_blocked', 'true', true);
end;
$$;

select set_config(
  'eliscaretex_validation.gm_prepared',
  public.prepare_production_roster_gm_review(
    (current_setting('eliscaretex_validation.submission')::jsonb ->> 'leave_request_id')::uuid
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.gm_marked',
  public.mark_production_roster_gm_email_result(
    (current_setting('eliscaretex_validation.submission')::jsonb ->> 'leave_request_id')::uuid,
    true,
    null
  )::text,
  true
);

reset role;
set local role anon;

select set_config(
  'eliscaretex_validation.gm_review',
  public.get_production_roster_gm_review(
    current_setting('eliscaretex_validation.gm_prepared')::jsonb ->> 'review_token'
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.gm_decision',
  public.decide_production_roster_gm_review(
    current_setting('eliscaretex_validation.gm_prepared')::jsonb ->> 'review_token',
    'APPROVED',
    'General Manager validation approval'
  )::text,
  true
);

reset role;
set local role authenticated;

select set_config(
  'eliscaretex_validation.history',
  public.get_production_roster_leave_request_history(
    (current_setting('eliscaretex_validation.submission')::jsonb ->> 'leave_request_id')::uuid
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.overlay',
  public.get_production_roster_approved_leave(
    public.production_roster_week_start(current_setting('eliscaretex_validation.long_start')::date),
    'MORNING'
  )::text,
  true
);

reset role;
do $$
begin
  update public.production_roster_leave_request_events
  set note = 'This update must be blocked'
  where leave_event_id = (
    select e.leave_event_id
    from public.production_roster_leave_request_events e
    where e.leave_request_id = (current_setting('eliscaretex_validation.submission')::jsonb ->> 'leave_request_id')::uuid
    order by e.occurred_at
    limit 1
  );
  raise exception 'Leave request event history unexpectedly allowed an update.';
exception
  when sqlstate '55000' then
    perform set_config('eliscaretex_validation.event_history_immutable', 'true', true);
end;
$$;

-- Insert one missed Pending request directly so expiry can be validated without
-- weakening the public submission rule that only permits future requests.
reset role;
with inserted as (
  insert into public.production_roster_leave_requests (
    staff_id, staff_display_name_snapshot, request_type, start_date, end_date,
    reason, status, source_application, requires_general_manager, gm_threshold_days_snapshot
  )
  select
    sm.staff_id, sm.display_name, 'DAY_OFF',
    (now() at time zone 'Europe/Dublin')::date - 2,
    (now() at time zone 'Europe/Dublin')::date - 2,
    'Expiry validation', 'PENDING', 'VALIDATION', false, 20
  from public.staff_members sm
  where sm.staff_id = current_setting('eliscaretex_validation.staff_id')::uuid
  returning leave_request_id
)
select set_config(
  'eliscaretex_validation.expiry_request_id',
  (select leave_request_id::text from inserted),
  true
);

set local role authenticated;
select set_config(
  'eliscaretex_validation.expired_count',
  public.expire_stale_production_roster_leave_requests()::text,
  true
);

select set_config(
  'eliscaretex_validation.expiry_history',
  public.get_production_roster_leave_dashboard(
    public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date),
    null,
    'HISTORY'
  )::text,
  true
);

reset role;

do $$
declare
  v_settings jsonb := current_setting('eliscaretex_validation.settings')::jsonb;
  v_submission jsonb := current_setting('eliscaretex_validation.submission')::jsonb;
  v_dashboard jsonb := current_setting('eliscaretex_validation.dashboard')::jsonb;
  v_gm_prepared jsonb := current_setting('eliscaretex_validation.gm_prepared')::jsonb;
  v_gm_marked jsonb := current_setting('eliscaretex_validation.gm_marked')::jsonb;
  v_gm_review jsonb := current_setting('eliscaretex_validation.gm_review')::jsonb;
  v_gm_decision jsonb := current_setting('eliscaretex_validation.gm_decision')::jsonb;
  v_history jsonb := current_setting('eliscaretex_validation.history')::jsonb;
  v_overlay jsonb := current_setting('eliscaretex_validation.overlay')::jsonb;
  v_request_id uuid := (current_setting('eliscaretex_validation.submission')::jsonb ->> 'leave_request_id')::uuid;
  v_fingerprint_after text;
begin
  if (v_settings ->> 'general_manager_threshold_days')::integer <> 20 then
    raise exception 'Configurable General Manager threshold was not saved as 20 days.';
  end if;

  if (v_submission ->> 'status') <> 'PENDING'
     or coalesce((v_submission ->> 'requires_general_manager')::boolean, false) <> true
     or (v_submission ->> 'duration_days')::integer <> 21 then
    raise exception 'A 21-day Holiday was not routed to General Manager governance.';
  end if;

  if current_setting('eliscaretex_validation.direct_manager_blocked', true) <> 'true' then
    raise exception 'Direct manager approval was not blocked for the GM-required Holiday.';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(coalesce(v_dashboard -> 'requests', '[]'::jsonb)) item
    where item ->> 'leave_request_id' = v_request_id::text
      and coalesce((item ->> 'requires_general_manager')::boolean, false) = true
  ) then
    raise exception 'The planning-aware dashboard did not return the long Holiday request.';
  end if;

  if nullif(v_gm_prepared ->> 'review_token', '') is null
     or v_gm_prepared ->> 'sent_to' <> 'general.manager@example.com' then
    raise exception 'General Manager secure review preparation failed.';
  end if;

  if v_gm_marked ->> 'gm_state' <> 'AWAITING_GM' then
    raise exception 'General Manager email workflow did not reach AWAITING_GM.';
  end if;

  if v_gm_review ->> 'status' <> 'PENDING'
     or coalesce((v_gm_review ->> 'duration_days')::integer, 0) <> 21 then
    raise exception 'The anonymous General Manager review payload is invalid.';
  end if;

  if v_gm_decision ->> 'status' <> 'APPROVED' then
    raise exception 'General Manager approval did not become the final leave decision.';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_history) item
    where item ->> 'event_type' = 'SUBMITTED'
  ) or not exists (
    select 1 from jsonb_array_elements(v_history) item
    where item ->> 'event_type' = 'FORWARDED_TO_GM'
  ) or not exists (
    select 1 from jsonb_array_elements(v_history) item
    where item ->> 'event_type' = 'GENERAL_MANAGER_DECISION'
      and item ->> 'to_status' = 'APPROVED'
  ) then
    raise exception 'Leave request event history is incomplete.';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_overlay) item
    where item ->> 'leave_request_id' = v_request_id::text
  ) then
    raise exception 'The approved General Manager Holiday is missing from the planner overlay.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(
      coalesce(
        current_setting('eliscaretex_validation.expiry_history', true)::jsonb -> 'requests',
        '[]'::jsonb
      )
    ) item
    where item ->> 'leave_request_id' = current_setting('eliscaretex_validation.expiry_request_id')
      and item ->> 'status' = 'EXPIRED'
  ) then
    raise exception 'A forgotten past Pending request was not closed as EXPIRED.';
  end if;

  if current_setting('eliscaretex_validation.event_history_immutable', true) <> 'true' then
    raise exception 'Leave request event history was not immutable.';
  end if;

  select coalesce(md5(string_agg(to_jsonb(pre)::text, '|' order by pre.roster_entry_id)), md5(''))
  into v_fingerprint_after
  from public.production_roster_entries pre
  join public.production_roster_versions prv on prv.roster_version_id = pre.roster_version_id
  where prv.status in ('PUBLISHED', 'SUPERSEDED');

  if v_fingerprint_after <> current_setting('eliscaretex_validation.published_fingerprint_before') then
    raise exception 'Published Production Roster entries changed during leave-governance validation.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608070002_production_roster_leave_governance_validation',
  'planning_aware_queue', true,
  'forgotten_pending_requests_expire', true,
  'general_manager_threshold_days', 20,
  'greater_than_threshold_requires_gm', true,
  'direct_manager_approval_blocked_for_long_holiday', true,
  'secure_gm_token_review', true,
  'request_event_history', true,
  'event_history_immutable', true,
  'approved_overlay_preserved', true,
  'published_entries_unchanged', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
