-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608100001_sorting_schedule_trace_mop_assignment_and_visual_board
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
            coalesce(nullif(pre.area_code_snapshot,''),a.area_code)='SORTING'
            or coalesce(nullif(pre.station_code_snapshot,''),st.station_code)='SORTING_MAIN'
            or pre.display_section_code='SORTING_AREA'
            or coalesce(nullif(pre.operational_role_code_snapshot,''),opr.role_code)='SORTING_AREA'
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
        coalesce(nullif(pre.area_code_snapshot,''),a.area_code)='SORTING'
        or coalesce(nullif(pre.station_code_snapshot,''),st.station_code)='SORTING_MAIN'
        or pre.display_section_code='SORTING_AREA'
        or coalesce(nullif(pre.operational_role_code_snapshot,''),opr.role_code)='SORTING_AREA'
      )
    order by pre.staff_display_name_snapshot
    limit 1
  ), ''),
  true
);

select set_config(
  'eliscaretex_validation.schedule_product_id',
  coalesce((
    select sp.schedule_product_id::text
    from public.customer_schedule_versions csv
    join public.customer_schedule_days sd
      on sd.schedule_version_id = csv.schedule_version_id
     and sd.active = true
     and sd.production_weekday = extract(isodow from ((now() at time zone 'Europe/Dublin')::date + 1))::smallint
    join public.customer_schedule_products sp
      on sp.schedule_day_id = sd.schedule_day_id
     and sp.active = true
    join public.product_types pt
      on pt.product_type_id = sp.product_type_id
     and pt.active = true
     and pt.deleted_at is null
     and pt.product_code in ('CLOTHES','MOP')
    join public.customers c
      on c.customer_id = csv.customer_id
     and c.active = true
     and c.deleted_at is null
    where csv.status = 'PUBLISHED'
      and csv.effective_from <= ((now() at time zone 'Europe/Dublin')::date + 1)
      and (csv.effective_until is null or csv.effective_until >= ((now() at time zone 'Europe/Dublin')::date + 1))
    order by pt.product_code, sp.production_order nulls last, c.customer_name
    limit 1
  ), ''),
  true
);

select set_config(
  'eliscaretex_validation.customer_id',
  coalesce((
    select csv.customer_id::text
    from public.customer_schedule_products sp
    join public.customer_schedule_days sd on sd.schedule_day_id = sp.schedule_day_id
    join public.customer_schedule_versions csv on csv.schedule_version_id = sd.schedule_version_id
    where sp.schedule_product_id = nullif(current_setting('eliscaretex_validation.schedule_product_id'),'')::uuid
    limit 1
  ), ''),
  true
);

select set_config(
  'eliscaretex_validation.product_code',
  coalesce((
    select pt.product_code
    from public.customer_schedule_products sp
    join public.product_types pt on pt.product_type_id = sp.product_type_id
    where sp.schedule_product_id = nullif(current_setting('eliscaretex_validation.schedule_product_id'),'')::uuid
    limit 1
  ), ''),
  true
);

select set_config(
  'eliscaretex_validation.washer_code',
  'TV13' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  true
);

insert into public.sorting_washers (
  washer_code,
  washer_name,
  capacity_kg,
  category,
  active,
  sort_order,
  notes,
  metadata
)
values (
  current_setting('eliscaretex_validation.washer_code'),
  'Temporary Validation Washer',
  10,
  'VALIDATION',
  true,
  9999,
  'Temporary Snapshot 62 validation washer.',
  '{"validation":true}'::jsonb
);

select set_config(
  'eliscaretex_validation.washer_id',
  (
    select w.washer_id::text
    from public.sorting_washers w
    where w.washer_code = current_setting('eliscaretex_validation.washer_code')
  ),
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
  if nullif(current_setting('eliscaretex_validation.schedule_product_id',true),'') is null then
    raise exception 'No tomorrow published Clothes/MOP schedule row was found.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_staff_context jsonb;
  v_board jsonb;
  v_result jsonb;
  v_washing_context jsonb;
  v_trace jsonb;
  v_tomorrow date := (now() at time zone 'Europe/Dublin')::date + 1;
begin
  if has_table_privilege('authenticated','public.sorting_daily_staff_modes','SELECT') then
    raise exception 'sorting_daily_staff_modes must remain private.';
  end if;

  v_staff_context := public.get_sorting_staff_work_context_v2(
    current_setting('eliscaretex_validation.shift_code')
  );

  if jsonb_array_length(coalesce(v_staff_context -> 'staff','[]'::jsonb)) = 0 then
    raise exception 'Sorting Staff V2 context returned no staff.';
  end if;

  perform public.set_sorting_mop_staff(
    current_setting('eliscaretex_validation.shift_code'),
    current_setting('eliscaretex_validation.operator_staff_id')::uuid
  );

  v_staff_context := public.get_sorting_staff_work_context_v2(
    current_setting('eliscaretex_validation.shift_code')
  );

  if coalesce(v_staff_context ->> 'mop_staff_id','') <>
     current_setting('eliscaretex_validation.operator_staff_id') then
    raise exception 'MOP staff assignment did not persist through controlled context.';
  end if;

  v_board := public.get_sorting_customer_board_v2();

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_board -> 'customers','[]'::jsonb)) row_item
    where row_item ->> 'day_relation' = 'TOMORROW'
      and row_item ? 'route_color'
      and row_item ? 'planned_trolley_quantity'
      and row_item ? 'scheduled_weekday_name'
  ) then
    raise exception 'Customer board V2 does not expose tomorrow/route/trolley/day data.';
  end if;

  v_result := public.save_sorting_wash_run_v2(
    current_setting('eliscaretex_validation.shift_code'),
    current_setting('eliscaretex_validation.washer_id')::uuid,
    current_setting('eliscaretex_validation.operator_staff_id')::uuid,
    ((now() at time zone 'Europe/Dublin') - interval '30 minutes')::time,
    1.00,
    current_setting('eliscaretex_validation.product_code'),
    jsonb_build_array(
      jsonb_build_object(
        'customer_id', current_setting('eliscaretex_validation.customer_id'),
        'schedule_product_id', current_setting('eliscaretex_validation.schedule_product_id'),
        'scheduled_for_date', v_tomorrow
      )
    ),
    'Temporary Snapshot 62 schedule-trace validation.'
  );

  if coalesce(v_result ->> 'status','') <> 'success'
     or coalesce((v_result ->> 'early_customer_count')::integer,0) <> 1 then
    raise exception 'Tomorrow work-ahead wash was not recorded as EARLY: %', v_result;
  end if;

  v_trace := v_result -> 'trace_rows' -> 0;

  if coalesce(v_trace ->> 'schedule_relation','') <> 'EARLY'
     or (v_trace ->> 'scheduled_for_date')::date <> v_tomorrow
     or nullif(v_trace ->> 'scheduled_weekday','') is null
     or not (v_trace ? 'route_color') then
    raise exception 'Trace does not preserve scheduled date/day/route: %', v_trace;
  end if;

  v_washing_context := public.get_sorting_washing_context_v2(
    current_setting('eliscaretex_validation.shift_code')
  );

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_washing_context -> 'recent_washes','[]'::jsonb)) wash_row
    cross join lateral jsonb_array_elements(coalesce(wash_row -> 'customers','[]'::jsonb)) customer_row
    where wash_row ->> 'wash_code' = v_result ->> 'wash_code'
      and (wash_row ->> 'business_date')::date = (now() at time zone 'Europe/Dublin')::date
      and (customer_row ->> 'scheduled_for_date')::date = v_tomorrow
      and customer_row ? 'route_color'
  ) then
    raise exception 'Recent wash context does not expose wash date + scheduled date + customer color.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608100001_sorting_schedule_trace_mop_assignment_and_visual_board_validation',
  'one_mop_assignment_supported',true,
  'today_tomorrow_board_supported',true,
  'tomorrow_wash_recorded_as_early',true,
  'scheduled_weekday_preserved',true,
  'route_color_preserved_in_trace',true,
  'recent_wash_date_supported',true,
  'private_staff_mode_table_protected',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
