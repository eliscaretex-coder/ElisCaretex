-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608030001_customer_planner_production_order_management.sql
-- Purpose:
--   - Assign a safe production order automatically when a newly saved
--     Customer Schedule product has no order yet.
--   - Provide one controlled, audited and transactional RPC for reordering
--     a complete Clothes or MOP day from the Customer Planner.
--
-- Design principles:
--   - Published schedule children remain immutable.
--   - Planner reordering creates and publishes replacement revisions only
--     for customers whose order actually changed.
--   - A complete day list plus expected schedule version IDs is required,
--     preventing partial or stale browser updates.
--   - ADMIN, MANAGER and PLANNER are the only allowed roles.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Safety guard
-- ---------------------------------------------------------------------

do $$
begin
  if to_regprocedure(
       'public.save_customer_schedule_draft(uuid,integer,jsonb,text,text)'
     ) is null
     or to_regprocedure(
       'public.create_customer_schedule_draft(uuid,date,uuid,text,text)'
     ) is null
     or to_regprocedure(
       'public.publish_customer_schedule(uuid,text,text)'
     ) is null
     or to_regprocedure(
       'public.publish_customer_schedule_draft(uuid,integer,text,text)'
     ) is null
     or to_regprocedure(
       'public.build_customer_schedule_version_snapshot(uuid)'
     ) is null
     or to_regprocedure(
       'public.get_clothes_weekly_planner(date,smallint,text)'
     ) is null
     or to_regprocedure(
       'public.get_mop_weekly_planner(date,smallint,text)'
     ) is null then
    raise exception using
      message = 'Safety stop: prerequisite Customer Schedule APIs are missing.',
      hint = 'Apply migrations through 202607310002 before this migration.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Save a complete draft and assign missing production orders
-- ---------------------------------------------------------------------

create or replace function public.save_customer_schedule_draft_with_auto_orders(
  p_schedule_version_id uuid,
  p_expected_row_version integer,
  p_draft jsonb,
  p_change_reason text,
  p_source_application text default 'CUSTOMER_STUDIO'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_snapshot jsonb;
  v_version public.customer_schedule_versions%rowtype;
  v_product record;
  v_next_order integer;
  v_assignments jsonb := '[]'::jsonb;
begin
  perform public.require_customer_schedule_edit_role();

  -- Existing API performs full validation, optimistic concurrency and audit.
  v_snapshot := public.save_customer_schedule_draft(
    p_schedule_version_id,
    p_expected_row_version,
    p_draft,
    p_change_reason,
    p_source_application
  );

  select *
  into v_version
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found or v_version.status <> 'DRAFT' then
    raise exception using
      errcode = '55000',
      message = 'The saved Customer Schedule revision is not an editable working revision.';
  end if;

  for v_product in
    select
      p.schedule_product_id,
      d.production_weekday,
      pt.product_code
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and p.active = true
      and p.production_order is null
    order by d.production_weekday, pt.sort_order, pt.product_code
  loop
    -- Serialize assignment for one service/day/effective date. This prevents
    -- two users from receiving the same next number in concurrent saves.
    perform pg_advisory_xact_lock(
      hashtextextended(
        concat_ws(
          ':',
          'CUSTOMER_PRODUCTION_ORDER',
          v_product.product_code,
          v_product.production_weekday,
          v_version.effective_from
        ),
        0
      )
    );

    select coalesce(max(current_product.production_order), 0) + 1
    into v_next_order
    from public.customer_schedule_versions current_version
    join public.customer_schedule_days current_day
      on current_day.schedule_version_id = current_version.schedule_version_id
    join public.customer_schedule_products current_product
      on current_product.schedule_day_id = current_day.schedule_day_id
    join public.product_types current_type
      on current_type.product_type_id = current_product.product_type_id
    where current_version.status = 'PUBLISHED'
      and v_version.effective_from >= current_version.effective_from
      and (
        current_version.effective_until is null
        or v_version.effective_from <= current_version.effective_until
      )
      and current_version.customer_id <> v_version.customer_id
      and current_day.active = true
      and current_day.production_weekday = v_product.production_weekday
      and current_product.active = true
      and current_type.product_code = v_product.product_code;

    update public.customer_schedule_products
    set
      production_order = v_next_order,
      updated_by = auth.uid()
    where schedule_product_id = v_product.schedule_product_id;

    v_assignments := v_assignments || jsonb_build_array(
      jsonb_build_object(
        'schedule_product_id', v_product.schedule_product_id,
        'product_code', v_product.product_code,
        'production_weekday', v_product.production_weekday,
        'production_order', v_next_order
      )
    );
  end loop;

  if jsonb_array_length(v_assignments) > 0 then
    -- Child changes must also advance the revision token returned to the UI.
    update public.customer_schedule_versions
    set updated_by = auth.uid()
    where schedule_version_id = p_schedule_version_id;

    insert into public.audit_log (
      actor_auth_user_id,
      actor_staff_id,
      action,
      entity_table,
      entity_id,
      new_data,
      reason,
      source_application
    )
    values (
      auth.uid(),
      public.current_staff_id(),
      'ASSIGN_MISSING_CUSTOMER_PRODUCTION_ORDERS',
      'customer_schedule_versions',
      p_schedule_version_id::text,
      jsonb_build_object('assignments', v_assignments),
      trim(p_change_reason),
      p_source_application
    );
  end if;

  return public.build_customer_schedule_version_snapshot(
    p_schedule_version_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Publish with a final order conflict check
-- ---------------------------------------------------------------------

create or replace function public.publish_customer_schedule_draft_with_order_normalization(
  p_schedule_version_id uuid,
  p_expected_row_version integer,
  p_change_reason text,
  p_source_application text default 'CUSTOMER_STUDIO'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_version public.customer_schedule_versions%rowtype;
  v_product record;
  v_next_order integer;
  v_expected_after_normalization integer;
  v_assignments jsonb := '[]'::jsonb;
begin
  perform public.require_customer_schedule_edit_role();

  if nullif(trim(p_change_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'A publication reason is required.';
  end if;

  if p_expected_row_version is null then
    raise exception using
      errcode = '22023',
      message = 'The expected schedule row version is required.';
  end if;

  select *
  into v_version
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Schedule working revision not found.';
  end if;

  if v_version.status <> 'DRAFT' then
    raise exception using
      errcode = '55000',
      message = 'Only an editable working schedule revision can be published.';
  end if;

  if v_version.row_version <> p_expected_row_version then
    raise exception using
      errcode = '40001',
      message = 'The schedule was changed by another user.',
      hint = 'Reload the schedule before confirming the update.';
  end if;

  for v_product in
    select
      p.schedule_product_id,
      p.production_order,
      d.production_weekday,
      pt.product_code
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and p.active = true
    order by d.production_weekday, pt.sort_order, pt.product_code
  loop
    perform pg_advisory_xact_lock(
      hashtextextended(
        concat_ws(
          ':',
          'CUSTOMER_PRODUCTION_ORDER',
          v_product.product_code,
          v_product.production_weekday,
          v_version.effective_from
        ),
        0
      )
    );

    if v_product.production_order is null
       or exists (
         select 1
         from public.customer_schedule_versions current_version
         join public.customer_schedule_days current_day
           on current_day.schedule_version_id = current_version.schedule_version_id
         join public.customer_schedule_products current_product
           on current_product.schedule_day_id = current_day.schedule_day_id
         join public.product_types current_type
           on current_type.product_type_id = current_product.product_type_id
         where current_version.status = 'PUBLISHED'
           and v_version.effective_from >= current_version.effective_from
           and (
             current_version.effective_until is null
             or v_version.effective_from <= current_version.effective_until
           )
           and current_version.customer_id <> v_version.customer_id
           and current_day.active = true
           and current_day.production_weekday = v_product.production_weekday
           and current_product.active = true
           and current_type.product_code = v_product.product_code
           and current_product.production_order = v_product.production_order
       ) then
      select coalesce(max(current_product.production_order), 0) + 1
      into v_next_order
      from public.customer_schedule_versions current_version
      join public.customer_schedule_days current_day
        on current_day.schedule_version_id = current_version.schedule_version_id
      join public.customer_schedule_products current_product
        on current_product.schedule_day_id = current_day.schedule_day_id
      join public.product_types current_type
        on current_type.product_type_id = current_product.product_type_id
      where current_version.status = 'PUBLISHED'
        and v_version.effective_from >= current_version.effective_from
        and (
          current_version.effective_until is null
          or v_version.effective_from <= current_version.effective_until
        )
        and current_version.customer_id <> v_version.customer_id
        and current_day.active = true
        and current_day.production_weekday = v_product.production_weekday
        and current_product.active = true
        and current_type.product_code = v_product.product_code;

      update public.customer_schedule_products
      set
        production_order = v_next_order,
        updated_by = auth.uid()
      where schedule_product_id = v_product.schedule_product_id;

      v_assignments := v_assignments || jsonb_build_array(
        jsonb_build_object(
          'schedule_product_id', v_product.schedule_product_id,
          'product_code', v_product.product_code,
          'production_weekday', v_product.production_weekday,
          'previous_order', v_product.production_order,
          'production_order', v_next_order
        )
      );
    end if;
  end loop;

  if jsonb_array_length(v_assignments) > 0 then
    update public.customer_schedule_versions
    set updated_by = auth.uid()
    where schedule_version_id = p_schedule_version_id
    returning row_version into v_expected_after_normalization;

    insert into public.audit_log (
      actor_auth_user_id,
      actor_staff_id,
      action,
      entity_table,
      entity_id,
      old_data,
      new_data,
      reason,
      source_application
    )
    values (
      auth.uid(),
      public.current_staff_id(),
      'NORMALIZE_CUSTOMER_PRODUCTION_ORDERS_BEFORE_PUBLISH',
      'customer_schedule_versions',
      p_schedule_version_id::text,
      jsonb_build_object('expected_row_version', p_expected_row_version),
      jsonb_build_object('assignments', v_assignments),
      trim(p_change_reason),
      p_source_application
    );
  else
    v_expected_after_normalization := p_expected_row_version;
  end if;

  return public.publish_customer_schedule_draft(
    p_schedule_version_id,
    v_expected_after_normalization,
    p_change_reason,
    p_source_application
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Reorder one complete planner day
-- ---------------------------------------------------------------------

create or replace function public.reorder_customer_planner_day(
  p_product_code text,
  p_production_weekday smallint,
  p_effective_date date,
  p_items jsonb,
  p_change_reason text,
  p_source_application text default 'CUSTOMER_PLANNER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_product_code text := upper(trim(p_product_code));
  v_item jsonb;
  v_customer_id uuid;
  v_expected_version_id uuid;
  v_current_version_id uuid;
  v_current_order integer;
  v_desired_order integer;
  v_item_count integer;
  v_current_count integer;
  v_updated_rows integer;
  v_updated_count integer := 0;
  v_draft_id uuid;
  v_published public.customer_schedule_versions%rowtype;
  v_seen_customer_ids uuid[] := array[]::uuid[];
  v_changes jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  perform public.require_customer_schedule_edit_role();

  if v_product_code is null
     or v_product_code not in ('CLOTHES', 'MOP') then
    raise exception using
      errcode = '22023',
      message = 'Product code must be CLOTHES or MOP.';
  end if;

  if p_production_weekday is null
     or p_production_weekday not between 1 and 7 then
    raise exception using
      errcode = '22023',
      message = 'Production weekday must be between 1 and 7.';
  end if;

  if p_effective_date is null then
    raise exception using
      errcode = '22023',
      message = 'Effective date is required.';
  end if;

  if p_effective_date < public.current_business_date() then
    raise exception using
      errcode = '22023',
      message = 'Historical production order cannot be changed.',
      hint = 'Select the current business date or a future effective date.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'A reason is required to change production order.';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception using
      errcode = '22023',
      message = 'The ordered items payload must be a JSON array.';
  end if;

  v_item_count := jsonb_array_length(p_items);

  if v_item_count = 0 then
    raise exception using
      errcode = '22023',
      message = 'At least one planner item is required.';
  end if;

  -- One lock covers the complete day and service. All validation and all
  -- replacement publications below occur in the same transaction.
  perform pg_advisory_xact_lock(
    hashtextextended(
      concat_ws(
        ':',
        'CUSTOMER_PLANNER_REORDER',
        v_product_code,
        p_production_weekday,
        p_effective_date
      ),
      0
    )
  );

  -- Use the same lock as automatic assignment/publication so a new customer
  -- cannot enter this day between the browser snapshot validation and commit.
  perform pg_advisory_xact_lock(
    hashtextextended(
      concat_ws(
        ':',
        'CUSTOMER_PRODUCTION_ORDER',
        v_product_code,
        p_production_weekday,
        p_effective_date
      ),
      0
    )
  );

  select count(*)
  into v_current_count
  from public.customer_schedule_versions current_version
  join public.customers customer
    on customer.customer_id = current_version.customer_id
  join public.customer_schedule_days current_day
    on current_day.schedule_version_id = current_version.schedule_version_id
  join public.customer_schedule_products current_product
    on current_product.schedule_day_id = current_day.schedule_day_id
  join public.product_types current_type
    on current_type.product_type_id = current_product.product_type_id
  where current_version.status = 'PUBLISHED'
    and p_effective_date >= current_version.effective_from
    and (
      current_version.effective_until is null
      or p_effective_date <= current_version.effective_until
    )
    and customer.active = true
    and customer.deleted_at is null
    and current_day.active = true
    and current_day.production_weekday = p_production_weekday
    and current_product.active = true
    and current_type.active = true
    and current_type.deleted_at is null
    and current_type.product_code = v_product_code;

  if v_current_count <> v_item_count then
    raise exception using
      errcode = '40001',
      message = 'The planner changed before the new order was saved.',
      detail = format(
        'Browser item count %s does not match current item count %s.',
        v_item_count,
        v_current_count
      ),
      hint = 'Reload the planner and drag the customer again.';
  end if;

  -- Validate the complete browser snapshot before creating any revision.
  for v_item, v_desired_order in
    select value, ordinality::integer
    from jsonb_array_elements(p_items) with ordinality
  loop
    begin
      v_customer_id := nullif(trim(v_item ->> 'customer_id'), '')::uuid;
      v_expected_version_id := nullif(
        trim(v_item ->> 'schedule_version_id'),
        ''
      )::uuid;
    exception when others then
      raise exception using
        errcode = '22023',
        message = 'Every planner item needs valid customer_id and schedule_version_id values.';
    end;

    if v_customer_id is null or v_expected_version_id is null then
      raise exception using
        errcode = '22023',
        message = 'Every planner item needs customer_id and schedule_version_id.';
    end if;

    if v_customer_id = any(v_seen_customer_ids) then
      raise exception using
        errcode = '22023',
        message = 'The same customer appears more than once in the ordered planner payload.';
    end if;

    v_seen_customer_ids := array_append(v_seen_customer_ids, v_customer_id);

    select
      current_version.schedule_version_id,
      current_product.production_order
    into
      v_current_version_id,
      v_current_order
    from public.customer_schedule_versions current_version
    join public.customers customer
      on customer.customer_id = current_version.customer_id
    join public.customer_schedule_days current_day
      on current_day.schedule_version_id = current_version.schedule_version_id
    join public.customer_schedule_products current_product
      on current_product.schedule_day_id = current_day.schedule_day_id
    join public.product_types current_type
      on current_type.product_type_id = current_product.product_type_id
    where current_version.customer_id = v_customer_id
      and current_version.status = 'PUBLISHED'
      and p_effective_date >= current_version.effective_from
      and (
        current_version.effective_until is null
        or p_effective_date <= current_version.effective_until
      )
      and customer.active = true
      and customer.deleted_at is null
      and current_day.active = true
      and current_day.production_weekday = p_production_weekday
      and current_product.active = true
      and current_type.product_code = v_product_code
    limit 1;

    if v_current_version_id is null
       or v_current_version_id <> v_expected_version_id then
      raise exception using
        errcode = '40001',
        message = 'The planner changed before the new order was saved.',
        detail = format('Customer %s is no longer on the expected revision.', v_customer_id),
        hint = 'Reload the planner and drag the customer again.';
    end if;

    if exists (
      select 1
      from public.customer_schedule_versions draft
      where draft.customer_id = v_customer_id
        and draft.status = 'DRAFT'
    ) then
      raise exception using
        errcode = '55000',
        message = 'A customer in this day is currently being edited.',
        detail = format('Customer %s has an open working schedule revision.', v_customer_id),
        hint = 'Finish or discard that customer edit, reload the planner, and try again.';
    end if;
  end loop;

  -- Create a replacement revision only where the position actually changes.
  for v_item, v_desired_order in
    select value, ordinality::integer
    from jsonb_array_elements(p_items) with ordinality
  loop
    v_customer_id := (v_item ->> 'customer_id')::uuid;
    v_expected_version_id := (v_item ->> 'schedule_version_id')::uuid;

    select current_product.production_order
    into v_current_order
    from public.customer_schedule_days current_day
    join public.customer_schedule_products current_product
      on current_product.schedule_day_id = current_day.schedule_day_id
    join public.product_types current_type
      on current_type.product_type_id = current_product.product_type_id
    where current_day.schedule_version_id = v_expected_version_id
      and current_day.active = true
      and current_day.production_weekday = p_production_weekday
      and current_product.active = true
      and current_type.product_code = v_product_code
    limit 1;

    if v_current_order is not distinct from v_desired_order then
      continue;
    end if;

    v_draft_id := public.create_customer_schedule_draft(
      v_customer_id,
      p_effective_date,
      v_expected_version_id,
      trim(p_change_reason),
      p_source_application
    );

    update public.customer_schedule_products draft_product
    set
      production_order = v_desired_order,
      updated_by = auth.uid()
    from public.customer_schedule_days draft_day,
         public.product_types draft_type
    where draft_day.schedule_version_id = v_draft_id
      and draft_day.schedule_day_id = draft_product.schedule_day_id
      and draft_day.active = true
      and draft_day.production_weekday = p_production_weekday
      and draft_type.product_type_id = draft_product.product_type_id
      and draft_type.product_code = v_product_code
      and draft_product.active = true;

    get diagnostics v_updated_rows = row_count;

    if v_updated_rows <> 1 then
      raise exception using
        errcode = '55000',
        message = 'The production order target could not be resolved in the replacement schedule.',
        detail = format(
          'Customer %s, product %s, weekday %s, affected rows %s.',
          v_customer_id,
          v_product_code,
          p_production_weekday,
          v_updated_rows
        );
    end if;

    v_published := public.publish_customer_schedule(
      v_draft_id,
      trim(p_change_reason),
      p_source_application
    );

    v_updated_count := v_updated_count + 1;
    v_changes := v_changes || jsonb_build_array(
      jsonb_build_object(
        'customer_id', v_customer_id,
        'previous_schedule_version_id', v_expected_version_id,
        'published_schedule_version_id', v_published.schedule_version_id,
        'previous_order', v_current_order,
        'production_order', v_desired_order
      )
    );
  end loop;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'REORDER_CUSTOMER_PLANNER_DAY',
    'customer_schedule_products',
    concat_ws(
      ':',
      v_product_code,
      p_production_weekday,
      p_effective_date
    ),
    jsonb_build_object('submitted_items', p_items),
    jsonb_build_object(
      'updated_count', v_updated_count,
      'changes', v_changes
    ),
    trim(p_change_reason),
    p_source_application
  );

  if v_product_code = 'MOP' then
    v_result := public.get_mop_weekly_planner(
      p_effective_date,
      null,
      null
    );
  else
    v_result := public.get_clothes_weekly_planner(
      p_effective_date,
      null,
      null
    );
  end if;

  return v_result || jsonb_build_object(
    'updated_count', v_updated_count,
    'reordered_weekday', p_production_weekday,
    'product_code', v_product_code
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Privileges and documentation
-- ---------------------------------------------------------------------

-- The previous browser write paths are intentionally closed so missing or
-- conflicting production orders cannot bypass the new controlled wrappers.
revoke all on function public.save_customer_schedule_draft(
  uuid, integer, jsonb, text, text
) from authenticated;
revoke all on function public.publish_customer_schedule_draft(
  uuid, integer, text, text
) from authenticated;

revoke all on function public.save_customer_schedule_draft_with_auto_orders(
  uuid, integer, jsonb, text, text
) from public, anon, authenticated;
revoke all on function public.publish_customer_schedule_draft_with_order_normalization(
  uuid, integer, text, text
) from public, anon, authenticated;
revoke all on function public.reorder_customer_planner_day(
  text, smallint, date, jsonb, text, text
) from public, anon, authenticated;

grant execute on function public.save_customer_schedule_draft_with_auto_orders(
  uuid, integer, jsonb, text, text
) to authenticated;
grant execute on function public.publish_customer_schedule_draft_with_order_normalization(
  uuid, integer, text, text
) to authenticated;
grant execute on function public.reorder_customer_planner_day(
  text, smallint, date, jsonb, text, text
) to authenticated;

comment on function public.save_customer_schedule_draft_with_auto_orders(
  uuid, integer, jsonb, text, text
) is 'Saves one complete Customer Schedule working revision and assigns the next available production order to any active product whose order is blank.';

comment on function public.publish_customer_schedule_draft_with_order_normalization(
  uuid, integer, text, text
) is 'Performs a final concurrency-safe production-order conflict check before publishing a Customer Schedule working revision.';

comment on function public.reorder_customer_planner_day(
  text, smallint, date, jsonb, text, text
) is 'Atomically reorders one complete Clothes or MOP production day. The function validates a full current planner snapshot and publishes replacement revisions only for changed customers.';

commit;
