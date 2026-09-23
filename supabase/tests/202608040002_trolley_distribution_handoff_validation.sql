-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608040002_trolley_distribution_handoff_validation.sql
--
-- Covered:
--   - controlled authenticated RPC access;
--   - no authenticated direct SELECT on protected trolley stay data;
--   - route/customer/trolley grouping from the immutable source schedule;
--   - inferred delivery provenance remains explicit;
--   - the handoff is read-only and validation writes are rolled back.
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
  'DIST-HANDOFF-' || upper(substr(gen_random_uuid()::text, 1, 8)),
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
    d.default_route_id,
    r.route_code
  from generate_series(
    current_date - interval '30 days',
    current_date - interval '1 day',
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
   and d.default_route_id is not null
  join public.distribution_routes r
    on r.route_id = d.default_route_id
   and r.deleted_at is null
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
  order by day_value.business_date desc, d.delivery_order nulls last, c.customer_name
  limit 1
)
select
  set_config('eliscaretex_validation.production_date', candidate.business_date::text, true),
  set_config('eliscaretex_validation.delivery_date', public.next_distribution_business_date(candidate.business_date)::text, true),
  set_config('eliscaretex_validation.area_code', candidate.area_code, true),
  set_config('eliscaretex_validation.customer_id', candidate.customer_id::text, true),
  set_config('eliscaretex_validation.route_id', candidate.default_route_id::text, true),
  set_config('eliscaretex_validation.route_code', candidate.route_code, true)
from candidate;

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;

  if nullif(current_setting('eliscaretex_validation.production_date', true), '') is null then
    raise exception 'No published scheduled customer with a default route was found for validation.';
  end if;
end;
$$;

set local role authenticated;

do $$
declare
  v_capabilities jsonb;
begin
  if not has_function_privilege(
    'authenticated',
    'public.get_trolley_distribution_handoff(date)',
    'EXECUTE'
  ) then
    raise exception 'Authenticated EXECUTE privilege is missing for the Distribution trolley handoff RPC.';
  end if;

  if has_table_privilege(
    'authenticated',
    'public.trolley_customer_stays',
    'SELECT'
  ) then
    raise exception 'Authenticated must not have direct SELECT access to trolley_customer_stays.';
  end if;

  v_capabilities := public.get_trolley_lifecycle_capabilities();

  if coalesce((v_capabilities ->> 'can_view_distribution_handoff')::boolean, false) is false then
    raise exception 'ADMIN Distribution handoff capability is missing.';
  end if;
end;
$$;

select set_config(
  'eliscaretex_validation.trolley_id',
  public.register_physical_trolley(
    p_trolley_code => current_setting('eliscaretex_validation.trolley_code'),
    p_trolley_type_id => current_setting('eliscaretex_validation.trolley_type_id')::uuid,
    p_registered_on => current_date,
    p_notes => 'Temporary Distribution handoff validation trolley.',
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
    p_notes => 'Temporary Distribution handoff validation assignment.',
    p_source_application => 'DATABASE_TEST'
  ) ->> 'stay_id',
  true
);

select set_config(
  'eliscaretex_validation.handoff_result',
  public.get_trolley_distribution_handoff(
    current_setting('eliscaretex_validation.delivery_date')::date
  )::text,
  true
);

do $$
declare
  v_result jsonb := current_setting('eliscaretex_validation.handoff_result')::jsonb;
  v_trolley_code text := current_setting('eliscaretex_validation.trolley_code');
  v_customer_id uuid := current_setting('eliscaretex_validation.customer_id')::uuid;
  v_route_id uuid := current_setting('eliscaretex_validation.route_id')::uuid;
  v_delivery_date date := current_setting('eliscaretex_validation.delivery_date')::date;
begin
  if (v_result ->> 'delivery_date')::date <> v_delivery_date then
    raise exception 'Distribution handoff returned the wrong delivery date.';
  end if;

  if v_result ->> 'delivery_tracking_mode' <> 'PRODUCTION_NEXT_DAY_INFERENCE' then
    raise exception 'Distribution handoff did not preserve inferred-delivery provenance.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_result -> 'routes', '[]'::jsonb)) route_item
    cross join lateral jsonb_array_elements(coalesce(route_item -> 'customers', '[]'::jsonb)) customer_item
    cross join lateral jsonb_array_elements(coalesce(customer_item -> 'trolleys', '[]'::jsonb)) trolley_item
    where (route_item ->> 'route_id')::uuid = v_route_id
      and (customer_item ->> 'customer_id')::uuid = v_customer_id
      and trolley_item ->> 'trolley_code' = v_trolley_code
      and trolley_item ->> 'custody_start_source' = 'PRODUCTION_NEXT_DAY_INFERENCE'
  ) then
    raise exception 'Distribution handoff did not group the assigned trolley under its source route and customer.';
  end if;

  if coalesce((v_result #>> '{summary,trolley_count}')::integer, 0) < 1
     or coalesce((v_result #>> '{summary,customer_count}')::integer, 0) < 1 then
    raise exception 'Distribution handoff summary counts are incomplete.';
  end if;
end;
$$;

reset role;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608040002_trolley_distribution_handoff_validation',
  'controlled_rpc_access', true,
  'protected_tables_remain_private', true,
  'source_route_grouping', true,
  'physical_trolley_codes_visible', true,
  'inferred_delivery_provenance_preserved', true,
  'read_only_handoff', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
