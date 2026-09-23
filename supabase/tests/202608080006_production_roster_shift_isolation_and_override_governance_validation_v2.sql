-- =====================================================================
-- ElisCaretex V2
-- Validation v2: 202608080006 shift isolation + explicit override governance
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
  'eliscaretex_validation.week_start',
  public.production_roster_week_start(current_date + 742)::text,
  true
);

select set_config(
  'eliscaretex_validation.morning_staff_id',
  candidate.staff_id::text,
  true
)
from (
  select sm.staff_id
  from public.staff_members sm
  join public.shifts sh on sh.shift_id = sm.default_shift_id
  join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
  join public.areas a on a.area_id = sm.default_area_id
  join public.stations st on st.station_id = sm.default_station_id
  where sm.production_staff = true
    and sm.active = true
    and sm.roster_eligible = true
    and sm.deleted_at is null
    and sh.shift_code = 'MORNING'
    and opr.role_code = 'GENERAL_OPERATIVE'
    and a.area_code = 'FINISH'
    and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
  order by sm.created_at
  limit 1
) candidate;

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.morning_staff_id', true), '') is null then
    raise exception 'No eligible Morning staff was found.';
  end if;
end;
$$;

-- Build a normal Morning payload.
select set_config(
  'eliscaretex_validation.morning_working_payload',
  (
    select jsonb_agg(jsonb_build_object(
      'staff_id', current_setting('eliscaretex_validation.morning_staff_id')::uuid,
      'work_date', current_setting('eliscaretex_validation.week_start')::date + d,
      'day_status', 'WORKING',
      'assignment_type', 'BASE',
      'operational_role_code', coalesce(opr.role_code, 'GENERAL_OPERATIVE'),
      'area_code', coalesce(a.area_code, 'FINISH'),
      'station_code', st.station_code,
      'display_section_code', public.production_roster_default_display_section(opr.role_code, st.station_code),
      'shift_override_confirmed', false,
      'notes', null
    ) order by d)::text
    from generate_series(0,5) d
    cross join public.staff_members sm
    left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
    left join public.areas a on a.area_id = sm.default_area_id
    left join public.stations st on st.station_id = sm.default_station_id
    where sm.staff_id = current_setting('eliscaretex_validation.morning_staff_id')::uuid
  ),
  true
);

set local role authenticated;

select set_config(
  'eliscaretex_validation.morning_saved',
  public.save_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'MORNING',
    false,
    'Shift isolation validation.',
    current_setting('eliscaretex_validation.morning_working_payload')::jsonb,
    null,
    'Create Morning baseline for shift-isolation validation.',
    'DATABASE_TEST'
  )::text,
  true
);

reset role;

-- Unconfirmed cross-shift save must fail.
select set_config(
  'eliscaretex_validation.evening_unconfirmed_payload',
  (
    select jsonb_agg(
      jsonb_set(item, '{shift_override_confirmed}', 'false'::jsonb)
      order by item->>'work_date'
    )::text
    from jsonb_array_elements(current_setting('eliscaretex_validation.morning_working_payload')::jsonb) item
  ),
  true
);

set local role authenticated;

do $$
begin
  begin
    perform public.save_production_roster_week(
      current_setting('eliscaretex_validation.week_start')::date,
      'EVENING',
      false,
      'Shift isolation validation.',
      current_setting('eliscaretex_validation.evening_unconfirmed_payload')::jsonb,
      null,
      'Unconfirmed override must fail.',
      'DATABASE_TEST'
    );
    raise exception 'Unconfirmed cross-shift save unexpectedly succeeded.';
  exception
    when others then
      if sqlerrm = 'Unconfirmed cross-shift save unexpectedly succeeded.' then
        raise;
      end if;
      if sqlstate <> '22023'
         or position('belongs to' in sqlerrm) = 0
         or position('temporary' in sqlerrm) = 0
         or position('shift override' in sqlerrm) = 0 then
        raise exception 'Unexpected unconfirmed override error [%]: %', sqlstate, sqlerrm;
      end if;
  end;
end;
$$;

reset role;

-- Confirmed override still fails while Morning has the same staff/date planned.
select set_config(
  'eliscaretex_validation.evening_confirmed_payload',
  (
    select jsonb_agg(
      jsonb_set(item, '{shift_override_confirmed}', 'true'::jsonb)
      order by item->>'work_date'
    )::text
    from jsonb_array_elements(current_setting('eliscaretex_validation.morning_working_payload')::jsonb) item
  ),
  true
);

set local role authenticated;

do $$
begin
  begin
    perform public.save_production_roster_week(
      current_setting('eliscaretex_validation.week_start')::date,
      'EVENING',
      false,
      'Shift isolation validation.',
      current_setting('eliscaretex_validation.evening_confirmed_payload')::jsonb,
      null,
      'Double allocation must fail.',
      'DATABASE_TEST'
    );
    raise exception 'Double-allocation cross-shift save unexpectedly succeeded.';
  exception
    when others then
      if sqlerrm = 'Double-allocation cross-shift save unexpectedly succeeded.' then
        raise;
      end if;
      if sqlstate <> '22023'
         or position('already planned in' in sqlerrm) = 0
         or position('Morning Shift' in sqlerrm) = 0
         or position('temporary Evening Shift override' in sqlerrm) = 0 then
        raise exception 'Unexpected double-allocation error [%]: %', sqlstate, sqlerrm;
      end if;
  end;
end;
$$;

reset role;

-- Make Morning non-working, then the confirmed Evening override may be saved.
select set_config(
  'eliscaretex_validation.morning_off_payload',
  (
    select jsonb_agg(
      jsonb_build_object(
        'staff_id', item->>'staff_id',
        'work_date', item->>'work_date',
        'day_status', 'OFF',
        'assignment_type', 'BASE',
        'operational_role_code', null,
        'area_code', null,
        'station_code', null,
        'display_section_code', item->>'display_section_code',
        'shift_override_confirmed', false,
        'notes', null
      )
      order by item->>'work_date'
    )::text
    from jsonb_array_elements(current_setting('eliscaretex_validation.morning_working_payload')::jsonb) item
  ),
  true
);

set local role authenticated;

select set_config(
  'eliscaretex_validation.morning_off_saved',
  public.save_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'MORNING',
    false,
    'Shift isolation validation.',
    current_setting('eliscaretex_validation.morning_off_payload')::jsonb,
    (current_setting('eliscaretex_validation.morning_saved')::jsonb ->> 'row_version')::integer,
    'Make Morning non-working before temporary Evening override.',
    'DATABASE_TEST'
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.evening_saved',
  public.save_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'EVENING',
    false,
    'Shift isolation validation.',
    current_setting('eliscaretex_validation.evening_confirmed_payload')::jsonb,
    null,
    'Confirmed temporary Evening shift override.',
    'DATABASE_TEST'
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.evening_read',
  public.get_production_roster_week(
    current_setting('eliscaretex_validation.week_start')::date,
    'EVENING',
    null
  )::text,
  true
);

reset role;

do $$
declare
  v_override_count integer;
  v_confirmed_days integer;
  v_read_authorized boolean;
  v_read_default_shift text;
  v_recovery_bad integer;
begin
  select count(*), max(cardinality(confirmed_days))
  into v_override_count, v_confirmed_days
  from public.production_roster_shift_overrides
  where roster_version_id =
    (current_setting('eliscaretex_validation.evening_saved')::jsonb ->> 'roster_version_id')::uuid
    and staff_id = current_setting('eliscaretex_validation.morning_staff_id')::uuid;

  if v_override_count <> 1 or v_confirmed_days <> 6 then
    raise exception 'Explicit override evidence was not persisted correctly: count %, days %.',
      v_override_count, v_confirmed_days;
  end if;

  select
    coalesce((item->>'shift_override_authorized')::boolean, false),
    item->>'default_shift_code'
  into v_read_authorized, v_read_default_shift
  from jsonb_array_elements(
    current_setting('eliscaretex_validation.evening_read')::jsonb -> 'staff'
  ) item
  where item->>'staff_id' = current_setting('eliscaretex_validation.morning_staff_id')
  limit 1;

  if v_read_authorized is not true or v_read_default_shift <> 'MORNING' then
    raise exception 'Roster read API did not preserve explicit override/default-shift evidence.';
  end if;

  select count(*) into v_recovery_bad
  from public.production_roster_versions prv
  join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
  join public.shifts sh on sh.shift_id = prv.shift_id
  where prv.status = 'DRAFT'
    and exists (
      select 1 from public.production_roster_entries pre
      where pre.roster_version_id = prv.roster_version_id
    )
    and (
      select count(distinct pre.staff_id)
      from public.production_roster_entries pre
      where pre.roster_version_id = prv.roster_version_id
        and coalesce(pre.staff_default_shift_code_snapshot, pre.shift_code_snapshot) = sh.shift_code
    ) = 0
    and (
      select count(distinct pre.staff_id)
      from public.production_roster_entries pre
      where pre.roster_version_id = prv.roster_version_id
    ) >= 5;

  if v_recovery_bad <> 0 then
    raise exception 'An all-cross-shift contaminated DRAFT remains active after migration.';
  end if;
end;
$$;

-- Direct browser access must remain denied.
do $$
begin
  if has_table_privilege('authenticated', 'public.production_roster_shift_overrides', 'SELECT') then
    raise exception 'authenticated unexpectedly has direct SELECT on production_roster_shift_overrides.';
  end if;
  if has_table_privilege('authenticated', 'public.production_roster_draft_recovery_snapshots', 'SELECT') then
    raise exception 'authenticated unexpectedly has direct SELECT on production_roster_draft_recovery_snapshots.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608080006_production_roster_shift_isolation_and_override_governance_validation',
  'unconfirmed_cross_shift_rejected', true,
  'double_allocation_rejected', true,
  'explicit_override_persisted', true,
  'default_shift_preserved_in_read_api', true,
  'contaminated_drafts_quarantined', true,
  'private_override_evidence', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
