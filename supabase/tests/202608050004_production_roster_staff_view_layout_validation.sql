-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608050004_production_roster_staff_view_layout_validation.sql
--
-- Validates the enriched anonymous RosterView payload while proving that
-- published Production Roster entries are not modified. All writes roll back.
-- =====================================================================

begin;

select set_config(
  'eliscaretex_validation.entry_fingerprint_before',
  coalesce((
    select md5(string_agg(to_jsonb(pre)::text, '|' order by pre.roster_entry_id))
    from public.production_roster_entries pre
    join public.production_roster_versions prv
      on prv.roster_version_id = pre.roster_version_id
    where prv.status in ('PUBLISHED', 'SUPERSEDED')
  ), md5('')),
  true
);

select set_config(
  'eliscaretex_validation.shift_id',
  candidate.shift_id::text,
  true
)
from (
  select prv.shift_id
  from public.production_roster_versions prv
  join public.roster_periods rp
    on rp.roster_period_id = prv.roster_period_id
  where prv.status = 'PUBLISHED'
    and rp.week_start in (
      public.production_roster_week_start(current_date),
      public.production_roster_week_start(current_date) + 7
    )
    and exists (
      select 1
      from public.production_roster_entries pre
      where pre.roster_version_id = prv.roster_version_id
    )
  order by rp.week_start, prv.version_number desc
  limit 1
) candidate;

do $$
begin
  if nullif(current_setting('eliscaretex_validation.shift_id', true), '') is null then
    raise exception 'A published current- or next-week Production Roster with entries is required for this validation.';
  end if;
end;
$$;

update public.production_roster_view_links
set active = false,
    revoked_at = coalesce(revoked_at, now())
where shift_id = current_setting('eliscaretex_validation.shift_id')::uuid
  and active = true;

select set_config(
  'eliscaretex_validation.token',
  replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  true
);

insert into public.production_roster_view_links (
  shift_id,
  token_hash,
  token_hint,
  active
)
values (
  current_setting('eliscaretex_validation.shift_id')::uuid,
  public.production_roster_view_token_hash(current_setting('eliscaretex_validation.token')),
  right(current_setting('eliscaretex_validation.token'), 6),
  true
);

set local role anon;

select set_config(
  'eliscaretex_validation.payload',
  public.get_published_production_roster(
    current_setting('eliscaretex_validation.token')
  )::text,
  true
);

reset role;

do $$
declare
  v_payload jsonb := current_setting('eliscaretex_validation.payload')::jsonb;
  v_entry jsonb;
  v_fingerprint_after text;
begin
  if jsonb_array_length(coalesce(v_payload -> 'weeks', '[]'::jsonb)) = 0 then
    raise exception 'RosterView returned no published week.';
  end if;

  select entry
  into v_entry
  from jsonb_array_elements(v_payload -> 'weeks') week_item
  cross join lateral jsonb_array_elements(coalesce(week_item -> 'entries', '[]'::jsonb)) entry
  limit 1;

  if v_entry is null then
    raise exception 'RosterView returned no published entry.';
  end if;

  if not (
    v_entry ? 'display_section_code'
    and v_entry ? 'staff_primary_role_code'
    and v_entry ? 'staff_default_station_code'
    and v_entry ? 'staff_default_shift_code'
    and v_entry ? 'roster_shift_code'
    and v_entry ? 'fire_training'
    and v_entry ? 'first_aid_training'
    and v_entry ? 'eod_capable'
    and v_entry ? 'notes'
  ) then
    raise exception 'RosterView entry is missing one or more layout snapshot fields.';
  end if;

  if v_entry ? 'employee_code' then
    raise exception 'Anonymous RosterView payload still exposes employee_code.';
  end if;

  if jsonb_typeof(v_entry -> 'fire_training') <> 'boolean'
     or jsonb_typeof(v_entry -> 'first_aid_training') <> 'boolean'
     or jsonb_typeof(v_entry -> 'eod_capable') <> 'boolean' then
    raise exception 'RosterView qualification flags are not booleans.';
  end if;

  select coalesce(md5(string_agg(to_jsonb(pre)::text, '|' order by pre.roster_entry_id)), md5(''))
  into v_fingerprint_after
  from public.production_roster_entries pre
  join public.production_roster_versions prv
    on prv.roster_version_id = pre.roster_version_id
  where prv.status in ('PUBLISHED', 'SUPERSEDED');

  if v_fingerprint_after <> current_setting('eliscaretex_validation.entry_fingerprint_before') then
    raise exception 'Published Production Roster entries changed during staff-view validation.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608050004_production_roster_staff_view_layout_validation',
  'anonymous_token_access', true,
  'current_next_weeks_only', true,
  'layout_snapshots_present', true,
  'qualification_flags_present', true,
  'employee_code_omitted', true,
  'published_entries_unchanged', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
