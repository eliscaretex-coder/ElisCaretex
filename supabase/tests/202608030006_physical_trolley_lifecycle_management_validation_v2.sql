-- =====================================================================
-- ElisCaretex V2
-- Validation V2:
-- 202608030006_physical_trolley_lifecycle_management_validation_v2.sql
--
-- V2 correction:
--   - removes the temporary trolley_lifecycle_test_state table;
--   - stores validation identifiers in transaction-local custom settings;
--   - remains compatible after SET LOCAL ROLE authenticated;
--   - all validation writes are rolled back.
--
-- Covered:
--   - controlled RPC and direct-table access boundary;
--   - physical trolley registration;
--   - one-open-stay enforcement;
--   - normal dispatch and receipt;
--   - receipt without outbound record with sent_on kept NULL;
--   - reconciliation review lifecycle;
--   - out-of-service and return-to-service controls;
--   - dashboard and detailed history read models;
--   - all validation writes are rolled back.
-- =====================================================================

begin;

-- Resolve one active ADMIN so every protected operation can be exercised.
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

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;

  if not exists (
    select 1
    from public.trolley_types tt
    where tt.active = true
      and tt.deleted_at is null
  ) then
    raise exception 'No active trolley type exists for validation.';
  end if;

  if not exists (
    select 1
    from public.customers c
    where c.active = true
      and c.deleted_at is null
  ) then
    raise exception 'No active customer exists for validation.';
  end if;
end;
$$;

-- Store all validation state in transaction-local custom settings. This is
-- deliberately independent from temporary-table visibility and search_path.
select set_config(
  'eliscaretex_validation.trolley_code',
  'VALIDATION-TROLLEY-' || upper(substr(gen_random_uuid()::text, 1, 8)),
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
  'eliscaretex_validation.customer_id',
  (
    select c.customer_id::text
    from public.customers c
    where c.active = true
      and c.deleted_at is null
    order by c.customer_name
    limit 1
  ),
  true
);

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Controlled access boundary and capabilities
-- ---------------------------------------------------------------------

do $$
declare
  v_capabilities jsonb;
  v_reference jsonb;
begin
  if has_table_privilege('authenticated', 'public.trolleys', 'SELECT')
     or has_table_privilege('authenticated', 'public.trolleys', 'INSERT')
     or has_table_privilege('authenticated', 'public.trolleys', 'UPDATE')
     or has_table_privilege('authenticated', 'public.trolley_customer_stays', 'SELECT')
     or has_table_privilege('authenticated', 'public.trolley_customer_stays', 'INSERT')
     or has_table_privilege('authenticated', 'public.trolley_events', 'SELECT') then
    raise exception 'Authenticated still has direct trolley table access.';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.get_trolley_dashboard(text,text)',
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    'public.send_trolley_to_customer(text,uuid,date,text,text)',
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    'public.receive_trolley_from_customer(text,uuid,date,text,text,text)',
    'EXECUTE'
  ) then
    raise exception 'Required controlled trolley RPC privilege is missing.';
  end if;

  v_capabilities := public.get_trolley_lifecycle_capabilities();

  if coalesce((v_capabilities ->> 'can_view_trolleys')::boolean, false) is false
     or coalesce((v_capabilities ->> 'can_dispatch_trolleys')::boolean, false) is false
     or coalesce((v_capabilities ->> 'can_receive_trolleys')::boolean, false) is false
     or coalesce((v_capabilities ->> 'can_review_trolley_exceptions')::boolean, false) is false
     or coalesce((v_capabilities ->> 'can_manage_trolley_master')::boolean, false) is false then
    raise exception 'ADMIN trolley capabilities are incomplete.';
  end if;

  v_reference := public.get_trolley_reference_data();

  if jsonb_array_length(coalesce(v_reference -> 'customers', '[]'::jsonb)) = 0
     or jsonb_array_length(coalesce(v_reference -> 'trolley_types', '[]'::jsonb)) = 0 then
    raise exception 'Trolley reference data is incomplete.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Register a temporary physical trolley
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.trolley_id',
  public.register_physical_trolley(
    p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
    p_trolley_type_id => current_setting('eliscaretex_validation.trolley_type_id')::uuid,
    p_registered_on => current_date,
    p_notes => 'Temporary rollback validation trolley.',
    p_source_application => 'DATABASE_TEST'
  ) ->> 'trolley_id',
  true
);

do $$
declare
  v_trolley_code text := current_setting('eliscaretex_validation.trolley_code');
  v_trolley_id uuid := current_setting('eliscaretex_validation.trolley_id')::uuid;
  v_record jsonb;
begin
  if v_trolley_id is null then
    raise exception 'Physical trolley registration did not return a trolley ID.';
  end if;

  v_record := public.get_trolley_record(v_trolley_code);

  if v_record -> 'trolley' ->> 'status' <> 'AVAILABLE' then
    raise exception 'New physical trolley is not AVAILABLE.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Dispatch and one-open-stay protection
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.first_stay_id',
  dispatched.stay_id::text,
  true
)
from public.send_trolley_to_customer(
  p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
  p_customer_id => current_setting('eliscaretex_validation.customer_id')::uuid,
  p_sent_on => current_date - 2,
  p_notes => 'Temporary outbound validation.',
  p_source_application => 'DATABASE_TEST'
) dispatched;

do $$
declare
  v_trolley_code text := current_setting('eliscaretex_validation.trolley_code');
  v_customer_id uuid := current_setting('eliscaretex_validation.customer_id')::uuid;
  v_first_stay_id uuid := current_setting('eliscaretex_validation.first_stay_id')::uuid;
  v_suggestion record;
  v_duplicate_rejected boolean := false;
begin
  select * into v_suggestion
  from public.suggest_trolley_customer(v_trolley_code);

  if v_suggestion.open_stay_id <> v_first_stay_id
     or v_suggestion.suggested_customer_id <> v_customer_id
     or v_suggestion.suggestion_reason <> 'OPEN_STAY' then
    raise exception 'Open-stay customer suggestion is incorrect.';
  end if;

  begin
    perform public.send_trolley_to_customer(
      p_trolley_code => v_trolley_code,
      p_customer_id => v_customer_id,
      p_sent_on => current_date,
      p_notes => 'Duplicate outbound must fail.',
      p_source_application => 'DATABASE_TEST'
    );
  exception
    when unique_violation then
      v_duplicate_rejected := true;
    when others then
      if position('already has an open customer stay' in sqlerrm) > 0 then
        v_duplicate_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_rejected then
    raise exception 'A second open stay was not rejected.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Normal receipt closes the stay without an exception
-- ---------------------------------------------------------------------

do $$
declare
  v_trolley_code text := current_setting('eliscaretex_validation.trolley_code');
  v_customer_id uuid := current_setting('eliscaretex_validation.customer_id')::uuid;
  v_first_stay_id uuid := current_setting('eliscaretex_validation.first_stay_id')::uuid;
  v_received public.trolley_customer_stays%rowtype;
begin
  v_received := public.receive_trolley_from_customer(
    p_trolley_code => v_trolley_code,
    p_received_from_customer_id => v_customer_id,
    p_received_on => current_date,
    p_confirmation_source => 'OPEN_STAY',
    p_notes => 'Temporary normal receipt validation.',
    p_source_application => 'DATABASE_TEST'
  );

  if v_received.stay_id <> v_first_stay_id
     or v_received.sent_on <> current_date - 2
     or v_received.received_on <> current_date
     or v_received.exception_type is not null
     or v_received.review_status <> 'NOT_REQUIRED'
     or v_received.status <> 'RECEIVED' then
    raise exception 'Normal trolley receipt produced an incorrect stay record.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Receipt without outbound record keeps sent_on NULL and queues review
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.exception_stay_id',
  received.stay_id::text,
  true
)
from public.receive_trolley_from_customer(
  p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
  p_received_from_customer_id => current_setting('eliscaretex_validation.customer_id')::uuid,
  p_received_on => current_date,
  p_confirmation_source => 'LAST_KNOWN_CUSTOMER',
  p_notes => 'Temporary missing outbound validation.',
  p_source_application => 'DATABASE_TEST'
) received;

do $$
declare
  v_trolley_code text := current_setting('eliscaretex_validation.trolley_code');
  v_exception_stay_id uuid := current_setting('eliscaretex_validation.exception_stay_id')::uuid;
  v_record jsonb;
  v_queue jsonb;
  v_history_item jsonb;
begin
  v_record := public.get_trolley_record(v_trolley_code);

  select item
  into v_history_item
  from jsonb_array_elements(v_record -> 'history') item
  where (item ->> 'stay_id')::uuid = v_exception_stay_id;

  if v_history_item is null
     or v_history_item ->> 'sent_on' is not null
     or v_history_item ->> 'exception_type' <> 'MISSING_OUTBOUND_RECORD'
     or v_history_item ->> 'review_status' <> 'PENDING' then
    raise exception 'Receipt without outbound did not preserve the required exception state.';
  end if;

  v_queue := public.get_trolley_reconciliation_queue();

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_queue -> 'items', '[]'::jsonb)) item
    where (item ->> 'stay_id')::uuid = v_exception_stay_id
  ) then
    raise exception 'Missing outbound exception is absent from the reconciliation queue.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Review lifecycle preserves the recorded exception
-- ---------------------------------------------------------------------

do $$
declare
  v_exception_stay_id uuid := current_setting('eliscaretex_validation.exception_stay_id')::uuid;
  v_result jsonb;
  v_queue jsonb;
begin
  v_result := public.review_trolley_exception(
    p_stay_id => v_exception_stay_id,
    p_action => 'START_REVIEW',
    p_notes => 'Validation review started.',
    p_source_application => 'DATABASE_TEST'
  );

  if v_result ->> 'review_status' <> 'UNDER_REVIEW' then
    raise exception 'Trolley exception did not enter UNDER_REVIEW.';
  end if;

  v_result := public.review_trolley_exception(
    p_stay_id => v_exception_stay_id,
    p_action => 'RESOLVE_AS_RECORDED',
    p_notes => 'Confirmed that the outbound record is genuinely missing.',
    p_source_application => 'DATABASE_TEST'
  );

  if v_result ->> 'review_status' <> 'RESOLVED'
     or v_result ->> 'review_decision' <> 'CONFIRMED_AS_RECORDED'
     or v_result ->> 'exception_type' <> 'MISSING_OUTBOUND_RECORD' then
    raise exception 'Trolley exception resolution did not preserve the recorded exception.';
  end if;

  v_queue := public.get_trolley_reconciliation_queue();

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_queue -> 'items', '[]'::jsonb)) item
    where (item ->> 'stay_id')::uuid = v_exception_stay_id
  ) then
    raise exception 'Resolved exception remains in the active reconciliation queue.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Service-state management and dashboard read model
-- ---------------------------------------------------------------------

do $$
declare
  v_trolley_code text := current_setting('eliscaretex_validation.trolley_code');
  v_result jsonb;
  v_dashboard jsonb;
begin
  v_result := public.set_trolley_service_status(
    p_trolley_code => v_trolley_code,
    p_action => 'MARK_OUT_OF_SERVICE',
    p_reason => 'Temporary service-state validation.',
    p_source_application => 'DATABASE_TEST'
  );

  if v_result ->> 'status' <> 'OUT_OF_SERVICE' then
    raise exception 'Trolley was not marked OUT_OF_SERVICE.';
  end if;

  v_result := public.set_trolley_service_status(
    p_trolley_code => v_trolley_code,
    p_action => 'RETURN_TO_SERVICE',
    p_reason => 'Temporary return-to-service validation.',
    p_source_application => 'DATABASE_TEST'
  );

  if v_result ->> 'status' <> 'AVAILABLE' then
    raise exception 'Trolley was not returned to AVAILABLE.';
  end if;

  v_dashboard := public.get_trolley_dashboard(v_trolley_code, 'ALL');

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_dashboard -> 'items', '[]'::jsonb)) item
    where item ->> 'trolley_code' = v_trolley_code
      and item ->> 'status' = 'AVAILABLE'
  ) then
    raise exception 'Dashboard does not return the validated trolley.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608030006_physical_trolley_lifecycle_management_validation_v2',
  'controlled_rpc_boundary', true,
  'physical_identity', true,
  'one_open_stay', true,
  'normal_dispatch_and_receipt', true,
  'missing_outbound_exception', true,
  'exception_review', true,
  'service_state_management', true,
  'dashboard_and_history', true,
  'temporary_table_dependency_removed', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
