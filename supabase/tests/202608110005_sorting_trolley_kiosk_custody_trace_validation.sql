-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608110005_sorting_trolley_kiosk_custody_trace
--
-- Supersedes the failed Validation 024 scenario selection.
-- Migration 024 is already applied and must not be rerun.
-- =====================================================================

begin;

-- Re-check core 024 state semantics.
do $$
begin
  if public.sorting_trolley_intake_state(2,1,0,1,0,0) <> 'RECEIVED' then
    raise exception 'Partial empty receipt must not mean Nothing to wash.';
  end if;
  if public.sorting_trolley_intake_state(1,1,0,1,0,0) <> 'NOTHING_TO_WASH' then
    raise exception 'All known/planned empty receipts should mean Nothing to wash.';
  end if;
  if public.sorting_trolley_intake_state(1,1,0,1,1,0) <> 'WASHING_RECORDED' then
    raise exception 'Recorded washing must outrank empty receipt state.';
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
  v_context jsonb;
  v_board_row jsonb;
  v_operator_id uuid;
  v_business_date date;
  v_shift_id uuid;
  v_trolley_type_id uuid;
  v_code_tracked text;
  v_code_missing text;
  v_code_swap text;
  v_other_customer_id uuid;
begin
  foreach v_shift in array array['MORNING','EVENING'] loop
    v_context := public.get_sorting_trolley_intake_context_v2(v_shift);
    v_business_date := public.operational_business_date_for_shift(v_shift);

    select sh.shift_id
    into v_shift_id
    from public.shifts sh
    where sh.shift_code=v_shift
      and sh.active=true
      and sh.deleted_at is null
    limit 1;

    select value
    into v_board_row
    from jsonb_array_elements(coalesce(v_context->'board','[]'::jsonb))
    where value->>'day_relation'='TODAY'
    order by
      case value->>'product_code' when 'CLOTHES' then 1 else 2 end,
      (value->>'production_order')::integer nulls last,
      value->>'customer_name'
    limit 1;

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
    raise exception 'Need one TODAY scheduled customer/product for Validation 025.';
  end if;

  if v_operator_id is null then
    raise exception 'Need one Sorting operator with zero RECORDED washes for Validation 025.';
  end if;

  select c.customer_id
  into v_other_customer_id
  from public.customers c
  where c.active=true
    and c.deleted_at is null
    and c.customer_id<>(v_board_row->>'customer_id')::uuid
  order by c.customer_name
  limit 1;

  if v_other_customer_id is null then
    raise exception 'Need a second active customer for trolley-swap validation.';
  end if;

  select tt.trolley_type_id
  into v_trolley_type_id
  from public.trolley_types tt
  where tt.active=true
  order by tt.trolley_type_code
  limit 1;

  if v_trolley_type_id is null then
    raise exception 'Need one active trolley type for Validation 025.';
  end if;

  v_code_tracked := 'TV25A' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  v_code_missing := 'TV25B' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  v_code_swap := 'TV25C' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));

  insert into public.trolleys(
    trolley_code,trolley_type_id,status,active,registered_on,notes,metadata
  ) values
    (v_code_tracked,v_trolley_type_id,'AT_CUSTOMER',true,current_date,'Validation 025 tracked trolley.','{"validation":true}'::jsonb),
    (v_code_missing,v_trolley_type_id,'AVAILABLE',true,current_date,'Validation 025 missing-outbound trolley.','{"validation":true}'::jsonb),
    (v_code_swap,v_trolley_type_id,'AT_CUSTOMER',true,current_date,'Validation 025 swapped trolley.','{"validation":true}'::jsonb);

  insert into public.trolley_customer_stays(
    trolley_id,outbound_customer_id,sent_on,status,
    confirmation_source,operator_confirmed,review_status,notes
  )
  select t.trolley_id,(v_board_row->>'customer_id')::uuid,current_date-3,'OPEN',
         null,false,'NOT_REQUIRED','Validation 025 tracked stay.'
  from public.trolleys t where t.trolley_code=v_code_tracked;

  insert into public.trolley_customer_stays(
    trolley_id,outbound_customer_id,sent_on,status,
    confirmation_source,operator_confirmed,review_status,notes
  )
  select t.trolley_id,v_other_customer_id,current_date-2,'OPEN',
         null,false,'NOT_REQUIRED','Validation 025 trolley-swap tracked stay.'
  from public.trolleys t where t.trolley_code=v_code_swap;

  perform set_config('eliscaretex.v25.shift',v_shift,true);
  perform set_config('eliscaretex.v25.operator',v_operator_id::text,true);
  perform set_config('eliscaretex.v25.row',v_board_row::text,true);
  perform set_config('eliscaretex.v25.code_tracked',v_code_tracked,true);
  perform set_config('eliscaretex.v25.code_missing',v_code_missing,true);
  perform set_config('eliscaretex.v25.code_swap',v_code_swap,true);
  perform set_config('eliscaretex.v25.other_customer',v_other_customer_id::text,true);
end;
$$;

set local role authenticated;

do $$
declare
  v_shift text := current_setting('eliscaretex.v25.shift');
  v_operator uuid := current_setting('eliscaretex.v25.operator')::uuid;
  v_row jsonb := current_setting('eliscaretex.v25.row')::jsonb;
  v_code_tracked text := current_setting('eliscaretex.v25.code_tracked');
  v_code_missing text := current_setting('eliscaretex.v25.code_missing');
  v_code_swap text := current_setting('eliscaretex.v25.code_swap');
  v_other_customer uuid := current_setting('eliscaretex.v25.other_customer')::uuid;
  v_preview jsonb;
  v_result jsonb;
  v_trace jsonb;
  v_flow_id uuid;
  v_rejected boolean := false;
begin
  if has_table_privilege('authenticated','public.sorting_trolley_intakes','SELECT') then
    raise exception 'sorting_trolley_intakes must remain private.';
  end if;

  -- 1) Tracked stay: exact physical trolley Days out.
  v_preview := public.get_sorting_trolley_intake_preview_v2(v_shift,v_code_tracked);

  if v_preview->'custody'->>'tracking_status'<>'TRACKED'
     or (v_preview->'custody'->>'days_at_customer')::integer<>3
     or v_preview->'custody'->>'customer_id'<>v_row->>'customer_id' then
    raise exception 'Tracked trolley preview does not expose correct custody evidence: %',v_preview;
  end if;

  v_result := public.record_sorting_trolley_intake_v2(
    v_shift,
    v_code_tracked,
    v_operator,
    (v_row->>'customer_id')::uuid,
    'CONTENTS',
    (v_row->>'scheduled_for_date')::date,
    array[v_row->>'product_code'],
    null,
    null,
    null
  );

  if v_result->>'custody_tracking_status'<>'TRACKED_MATCH'
     or (v_result->>'tracked_days_at_customer')::integer<>3
     or v_result->>'trolley_status_after_receipt'<>'AVAILABLE' then
    raise exception 'Tracked receipt result is incorrect: %',v_result;
  end if;

  v_flow_id := (v_result->'products'->0->>'production_flow_item_id')::uuid;
  v_trace := public.get_production_flow_trace(v_flow_id);

  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_trace->'events','[]'::jsonb)) e
    where e.value->>'event_type'='TROLLEY_RECEIVED_CONTENTS'
      and e.value->'event_data'->>'trolley_code'=v_code_tracked
      and (e.value->'event_data'->>'tracked_days_at_customer')::integer=3
      and e.value->'event_data'->>'custody_tracking_status'='TRACKED_MATCH'
  ) then
    raise exception 'Production Flow event lacks tracked trolley Days out evidence.';
  end if;

  -- 2) Missing outbound: receive is allowed, but Days out stays unavailable.
  v_result := public.record_sorting_trolley_intake_v2(
    v_shift,
    v_code_missing,
    v_operator,
    (v_row->>'customer_id')::uuid,
    'EMPTY',
    (v_row->>'scheduled_for_date')::date,
    array[v_row->>'product_code'],
    null,
    null,
    null
  );

  if v_result->>'custody_tracking_status'<>'MISSING_OUTBOUND_RECORD'
     or v_result->>'tracked_days_at_customer' is not null
     or v_result->>'review_status'<>'PENDING'
     or v_result->>'trolley_status_after_receipt'<>'AVAILABLE' then
    raise exception 'Missing-outbound receipt fabricated custody evidence or failed review semantics: %',v_result;
  end if;

  -- 3) Trolley/content swap: Days out remains attached to tracked customer,
  -- while contents are linked to the confirmed production customer.
  v_result := public.record_sorting_trolley_intake_v2(
    v_shift,
    v_code_swap,
    v_operator,
    (v_row->>'customer_id')::uuid,
    'CONTENTS',
    (v_row->>'scheduled_for_date')::date,
    array[v_row->>'product_code'],
    'TROLLEY_CHANGED_BEFORE_SCAN',
    null,
    null
  );

  if v_result->>'custody_tracking_status'<>'TRACKED_CUSTOMER_MISMATCH'
     or (v_result->>'tracked_days_at_customer')::integer<>2
     or v_result->>'tracked_outbound_customer_id'<>v_other_customer::text then
    raise exception 'Trolley-swap receipt incorrectly reassigned custody evidence: %',v_result;
  end if;

  -- This operator had zero washes, therefore the rejection below must now be
  -- caused by actual Trolley Intake evidence rather than the washing guard.
  v_rejected := false;
  begin
    perform public.set_sorting_staff_attendance(
      v_shift,v_operator,'ABSENT','NO_SHOW',
      'Validation 025 must fail because trolley intake proves presence.'
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
    raise exception 'Trolley Intake operator was incorrectly allowed to become absent.';
  end if;
end;
$$;

reset role;

do $$
declare
  v_code_tracked text := current_setting('eliscaretex.v25.code_tracked');
  v_code_missing text := current_setting('eliscaretex.v25.code_missing');
  v_code_swap text := current_setting('eliscaretex.v25.code_swap');
  v_intake record;
begin
  select sti.*
  into v_intake
  from public.sorting_trolley_intakes sti
  where sti.trolley_code_snapshot=v_code_tracked
  limit 1;

  if v_intake.custody_tracking_status<>'TRACKED_MATCH'
     or v_intake.tracked_days_at_customer<>3 then
    raise exception 'Tracked custody snapshot was not persisted correctly.';
  end if;

  if not exists(
    select 1 from public.trolleys t
    where t.trolley_code in (v_code_tracked,v_code_missing,v_code_swap)
      and t.status='AVAILABLE'
  ) then
    raise exception 'At least one received test trolley did not become AVAILABLE.';
  end if;

  if exists(
    select 1 from public.sorting_trolley_intakes sti
    where sti.trolley_code_snapshot=v_code_missing
      and sti.tracked_days_at_customer is not null
  ) then
    raise exception 'Missing outbound trolley received fabricated Days out.';
  end if;

  if not exists(
    select 1 from public.sorting_trolley_intakes sti
    where sti.trolley_code_snapshot=v_code_swap
      and sti.custody_tracking_status='TRACKED_CUSTOMER_MISMATCH'
      and sti.customer_override_code='TROLLEY_CHANGED_BEFORE_SCAN'
      and sti.tracked_days_at_customer=2
  ) then
    raise exception 'Trolley-before-scan swap evidence was not persisted.';
  end if;
end;
$$;

select jsonb_build_object(
  'status','PASS',
  'test','202608110005_sorting_trolley_kiosk_custody_trace_validation',
  'migration024_core_states_rechecked',true,
  'tracked_days_out_exact',true,
  'missing_outbound_days_unknown',true,
  'trolley_swap_does_not_reassign_days',true,
  'trolley_available_after_receipt',true,
  'production_flow_receipt_has_custody_evidence',true,
  'trolley_intake_is_presence_evidence',true,
  'private_intake_table_protected',true,
  'writes_rolled_back',true
) as validation_result;

rollback;
