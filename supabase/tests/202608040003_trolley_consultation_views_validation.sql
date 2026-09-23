-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608040003_trolley_consultation_views_validation.sql
-- Covered:
--   - controlled location-overview RPC access;
--   - Elis Laundry group and days at current location;
--   - customer grouping after a production assignment;
--   - protected tables remain unavailable to authenticated;
--   - traceable trolley retirement without physical deletion;
--   - all test writes are rolled back.
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
  'eliscaretex_validation.location_trolley_code',
  'LOCATION-VALIDATION-' || upper(substr(gen_random_uuid()::text, 1, 8)),
  true
);

select set_config(
  'eliscaretex_validation.customer_trolley_code',
  'CUSTOMER-VALIDATION-' || upper(substr(gen_random_uuid()::text, 1, 8)),
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
    v.customer_id,
    c.customer_name
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
  set_config('eliscaretex_validation.customer_id', candidate.customer_id::text, true),
  set_config('eliscaretex_validation.customer_name', candidate.customer_name, true)
from candidate;

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;

  if nullif(current_setting('eliscaretex_validation.production_date', true), '') is null then
    raise exception 'No published Finish/Mop schedule was found for location validation.';
  end if;
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Permission boundary
-- ---------------------------------------------------------------------

do $$
begin
  if not has_function_privilege(
    'authenticated',
    'public.get_trolley_location_overview(text,text)',
    'EXECUTE'
  ) then
    raise exception 'authenticated is missing EXECUTE on get_trolley_location_overview.';
  end if;

  if has_table_privilege('authenticated', 'public.trolleys', 'SELECT')
     or has_table_privilege('authenticated', 'public.trolley_customer_stays', 'SELECT')
     or has_table_privilege('authenticated', 'public.trolley_events', 'SELECT') then
    raise exception 'Protected trolley tables must not grant direct SELECT to authenticated.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. A newly registered trolley appears at Elis Laundry
-- ---------------------------------------------------------------------

select public.register_physical_trolley(
  p_trolley_code => current_setting('eliscaretex_validation.location_trolley_code'),
  p_trolley_type_id => current_setting('eliscaretex_validation.trolley_type_id')::uuid,
  p_registered_on => current_date - 5,
  p_notes => 'Temporary Elis Laundry location validation trolley.',
  p_source_application => 'DATABASE_TEST'
);

select set_config(
  'eliscaretex_validation.elis_result',
  public.get_trolley_location_overview(
    current_setting('eliscaretex_validation.location_trolley_code'),
    'ELIS_LAUNDRY'
  )::text,
  true
);

do $$
declare
  v_result jsonb := current_setting('eliscaretex_validation.elis_result')::jsonb;
  v_item jsonb;
begin
  select trolley_item
  into v_item
  from jsonb_array_elements(coalesce(v_result -> 'groups', '[]'::jsonb)) location_group
  cross join lateral jsonb_array_elements(coalesce(location_group -> 'trolleys', '[]'::jsonb)) trolley_item
  where trolley_item ->> 'trolley_code' = current_setting('eliscaretex_validation.location_trolley_code')
  limit 1;

  if v_item is null then
    raise exception 'Registered trolley was not returned in the Elis Laundry group.';
  end if;

  if v_item ->> 'location_status' <> 'AT_LAUNDRY' then
    raise exception 'Registered trolley did not receive AT_LAUNDRY location status.';
  end if;

  if (v_item ->> 'days_at_location')::integer <> 5 then
    raise exception 'Elis Laundry days-at-location calculation is incorrect.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Production assignment appears under the customer location
-- ---------------------------------------------------------------------

select public.register_physical_trolley(
  p_trolley_code => current_setting('eliscaretex_validation.customer_trolley_code'),
  p_trolley_type_id => current_setting('eliscaretex_validation.trolley_type_id')::uuid,
  p_registered_on => current_date,
  p_notes => 'Temporary customer location validation trolley.',
  p_source_application => 'DATABASE_TEST'
);

select public.assign_trolley_to_customer_from_production(
  p_trolley_code => current_setting('eliscaretex_validation.customer_trolley_code'),
  p_customer_id => current_setting('eliscaretex_validation.customer_id')::uuid,
  p_production_business_date => current_setting('eliscaretex_validation.production_date')::date,
  p_area_code => current_setting('eliscaretex_validation.area_code'),
  p_notes => 'Temporary customer grouping validation.',
  p_source_application => 'DATABASE_TEST'
);

select set_config(
  'eliscaretex_validation.customer_result',
  public.get_trolley_location_overview(
    current_setting('eliscaretex_validation.customer_trolley_code'),
    'CUSTOMERS'
  )::text,
  true
);

do $$
declare
  v_result jsonb := current_setting('eliscaretex_validation.customer_result')::jsonb;
  v_group jsonb;
  v_item jsonb;
  v_expected_days integer := current_date - public.next_distribution_business_date(
    current_setting('eliscaretex_validation.production_date')::date
  );
begin
  select location_group
  into v_group
  from jsonb_array_elements(coalesce(v_result -> 'groups', '[]'::jsonb)) location_group
  where location_group ->> 'location_type' = 'CUSTOMER'
    and location_group ->> 'location_name' = current_setting('eliscaretex_validation.customer_name')
  limit 1;

  if v_group is null then
    raise exception 'Customer location group was not returned.';
  end if;

  select trolley_item
  into v_item
  from jsonb_array_elements(coalesce(v_group -> 'trolleys', '[]'::jsonb)) trolley_item
  where trolley_item ->> 'trolley_code' = current_setting('eliscaretex_validation.customer_trolley_code')
  limit 1;

  if v_item is null then
    raise exception 'Assigned trolley was not returned under the customer.';
  end if;

  if v_item ->> 'location_status' <> 'AT_CUSTOMER' then
    raise exception 'Assigned trolley did not receive AT_CUSTOMER location status.';
  end if;

  if (v_item ->> 'days_at_location')::integer <> greatest(v_expected_days, 0) then
    raise exception 'Customer days-at-location calculation is incorrect.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Retirement preserves the record and removes it from locations
-- ---------------------------------------------------------------------

select public.set_trolley_service_status(
  p_trolley_code => current_setting('eliscaretex_validation.location_trolley_code'),
  p_action => 'RETIRE_TROLLEY',
  p_reason => 'Temporary retirement validation.',
  p_source_application => 'DATABASE_TEST'
);

select set_config(
  'eliscaretex_validation.retired_location_result',
  public.get_trolley_location_overview(
    current_setting('eliscaretex_validation.location_trolley_code'),
    'ALL'
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.retired_master_result',
  public.get_trolley_dashboard(
    current_setting('eliscaretex_validation.location_trolley_code'),
    'RETIRED'
  )::text,
  true
);

do $$
declare
  v_location_result jsonb := current_setting('eliscaretex_validation.retired_location_result')::jsonb;
  v_master_result jsonb := current_setting('eliscaretex_validation.retired_master_result')::jsonb;
begin
  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_location_result -> 'groups', '[]'::jsonb)) location_group
    cross join lateral jsonb_array_elements(coalesce(location_group -> 'trolleys', '[]'::jsonb)) trolley_item
    where trolley_item ->> 'trolley_code' = current_setting('eliscaretex_validation.location_trolley_code')
  ) then
    raise exception 'Retired trolley must not remain in the current-location overview.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_master_result -> 'items', '[]'::jsonb)) trolley_item
    where trolley_item ->> 'trolley_code' = current_setting('eliscaretex_validation.location_trolley_code')
      and trolley_item ->> 'status' = 'RETIRED'
  ) then
    raise exception 'Retired trolley was not preserved in Trolley Master.';
  end if;
end;
$$;

reset role;

do $$
begin
  if not exists (
    select 1
    from public.trolleys t
    where t.trolley_code = current_setting('eliscaretex_validation.location_trolley_code')
      and t.status = 'RETIRED'
      and t.active = false
      and t.deleted_at is null
  ) then
    raise exception 'Retirement did not preserve the trolley master record correctly.';
  end if;

  if not exists (
    select 1
    from public.trolley_events e
    join public.trolleys t on t.trolley_id = e.trolley_id
    where t.trolley_code = current_setting('eliscaretex_validation.location_trolley_code')
      and e.event_type = 'TROLLEY_RETIRED'
  ) then
    raise exception 'Retirement event was not recorded.';
  end if;
end;
$$;

rollback;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608040003_trolley_consultation_views_validation',
  'elis_laundry_group', true,
  'days_at_location', true,
  'customer_location_grouping', true,
  'protected_tables_remain_private', true,
  'retirement_preserves_history', true,
  'writes_rolled_back', true
);
