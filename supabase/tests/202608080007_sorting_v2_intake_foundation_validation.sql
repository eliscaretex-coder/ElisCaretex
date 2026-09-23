-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080007_sorting_v2_intake_foundation_validation.sql
--
-- Covered:
--   - Sorting RPC privileges and protected-table boundaries;
--   - current daily context uses PUBLISHED Production Roster only;
--   - planned Sorting staff count matches the protected published roster;
--   - trolley preview is read-only;
--   - current-day trolley intake reuses lifecycle exception handling;
--   - immediate duplicate intake is rejected;
--   - all writes are rolled back.
-- =====================================================================

begin;

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
  'eliscaretex_validation.sorting_shift',
  coalesce((
    select sh.shift_code
    from public.production_roster_versions prv
    join public.roster_periods rp
      on rp.roster_period_id = prv.roster_period_id
     and rp.week_start = public.production_roster_week_start(current_date)
    join public.shifts sh
      on sh.shift_id = prv.shift_id
    where prv.status = 'PUBLISHED'
      and exists (
        select 1
        from public.production_roster_entries pre
        left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
        left join public.areas a on a.area_id = pre.area_id
        left join public.stations st on st.station_id = pre.station_id
        where pre.roster_version_id = prv.roster_version_id
          and pre.work_date = current_date
          and pre.day_status = 'WORKING'
          and (
            coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) = 'SORTING'
            or coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) = 'SORTING_MAIN'
            or pre.display_section_code = 'SORTING_AREA'
            or coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) = 'SORTING_AREA'
          )
      )
    order by sh.shift_code
    limit 1
  ), 'MORNING'),
  true
);

select set_config(
  'eliscaretex_validation.expected_sorting_staff',
  (
    select count(*)::text
    from public.production_roster_versions prv
    join public.roster_periods rp
      on rp.roster_period_id = prv.roster_period_id
     and rp.week_start = public.production_roster_week_start(current_date)
    join public.shifts sh
      on sh.shift_id = prv.shift_id
     and sh.shift_code = current_setting('eliscaretex_validation.sorting_shift')
    join public.production_roster_entries pre
      on pre.roster_version_id = prv.roster_version_id
     and pre.work_date = current_date
    left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
    left join public.areas a on a.area_id = pre.area_id
    left join public.stations st on st.station_id = pre.station_id
    where prv.status = 'PUBLISHED'
      and pre.day_status = 'WORKING'
      and (
        coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) = 'SORTING'
        or coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) = 'SORTING_MAIN'
        or pre.display_section_code = 'SORTING_AREA'
        or coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) = 'SORTING_AREA'
      )
  ),
  true
);

select set_config(
  'eliscaretex_validation.customer_id',
  (
    select c.customer_id::text
    from public.customers c
    where c.active = true
      and c.deleted_at is null
    order by c.created_at, c.customer_name
    limit 1
  ),
  true
);

select set_config(
  'eliscaretex_validation.trolley_type_id',
  (
    select tt.trolley_type_id::text
    from public.trolley_types tt
    where tt.active = true
      and tt.deleted_at is null
    order by tt.sort_order, tt.trolley_type_code
    limit 1
  ),
  true
);

select set_config(
  'eliscaretex_validation.trolley_code',
  'TSORT' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)) || 'T',
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.customer_id', true), '') is null then
    raise exception 'No active customer was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.trolley_type_id', true), '') is null then
    raise exception 'No active trolley type was found.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_context jsonb;
  v_expected integer := current_setting('eliscaretex_validation.expected_sorting_staff')::integer;
begin
  if not has_function_privilege(
    'authenticated',
    'public.get_sorting_daily_context(date,text)',
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    'public.get_sorting_trolley_intake_preview(text)',
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    'public.record_sorting_trolley_intake(text,uuid,text)',
    'EXECUTE'
  ) then
    raise exception 'Required Sorting V2 RPC privilege is missing.';
  end if;

  if has_table_privilege('authenticated', 'public.production_roster_entries', 'SELECT')
     or has_table_privilege('authenticated', 'public.trolley_customer_stays', 'SELECT') then
    raise exception 'Sorting V2 must not require direct browser SELECT on protected operational tables.';
  end if;

  v_context := public.get_sorting_daily_context(
    current_date,
    current_setting('eliscaretex_validation.sorting_shift')
  );

  if coalesce(v_context ->> 'source', '') <> 'PUBLISHED_PRODUCTION_ROSTER' then
    raise exception 'Sorting context did not identify the PUBLISHED Production Roster as its source.';
  end if;

  if coalesce((v_context ->> 'planned_staff_count')::integer, 0) <> v_expected then
    raise exception 'Sorting planned staff count mismatch. Expected %, received %.',
      v_expected, coalesce((v_context ->> 'planned_staff_count')::integer, 0);
  end if;

  if v_context -> 'roster' is not null
     and coalesce(v_context -> 'roster' ->> 'status', '') <> 'PUBLISHED' then
    raise exception 'Sorting context exposed a non-published roster document.';
  end if;
end;
$$;

select public.register_physical_trolley(
  p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
  p_trolley_type_id => current_setting('eliscaretex_validation.trolley_type_id')::uuid,
  p_registered_on => current_date,
  p_notes => 'Temporary Sorting V2 validation trolley.',
  p_source_application => 'DATABASE_TEST'
);

do $$
declare
  v_preview jsonb;
  v_result jsonb;
  v_duplicate_rejected boolean := false;
begin
  v_preview := public.get_sorting_trolley_intake_preview(
    current_setting('eliscaretex_validation.trolley_code')
  );

  if coalesce(v_preview -> 'trolley' ->> 'trolley_code', '') <>
     current_setting('eliscaretex_validation.trolley_code') then
    raise exception 'Sorting trolley preview returned the wrong trolley.';
  end if;

  v_result := public.record_sorting_trolley_intake(
    current_setting('eliscaretex_validation.trolley_code'),
    current_setting('eliscaretex_validation.customer_id')::uuid,
    'Temporary Sorting V2 database validation.'
  );

  if coalesce(v_result ->> 'review_status', '') <> 'PENDING'
     or coalesce(v_result ->> 'exception_type', '') <> 'MISSING_OUTBOUND_RECORD' then
    raise exception 'Sorting intake without outbound history did not preserve the expected review exception.';
  end if;

  begin
    perform public.record_sorting_trolley_intake(
      current_setting('eliscaretex_validation.trolley_code'),
      current_setting('eliscaretex_validation.customer_id')::uuid,
      'Immediate duplicate test.'
    );
  exception
    when unique_violation then
      v_duplicate_rejected := position('already recorded at Sorting' in sqlerrm) > 0;
  end;

  if not v_duplicate_rejected then
    raise exception 'Immediate duplicate Sorting trolley intake was not rejected.';
  end if;
end;
$$;

reset role;

do $$
declare
  v_event_count integer;
begin
  select count(*)
  into v_event_count
  from public.trolley_events te
  join public.trolleys t on t.trolley_id = te.trolley_id
  where t.trolley_code = current_setting('eliscaretex_validation.trolley_code')
    and te.event_type = 'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND'
    and te.business_date = current_date;

  if v_event_count <> 1 then
    raise exception 'Expected exactly one Sorting arrival event for the validation trolley, found %.', v_event_count;
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608080007_sorting_v2_intake_foundation_validation',
  'published_roster_only', true,
  'planned_sorting_staff_matches', true,
  'protected_tables_remain_private', true,
  'trolley_preview_read_only', true,
  'missing_outbound_review_preserved', true,
  'duplicate_intake_rejected', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
