-- =====================================================================
-- ElisCaretex V2
-- Validation:
-- 202608030001_customer_planner_production_order_management_validation.sql
--
-- Covered:
--   - new controlled RPC privileges;
--   - previous save/publish browser paths are closed;
--   - blank production order receives the next available number on save;
--   - complete day drag-and-drop reorder returns a 1..N sequence;
--   - all temporary revisions and audit records are rolled back.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Resolve one active ADMIN and one safe production day
-- ---------------------------------------------------------------------

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
end;
$$;

with current_rows as (
  select
    pt.product_code,
    d.production_weekday,
    c.customer_id,
    c.customer_name,
    v.schedule_version_id,
    p.production_order,
    not exists (
      select 1
      from public.customer_schedule_versions draft
      where draft.customer_id = c.customer_id
        and draft.status = 'DRAFT'
    ) as has_no_draft,
    not exists (
      select 1
      from public.customer_schedule_versions future_version
      where future_version.customer_id = c.customer_id
        and future_version.status = 'PUBLISHED'
        and future_version.effective_from > public.current_business_date()
    ) as has_no_future
  from public.customer_schedule_versions v
  join public.customers c
    on c.customer_id = v.customer_id
  join public.customer_schedule_days d
    on d.schedule_version_id = v.schedule_version_id
  join public.customer_schedule_products p
    on p.schedule_day_id = d.schedule_day_id
  join public.product_types pt
    on pt.product_type_id = p.product_type_id
  where v.status = 'PUBLISHED'
    and public.current_business_date() >= v.effective_from
    and (
      v.effective_until is null
      or public.current_business_date() <= v.effective_until
    )
    and c.active = true
    and c.deleted_at is null
    and d.active = true
    and p.active = true
    and pt.product_code in ('CLOTHES', 'MOP')
), selected_group as (
  select product_code, production_weekday
  from current_rows
  group by product_code, production_weekday
  having count(*) >= 2
     and bool_and(has_no_draft)
     and bool_and(has_no_future)
  order by count(*) desc, product_code, production_weekday
  limit 1
), selected_rows as (
  select current_rows.*
  from current_rows
  join selected_group using (product_code, production_weekday)
), numbered as (
  select
    selected_rows.*,
    row_number() over (
      order by production_order nulls last, lower(customer_name), customer_id
    ) as current_position
  from selected_rows
)
select set_config(
  'eliscaretex.validation.production_order_setup',
  jsonb_build_object(
    'product_code', max(product_code),
    'production_weekday', max(production_weekday),
    'customer_id', (array_agg(customer_id order by current_position))[1],
    'base_version_id', (array_agg(schedule_version_id order by current_position))[1],
    'reversed_items', jsonb_agg(
      jsonb_build_object(
        'customer_id', customer_id,
        'schedule_version_id', schedule_version_id
      )
      order by current_position desc
    )
  )::text,
  true
)
from numbered;

do $$
declare
  v_setup jsonb := nullif(
    current_setting(
      'eliscaretex.validation.production_order_setup',
      true
    ),
    ''
  )::jsonb;
begin
  if v_setup is null
     or nullif(v_setup ->> 'product_code', '') is null
     or nullif(v_setup ->> 'production_weekday', '') is null
     or jsonb_typeof(v_setup -> 'reversed_items') is distinct from 'array'
     or jsonb_array_length(v_setup -> 'reversed_items') < 2 then
    raise exception
      'No safe Clothes or MOP day with at least two customers was found.';
  end if;
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Privileges
-- ---------------------------------------------------------------------

do $$
begin
  if has_function_privilege(
       'authenticated',
       'public.save_customer_schedule_draft(uuid,integer,jsonb,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Legacy browser save RPC is still executable.';
  end if;

  if has_function_privilege(
       'authenticated',
       'public.publish_customer_schedule_draft(uuid,integer,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Legacy browser publish RPC is still executable.';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.save_customer_schedule_draft_with_auto_orders(uuid,integer,jsonb,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Controlled save-with-order RPC is not executable.';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.publish_customer_schedule_draft_with_order_normalization(uuid,integer,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Controlled publish-with-order RPC is not executable.';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.reorder_customer_planner_day(text,smallint,date,jsonb,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Planner reorder RPC is not executable.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Save one draft with a deliberately blank order
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.production_order_draft',
  public.create_customer_schedule_management_draft(
    p_customer_id => (
      current_setting(
        'eliscaretex.validation.production_order_setup'
      )::jsonb ->> 'customer_id'
    )::uuid,
    p_effective_from => public.current_business_date(),
    p_based_on_version_id => (
      current_setting(
        'eliscaretex.validation.production_order_setup'
      )::jsonb ->> 'base_version_id'
    )::uuid,
    p_change_reason => 'Validate automatic production order assignment.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

select set_config(
  'eliscaretex.validation.production_order_saved',
  public.save_customer_schedule_draft_with_auto_orders(
    p_schedule_version_id => (
      current_setting(
        'eliscaretex.validation.production_order_draft'
      )::jsonb ->> 'schedule_version_id'
    )::uuid,
    p_expected_row_version => (
      current_setting(
        'eliscaretex.validation.production_order_draft'
      )::jsonb -> 'draft' ->> 'row_version'
    )::integer,
    p_draft => jsonb_set(
      current_setting(
        'eliscaretex.validation.production_order_draft'
      )::jsonb -> 'draft',
      '{days,0,products,0,production_order}',
      'null'::jsonb,
      true
    ),
    p_change_reason => 'Validate automatic production order assignment.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
declare
  v_saved jsonb := current_setting(
    'eliscaretex.validation.production_order_saved'
  )::jsonb;
begin
  if exists (
    select 1
    from jsonb_array_elements(v_saved -> 'days') day_items(day_row)
    cross join lateral jsonb_array_elements(
      day_row -> 'products'
    ) product_items(product_row)
    where nullif(product_row ->> 'production_order', '') is null
  ) then
    raise exception
      'Automatic production order assignment failed. Payload: %',
      v_saved;
  end if;
end;
$$;

select public.cancel_customer_schedule_draft(
  p_schedule_version_id => (
    current_setting(
      'eliscaretex.validation.production_order_saved'
    )::jsonb ->> 'schedule_version_id'
  )::uuid,
  p_expected_row_version => (
    current_setting(
      'eliscaretex.validation.production_order_saved'
    )::jsonb ->> 'row_version'
  )::integer,
  p_reason => 'Finish automatic order validation.',
  p_source_application => 'DATABASE_TEST'
);

-- ---------------------------------------------------------------------
-- 3. Reverse one complete day and verify the normalized 1..N result
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.production_order_reordered',
  public.reorder_customer_planner_day(
    p_product_code => current_setting(
      'eliscaretex.validation.production_order_setup'
    )::jsonb ->> 'product_code',
    p_production_weekday => (
      current_setting(
        'eliscaretex.validation.production_order_setup'
      )::jsonb ->> 'production_weekday'
    )::smallint,
    p_effective_date => public.current_business_date(),
    p_items => current_setting(
      'eliscaretex.validation.production_order_setup'
    )::jsonb -> 'reversed_items',
    p_change_reason => 'Validate Customer Planner drag-and-drop reorder.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
declare
  v_result jsonb := current_setting(
    'eliscaretex.validation.production_order_reordered'
  )::jsonb;
  v_product_code text := current_setting(
    'eliscaretex.validation.production_order_setup'
  )::jsonb ->> 'product_code';
  v_weekday smallint := (
    current_setting(
      'eliscaretex.validation.production_order_setup'
    )::jsonb ->> 'production_weekday'
  )::smallint;
  v_expected integer := 0;
  v_item jsonb;
begin
  if coalesce((v_result ->> 'updated_count')::integer, 0) = 0 then
    raise exception 'Reorder validation did not publish any replacement revision.';
  end if;

  for v_item in
    select value
    from jsonb_array_elements(v_result -> 'items')
    where (value ->> 'production_weekday')::smallint = v_weekday
    order by (value ->> 'production_order')::integer
  loop
    v_expected := v_expected + 1;

    if (v_item ->> 'production_order')::integer <> v_expected then
      raise exception
        'Reordered sequence is not contiguous at position %. Payload: %',
        v_expected,
        v_result;
    end if;
  end loop;

  if v_expected < 2 then
    raise exception 'Reordered validation day returned fewer than two items.';
  end if;

  if coalesce(v_result ->> 'product_code', '') <> v_product_code then
    raise exception 'Reorder result product code does not match the request.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608030001_customer_planner_production_order_management_validation',
  'automatic_order_assignment', true,
  'drag_and_drop_reorder', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
