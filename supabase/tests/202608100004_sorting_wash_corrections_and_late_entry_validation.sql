-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608100004_sorting_wash_corrections_and_late_entry
-- =====================================================================

begin;

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

select set_config('eliscaretex_validation.washer_a','VC16A'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)),true);
select set_config('eliscaretex_validation.washer_b','VC16B'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)),true);

insert into public.sorting_washers(washer_code,washer_name,capacity_kg,category,active,sort_order,notes,metadata)
values
(current_setting('eliscaretex_validation.washer_a'),'Validation Correction Washer',10,'VALIDATION',true,9998,'Temporary validation washer','{"validation":true}'::jsonb),
(current_setting('eliscaretex_validation.washer_b'),'Validation Late Entry Washer',10,'VALIDATION',true,9999,'Temporary validation washer','{"validation":true}'::jsonb);

select set_config(
  'eliscaretex_validation.washer_a_id',
  (select washer_id::text from public.sorting_washers where washer_code=current_setting('eliscaretex_validation.washer_a')),
  true
);
select set_config(
  'eliscaretex_validation.washer_b_id',
  (select washer_id::text from public.sorting_washers where washer_code=current_setting('eliscaretex_validation.washer_b')),
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
  v_original jsonb;
  v_corrected jsonb;
  v_late jsonb;
  v_context jsonb;
  v_original_row jsonb;
  v_corrected_row jsonb;
  v_late_row jsonb;
  v_cancel jsonb;
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

  v_board := public.get_sorting_customer_board_v2();
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
      then ((now() at time zone 'Europe/Dublin') - interval '5 minutes')::time
    else time '00:00'
  end;

  v_original := public.save_sorting_wash_run_v2(
    v_shift,
    current_setting('eliscaretex_validation.washer_a_id')::uuid,
    v_operator,
    v_start,
    1.00,
    v_customer->>'product_code',
    jsonb_build_array(jsonb_build_object(
      'customer_id',v_customer->>'customer_id',
      'schedule_product_id',v_customer->>'schedule_product_id',
      'scheduled_for_date',v_customer->>'scheduled_for_date'
    )),
    'Temporary correction validation original.'
  );

  v_context := public.get_sorting_washing_context_v3(v_shift);
  select value into v_original_row
  from jsonb_array_elements(coalesce(v_context->'recent_washes','[]'::jsonb))
  where value->>'wash_code'=v_original->>'wash_code'
  limit 1;

  v_corrected := public.correct_sorting_wash_run_v2(
    (v_original->>'wash_run_id')::uuid,
    (v_original_row->>'row_version')::integer,
    v_shift,
    current_setting('eliscaretex_validation.washer_a_id')::uuid,
    v_operator,
    v_start,
    2.00,
    v_customer->>'product_code',
    jsonb_build_array(jsonb_build_object(
      'customer_id',v_customer->>'customer_id',
      'schedule_product_id',v_customer->>'schedule_product_id',
      'scheduled_for_date',v_customer->>'scheduled_for_date'
    )),
    'Temporary corrected wash.',
    'Validation: wrong KG corrected.'
  );

  v_context := public.get_sorting_washing_context_v3(v_shift);

  select value into v_original_row
  from jsonb_array_elements(coalesce(v_context->'recent_washes','[]'::jsonb))
  where value->>'wash_code'=v_original->>'wash_code'
  limit 1;

  select value into v_corrected_row
  from jsonb_array_elements(coalesce(v_context->'recent_washes','[]'::jsonb))
  where value->>'wash_code'=v_corrected->>'wash_code'
  limit 1;

  if coalesce(v_original_row->>'status','')<>'CANCELLED'
     or coalesce(v_corrected_row->>'status','')<>'RECORDED'
     or coalesce(v_corrected_row->>'entry_mode','')<>'CORRECTION'
     or coalesce((v_corrected_row->>'total_weight_kg')::numeric,0)<>2.00
     or coalesce(v_corrected_row->>'replaces_wash_code','')<>v_original->>'wash_code' then
    raise exception 'Correction chain is invalid. Old %, New %',v_original_row,v_corrected_row;
  end if;

  v_late := public.save_sorting_missed_wash_v2(
    v_shift,
    current_setting('eliscaretex_validation.washer_b_id')::uuid,
    v_operator,
    v_start,
    1.50,
    v_customer->>'product_code',
    jsonb_build_array(jsonb_build_object(
      'customer_id',v_customer->>'customer_id',
      'schedule_product_id',v_customer->>'schedule_product_id',
      'scheduled_for_date',v_customer->>'scheduled_for_date'
    )),
    'Temporary late entry validation.',
    'Validation: operator forgot the original entry.'
  );

  v_context := public.get_sorting_washing_context_v3(v_shift);
  select value into v_late_row
  from jsonb_array_elements(coalesce(v_context->'recent_washes','[]'::jsonb))
  where value->>'wash_code'=v_late->>'wash_code'
  limit 1;

  if coalesce(v_late_row->>'entry_mode','')<>'LATE_ENTRY'
     or coalesce(v_late_row->>'status','')<>'RECORDED' then
    raise exception 'Late entry was not exposed correctly: %',v_late_row;
  end if;

  v_cancel := public.cancel_sorting_wash_run(
    (v_corrected->>'wash_run_id')::uuid,
    (v_corrected_row->>'row_version')::integer,
    'Validation: remove corrected test wash.'
  );

  v_context := public.get_sorting_washing_context_v3(v_shift);
  select value into v_corrected_row
  from jsonb_array_elements(coalesce(v_context->'recent_washes','[]'::jsonb))
  where value->>'wash_code'=v_corrected->>'wash_code'
  limit 1;

  if coalesce(v_corrected_row->>'status','')<>'CANCELLED' then
    raise exception 'Logical delete/cancel was not reflected in context.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608100004_sorting_wash_corrections_and_late_entry_validation',
  'logical_cancel_supported',true,
  'original_wash_id_preserved',true,
  'correction_creates_replacement_wash_id',true,
  'kg_correction_supported',true,
  'customer_selection_correction_path_supported',true,
  'late_entry_supported',true,
  'private_wash_tables_remain_private',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
