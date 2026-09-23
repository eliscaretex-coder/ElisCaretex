-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608030004_distribution_daily_planning_validation.sql
--
-- Covered:
--   - no authenticated direct table access;
--   - controlled RPC privileges;
--   - daily plan creation from the applicable Customer Schedule;
--   - actual route reassignment without rewriting the default route;
--   - transactional save with row_version concurrency;
--   - Ready and Reopen Planning status flow;
--   - all temporary writes are rolled back.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Resolve an active ADMIN and a safe date with scheduled stops
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

with candidate_dates as (
  select (public.current_business_date() + offset_days)::date as business_date
  from generate_series(-28, 56) as offset_days
), safe_dates as (
  select
    c.business_date,
    count(*)::integer as stop_count
  from candidate_dates c
  cross join lateral public.distribution_daily_source_stops(c.business_date) s
  where not exists (
    select 1
    from public.distribution_daily_plans p
    where p.business_date = c.business_date
  )
  group by c.business_date
  having count(*) >= 2
  order by
    case when c.business_date >= public.current_business_date() then 0 else 1 end,
    abs(c.business_date - public.current_business_date()),
    c.business_date
  limit 1
)
select set_config(
  'eliscaretex.validation.distribution_daily_date',
  business_date::text,
  true
)
from safe_dates;

do $$
begin
  if nullif(
    current_setting('eliscaretex.validation.distribution_daily_date', true),
    ''
  ) is null then
    raise exception 'No safe Distribution date with at least two scheduled stops was found.';
  end if;
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Security and privileges
-- ---------------------------------------------------------------------

do $$
begin
  if has_table_privilege('authenticated', 'public.distribution_daily_plans', 'SELECT')
     or has_table_privilege('authenticated', 'public.distribution_daily_plans', 'INSERT')
     or has_table_privilege('authenticated', 'public.distribution_daily_plans', 'UPDATE')
     or has_table_privilege('authenticated', 'public.distribution_daily_stops', 'SELECT')
     or has_table_privilege('authenticated', 'public.distribution_daily_stops', 'INSERT')
     or has_table_privilege('authenticated', 'public.distribution_daily_stops', 'UPDATE') then
    raise exception 'Authenticated still has direct Distribution Daily table access.';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.get_distribution_daily_plan(date)',
       'EXECUTE'
     ) then
    raise exception 'Daily plan read RPC is not executable.';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.create_distribution_daily_plan(date,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Daily plan create RPC is not executable.';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.save_distribution_daily_plan(uuid,integer,jsonb,text,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Daily plan save RPC is not executable.';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.set_distribution_daily_plan_status(uuid,integer,text,text,text)',
       'EXECUTE'
     ) then
    raise exception 'Daily plan status RPC is not executable.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Read preview and create the daily plan
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.distribution_daily_preview',
  public.get_distribution_daily_plan(
    current_setting('eliscaretex.validation.distribution_daily_date')::date
  )::text,
  true
);

do $$
declare
  v_preview jsonb := current_setting(
    'eliscaretex.validation.distribution_daily_preview'
  )::jsonb;
begin
  if v_preview -> 'plan' <> 'null'::jsonb then
    raise exception 'The selected validation date unexpectedly already has a plan.';
  end if;

  if coalesce((v_preview -> 'source_preview' ->> 'stop_count')::integer, 0) < 2 then
    raise exception 'The source preview did not return the expected scheduled stops.';
  end if;
end;
$$;

select set_config(
  'eliscaretex.validation.distribution_daily_created',
  public.create_distribution_daily_plan(
    p_business_date => current_setting(
      'eliscaretex.validation.distribution_daily_date'
    )::date,
    p_change_reason => 'Validate Distribution Daily plan creation.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
declare
  v_created jsonb := current_setting(
    'eliscaretex.validation.distribution_daily_created'
  )::jsonb;
  v_stop jsonb;
begin
  if v_created -> 'plan' ->> 'status' <> 'PLANNING' then
    raise exception 'Created daily plan is not in PLANNING status.';
  end if;

  if jsonb_array_length(v_created -> 'stops') <> (
    v_created -> 'source_preview' ->> 'stop_count'
  )::integer then
    raise exception 'Created stop count does not match the source preview.';
  end if;

  for v_stop in select value from jsonb_array_elements(v_created -> 'stops')
  loop
    if v_stop ->> 'actual_route_id' is distinct from v_stop ->> 'default_route_id' then
      raise exception 'A newly created stop did not copy its default route.';
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Move one stop to SUPPORT and save
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.distribution_daily_support_route',
  route.value ->> 'route_id',
  true
)
from jsonb_array_elements(
  current_setting('eliscaretex.validation.distribution_daily_created')::jsonb
    -> 'routes'
) route(value)
where route.value ->> 'route_code' = 'SUPPORT'
limit 1;

do $$
begin
  if nullif(
    current_setting('eliscaretex.validation.distribution_daily_support_route', true),
    ''
  ) is null then
    raise exception 'The SUPPORT route is missing.';
  end if;
end;
$$;

with source_stops as (
  select
    value,
    row_number() over (
      order by
        (value ->> 'stop_order')::integer,
        value ->> 'customer_name'
    ) as sequence
  from jsonb_array_elements(
    current_setting('eliscaretex.validation.distribution_daily_created')::jsonb
      -> 'stops'
  )
), save_document as (
  select jsonb_agg(
    jsonb_build_object(
      'daily_stop_id', value ->> 'daily_stop_id',
      'actual_route_id', case
        when sequence = 1 then current_setting(
          'eliscaretex.validation.distribution_daily_support_route'
        )
        else nullif(value ->> 'actual_route_id', '')
      end,
      'stop_order', case
        when sequence = 1 then 1
        else (value ->> 'stop_order')::integer
      end,
      'delivery_window_start', nullif(value ->> 'delivery_window_start', ''),
      'delivery_window_end', nullif(value ->> 'delivery_window_end', ''),
      'planner_notes', case
        when sequence = 1 then 'Validation move to Support.'
        else nullif(value ->> 'planner_notes', '')
      end,
      'stop_status', value ->> 'stop_status'
    )
    order by sequence
  ) as stops
  from source_stops
)
select set_config(
  'eliscaretex.validation.distribution_daily_saved',
  public.save_distribution_daily_plan(
    p_plan_id => (
      current_setting('eliscaretex.validation.distribution_daily_created')::jsonb
        -> 'plan' ->> 'plan_id'
    )::uuid,
    p_expected_row_version => (
      current_setting('eliscaretex.validation.distribution_daily_created')::jsonb
        -> 'plan' ->> 'row_version'
    )::integer,
    p_stops => save_document.stops,
    p_plan_notes => 'Validation daily plan note.',
    p_change_reason => 'Validate actual route reassignment and save.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
)
from save_document;

do $$
declare
  v_created jsonb := current_setting(
    'eliscaretex.validation.distribution_daily_created'
  )::jsonb;
  v_saved jsonb := current_setting(
    'eliscaretex.validation.distribution_daily_saved'
  )::jsonb;
  v_support_route text := current_setting(
    'eliscaretex.validation.distribution_daily_support_route'
  );
  v_moved jsonb;
begin
  if (v_saved -> 'plan' ->> 'row_version')::integer <=
     (v_created -> 'plan' ->> 'row_version')::integer then
    raise exception 'Daily plan row_version did not increment.';
  end if;

  select value into v_moved
  from jsonb_array_elements(v_saved -> 'stops')
  where value ->> 'actual_route_id' = v_support_route
  limit 1;

  if v_moved is null then
    raise exception 'The stop was not reassigned to SUPPORT.';
  end if;

  if v_moved ->> 'actual_route_kind' <> 'SUPPORT' then
    raise exception 'The actual route kind was not returned as SUPPORT.';
  end if;

  if v_moved ->> 'default_route_id' = v_support_route then
    raise exception 'The protected default route was incorrectly rewritten.';
  end if;

  if v_saved -> 'plan' ->> 'plan_notes' <> 'Validation daily plan note.' then
    raise exception 'Daily plan notes were not saved.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Mark Ready, then reopen Planning
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex.validation.distribution_daily_ready',
  public.set_distribution_daily_plan_status(
    p_plan_id => (
      current_setting('eliscaretex.validation.distribution_daily_saved')::jsonb
        -> 'plan' ->> 'plan_id'
    )::uuid,
    p_expected_row_version => (
      current_setting('eliscaretex.validation.distribution_daily_saved')::jsonb
        -> 'plan' ->> 'row_version'
    )::integer,
    p_status => 'READY',
    p_change_reason => 'Validate Ready status.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
begin
  if current_setting('eliscaretex.validation.distribution_daily_ready')::jsonb
       -> 'plan' ->> 'status' <> 'READY' then
    raise exception 'Daily plan was not marked READY.';
  end if;
end;
$$;

select set_config(
  'eliscaretex.validation.distribution_daily_reopened',
  public.set_distribution_daily_plan_status(
    p_plan_id => (
      current_setting('eliscaretex.validation.distribution_daily_ready')::jsonb
        -> 'plan' ->> 'plan_id'
    )::uuid,
    p_expected_row_version => (
      current_setting('eliscaretex.validation.distribution_daily_ready')::jsonb
        -> 'plan' ->> 'row_version'
    )::integer,
    p_status => 'PLANNING',
    p_change_reason => 'Validate reopening the daily plan.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
begin
  if current_setting('eliscaretex.validation.distribution_daily_reopened')::jsonb
       -> 'plan' ->> 'status' <> 'PLANNING' then
    raise exception 'Daily plan was not reopened to PLANNING.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Final result
-- ---------------------------------------------------------------------

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608030004_distribution_daily_planning_validation',
  'daily_plan_snapshot', true,
  'actual_route_assignment', true,
  'default_schedule_preserved', true,
  'optimistic_concurrency', true,
  'ready_and_reopen_flow', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
