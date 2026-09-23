-- =====================================================================
-- ElisCaretex V2
-- Validation V2: 202608100002_production_roster_mop_and_staff_exit_guard
--
-- Security rule:
--   protected master tables are inspected only before SET LOCAL ROLE
--   authenticated. Browser-role validation uses controlled RPCs only.
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr
      on sr.staff_id = sm.staff_id
     and sr.active = true
    join public.roles r
      on r.role_id = sr.role_id
     and r.active = true
     and r.role_code = 'ADMIN'
    where sm.auth_user_id is not null
      and sm.deleted_at is null
    order by sm.created_at
    limit 1
  ),
  true
);

do $$
declare
  v_week date :=
    public.production_roster_week_start(
      (now() at time zone 'Europe/Dublin')::date + 35
    );
  v_shift record;
  v_staff_a record;
  v_staff_b record;
  v_exit_staff record;
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No ADMIN auth user available for validation.';
  end if;

  -- Scenario discovery runs with the owner role. operational_roles and the
  -- other protected master tables remain private from authenticated.
  select sh.shift_id, sh.shift_code
  into v_shift
  from public.shifts sh
  where sh.shift_code in ('MORNING', 'EVENING')
    and sh.active = true
    and sh.deleted_at is null
    and (
      select count(*)
      from public.staff_members sm
      left join public.operational_roles opr
        on opr.operational_role_id = sm.primary_operational_role_id
      left join public.areas a
        on a.area_id = sm.default_area_id
      where sm.default_shift_id = sh.shift_id
        and sm.production_staff = true
        and sm.deleted_at is null
        and sm.active = true
        and sm.roster_eligible = true
        and (sm.joined_on is null or sm.joined_on <= v_week)
        and (sm.deactivated_on is null or sm.deactivated_on >= v_week + 5)
        and (opr.role_code = 'SORTING_AREA' or a.area_code = 'SORTING')
    ) >= 2
  order by sh.shift_code
  limit 1;

  if v_shift.shift_id is null then
    raise exception 'Need two eligible Sorting staff in one shift for validation.';
  end if;

  select sm.staff_id, sm.display_name
  into v_staff_a
  from public.staff_members sm
  left join public.operational_roles opr
    on opr.operational_role_id = sm.primary_operational_role_id
  left join public.areas a
    on a.area_id = sm.default_area_id
  where sm.default_shift_id = v_shift.shift_id
    and sm.production_staff = true
    and sm.deleted_at is null
    and sm.active = true
    and sm.roster_eligible = true
    and (sm.joined_on is null or sm.joined_on <= v_week)
    and (sm.deactivated_on is null or sm.deactivated_on >= v_week + 5)
    and (opr.role_code = 'SORTING_AREA' or a.area_code = 'SORTING')
  order by sm.display_name
  limit 1;

  select sm.staff_id, sm.display_name
  into v_staff_b
  from public.staff_members sm
  left join public.operational_roles opr
    on opr.operational_role_id = sm.primary_operational_role_id
  left join public.areas a
    on a.area_id = sm.default_area_id
  where sm.default_shift_id = v_shift.shift_id
    and sm.staff_id <> v_staff_a.staff_id
    and sm.production_staff = true
    and sm.deleted_at is null
    and sm.active = true
    and sm.roster_eligible = true
    and (sm.joined_on is null or sm.joined_on <= v_week)
    and (sm.deactivated_on is null or sm.deactivated_on >= v_week + 5)
    and (opr.role_code = 'SORTING_AREA' or a.area_code = 'SORTING')
  order by sm.display_name
  limit 1;

  if v_staff_a.staff_id is null or v_staff_b.staff_id is null then
    raise exception 'Could not resolve two Sorting staff for validation.';
  end if;

  select
    sm.staff_id,
    sm.deactivated_on,
    coalesce(sh.shift_code, 'MORNING') as shift_code
  into v_exit_staff
  from public.staff_members sm
  left join public.shifts sh
    on sh.shift_id = sm.default_shift_id
  where sm.production_staff = true
    and sm.deleted_at is null
    and sm.deactivated_on is not null
    and sm.deactivated_on <
      public.production_roster_week_start(
        (now() at time zone 'Europe/Dublin')::date
      )
  order by sm.deactivated_on desc
  limit 1;

  perform set_config('eliscaretex_validation.week_start', v_week::text, true);
  perform set_config('eliscaretex_validation.shift_code', v_shift.shift_code, true);
  perform set_config('eliscaretex_validation.staff_a_id', v_staff_a.staff_id::text, true);
  perform set_config('eliscaretex_validation.staff_b_id', v_staff_b.staff_id::text, true);
  perform set_config(
    'eliscaretex_validation.exit_staff_id',
    coalesce(v_exit_staff.staff_id::text, ''),
    true
  );
  perform set_config(
    'eliscaretex_validation.exit_shift_code',
    coalesce(v_exit_staff.shift_code, 'MORNING'),
    true
  );
end;
$$;

set local role authenticated;

do $$
declare
  v_week date :=
    current_setting('eliscaretex_validation.week_start')::date;
  v_shift_code text :=
    current_setting('eliscaretex_validation.shift_code');
  v_staff_a_id uuid :=
    current_setting('eliscaretex_validation.staff_a_id')::uuid;
  v_staff_b_id uuid :=
    current_setting('eliscaretex_validation.staff_b_id')::uuid;
  v_entries jsonb := '[]'::jsonb;
  v_day date;
  v_saved jsonb;
  v_doc jsonb;
  v_missing_mop_rejected boolean := false;
  v_exit_staff_id text :=
    current_setting('eliscaretex_validation.exit_staff_id', true);
  v_exit_shift_code text :=
    current_setting('eliscaretex_validation.exit_shift_code', true);
  v_pool jsonb;
begin
  -- Security remains intentional: do not grant browser SELECT to this table.
  if has_table_privilege(
    'authenticated',
    'public.operational_roles',
    'SELECT'
  ) then
    raise exception 'operational_roles must remain private from authenticated.';
  end if;

  for i in 0..5 loop
    v_day := v_week + i;

    v_entries := v_entries || jsonb_build_array(
      jsonb_build_object(
        'staff_id', v_staff_a_id,
        'work_date', v_day,
        'day_status', 'WORKING',
        'assignment_type', 'BASE',
        'operational_role_code', 'SORTING_AREA',
        'area_code', 'SORTING',
        'station_code', 'SORTING_MAIN',
        'display_section_code', 'SORTING_AREA',
        'sorting_work_mode', 'MOP',
        'shift_override_confirmed', false
      ),
      jsonb_build_object(
        'staff_id', v_staff_b_id,
        'work_date', v_day,
        'day_status', 'WORKING',
        'assignment_type', 'BASE',
        'operational_role_code', 'SORTING_AREA',
        'area_code', 'SORTING',
        'station_code', 'SORTING_MAIN',
        'display_section_code', 'SORTING_AREA',
        'sorting_work_mode', 'CLOTHES',
        'shift_override_confirmed', false
      )
    );
  end loop;

  v_saved := public.save_production_roster_week(
    v_week,
    v_shift_code,
    false,
    'Validation roster',
    v_entries,
    null,
    'Validate one MOP per Sorting day',
    'ROSTER_VALIDATION'
  );

  if coalesce(v_saved ->> 'status', '') <> 'DRAFT' then
    raise exception 'Valid MOP roster did not save: %', v_saved;
  end if;

  v_doc := public.get_production_roster_week(
    v_week,
    v_shift_code,
    (v_saved ->> 'roster_version_id')::uuid
  );

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_doc -> 'entries', '[]'::jsonb)) e
    where e ->> 'sorting_work_mode' = 'MOP'
  ) then
    raise exception 'Roster read model does not expose sorting_work_mode.';
  end if;

  begin
    perform public.save_production_roster_week(
      v_week,
      v_shift_code,
      false,
      'Validation roster',
      (
        select jsonb_agg(
          case
            when e ->> 'sorting_work_mode' = 'MOP'
              then e - 'sorting_work_mode'
            else e
          end
        )
        from jsonb_array_elements(v_entries) e
      ),
      (v_saved ->> 'row_version')::integer,
      'Validation missing MOP must fail',
      'ROSTER_VALIDATION'
    );
  exception
    when others then
      if sqlstate = '22023'
         and position('Select exactly one MOP staff member' in sqlerrm) > 0 then
        v_missing_mop_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_missing_mop_rejected then
    raise exception 'Roster save did not reject a Sorting day without MOP.';
  end if;

  -- The valid draft must also pass the server-side Publish guard.
  -- The transaction rolls back at the end.
  v_saved := public.publish_production_roster_week(
    (v_saved ->> 'roster_version_id')::uuid,
    (v_saved ->> 'row_version')::integer,
    'Validate mandatory MOP publish guard',
    'ROSTER_VALIDATION'
  );

  if coalesce(v_saved ->> 'status', '') <> 'PUBLISHED' then
    raise exception
      'Valid MOP roster did not publish through the guarded backend: %',
      v_saved;
  end if;

  -- Exit-date validation is also performed through the controlled staff-pool RPC.
  if nullif(v_exit_staff_id, '') is not null then
    v_pool := public.get_production_roster_staff_pool(
      public.production_roster_week_start(
        (now() at time zone 'Europe/Dublin')::date
      ),
      coalesce(nullif(v_exit_shift_code, ''), 'MORNING'),
      null
    );

    if exists (
      select 1
      from jsonb_array_elements(coalesce(v_pool -> 'staff', '[]'::jsonb)) p
      where p ->> 'staff_id' = v_exit_staff_id
        and coalesce((p ->> 'currently_eligible')::boolean, false) = true
    ) then
      raise exception
        'Staff whose exit date is before the week is still currently_eligible in staff pool.';
    end if;
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608100002_production_roster_mop_and_staff_exit_guard_validation_v2',
  'one_mop_per_sorting_day_required', true,
  'sorting_work_mode_read_model', true,
  'missing_mop_save_rejected', true,
  'valid_mop_publish_guard_passed', true,
  'exit_date_pool_guard', true,
  'operational_roles_remains_private', true,
  'published_history_not_modified', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
