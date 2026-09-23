-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110007_sorting_wash_requires_trolley_contents_scan
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
    from public.staff_members sm
    join public.staff_roles sr
      on sr.staff_id=sm.staff_id
     and sr.active=true
    join public.roles r
      on r.role_id=sr.role_id
     and r.active=true
     and r.role_code='ADMIN'
    where sm.auth_user_id is not null
      and sm.deleted_at is null
    order by sm.created_at
    limit 1
  ),
  true
);

do $$
declare
  v_shift text;
  v_board jsonb;
  v_row_1 jsonb;
  v_row_2 jsonb;
  v_operator_id uuid;
  v_washer_id uuid;
  v_trolley_type_id uuid;
  v_trolley_1 text;
  v_trolley_2 text;
begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is null then
    raise exception 'No ADMIN auth user is available for Validation 027.';
  end if;

  foreach v_shift in array array['MORNING','EVENING'] loop
    v_board := public.get_sorting_customer_board_v3(v_shift);

    select value
    into v_row_1
    from jsonb_array_elements(coalesce(v_board->'customers','[]'::jsonb))
    where value->>'day_relation'='TODAY'
      and value->>'product_code'='CLOTHES'
      and coalesce((value->>'wash_enabled')::boolean,false)=false
    order by
      (value->>'production_order')::integer nulls last,
      value->>'customer_name'
    limit 1;

    select value
    into v_row_2
    from jsonb_array_elements(coalesce(v_board->'customers','[]'::jsonb))
    where value->>'day_relation'='TODAY'
      and value->>'product_code'='CLOTHES'
      and coalesce((value->>'wash_enabled')::boolean,false)=false
      and (v_row_1 is null or value->>'schedule_product_id'<>v_row_1->>'schedule_product_id')
    order by
      (value->>'production_order')::integer nulls last,
      value->>'customer_name'
    limit 1;

    select nullif(staff_row.value->>'staff_id','')::uuid
    into v_operator_id
    from jsonb_array_elements(
      coalesce(public.get_sorting_staff_work_context_v2(v_shift)->'staff','[]'::jsonb)
    ) staff_row
    where staff_row.value->>'staff_id' is not null
      and coalesce(staff_row.value->>'work_mode','CLOTHES')='CLOTHES'
      and coalesce(staff_row.value->>'attendance_status','PLANNED')<>'ABSENT'
    order by staff_row.value->>'display_name'
    limit 1;

    if v_row_1 is not null and v_row_2 is not null and v_operator_id is not null then
      exit;
    end if;
  end loop;

  if v_row_1 is null or v_row_2 is null then
    raise exception 'Need two current TODAY CLOTHES schedule rows without CONTENTS scan evidence for Validation 027.';
  end if;

  if v_operator_id is null then
    raise exception 'Need one active Clothes Sorting operator for Validation 027.';
  end if;

  select sw.washer_id
  into v_washer_id
  from public.sorting_washers sw
  where sw.active=true
    and sw.deleted_at is null
    and sw.capacity_kg>=10
    and coalesce(sw.category,'') in ('CLOTHES','HOUSEHOLD')
  order by sw.sort_order,sw.washer_code
  limit 1;

  if v_washer_id is null then
    raise exception 'Need one active washer with at least 10 KG capacity for Validation 027.';
  end if;

  select tt.trolley_type_id
  into v_trolley_type_id
  from public.trolley_types tt
  where tt.active=true
    and tt.deleted_at is null
  order by tt.sort_order,tt.trolley_type_code
  limit 1;

  if v_trolley_type_id is null then
    raise exception 'Need one active trolley type for Validation 027.';
  end if;

  v_trolley_1 := 'TV27C' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  v_trolley_2 := 'TV27E' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));

  insert into public.trolleys(
    trolley_code,trolley_type_id,status,active,registered_on,notes,metadata
  ) values
    (
      v_trolley_1,v_trolley_type_id,'AT_CUSTOMER',true,current_date,
      'Temporary Validation 027 CONTENTS trolley.',
      '{"validation":27}'::jsonb
    ),
    (
      v_trolley_2,v_trolley_type_id,'AT_CUSTOMER',true,current_date,
      'Temporary Validation 027 EMPTY trolley.',
      '{"validation":27}'::jsonb
    );

  insert into public.trolley_customer_stays(
    trolley_id,outbound_customer_id,sent_on,status,
    confirmation_source,operator_confirmed,review_status,notes
  )
  select
    t.trolley_id,
    (v_row_1->>'customer_id')::uuid,
    current_date-1,
    'OPEN',
    null,false,'NOT_REQUIRED',
    'Validation 027 CONTENTS tracked stay.'
  from public.trolleys t
  where t.trolley_code=v_trolley_1;

  insert into public.trolley_customer_stays(
    trolley_id,outbound_customer_id,sent_on,status,
    confirmation_source,operator_confirmed,review_status,notes
  )
  select
    t.trolley_id,
    (v_row_2->>'customer_id')::uuid,
    current_date-1,
    'OPEN',
    null,false,'NOT_REQUIRED',
    'Validation 027 EMPTY tracked stay.'
  from public.trolleys t
  where t.trolley_code=v_trolley_2;

  perform set_config('eliscaretex.v27.shift',v_shift,true);
  perform set_config('eliscaretex.v27.row_1',v_row_1::text,true);
  perform set_config('eliscaretex.v27.row_2',v_row_2::text,true);
  perform set_config('eliscaretex.v27.operator',v_operator_id::text,true);
  perform set_config('eliscaretex.v27.washer',v_washer_id::text,true);
  perform set_config('eliscaretex.v27.trolley_1',v_trolley_1,true);
  perform set_config('eliscaretex.v27.trolley_2',v_trolley_2,true);
end;
$$;

set local role authenticated;

do $$
declare
  v_shift text := current_setting('eliscaretex.v27.shift');
  v_row_1 jsonb := current_setting('eliscaretex.v27.row_1')::jsonb;
  v_row_2 jsonb := current_setting('eliscaretex.v27.row_2')::jsonb;
  v_operator uuid := current_setting('eliscaretex.v27.operator')::uuid;
  v_washer uuid := current_setting('eliscaretex.v27.washer')::uuid;
  v_trolley_1 text := current_setting('eliscaretex.v27.trolley_1');
  v_trolley_2 text := current_setting('eliscaretex.v27.trolley_2');
  v_start time := case when v_shift='EVENING' then time '18:00' else time '10:00' end;
  v_selection_1 jsonb;
  v_selection_2 jsonb;
  v_result jsonb;
  v_board jsonb;
  v_rejected boolean;
begin
  if has_function_privilege(
    'authenticated',
    'public.sorting_assert_wash_scan_gate(date,text,jsonb)',
    'EXECUTE'
  ) then
    raise exception 'Private wash scan assertion must not be browser-callable.';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.save_sorting_wash_run_v2(text,uuid,uuid,time,numeric,text,jsonb,text)',
    'EXECUTE'
  ) then
    raise exception 'Old save_sorting_wash_run_v2 remains browser-callable and can bypass scan gate.';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.save_sorting_missed_wash_v2(text,uuid,uuid,time,numeric,text,jsonb,text,text)',
    'EXECUTE'
  ) then
    raise exception 'Old save_sorting_missed_wash_v2 remains browser-callable.';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.correct_sorting_wash_run_v2(uuid,integer,text,uuid,uuid,time,numeric,text,jsonb,text,text)',
    'EXECUTE'
  ) then
    raise exception 'Old correct_sorting_wash_run_v2 remains browser-callable.';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.save_sorting_wash_run_v3(text,uuid,uuid,time,numeric,text,jsonb,text)',
    'EXECUTE'
  ) then
    raise exception 'New save_sorting_wash_run_v3 is not browser-callable.';
  end if;

  if has_table_privilege('authenticated','public.sorting_trolley_intakes','SELECT')
     or has_table_privilege('authenticated','public.sorting_trolley_intake_products','SELECT') then
    raise exception 'Trolley Intake source tables must remain private.';
  end if;

  v_selection_1 := jsonb_build_array(jsonb_build_object(
    'customer_id',v_row_1->>'customer_id',
    'schedule_product_id',v_row_1->>'schedule_product_id',
    'scheduled_for_date',v_row_1->>'scheduled_for_date'
  ));

  v_selection_2 := jsonb_build_array(jsonb_build_object(
    'customer_id',v_row_2->>'customer_id',
    'schedule_product_id',v_row_2->>'schedule_product_id',
    'scheduled_for_date',v_row_2->>'scheduled_for_date'
  ));

  -- Before scan, valid washer/operator/customer still MUST be blocked.
  v_rejected := false;
  begin
    perform public.save_sorting_wash_run_v3(
      v_shift,
      v_washer,
      v_operator,
      v_start,
      10,
      'CLOTHES',
      v_selection_1,
      'Validation 027 should be blocked before trolley scan.'
    );
  exception
    when others then
      if sqlstate='22023'
         and position('scan and identify' in lower(sqlerrm))>0 then
        v_rejected:=true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'Washing was incorrectly accepted before Customer CONTENTS scan.';
  end if;

  -- Physical CONTENTS scan unlocks the exact Customer + Date + Product.
  perform public.record_sorting_trolley_intake_v2(
    v_shift,
    v_trolley_1,
    v_operator,
    (v_row_1->>'customer_id')::uuid,
    'CONTENTS',
    (v_row_1->>'scheduled_for_date')::date,
    array['CLOTHES'],
    null,null,
    'Validation 027 CONTENTS scan.'
  );

  v_board := public.get_sorting_customer_board_v3(v_shift);

  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_board->'customers','[]'::jsonb)) row
    where row.value->>'schedule_product_id'=v_row_1->>'schedule_product_id'
      and row.value->>'scheduled_for_date'=v_row_1->>'scheduled_for_date'
      and coalesce((row.value->>'wash_enabled')::boolean,false)
      and (row.value->>'scan_contents_count')::integer>=1
      and row.value->>'wash_gate_status'='READY_TO_WASH'
  ) then
    raise exception 'CONTENTS scan did not unlock the Washing board row.';
  end if;

  v_result := public.save_sorting_wash_run_v3(
    v_shift,
    v_washer,
    v_operator,
    v_start,
    10,
    'CLOTHES',
    v_selection_1,
    'Validation 027 accepted after CONTENTS scan.'
  );

  if nullif(v_result->>'wash_run_id','') is null
     or nullif(v_result->>'wash_code','') is null then
    raise exception 'Washing did not save after valid CONTENTS scan: %',v_result;
  end if;

  -- EMPTY scan must remain locked.
  perform public.record_sorting_trolley_intake_v2(
    v_shift,
    v_trolley_2,
    v_operator,
    (v_row_2->>'customer_id')::uuid,
    'EMPTY',
    (v_row_2->>'scheduled_for_date')::date,
    array['CLOTHES'],
    null,null,
    'Validation 027 EMPTY scan.'
  );

  v_board := public.get_sorting_customer_board_v3(v_shift);

  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_board->'customers','[]'::jsonb)) row
    where row.value->>'schedule_product_id'=v_row_2->>'schedule_product_id'
      and row.value->>'scheduled_for_date'=v_row_2->>'scheduled_for_date'
      and coalesce((row.value->>'wash_enabled')::boolean,false)=false
      and (row.value->>'scan_empty_count')::integer>=1
      and row.value->>'wash_gate_status'='EMPTY_ONLY'
  ) then
    raise exception 'EMPTY scan incorrectly unlocked Washing board row.';
  end if;

  v_rejected := false;
  begin
    perform public.save_sorting_wash_run_v3(
      v_shift,
      v_washer,
      v_operator,
      v_start,
      10,
      'CLOTHES',
      v_selection_2,
      'Validation 027 EMPTY must stay blocked.'
    );
  exception
    when others then
      if sqlstate='22023'
         and position('only empty trolley receipt evidence' in lower(sqlerrm))>0 then
        v_rejected:=true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'EMPTY trolley receipt incorrectly unlocked Washing.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status','PASS',
  'test','202608110007_sorting_wash_requires_trolley_contents_scan_validation',
  'pre_scan_washing_blocked',true,
  'contents_scan_unlocks_exact_customer_date_product',true,
  'washing_saves_after_contents_scan',true,
  'empty_scan_does_not_unlock_washing',true,
  'board_exposes_scan_gate_state',true,
  'old_browser_write_versions_revoked',true,
  'private_scan_assertion_not_browser_callable',true,
  'trolley_intake_tables_remain_private',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
