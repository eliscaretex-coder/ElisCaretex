-- =====================================================================
-- ElisCaretex V2
-- Validation:
-- 202608040001_trolley_production_sorting_flow_validation_v2.sql
--
-- Covered:
--   - next Distribution business date;
--   - scheduled Finish/Mop production context;
--   - production assignment with inferred next-day delivery;
--   - effective AT_CUSTOMER state after the inferred delivery date;
--   - Sorting arrival and days-at-customer calculation;
--   - missing-outbound exception remains supported;
--   - all validation writes are rolled back.
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
  'eliscaretex_validation.trolley_code',
  'FLOW-VALIDATION-' || upper(substr(gen_random_uuid()::text, 1, 8)),
  true
);

select set_config(
  'eliscaretex_validation.trolley_type_id',
  (
    select tt.trolley_type_id::text
    from public.trolley_types tt
    where tt.active = true
      and tt.deleted_at is null
      and tt.trolley_type_code in ('SMALL', 'MEDIUM', 'LARGE')
    order by tt.sort_order, tt.trolley_type_code
    limit 1
  ),
  true
);

with candidate as (
  select
    day_value.business_date,
    case when pt.product_code = 'CLOTHES' then 'FINISH' else 'MOP' end as area_code,
    v.customer_id
  from generate_series(
    current_date - interval '30 days',
    current_date - interval '2 days',
    interval '1 day'
  ) generated(business_timestamp)
  cross join lateral (
    select generated.business_timestamp::date as business_date
  ) day_value
  join public.customer_schedule_versions v
    on v.status = 'PUBLISHED'
   and day_value.business_date >= v.effective_from
   and (v.effective_until is null or day_value.business_date <= v.effective_until)
  join public.customer_schedule_days d
    on d.schedule_version_id = v.schedule_version_id
   and d.active = true
   and d.production_weekday = extract(isodow from day_value.business_date)::smallint
  join public.customer_schedule_products sp
    on sp.schedule_day_id = d.schedule_day_id
   and sp.active = true
  join public.product_types pt
    on pt.product_type_id = sp.product_type_id
   and pt.active = true
   and pt.deleted_at is null
   and pt.product_code in ('CLOTHES', 'MOP')
  join public.customers c
    on c.customer_id = v.customer_id
   and c.active = true
   and c.deleted_at is null
  order by day_value.business_date desc, sp.production_order nulls last, c.customer_name
  limit 1
)
select
  set_config('eliscaretex_validation.production_date', candidate.business_date::text, true),
  set_config('eliscaretex_validation.area_code', candidate.area_code, true),
  set_config('eliscaretex_validation.customer_id', candidate.customer_id::text, true)
from candidate;

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;

  if nullif(current_setting('eliscaretex_validation.production_date', true), '') is null then
    raise exception 'No current published Finish/Mop production schedule was found for validation.';
  end if;

  if public.next_distribution_business_date(date '2026-08-01') <> date '2026-08-03' then
    raise exception 'Saturday production did not resolve to Monday delivery.';
  end if;

  if public.next_distribution_business_date(date '2026-08-03') <> date '2026-08-04' then
    raise exception 'Weekday production did not resolve to next-day delivery.';
  end if;
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Permissions and scheduled production context
-- ---------------------------------------------------------------------

do $$
declare
  v_capabilities jsonb;
  v_context jsonb;
  v_customer_id uuid := current_setting('eliscaretex_validation.customer_id')::uuid;
begin
  if not has_function_privilege(
    'authenticated',
    'public.assign_trolley_to_customer_from_production(text,uuid,date,text,text,text)',
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    'public.confirm_trolley_sorting_arrival(text,uuid,date,text,text)',
    'EXECUTE'
  ) then
    raise exception 'Required production/Sorting RPC privilege is missing.';
  end if;

  v_capabilities := public.get_trolley_lifecycle_capabilities();

  if coalesce((v_capabilities ->> 'can_assign_trolleys_from_production')::boolean, false) is false
     or coalesce((v_capabilities ->> 'can_confirm_sorting_arrival')::boolean, false) is false then
    raise exception 'ADMIN production/Sorting trolley capabilities are incomplete.';
  end if;

  v_context := public.get_trolley_production_customers(
    current_setting('eliscaretex_validation.area_code'),
    current_setting('eliscaretex_validation.production_date')::date
  );

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_context -> 'customers', '[]'::jsonb)) item
    where (item ->> 'customer_id')::uuid = v_customer_id
  ) then
    raise exception 'Scheduled production context did not return the selected customer.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Register and assign one temporary trolley in production
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.trolley_id',
  public.register_physical_trolley(
    p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
    p_trolley_type_id => current_setting('eliscaretex_validation.trolley_type_id')::uuid,
    p_registered_on => current_date,
    p_notes => 'Temporary production/Sorting validation trolley.',
    p_source_application => 'DATABASE_TEST'
  ) ->> 'trolley_id',
  true
);

select set_config(
  'eliscaretex_validation.stay_id',
  public.assign_trolley_to_customer_from_production(
    p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
    p_customer_id => current_setting('eliscaretex_validation.customer_id')::uuid,
    p_production_business_date => current_setting('eliscaretex_validation.production_date')::date,
    p_area_code => current_setting('eliscaretex_validation.area_code'),
    p_notes => 'Temporary assignment validation.',
    p_source_application => 'DATABASE_TEST'
  ) ->> 'stay_id',
  true
);

select set_config(
  'eliscaretex_validation.dashboard_result',
  public.get_trolley_dashboard(
    current_setting('eliscaretex_validation.trolley_code'),
    'AT_CUSTOMER'
  )::text,
  true
);

-- Internal storage checks must run as the SQL test owner. Do not grant
-- authenticated direct SELECT access to protected lifecycle tables.
reset role;

do $$
declare
  v_stay public.trolley_customer_stays%rowtype;
  v_dashboard jsonb := current_setting('eliscaretex_validation.dashboard_result')::jsonb;
  v_expected_delivery date := public.next_distribution_business_date(
    current_setting('eliscaretex_validation.production_date')::date
  );
begin
  select * into v_stay
  from public.trolley_customer_stays
  where stay_id = current_setting('eliscaretex_validation.stay_id')::uuid;

  if v_stay.production_business_date <> current_setting('eliscaretex_validation.production_date')::date
     or v_stay.planned_delivery_on <> v_expected_delivery
     or v_stay.sent_on <> v_expected_delivery
     or v_stay.custody_start_source <> 'PRODUCTION_NEXT_DAY_INFERENCE'
     or v_stay.production_area_code <> current_setting('eliscaretex_validation.area_code')
     or v_stay.received_on is not null then
    raise exception 'Production assignment did not preserve the expected operational context.';
  end if;

  if (
    select t.status
    from public.trolleys t
    where t.trolley_id = current_setting('eliscaretex_validation.trolley_id')::uuid
  ) <> 'IN_PRODUCTION' then
    raise exception 'Assigned trolley was not stored as IN_PRODUCTION.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_dashboard -> 'items', '[]'::jsonb)) item
    where item ->> 'trolley_code' = current_setting('eliscaretex_validation.trolley_code')
      and item ->> 'status' = 'AT_CUSTOMER'
      and item ->> 'custody_start_source' = 'PRODUCTION_NEXT_DAY_INFERENCE'
  ) then
    raise exception 'Dashboard did not derive AT_CUSTOMER after the inferred delivery date.';
  end if;
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 3. Sorting arrival closes the stay and calculates customer days
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.sorting_result',
  public.confirm_trolley_sorting_arrival(
    p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
    p_customer_id => current_setting('eliscaretex_validation.customer_id')::uuid,
    p_arrived_on => current_date,
    p_confirmation_source => 'OPEN_STAY',
    p_notes => 'Temporary Sorting arrival validation.'
  )::text,
  true
);

reset role;

do $$
declare
  v_result jsonb := current_setting('eliscaretex_validation.sorting_result')::jsonb;
  v_stay public.trolley_customer_stays%rowtype;
  v_expected_days integer;
begin
  select * into v_stay
  from public.trolley_customer_stays
  where stay_id = current_setting('eliscaretex_validation.stay_id')::uuid;

  v_expected_days := current_date - v_stay.sent_on;

  if v_stay.received_on <> current_date
     or v_stay.status <> 'RECEIVED'
     or v_stay.exception_type is not null
     or (v_result ->> 'days_at_customer')::integer <> v_expected_days then
    raise exception 'Sorting arrival did not close the expected stay correctly.';
  end if;

  if not exists (
    select 1
    from public.trolley_events e
    where e.stay_id = v_stay.stay_id
      and e.event_type = 'ARRIVED_AT_SORTING'
      and e.business_date = current_date
  ) then
    raise exception 'Sorting arrival event was not recorded.';
  end if;

  if (
    select t.status
    from public.trolleys t
    where t.trolley_id = v_stay.trolley_id
  ) <> 'AVAILABLE' then
    raise exception 'Trolley was not made AVAILABLE after Sorting arrival.';
  end if;
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 4. First Sorting scan without an outbound stays traceable
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.missing_outbound_result',
  public.confirm_trolley_sorting_arrival(
    p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
    p_customer_id => current_setting('eliscaretex_validation.customer_id')::uuid,
    p_arrived_on => current_date,
    p_confirmation_source => 'LAST_KNOWN_CUSTOMER',
    p_notes => 'Temporary missing outbound validation.'
  )::text,
  true
);

reset role;

do $$
declare
  v_result jsonb := current_setting('eliscaretex_validation.missing_outbound_result')::jsonb;
  v_stay public.trolley_customer_stays%rowtype;
begin
  select * into v_stay
  from public.trolley_customer_stays
  where stay_id = (v_result ->> 'stay_id')::uuid;

  if v_stay.sent_on is not null
     or v_stay.exception_type <> 'MISSING_OUTBOUND_RECORD'
     or v_stay.review_status <> 'PENDING'
     or v_stay.status <> 'REVIEW_REQUIRED' then
    raise exception 'Sorting arrival without outbound did not preserve the required exception.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608040001_trolley_production_sorting_flow_validation_v2',
  'next_day_delivery_rule', true,
  'scheduled_production_context', true,
  'production_trolley_assignment', true,
  'inferred_delivery_source_preserved', true,
  'sorting_arrival', true,
  'days_at_customer', true,
  'missing_outbound_exception', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
