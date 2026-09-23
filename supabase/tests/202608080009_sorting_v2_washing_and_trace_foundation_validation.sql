-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608080009_sorting_v2_washing_and_trace_foundation
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
  'eliscaretex_validation.shift_code',
  coalesce((
    select sh.shift_code
    from public.production_roster_versions prv
    join public.roster_periods rp
      on rp.roster_period_id = prv.roster_period_id
     and rp.week_start = public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date)
    join public.shifts sh on sh.shift_id = prv.shift_id
    where prv.status = 'PUBLISHED'
      and exists (
        select 1
        from public.production_roster_entries pre
        left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
        left join public.areas a on a.area_id = pre.area_id
        left join public.stations st on st.station_id = pre.station_id
        where pre.roster_version_id = prv.roster_version_id
          and pre.work_date = (now() at time zone 'Europe/Dublin')::date
          and pre.day_status = 'WORKING'
          and (
            coalesce(nullif(pre.area_code_snapshot,''),a.area_code) = 'SORTING'
            or coalesce(nullif(pre.station_code_snapshot,''),st.station_code) = 'SORTING_MAIN'
            or pre.display_section_code = 'SORTING_AREA'
            or coalesce(nullif(pre.operational_role_code_snapshot,''),opr.role_code) = 'SORTING_AREA'
          )
      )
    order by sh.shift_code
    limit 1
  ), 'MORNING'),
  true
);

select set_config(
  'eliscaretex_validation.operator_staff_id',
  coalesce((
    select pre.staff_id::text
    from public.production_roster_versions prv
    join public.roster_periods rp
      on rp.roster_period_id = prv.roster_period_id
     and rp.week_start = public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date)
    join public.shifts sh
      on sh.shift_id = prv.shift_id
     and sh.shift_code = current_setting('eliscaretex_validation.shift_code')
    join public.production_roster_entries pre
      on pre.roster_version_id = prv.roster_version_id
     and pre.work_date = (now() at time zone 'Europe/Dublin')::date
     and pre.day_status = 'WORKING'
    left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
    left join public.areas a on a.area_id = pre.area_id
    left join public.stations st on st.station_id = pre.station_id
    where prv.status = 'PUBLISHED'
      and (
        coalesce(nullif(pre.area_code_snapshot,''),a.area_code) = 'SORTING'
        or coalesce(nullif(pre.station_code_snapshot,''),st.station_code) = 'SORTING_MAIN'
        or pre.display_section_code = 'SORTING_AREA'
        or coalesce(nullif(pre.operational_role_code_snapshot,''),opr.role_code) = 'SORTING_AREA'
      )
    order by pre.staff_display_name_snapshot
    limit 1
  ), ''),
  true
);

select set_config(
  'eliscaretex_validation.washer_id',
  coalesce((
    select w.washer_id::text
    from public.sorting_washers w
    where w.active and w.deleted_at is null
    order by w.sort_order,w.washer_code
    limit 1
  ), ''),
  true
);

select set_config(
  'eliscaretex_validation.customer_id',
  coalesce((
    select c.customer_id::text
    from public.customers c
    where c.active and c.deleted_at is null
    order by c.created_at,c.customer_name
    limit 1
  ), ''),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.operator_staff_id',true),'') is null then
    raise exception 'No current published Sorting operator was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.washer_id',true),'') is null then
    raise exception 'No active Sorting washer was found.';
  end if;
  if nullif(current_setting('eliscaretex_validation.customer_id',true),'') is null then
    raise exception 'No active customer was found.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_context jsonb;
  v_result jsonb;
  v_wash_code text;
  v_trace_code text;
  v_duplicate_rejected boolean := false;
  v_start_time time := ((now() at time zone 'Europe/Dublin') - interval '30 minutes')::time;
begin
  if has_table_privilege('authenticated','public.sorting_washers','SELECT')
     or has_table_privilege('authenticated','public.sorting_wash_runs','SELECT')
     or has_table_privilege('authenticated','public.sorting_wash_run_customers','SELECT') then
    raise exception 'Private Washing tables must not have direct authenticated SELECT.';
  end if;

  v_context := public.get_sorting_washing_context(
    current_setting('eliscaretex_validation.shift_code')
  );

  if coalesce(v_context ->> 'source','') <> 'PUBLISHED_ROSTER_AND_PUBLISHED_CUSTOMER_SCHEDULE' then
    raise exception 'Unexpected Washing context source.';
  end if;

  if jsonb_array_length(coalesce(v_context -> 'washers','[]'::jsonb)) < 6 then
    raise exception 'Expected six legacy-reference washers.';
  end if;

  v_result := public.save_sorting_wash_run(
    current_setting('eliscaretex_validation.shift_code'),
    current_setting('eliscaretex_validation.washer_id')::uuid,
    current_setting('eliscaretex_validation.operator_staff_id')::uuid,
    v_start_time,
    1.00,
    'OTHERS',
    array[current_setting('eliscaretex_validation.customer_id')::uuid],
    'Temporary Sorting Washing validation.'
  );

  if coalesce(v_result ->> 'status','') <> 'success' then
    raise exception 'Washing save did not return success: %',v_result;
  end if;

  v_wash_code := v_result ->> 'wash_code';
  v_trace_code := v_result -> 'trace_rows' -> 0 ->> 'trace_code';

  if v_wash_code !~ '^W[0-9]{8}-[A-F0-9]{6}$' then
    raise exception 'Unexpected Wash ID: %',v_wash_code;
  end if;

  if v_trace_code <> (v_wash_code || '-01') then
    raise exception 'Customer trace code is not chained to Wash ID: %',v_trace_code;
  end if;

  if coalesce(v_result -> 'trace_rows' -> 0 ->> 'schedule_relation','') <> 'NOT_APPLICABLE' then
    raise exception 'OTHERS test should be NOT_APPLICABLE.';
  end if;

  begin
    perform public.save_sorting_wash_run(
      current_setting('eliscaretex_validation.shift_code'),
      current_setting('eliscaretex_validation.washer_id')::uuid,
      current_setting('eliscaretex_validation.operator_staff_id')::uuid,
      v_start_time,
      1.00,
      'OTHERS',
      array[current_setting('eliscaretex_validation.customer_id')::uuid],
      'Immediate duplicate validation.'
    );
  exception
    when unique_violation then
      v_duplicate_rejected := position('within 10 minutes' in sqlerrm) > 0;
  end;

  if not v_duplicate_rejected then
    raise exception 'Same-washer duplicate was not rejected.';
  end if;
end;
$$;

reset role;

do $$
declare
  v_runs integer;
  v_links integer;
begin
  select count(*) into v_runs
  from public.sorting_wash_runs
  where notes='Temporary Sorting Washing validation.';

  select count(*) into v_links
  from public.sorting_wash_run_customers wrc
  join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id
  where wr.notes='Temporary Sorting Washing validation.';

  if v_runs <> 1 or v_links <> 1 then
    raise exception 'Trace persistence failed. runs=%, links=%',v_runs,v_links;
  end if;
end;
$$;

select jsonb_build_object(
  'status','PASS',
  'test','202608080009_sorting_v2_washing_and_trace_foundation_validation',
  'private_tables_protected',true,
  'published_roster_context',true,
  'washer_master_available',true,
  'wash_id_generated',true,
  'per_customer_trace_generated',true,
  'same_washer_duplicate_rejected',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
