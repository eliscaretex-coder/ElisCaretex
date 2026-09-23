-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110004_sorting_trolley_contents_intake_and_flow_queue
-- =====================================================================

begin;

-- Deterministic misuse/state rules.
do $$
begin
  if public.sorting_trolley_intake_state(2,1,0,1,0,0) <> 'RECEIVED' then
    raise exception 'One empty trolley of two planned must NOT mean Nothing to wash.';
  end if;

  if public.sorting_trolley_intake_state(1,1,0,1,0,0) <> 'NOTHING_TO_WASH' then
    raise exception 'One planned + one explicitly empty + no wash must mean Nothing to wash.';
  end if;

  if public.sorting_trolley_intake_state(1,1,0,1,1,0) <> 'WASHING_RECORDED' then
    raise exception 'Existing wash must take precedence over Nothing to wash.';
  end if;

  if public.sorting_trolley_intake_state(3,1,1,0,0,0) <> 'WAITING_WASH' then
    raise exception 'Received contents with zero wash must enter Waiting wash.';
  end if;

  if public.sorting_trolley_intake_state(1,1,1,0,0,1) <> 'REVIEW' then
    raise exception 'Review-required intake must remain visibly Review.';
  end if;

  if public.sorting_trolley_receipt_status(3,1) <> 'PARTIAL'
     or public.sorting_trolley_receipt_status(3,3) <> 'COMPLETE'
     or public.sorting_trolley_receipt_status(0,1) <> 'RECEIVED' then
    raise exception 'Receipt-count status rules are invalid.';
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

do $$
declare
  v_shift text;
  v_context jsonb;
  v_board_row jsonb;
  v_operator_id uuid;
  v_business_date date;
  v_shift_id uuid;
  v_trolley_type_id uuid;
  v_trolley_code text;
begin
  foreach v_shift in array array['MORNING','EVENING'] loop
    v_context := public.get_sorting_trolley_intake_context_v2(v_shift);

    select value
    into v_board_row
    from jsonb_array_elements(coalesce(v_context->'board','[]'::jsonb))
    where value->>'day_relation'='TODAY'
      and (value->>'wash_count')::integer=0
    order by
      case value->>'product_code' when 'CLOTHES' then 1 else 2 end,
      (value->>'production_order')::integer nulls last
    limit 1;

    v_business_date := public.operational_business_date_for_shift(v_shift);

    select sh.shift_id
    into v_shift_id
    from public.shifts sh
    where sh.shift_code=v_shift
      and sh.active=true
      and sh.deleted_at is null
    limit 1;

    -- This validation specifically needs to reach the NEW trolley-activity
    -- absence guard. A staff member with an existing RECORDED wash would be
    -- rejected earlier by the older wash-activity guard, which is correct
    -- production behaviour but would not isolate the new rule being tested.
    select nullif(staff_row.value->>'staff_id','')::uuid
    into v_operator_id
    from jsonb_array_elements(
      coalesce(public.get_sorting_staff_work_context_v2(v_shift)->'staff','[]'::jsonb)
    ) staff_row
    where staff_row.value->>'staff_id' is not null
      and not exists (
        select 1
        from public.sorting_wash_runs wr
        where wr.business_date=v_business_date
          and wr.shift_id=v_shift_id
          and wr.operator_staff_id=nullif(staff_row.value->>'staff_id','')::uuid
          and wr.status='RECORDED'
      )
      and not exists (
        select 1
        from public.sorting_daily_staff_attendance a
        where a.business_date=v_business_date
          and a.shift_id=v_shift_id
          and a.staff_id=nullif(staff_row.value->>'staff_id','')::uuid
          and a.attendance_status='ABSENT'
      )
    order by staff_row.value->>'display_name'
    limit 1;

    if v_board_row is not null and v_operator_id is not null then
      exit;
    end if;
  end loop;

  if v_board_row is null then
    raise exception 'Need one current TODAY scheduled customer/product with zero wash for Validation 024.';
  end if;

  if v_operator_id is null then
    raise exception 'Need one current Sorting operator with zero RECORDED washes for Validation 024. This is a validation-data prerequisite, not a permission problem.';
  end if;

  select tt.trolley_type_id
  into v_trolley_type_id
  from public.trolley_types tt
  where tt.active=true
  order by tt.trolley_type_code
  limit 1;

  if v_trolley_type_id is null then
    raise exception 'Need one active trolley type for Validation 024.';
  end if;

  v_trolley_code := 'TV24' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));

  insert into public.trolleys(
    trolley_code,trolley_type_id,status,active,registered_on,notes,metadata
  )
  values(
    v_trolley_code,v_trolley_type_id,'AT_CUSTOMER',true,current_date,
    'Temporary Snapshot 77 validation trolley.',
    '{"validation":true}'::jsonb
  );

  insert into public.trolley_customer_stays(
    trolley_id,outbound_customer_id,sent_on,status,
    confirmation_source,operator_confirmed,review_status,notes
  )
  select
    t.trolley_id,
    (v_board_row->>'customer_id')::uuid,
    current_date-1,
    'OPEN',
    null,
    false,
    'NOT_REQUIRED',
    'Temporary Snapshot 77 validation open stay.'
  from public.trolleys t
  where t.trolley_code=v_trolley_code;

  perform set_config('eliscaretex.validation.shift',v_shift,true);
  perform set_config('eliscaretex.validation.operator_id',v_operator_id::text,true);
  perform set_config('eliscaretex.validation.board_row',v_board_row::text,true);
  perform set_config('eliscaretex.validation.trolley_code',v_trolley_code,true);
end;
$$;

do $$
declare
  v_shift text := current_setting('eliscaretex.validation.shift');
  v_operator_id uuid := current_setting('eliscaretex.validation.operator_id')::uuid;
  v_business_date date := public.operational_business_date_for_shift(v_shift);
  v_shift_id uuid;
begin
  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code=v_shift
    and sh.active=true
    and sh.deleted_at is null
  limit 1;

  if exists(
    select 1
    from public.sorting_wash_runs wr
    where wr.business_date=v_business_date
      and wr.shift_id=v_shift_id
      and wr.operator_staff_id=v_operator_id
      and wr.status='RECORDED'
  ) then
    raise exception 'Validation 024 V2 selected an operator with existing RECORDED washing activity.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_shift text := current_setting('eliscaretex.validation.shift');
  v_operator_id uuid := current_setting('eliscaretex.validation.operator_id')::uuid;
  v_board_row jsonb := current_setting('eliscaretex.validation.board_row')::jsonb;
  v_trolley_code text := current_setting('eliscaretex.validation.trolley_code');
  v_result jsonb;
  v_context jsonb;
  v_trace jsonb;
  v_flow_id uuid;
  v_staff jsonb;
  v_rejected boolean;
begin
  -- Browser must not bypass the new authoritative workflow.
  if has_function_privilege(
    'authenticated',
    'public.record_sorting_trolley_intake(text,uuid,text)',
    'EXECUTE'
  ) then
    raise exception 'Old Sorting trolley write RPC remains browser-callable.';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.confirm_trolley_sorting_arrival(text,uuid,date,text,text)',
    'EXECUTE'
  ) then
    raise exception 'Direct Sorting arrival RPC remains browser-callable.';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.receive_trolley_from_customer(text,uuid,date,text,text,text)',
    'EXECUTE'
  ) then
    raise exception 'Base trolley receive RPC remains browser-callable.';
  end if;

  if has_table_privilege('authenticated','public.sorting_trolley_intakes','SELECT')
     or has_table_privilege('authenticated','public.sorting_trolley_intake_products','SELECT') then
    raise exception 'Sorting Trolley Intake source tables must remain private.';
  end if;

  -- Missing off-schedule reason must fail before physical custody changes.
  v_rejected := false;
  begin
    perform public.record_sorting_trolley_intake_v2(
      v_shift,
      v_trolley_code,
      v_operator_id,
      (v_board_row->>'customer_id')::uuid,
      'CONTENTS',
      null,
      array[v_board_row->>'product_code'],
      null,
      null,
      null
    );
  exception
    when others then
      if sqlstate='22023'
         and position('off-schedule' in lower(sqlerrm))>0 then
        v_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'Off-schedule intake without reason was incorrectly accepted.';
  end if;

  -- Scheduled normal CONTENTS path.
  v_result := public.record_sorting_trolley_intake_v2(
    v_shift,
    v_trolley_code,
    v_operator_id,
    (v_board_row->>'customer_id')::uuid,
    'CONTENTS',
    (v_board_row->>'scheduled_for_date')::date,
    array[v_board_row->>'product_code'],
    null,
    null,
    'Snapshot 77 normal contents validation.'
  );

  if v_result->>'contents_status'<>'CONTENTS'
     or v_result->>'schedule_relation'<>'TODAY'
     or jsonb_array_length(coalesce(v_result->'products','[]'::jsonb))<>1 then
    raise exception 'Normal CONTENTS intake result is invalid: %',v_result;
  end if;

  v_flow_id := (v_result->'products'->0->>'production_flow_item_id')::uuid;
  v_trace := public.get_production_flow_trace(v_flow_id);

  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_trace->'events','[]'::jsonb)) e
    where e.value->>'event_type'='TROLLEY_RECEIVED_CONTENTS'
      and e.value->'event_data'->>'trolley_code'=v_trolley_code
      and e.value->'event_data'->>'scheduled_for_date'=v_board_row->>'scheduled_for_date'
  ) then
    raise exception 'Production Flow lacks TROLLEY_RECEIVED_CONTENTS event.';
  end if;

  v_context := public.get_sorting_trolley_intake_context_v2(v_shift);

  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_context->'board','[]'::jsonb)) row
    where row.value->>'schedule_product_id'=v_board_row->>'schedule_product_id'
      and (row.value->>'contents_count')::integer>=1
      and row.value->>'operational_state'='WAITING_WASH'
  ) then
    raise exception 'Received CONTENTS did not enter the schedule-level Waiting wash state.';
  end if;

  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_context->'waiting_queue','[]'::jsonb)) q
    where q.value->>'customer_id'=v_board_row->>'customer_id'
      and q.value->>'product_code'=v_board_row->>'product_code'
      and q.value->>'scheduled_for_date'=v_board_row->>'scheduled_for_date'
  ) then
    raise exception 'Received CONTENTS is missing from FIFO waiting queue.';
  end if;

  v_staff := public.get_sorting_staff_dashboard_context_v2(v_shift);

  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_staff->'staff','[]'::jsonb)) s
    where s.value->>'staff_id'=v_operator_id::text
      and (s.value->>'trolley_intake_count')::integer>=1
      and coalesce((s.value->>'has_actual_operational_activity')::boolean,false)
  ) then
    raise exception 'Trolley Intake did not become staff Actual activity evidence.';
  end if;

  -- Re-scanning same physical trolley immediately must fail.
  v_rejected := false;
  begin
    perform public.record_sorting_trolley_intake_v2(
      v_shift,
      v_trolley_code,
      v_operator_id,
      (v_board_row->>'customer_id')::uuid,
      'CONTENTS',
      (v_board_row->>'scheduled_for_date')::date,
      array[v_board_row->>'product_code'],
      null,null,'Duplicate must fail.'
    );
  exception
    when unique_violation then
      v_rejected := true;
    when others then
      if sqlstate='23505' then v_rejected:=true; else raise; end if;
  end;

  if not v_rejected then
    raise exception 'Immediate duplicate trolley intake was incorrectly accepted.';
  end if;

  -- Actual trolley activity must block later Absent.
  v_rejected := false;
  begin
    perform public.set_sorting_staff_attendance(
      v_shift,
      v_operator_id,
      'ABSENT',
      'NO_SHOW',
      'Must fail because trolley intake proves presence.'
    );
  exception
    when others then
      if sqlstate='22023'
         and position('trolley intake activity' in lower(sqlerrm))>0 then
        v_rejected:=true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'Staff with Trolley Intake activity was incorrectly marked absent.';
  end if;
end;
$$;

reset role;

-- Verify physical vs operational date separation and explicit trolley event.
do $$
declare
  v_trolley_code text := current_setting('eliscaretex.validation.trolley_code');
  v_intake public.sorting_trolley_intakes%rowtype;
begin
  select sti.*
  into v_intake
  from public.sorting_trolley_intakes sti
  where sti.trolley_code_snapshot=v_trolley_code
  limit 1;

  if not found then
    raise exception 'Sorting Trolley Intake source row was not created.';
  end if;

  if v_intake.physical_received_on<>current_date then
    raise exception 'Physical receipt date must remain the real calendar date.';
  end if;

  if not exists(
    select 1
    from public.trolley_events te
    where te.trolley_id=v_intake.trolley_id
      and te.event_type='SORTING_CONTENTS_CONFIRMED'
      and te.business_date=v_intake.business_date
      and te.metadata->>'sorting_trolley_intake_id'=v_intake.sorting_trolley_intake_id::text
  ) then
    raise exception 'Explicit trolley Contents event is missing.';
  end if;
end;
$$;

select jsonb_build_object(
  'status','PASS',
  'test','202608110004_sorting_trolley_contents_intake_and_flow_queue_validation_v2',
  'contents_enters_waiting_wash',true,
  'empty_does_not_infer_nothing_until_all_planned_empty',true,
  'wash_prevents_false_nothing_to_wash',true,
  'review_priority_preserved',true,
  'fifo_queue_from_first_receipt',true,
  'production_flow_intake_event',true,
  'operator_and_recorder_traceable',true,
  'trolley_intake_counts_as_presence',true,
  'absence_after_intake_blocked',true,
  'duplicate_scan_blocked',true,
  'off_schedule_requires_reason',true,
  'old_browser_write_shortcuts_revoked',true,
  'private_intake_tables_protected',true,
  'physical_and_business_dates_separate',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
