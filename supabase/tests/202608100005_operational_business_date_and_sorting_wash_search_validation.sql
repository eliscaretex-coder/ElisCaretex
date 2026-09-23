-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608100005_operational_business_date_and_sorting_wash_search
-- =====================================================================

begin;

do $$
declare
  v_cutoff text;
begin
  select value_json #>> '{}'
  into v_cutoff
  from public.app_config
  where config_key='evening_shift_rollover_time';

  if v_cutoff is distinct from '03:00' then
    raise exception 'Expected default Evening rollover 03:00, found %.',v_cutoff;
  end if;

  if public.operational_business_date_for_shift(
       'EVENING',
       '2026-08-11 01:30:00 Europe/Dublin'::timestamptz
     ) <> date '2026-08-10' then
    raise exception 'Evening 01:30 did not remain on previous Business Date.';
  end if;

  if public.operational_business_date_for_shift(
       'EVENING',
       '2026-08-11 02:59:00 Europe/Dublin'::timestamptz
     ) <> date '2026-08-10' then
    raise exception 'Evening 02:59 did not remain on previous Business Date.';
  end if;

  if public.operational_business_date_for_shift(
       'EVENING',
       '2026-08-11 03:00:00 Europe/Dublin'::timestamptz
     ) <> date '2026-08-11' then
    raise exception 'Evening rollover did not switch at 03:00.';
  end if;

  if public.operational_business_date_for_shift(
       'MORNING',
       '2026-08-11 01:30:00 Europe/Dublin'::timestamptz
     ) <> date '2026-08-11' then
    raise exception 'Morning Business Date must follow calendar date.';
  end if;

  if (
    public.operational_timestamp_for_shift(
      date '2026-08-10','EVENING',time '01:30'
    ) at time zone 'Europe/Dublin'
  )::date <> date '2026-08-11' then
    raise exception 'Evening 01:30 timestamp was not mapped to next calendar date.';
  end if;
end;
$$;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr on sr.staff_id=sm.staff_id and sr.active=true
    join public.roles r on r.role_id=sr.role_id and r.active=true and r.role_code='ADMIN'
    where sm.auth_user_id is not null and sm.deleted_at is null
    order by sm.created_at
    limit 1
  ),
  true
);

select set_config(
  'eliscaretex.validation.washer_code',
  'VS17'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  true
);

insert into public.sorting_washers(
  washer_code,washer_name,capacity_kg,category,active,sort_order,notes,metadata
)
values(
  current_setting('eliscaretex.validation.washer_code'),
  'Validation Search Washer',
  10,
  'VALIDATION',
  true,
  9999,
  'Temporary Snapshot 67 validation washer.',
  '{"validation":true}'::jsonb
);

select set_config(
  'eliscaretex.validation.washer_id',
  (
    select washer_id::text
    from public.sorting_washers
    where washer_code=current_setting('eliscaretex.validation.washer_code')
  ),
  true
);

set local role authenticated;

do $$
declare
  v_shift text := 'MORNING';
  v_staff_context jsonb;
  v_operator uuid;
  v_board jsonb;
  v_customer jsonb;
  v_start time;
  v_saved jsonb;
  v_search jsonb;
  v_context jsonb;
begin
  if has_table_privilege('authenticated','public.sorting_wash_runs','SELECT') then
    raise exception 'sorting_wash_runs must remain private.';
  end if;

  v_staff_context := public.get_sorting_staff_work_context_v2(v_shift);
  if jsonb_array_length(coalesce(v_staff_context->'staff','[]'::jsonb))=0 then
    v_shift := 'EVENING';
    v_staff_context := public.get_sorting_staff_work_context_v2(v_shift);
  end if;

  select nullif(value->>'staff_id','')::uuid
  into v_operator
  from jsonb_array_elements(coalesce(v_staff_context->'staff','[]'::jsonb))
  limit 1;

  if v_operator is null then
    raise exception 'No active Sorting staff available for validation.';
  end if;

  v_board := public.get_sorting_customer_board_v3(v_shift);

  select value
  into v_customer
  from jsonb_array_elements(coalesce(v_board->'customers','[]'::jsonb))
  where value->>'day_relation'='TODAY'
    and value->>'product_code' in ('CLOTHES','MOP')
  limit 1;

  if v_customer is null then
    raise exception 'No current scheduled customer available for validation.';
  end if;

  v_start := case
    when (now() at time zone 'Europe/Dublin')::time > time '00:10'
      then ((now() at time zone 'Europe/Dublin')-interval '5 minutes')::time
    else time '00:00'
  end;

  v_saved := public.save_sorting_wash_run_v2(
    v_shift,
    current_setting('eliscaretex.validation.washer_id')::uuid,
    v_operator,
    v_start,
    1.00,
    v_customer->>'product_code',
    jsonb_build_array(jsonb_build_object(
      'customer_id',v_customer->>'customer_id',
      'schedule_product_id',v_customer->>'schedule_product_id',
      'scheduled_for_date',v_customer->>'scheduled_for_date'
    )),
    'Snapshot 67 search validation.'
  );

  v_search := public.search_sorting_wash_history(
    v_shift,
    v_saved->>'wash_code',
    null,
    null,
    100
  );

  if coalesce((v_search->>'result_count')::integer,0) < 1 then
    raise exception 'Wash ID search did not return the test wash.';
  end if;

  v_search := public.search_sorting_wash_history(
    v_shift,
    v_customer->>'customer_name',
    null,
    null,
    100
  );

  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_search->'washes','[]'::jsonb)) w
    where w->>'wash_code'=v_saved->>'wash_code'
  ) then
    raise exception 'Customer-name search did not return the test wash.';
  end if;

  v_context := public.get_sorting_washing_context_v3(v_shift);

  if (v_context->'operational_clock'->>'business_date')::date
     <> (v_context->>'business_date')::date then
    raise exception 'Washing context Business Date does not match operational clock.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608100005_operational_business_date_and_sorting_wash_search_validation',
  'evening_overnight_business_date',true,
  'rollover_0300',true,
  'cross_midnight_timestamp_mapping',true,
  'shift_aware_customer_board',true,
  'wash_id_search',true,
  'customer_search',true,
  'wash_tables_remain_private',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
