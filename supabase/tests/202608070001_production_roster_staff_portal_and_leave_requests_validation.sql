-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608070001_production_roster_staff_portal_and_leave_requests_validation.sql
--
-- Validates the fixed shared Morning/Evening staff portal and the governed
-- Holiday / Day Off request lifecycle. All writes roll back.
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
  'eliscaretex_validation.request_date',
  candidate.request_date::text,
  true
)
from (
  select public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + (series.week_offset * 7) + 2 as request_date
  from generate_series(10, 40) as series(week_offset)
  where not exists (
    select 1
    from public.production_roster_leave_requests prlr
    where prlr.staff_id = current_setting('eliscaretex_validation.staff_id')::uuid
      and prlr.status in ('PENDING', 'APPROVED')
      and public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + (series.week_offset * 7) + 2
          between prlr.start_date and prlr.end_date
  )
  order by series.week_offset
  limit 1
) candidate;

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.staff_id', true), '') is null then
    raise exception 'No active production staff member was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.request_date', true), '') is null then
    raise exception 'No safe future leave-request date was found.';
  end if;
end;
$$;

select set_config(
  'eliscaretex_validation.portal_token',
  replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  true
);

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

set local role anon;

select set_config(
  'eliscaretex_validation.portal_payload',
  public.get_published_production_roster_portal(current_setting('eliscaretex_validation.portal_token'))::text,
  true
);

select set_config(
  'eliscaretex_validation.submission',
  public.submit_production_roster_leave_request(
    current_setting('eliscaretex_validation.portal_token'),
    current_setting('eliscaretex_validation.staff_id')::uuid,
    'DAY_OFF',
    current_setting('eliscaretex_validation.request_date')::date,
    null,
    'Validation request'
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.my_requests',
  public.get_my_production_roster_leave_requests(
    current_setting('eliscaretex_validation.portal_token'),
    current_setting('eliscaretex_validation.staff_id')::uuid
  )::text,
  true
);

reset role;

set local role authenticated;

select set_config(
  'eliscaretex_validation.fixed_link_first',
  public.get_or_create_production_roster_staff_portal_link()::text,
  true
);

select set_config(
  'eliscaretex_validation.fixed_link_second',
  public.get_or_create_production_roster_staff_portal_link()::text,
  true
);

select set_config(
  'eliscaretex_validation.decision',
  public.decide_production_roster_leave_request(
    (current_setting('eliscaretex_validation.submission')::jsonb ->> 'leave_request_id')::uuid,
    'APPROVED',
    'Validation approval'
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.approved_overlay',
  public.get_production_roster_approved_leave(
    public.production_roster_week_start(current_setting('eliscaretex_validation.request_date')::date),
    'MORNING'
  )::text,
  true
);

reset role;

do $$
declare
  v_portal jsonb := current_setting('eliscaretex_validation.portal_payload')::jsonb;
  v_submission jsonb := current_setting('eliscaretex_validation.submission')::jsonb;
  v_my jsonb := current_setting('eliscaretex_validation.my_requests')::jsonb;
  v_first jsonb := current_setting('eliscaretex_validation.fixed_link_first')::jsonb;
  v_second jsonb := current_setting('eliscaretex_validation.fixed_link_second')::jsonb;
  v_decision jsonb := current_setting('eliscaretex_validation.decision')::jsonb;
  v_overlay jsonb := current_setting('eliscaretex_validation.approved_overlay')::jsonb;
  v_fingerprint_after text;
begin
  if jsonb_array_length(coalesce(v_portal -> 'shifts', '[]'::jsonb)) < 2 then
    raise exception 'The fixed portal did not expose both Morning and Evening shifts.';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_portal -> 'shifts') item
    where item ->> 'shift_code' = 'MORNING'
  ) or not exists (
    select 1 from jsonb_array_elements(v_portal -> 'shifts') item
    where item ->> 'shift_code' = 'EVENING'
  ) then
    raise exception 'Morning or Evening is missing from the fixed portal payload.';
  end if;

  if v_submission ->> 'status' <> 'PENDING' then
    raise exception 'Leave request was not created as PENDING.';
  end if;

  if jsonb_array_length(v_my) = 0 then
    raise exception 'The staff leave-request history did not return the submitted request.';
  end if;

  if v_first ->> 'token' <> v_second ->> 'token' then
    raise exception 'The manager staff link changed between reads; it is not fixed.';
  end if;

  if v_decision ->> 'status' <> 'APPROVED' then
    raise exception 'The manager approval lifecycle failed.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(v_overlay) item
    where item ->> 'leave_request_id' = v_submission ->> 'leave_request_id'
      and item ->> 'work_date' = current_setting('eliscaretex_validation.request_date')
  ) then
    raise exception 'Approved leave was not returned to the roster planning overlay.';
  end if;

  select coalesce(md5(string_agg(to_jsonb(pre)::text, '|' order by pre.roster_entry_id)), md5(''))
  into v_fingerprint_after
  from public.production_roster_entries pre
  join public.production_roster_versions prv on prv.roster_version_id = pre.roster_version_id
  where prv.status in ('PUBLISHED', 'SUPERSEDED');

  if v_fingerprint_after <> current_setting('eliscaretex_validation.published_fingerprint_before') then
    raise exception 'Published Production Roster entries changed during portal/leave validation.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608070001_production_roster_staff_portal_and_leave_requests_validation',
  'fixed_staff_link', true,
  'morning_and_evening_same_link', true,
  'anonymous_leave_submission', true,
  'manager_approval_queue', true,
  'approved_leave_overlay', true,
  'published_entries_unchanged', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
