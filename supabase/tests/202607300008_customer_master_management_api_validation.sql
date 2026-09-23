-- =====================================================================
-- ElisCaretex V2
-- Authoritative validation:
-- 202607300008_customer_master_management_api_validation.sql
--
-- Purpose:
--   Validate the complete Customer Master lifecycle through controlled RPCs:
--   reference data, create, read, update, optimistic concurrency,
--   deactivate, directory exclusion, reactivate and function privileges.
--
-- Safety:
--   - Uses an existing active ADMIN identity only for the test transaction.
--   - Does not grant authenticated direct access to public.customers.
--   - Stores only temporary identifiers in pg_temp.
--   - Rolls back every write at the end.
-- =====================================================================

begin;

do $$
begin
  if not exists (
    select 1
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
  ) then
    raise exception 'Validation setup failed: no active ADMIN identity is available.';
  end if;
end;
$$;

select set_config(
  'request.jwt.claim.sub',
  (
    select sm.auth_user_id::text
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
  ),
  true
);

create temporary table customer_master_test_state (
  customer_id uuid primary key,
  customer_code text not null,
  initial_row_version integer not null,
  current_row_version integer not null,
  customer_name text not null
) on commit drop;

grant select, insert, update, delete
on table customer_master_test_state
to authenticated;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Reference data, capabilities and access boundary
-- ---------------------------------------------------------------------

do $$
begin
  if has_table_privilege('authenticated', 'public.customers', 'SELECT')
     or has_table_privilege('authenticated', 'public.customers', 'INSERT')
     or has_table_privilege('authenticated', 'public.customers', 'UPDATE')
     or has_table_privilege('authenticated', 'public.customers', 'DELETE') then
    raise exception 'Validation failed: authenticated has direct table access to public.customers.';
  end if;
end;
$$;

do $$
declare
  v_reference jsonb;
begin
  v_reference := public.get_customer_master_reference_data();

  if coalesce((v_reference ->> 'can_edit_customers')::boolean, false) is not true then
    raise exception 'Validation failed: ADMIN cannot edit customers.';
  end if;

  if coalesce((v_reference ->> 'can_deactivate_customers')::boolean, false) is not true then
    raise exception 'Validation failed: ADMIN cannot deactivate customers.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_reference -> 'product_types', '[]'::jsonb)) item
    where item ->> 'product_code' = 'CLOTHES'
  ) then
    raise exception 'Validation failed: CLOTHES reference data is missing.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_reference -> 'product_types', '[]'::jsonb)) item
    where item ->> 'product_code' = 'MOP'
  ) then
    raise exception 'Validation failed: MOP reference data is missing.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Create through the user-friendly wrapper
-- ---------------------------------------------------------------------

insert into customer_master_test_state (
  customer_id,
  customer_code,
  initial_row_version,
  current_row_version,
  customer_name
)
select
  (created.result ->> 'customer_id')::uuid,
  created.result ->> 'customer_code',
  (created.result ->> 'row_version')::integer,
  (created.result ->> 'row_version')::integer,
  created.result ->> 'customer_name'
from (
  select public.create_customer_master(
    p_customer_name => 'Temporary Customer Master Lifecycle Test',
    p_eircode => 'D00 TEST',
    p_distribution_estimated_kg => 100,
    p_distribution_stop_count => 2,
    p_notes => 'Temporary test record.',
    p_operational_alert => 'Temporary operational alert.',
    p_product_codes => array['CLOTHES'],
    p_change_reason => 'Validate Customer Master create lifecycle.',
    p_source_application => 'DATABASE_TEST'
  ) as result
) created;

do $$
declare
  v_state customer_master_test_state%rowtype;
  v_record jsonb;
begin
  select * into v_state from customer_master_test_state;

  if v_state.customer_id is null
     or nullif(v_state.customer_code, '') is null
     or v_state.initial_row_version < 1 then
    raise exception 'Validation failed: create_customer_master returned invalid identifiers.';
  end if;

  v_record := public.get_customer_master_record(
    p_customer_id => v_state.customer_id,
    p_effective_date => public.current_business_date()
  );

  if (v_record ->> 'active')::boolean is not true then
    raise exception 'Validation failed: created customer is not active.';
  end if;

  if v_record ->> 'customer_name' <> 'Temporary Customer Master Lifecycle Test' then
    raise exception 'Validation failed: created customer name is incorrect.';
  end if;

  if not ('CLOTHES' = any(
    array(select jsonb_array_elements_text(v_record -> 'product_services'))
  )) then
    raise exception 'Validation failed: created CLOTHES service is missing.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Update and enable MOP
-- ---------------------------------------------------------------------

select public.update_customer(
  p_customer_id => state.customer_id,
  p_expected_row_version => state.current_row_version,
  p_customer_code => state.customer_code,
  p_customer_name => 'Temporary Customer Master Lifecycle Test Updated',
  p_eircode => 'D00 TEST',
  p_distribution_estimated_kg => 120,
  p_distribution_stop_count => 3,
  p_notes => 'Updated temporary notes.',
  p_operational_alert => 'Updated temporary alert.',
  p_product_codes => array['CLOTHES', 'MOP'],
  p_change_reason => 'Validate Customer Master update lifecycle.',
  p_source_application => 'DATABASE_TEST'
)
from customer_master_test_state state;

update customer_master_test_state state
set current_row_version = (
  public.get_customer_master_record(
    p_customer_id => state.customer_id,
    p_effective_date => public.current_business_date()
  ) ->> 'row_version'
)::integer;

do $$
declare
  v_state customer_master_test_state%rowtype;
  v_record jsonb;
  v_services text[];
begin
  select * into v_state from customer_master_test_state;

  v_record := public.get_customer_master_record(
    p_customer_id => v_state.customer_id,
    p_effective_date => public.current_business_date()
  );
  v_services := array(select jsonb_array_elements_text(v_record -> 'product_services'));

  if v_record ->> 'customer_name' <> 'Temporary Customer Master Lifecycle Test Updated' then
    raise exception 'Validation failed: customer update was not returned by the read RPC.';
  end if;

  if v_state.current_row_version <= v_state.initial_row_version then
    raise exception 'Validation failed: row_version did not increase after update.';
  end if;

  if not ('CLOTHES' = any(v_services) and 'MOP' = any(v_services)) then
    raise exception 'Validation failed: updated services do not include CLOTHES and MOP.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Optimistic concurrency must reject a stale row_version
-- ---------------------------------------------------------------------

do $$
declare
  v_state customer_master_test_state%rowtype;
  v_rejected boolean := false;
begin
  select * into v_state from customer_master_test_state;

  begin
    perform public.update_customer(
      p_customer_id => v_state.customer_id,
      p_expected_row_version => v_state.initial_row_version,
      p_customer_code => v_state.customer_code,
      p_customer_name => 'This stale update must fail',
      p_eircode => 'D00 TEST',
      p_distribution_estimated_kg => 120,
      p_distribution_stop_count => 3,
      p_notes => 'Stale update.',
      p_operational_alert => null,
      p_product_codes => array['CLOTHES', 'MOP'],
      p_change_reason => 'Validate stale row version rejection.',
      p_source_application => 'DATABASE_TEST'
    );
  exception
    when others then
      if position('changed by another user' in sqlerrm) > 0 then
        v_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'Validation failed: stale Customer Master update was not rejected.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Deactivate and confirm operational-directory exclusion
-- ---------------------------------------------------------------------

select public.deactivate_customer(
  p_customer_id => state.customer_id,
  p_reason => 'Validate Customer Master deactivation lifecycle.',
  p_source_application => 'DATABASE_TEST'
)
from customer_master_test_state state;

do $$
declare
  v_state customer_master_test_state%rowtype;
  v_record jsonb;
  v_active_directory jsonb;
  v_inactive_directory jsonb;
begin
  select * into v_state from customer_master_test_state;

  v_record := public.get_customer_master_record(
    p_customer_id => v_state.customer_id,
    p_effective_date => public.current_business_date()
  );

  if (v_record ->> 'active')::boolean is not false
     or nullif(v_record ->> 'deactivation_reason', '') is null then
    raise exception 'Validation failed: deactivation state is incomplete.';
  end if;

  v_active_directory := public.get_customer_directory(
    p_status => 'ACTIVE',
    p_service_filter => 'ALL',
    p_search => v_state.customer_code,
    p_effective_date => public.current_business_date(),
    p_limit => 10,
    p_offset => 0
  );

  if (v_active_directory ->> 'total_count')::integer <> 0 then
    raise exception 'Validation failed: inactive customer remains in ACTIVE directory.';
  end if;

  v_inactive_directory := public.get_customer_directory(
    p_status => 'INACTIVE',
    p_service_filter => 'ALL',
    p_search => v_state.customer_code,
    p_effective_date => public.current_business_date(),
    p_limit => 10,
    p_offset => 0
  );

  if (v_inactive_directory ->> 'total_count')::integer <> 1 then
    raise exception 'Validation failed: deactivated customer is missing from INACTIVE directory.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Reactivate
-- ---------------------------------------------------------------------

select public.reactivate_customer(
  p_customer_id => state.customer_id,
  p_product_codes => array['CLOTHES', 'MOP'],
  p_reason => 'Validate Customer Master reactivation lifecycle.',
  p_source_application => 'DATABASE_TEST'
)
from customer_master_test_state state;

do $$
declare
  v_state customer_master_test_state%rowtype;
  v_record jsonb;
  v_services text[];
begin
  select * into v_state from customer_master_test_state;

  v_record := public.get_customer_master_record(
    p_customer_id => v_state.customer_id,
    p_effective_date => public.current_business_date()
  );
  v_services := array(select jsonb_array_elements_text(v_record -> 'product_services'));

  if (v_record ->> 'active')::boolean is not true then
    raise exception 'Validation failed: reactivated customer is not active.';
  end if;

  if nullif(v_record ->> 'deactivation_reason', '') is not null then
    raise exception 'Validation failed: reactivation did not clear the deactivation reason.';
  end if;

  if not ('CLOTHES' = any(v_services) and 'MOP' = any(v_services)) then
    raise exception 'Validation failed: reactivated services are incomplete.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Function privileges
-- ---------------------------------------------------------------------

do $$
declare
  v_missing text;
begin
  select string_agg(p.proname, ', ' order by p.proname)
  into v_missing
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'get_customer_master_reference_data',
      'get_customer_master_record',
      'create_customer_master',
      'update_customer',
      'deactivate_customer',
      'reactivate_customer'
    )
    and not has_function_privilege('authenticated', p.oid, 'EXECUTE');

  if v_missing is not null then
    raise exception 'Validation failed: authenticated EXECUTE is missing for %.', v_missing;
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202607300008_customer_master_management_api_validation',
  'writes_rolled_back', true,
  'validated_lifecycle', jsonb_build_array(
    'ACCESS_BOUNDARY',
    'REFERENCE_DATA',
    'CREATE',
    'READ',
    'UPDATE',
    'OPTIMISTIC_CONCURRENCY',
    'DEACTIVATE',
    'DIRECTORY_EXCLUSION',
    'REACTIVATE',
    'FUNCTION_PRIVILEGES'
  )
) as validation_result;

rollback;
