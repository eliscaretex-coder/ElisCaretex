-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608030004_distribution_daily_planning.sql
-- Purpose:
--   Create the controlled Distribution Daily Planning model and RPC API.
--
-- Important semantics:
--   - Customer Schedule routes remain the default/reference routes.
--   - A daily plan snapshots the applicable delivery stops for one date.
--   - Actual daily route assignments and stop order never rewrite the
--     published Customer Schedule.
--   - Browser clients use security-definer RPCs; no direct table access.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Reserved operational routes
-- ---------------------------------------------------------------------

insert into public.distribution_routes (
  route_code,
  display_name,
  route_color,
  route_kind,
  allow_as_default,
  active,
  sort_order,
  notes,
  metadata
)
values
  ('COLLECTION', 'Collection', '#0EA5A6', 'COLLECTION', false, true, 900,
   'Reserved actual daily route. It must not be used as a Customer Schedule default route.',
   jsonb_build_object('system_route', true, 'daily_planning_only', true)),
  ('AD_HOC', 'Ad hoc', '#F97316', 'AD_HOC', false, true, 910,
   'Reserved actual daily route. It must not be used as a Customer Schedule default route.',
   jsonb_build_object('system_route', true, 'daily_planning_only', true)),
  ('SUPPORT', 'Support', '#64748B', 'SUPPORT', false, true, 920,
   'Reserved actual daily route. It must not be used as a Customer Schedule default route.',
   jsonb_build_object('system_route', true, 'daily_planning_only', true))
on conflict (route_code) do nothing;

-- ---------------------------------------------------------------------
-- Daily plan tables
-- ---------------------------------------------------------------------

create table public.distribution_daily_plans (
  plan_id uuid primary key default gen_random_uuid(),
  business_date date not null unique,
  status text not null default 'PLANNING',
  source_effective_date date not null,
  source_signature text not null,
  plan_notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  ready_at timestamptz,
  ready_by uuid references auth.users(id) on delete set null,
  closed_at timestamptz,
  closed_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint distribution_daily_plans_status_check
    check (status in ('PLANNING', 'READY', 'CLOSED', 'CANCELLED')),
  constraint distribution_daily_plans_row_version_check
    check (row_version > 0)
);

create table public.distribution_daily_stops (
  daily_stop_id uuid primary key default gen_random_uuid(),
  plan_id uuid not null
    references public.distribution_daily_plans(plan_id) on delete cascade,
  customer_id uuid not null
    references public.customers(customer_id) on delete restrict,
  source_schedule_version_id uuid
    references public.customer_schedule_versions(schedule_version_id)
    on delete restrict,
  source_schedule_day_id uuid
    references public.customer_schedule_days(schedule_day_id)
    on delete restrict,
  production_weekday smallint,
  delivery_weekday smallint,
  default_route_id uuid
    references public.distribution_routes(route_id) on delete restrict,
  actual_route_id uuid
    references public.distribution_routes(route_id) on delete restrict,
  source_delivery_order integer,
  stop_order integer not null,
  delivery_window_start time,
  delivery_window_end time,
  customer_code_snapshot text not null,
  customer_name_snapshot text not null,
  eircode_snapshot text,
  planned_product_codes text[] not null default array[]::text[],
  planned_trolley_total integer not null default 0,
  planned_trolley_summary text,
  estimated_kg numeric(12,2),
  stop_units integer,
  operational_alert text,
  day_alert text,
  distribution_instructions text,
  planner_notes text,
  stop_status text not null default 'PLANNED',
  manually_added boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint distribution_daily_stops_production_weekday_check
    check (production_weekday is null or production_weekday between 1 and 7),
  constraint distribution_daily_stops_delivery_weekday_check
    check (delivery_weekday is null or delivery_weekday between 1 and 7),
  constraint distribution_daily_stops_order_check
    check (stop_order > 0),
  constraint distribution_daily_stops_trolley_check
    check (planned_trolley_total >= 0),
  constraint distribution_daily_stops_status_check
    check (stop_status in ('PLANNED', 'REMOVED', 'SKIPPED', 'COMPLETED')),
  constraint distribution_daily_stops_row_version_check
    check (row_version > 0),
  constraint distribution_daily_stops_window_check
    check (
      delivery_window_start is null
      or delivery_window_end is null
      or delivery_window_end >= delivery_window_start
    )
);

create unique index distribution_daily_stops_source_unique
  on public.distribution_daily_stops (plan_id, source_schedule_day_id)
  where source_schedule_day_id is not null;

create index distribution_daily_stops_route_order_idx
  on public.distribution_daily_stops
  (plan_id, actual_route_id, stop_status, stop_order);

create index distribution_daily_stops_customer_idx
  on public.distribution_daily_stops (customer_id, plan_id);

create trigger distribution_daily_plans_set_updated_at
before update on public.distribution_daily_plans
for each row execute function public.set_updated_at();

create trigger distribution_daily_stops_set_updated_at
before update on public.distribution_daily_stops
for each row execute function public.set_updated_at();

alter table public.distribution_daily_plans enable row level security;
alter table public.distribution_daily_stops enable row level security;

revoke all on table public.distribution_daily_plans
  from public, anon, authenticated;
revoke all on table public.distribution_daily_stops
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Internal source snapshot
-- ---------------------------------------------------------------------

create or replace function public.distribution_daily_source_stops(
  p_business_date date
)
returns table (
  source_schedule_version_id uuid,
  source_schedule_day_id uuid,
  customer_id uuid,
  production_weekday smallint,
  delivery_weekday smallint,
  default_route_id uuid,
  source_delivery_order integer,
  delivery_window_start time,
  delivery_window_end time,
  customer_code text,
  customer_name text,
  eircode text,
  planned_product_codes text[],
  planned_trolley_total integer,
  planned_trolley_summary text,
  estimated_kg numeric,
  stop_units integer,
  operational_alert text,
  day_alert text,
  distribution_instructions text
)
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select
    v.schedule_version_id,
    d.schedule_day_id,
    c.customer_id,
    d.production_weekday,
    d.delivery_weekday,
    d.default_route_id,
    d.delivery_order,
    d.delivery_window_start,
    d.delivery_window_end,
    c.customer_code,
    c.customer_name,
    c.eircode,
    coalesce(products.product_codes, array[]::text[]) as planned_product_codes,
    coalesce(trolley.total_quantity, 0)::integer as planned_trolley_total,
    trolley.trolley_summary,
    c.distribution_estimated_kg,
    c.distribution_stop_count,
    c.operational_alert,
    d.day_alert,
    d.distribution_instructions
  from public.customer_schedule_versions v
  join public.customers c
    on c.customer_id = v.customer_id
  join public.customer_schedule_days d
    on d.schedule_version_id = v.schedule_version_id
  left join lateral (
    select array_agg(pt.product_code order by pt.sort_order, pt.product_code)
      as product_codes
    from public.customer_schedule_products p
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
    where p.schedule_day_id = d.schedule_day_id
      and p.active = true
      and pt.active = true
      and pt.deleted_at is null
  ) products on true
  left join lateral (
    select
      sum(req.quantity)::integer as total_quantity,
      string_agg(
        concat(
          req.quantity,
          coalesce(tt.display_code, tt.trolley_type_code),
          ' (', owner_pt.product_code,
          case when served.product_count > 1 then ', Shared' else '' end,
          case when req.empty_trolley then ', Empty' else '' end,
          ')'
        ),
        ' + ' order by tt.sort_order, req.created_at
      ) as trolley_summary
    from public.customer_schedule_trolley_requirements req
    join public.trolley_types tt
      on tt.trolley_type_id = req.trolley_type_id
    join public.customer_schedule_products owner_product
      on owner_product.schedule_product_id = req.owner_schedule_product_id
    join public.product_types owner_pt
      on owner_pt.product_type_id = owner_product.product_type_id
    left join lateral (
      select count(*)::integer as product_count
      from public.customer_schedule_trolley_requirement_products map
      where map.schedule_trolley_requirement_id = req.schedule_trolley_requirement_id
    ) served on true
    where req.schedule_day_id = d.schedule_day_id
      and req.active = true
      and tt.active = true
      and tt.deleted_at is null
  ) trolley on true
  where v.status = 'PUBLISHED'
    and p_business_date >= v.effective_from
    and (v.effective_until is null or p_business_date <= v.effective_until)
    and c.active = true
    and c.deleted_at is null
    and d.active = true
    and d.delivery_weekday = extract(isodow from p_business_date)::smallint;
$$;

revoke all on function public.distribution_daily_source_stops(date)
  from public, anon, authenticated;

create or replace function public.distribution_daily_source_signature(
  p_business_date date
)
returns text
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select md5(
    coalesce(
      string_agg(
        concat_ws(
          '|',
          s.source_schedule_version_id::text,
          s.source_schedule_day_id::text,
          s.customer_id::text,
          coalesce(s.default_route_id::text, ''),
          coalesce(s.source_delivery_order::text, ''),
          array_to_string(s.planned_product_codes, ','),
          s.planned_trolley_total::text,
          coalesce(s.planned_trolley_summary, ''),
          coalesce(s.distribution_instructions, '')
        ),
        '||' order by
          s.delivery_weekday,
          s.default_route_id nulls last,
          s.source_delivery_order nulls last,
          lower(s.customer_name),
          s.source_schedule_day_id
      ),
      ''
    )
  )
  from public.distribution_daily_source_stops(p_business_date) s;
$$;

revoke all on function public.distribution_daily_source_signature(date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Read model
-- ---------------------------------------------------------------------

create or replace function public.get_distribution_daily_plan(
  p_business_date date default public.current_business_date()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_plan public.distribution_daily_plans%rowtype;
  v_result jsonb;
  v_source_signature text;
  v_source_stop_count integer;
  v_source_kg numeric;
  v_source_trolleys integer;
  v_can_edit boolean;
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR', 'AUDITOR']
  );

  v_can_edit := public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']
  );

  select * into v_plan
  from public.distribution_daily_plans
  where business_date = p_business_date;

  v_source_signature := public.distribution_daily_source_signature(p_business_date);

  select
    count(*)::integer,
    coalesce(sum(s.estimated_kg), 0),
    coalesce(sum(s.planned_trolley_total), 0)::integer
  into v_source_stop_count, v_source_kg, v_source_trolleys
  from public.distribution_daily_source_stops(p_business_date) s;

  select jsonb_build_object(
    'business_date', p_business_date,
    'delivery_weekday', extract(isodow from p_business_date)::integer,
    'delivery_day', public.weekday_name(extract(isodow from p_business_date)::smallint),
    'permissions', jsonb_build_object(
      'can_view', true,
      'can_edit', v_can_edit,
      'can_mark_ready', v_can_edit,
      'can_reopen', v_can_edit
    ),
    'source_preview', jsonb_build_object(
      'source', 'CUSTOMER_DEFAULT_SCHEDULE',
      'stop_count', v_source_stop_count,
      'estimated_kg', v_source_kg,
      'planned_trolleys', v_source_trolleys,
      'signature', v_source_signature
    ),
    'plan', case when v_plan.plan_id is null then null else jsonb_build_object(
      'plan_id', v_plan.plan_id,
      'business_date', v_plan.business_date,
      'status', v_plan.status,
      'source_effective_date', v_plan.source_effective_date,
      'source_signature', v_plan.source_signature,
      'source_schedule_changed', v_plan.source_signature is distinct from v_source_signature,
      'plan_notes', v_plan.plan_notes,
      'row_version', v_plan.row_version,
      'created_at', v_plan.created_at,
      'updated_at', v_plan.updated_at,
      'ready_at', v_plan.ready_at,
      'closed_at', v_plan.closed_at
    ) end,
    'routes', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'route_id', r.route_id,
          'route_code', r.route_code,
          'display_name', r.display_name,
          'route_color', r.route_color,
          'route_kind', r.route_kind,
          'allow_as_default', r.allow_as_default,
          'sort_order', r.sort_order
        ) order by r.sort_order, r.route_code
      )
      from public.distribution_routes r
      where r.active = true
        and r.deleted_at is null
    ), '[]'::jsonb),
    'stops', case when v_plan.plan_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'daily_stop_id', s.daily_stop_id,
          'plan_id', s.plan_id,
          'customer_id', s.customer_id,
          'source_schedule_version_id', s.source_schedule_version_id,
          'source_schedule_day_id', s.source_schedule_day_id,
          'production_weekday', s.production_weekday,
          'production_day', public.weekday_name(s.production_weekday),
          'delivery_weekday', s.delivery_weekday,
          'delivery_day', public.weekday_name(s.delivery_weekday),
          'default_route_id', s.default_route_id,
          'default_route_code', default_route.route_code,
          'default_route_display_name', default_route.display_name,
          'default_route_color', default_route.route_color,
          'actual_route_id', s.actual_route_id,
          'actual_route_code', actual_route.route_code,
          'actual_route_display_name', actual_route.display_name,
          'actual_route_color', actual_route.route_color,
          'actual_route_kind', actual_route.route_kind,
          'source_delivery_order', s.source_delivery_order,
          'stop_order', s.stop_order,
          'delivery_window_start', s.delivery_window_start,
          'delivery_window_end', s.delivery_window_end,
          'customer_code', s.customer_code_snapshot,
          'customer_name', s.customer_name_snapshot,
          'eircode', s.eircode_snapshot,
          'planned_product_codes', s.planned_product_codes,
          'planned_trolley_total', s.planned_trolley_total,
          'planned_trolley_summary', s.planned_trolley_summary,
          'estimated_kg', s.estimated_kg,
          'stop_units', s.stop_units,
          'operational_alert', s.operational_alert,
          'day_alert', s.day_alert,
          'distribution_instructions', s.distribution_instructions,
          'planner_notes', s.planner_notes,
          'stop_status', s.stop_status,
          'manually_added', s.manually_added,
          'row_version', s.row_version
        ) order by
          actual_route.sort_order nulls last,
          actual_route.route_code nulls last,
          s.stop_order,
          lower(s.customer_name_snapshot)
      )
      from public.distribution_daily_stops s
      left join public.distribution_routes default_route
        on default_route.route_id = s.default_route_id
      left join public.distribution_routes actual_route
        on actual_route.route_id = s.actual_route_id
      where s.plan_id = v_plan.plan_id
    ), '[]'::jsonb) end
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Create plan from Customer Schedule
-- ---------------------------------------------------------------------

create or replace function public.create_distribution_daily_plan(
  p_business_date date,
  p_change_reason text,
  p_source_application text default 'DISTRIBUTION_DAILY_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_plan_id uuid;
  v_reason text := nullif(trim(p_change_reason), '');
  v_existing uuid;
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']
  );

  if v_reason is null then
    raise exception using errcode = '22023', message = 'A reason is required.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('distribution_daily_plan:' || p_business_date::text, 0));

  select plan_id into v_existing
  from public.distribution_daily_plans
  where business_date = p_business_date;

  if v_existing is not null then
    return public.get_distribution_daily_plan(p_business_date);
  end if;

  insert into public.distribution_daily_plans (
    business_date,
    status,
    source_effective_date,
    source_signature,
    created_by,
    updated_by
  ) values (
    p_business_date,
    'PLANNING',
    p_business_date,
    public.distribution_daily_source_signature(p_business_date),
    auth.uid(),
    auth.uid()
  ) returning plan_id into v_plan_id;

  insert into public.distribution_daily_stops (
    plan_id,
    customer_id,
    source_schedule_version_id,
    source_schedule_day_id,
    production_weekday,
    delivery_weekday,
    default_route_id,
    actual_route_id,
    source_delivery_order,
    stop_order,
    delivery_window_start,
    delivery_window_end,
    customer_code_snapshot,
    customer_name_snapshot,
    eircode_snapshot,
    planned_product_codes,
    planned_trolley_total,
    planned_trolley_summary,
    estimated_kg,
    stop_units,
    operational_alert,
    day_alert,
    distribution_instructions,
    created_by,
    updated_by
  )
  select
    v_plan_id,
    s.customer_id,
    s.source_schedule_version_id,
    s.source_schedule_day_id,
    s.production_weekday,
    s.delivery_weekday,
    s.default_route_id,
    s.default_route_id,
    s.source_delivery_order,
    row_number() over (
      partition by s.default_route_id
      order by
        s.source_delivery_order nulls last,
        lower(s.customer_name),
        s.source_schedule_day_id
    )::integer,
    s.delivery_window_start,
    s.delivery_window_end,
    s.customer_code,
    s.customer_name,
    s.eircode,
    s.planned_product_codes,
    s.planned_trolley_total,
    s.planned_trolley_summary,
    s.estimated_kg,
    s.stop_units,
    s.operational_alert,
    s.day_alert,
    s.distribution_instructions,
    auth.uid(),
    auth.uid()
  from public.distribution_daily_source_stops(p_business_date) s;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    new_data,
    reason,
    source_application
  ) values (
    auth.uid(),
    public.current_staff_id(),
    'DISTRIBUTION_DAILY_PLAN_CREATED',
    'distribution_daily_plans',
    v_plan_id::text,
    jsonb_build_object(
      'business_date', p_business_date,
      'source_signature', public.distribution_daily_source_signature(p_business_date),
      'stop_count', (select count(*) from public.distribution_daily_stops where plan_id = v_plan_id)
    ),
    v_reason,
    coalesce(nullif(trim(p_source_application), ''), 'DISTRIBUTION_DAILY_UI')
  );

  return public.get_distribution_daily_plan(p_business_date);
end;
$$;

-- ---------------------------------------------------------------------
-- Save route assignments, stop order and planner notes
-- ---------------------------------------------------------------------

create or replace function public.save_distribution_daily_plan(
  p_plan_id uuid,
  p_expected_row_version integer,
  p_stops jsonb,
  p_plan_notes text,
  p_change_reason text,
  p_source_application text default 'DISTRIBUTION_DAILY_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_plan public.distribution_daily_plans%rowtype;
  v_reason text := nullif(trim(p_change_reason), '');
  v_total integer;
  v_incoming integer;
  v_new_row_version integer;
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']
  );

  if v_reason is null then
    raise exception using errcode = '22023', message = 'A reason is required.';
  end if;

  if jsonb_typeof(p_stops) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Stops must be a JSON array.';
  end if;

  select * into v_plan
  from public.distribution_daily_plans
  where plan_id = p_plan_id
  for update;

  if v_plan.plan_id is null then
    raise exception using errcode = 'P0002', message = 'Distribution daily plan not found.';
  end if;

  if v_plan.status <> 'PLANNING' then
    raise exception using errcode = '55000', message = 'Only a plan in Planning status can be edited.';
  end if;

  if v_plan.row_version <> p_expected_row_version then
    raise exception using
      errcode = '40001',
      message = 'This daily plan was changed by another user.',
      hint = 'Reload the plan before saving again.';
  end if;

  select count(*) into v_total
  from public.distribution_daily_stops
  where plan_id = p_plan_id;

  select count(*) into v_incoming
  from jsonb_array_elements(p_stops);

  if v_total <> v_incoming then
    raise exception using
      errcode = '22023',
      message = 'The saved plan must include every daily stop.',
      detail = format('Expected %s stops but received %s.', v_total, v_incoming);
  end if;

  if exists (
    with incoming as (
      select x.daily_stop_id
      from jsonb_to_recordset(p_stops) as x(daily_stop_id uuid)
    )
    select 1 from incoming group by daily_stop_id having count(*) > 1
  ) then
    raise exception using errcode = '22023', message = 'Duplicate daily stop IDs were supplied.';
  end if;

  if exists (
    with incoming as (
      select x.daily_stop_id
      from jsonb_to_recordset(p_stops) as x(daily_stop_id uuid)
    )
    select 1
    from incoming i
    left join public.distribution_daily_stops s
      on s.daily_stop_id = i.daily_stop_id
     and s.plan_id = p_plan_id
    where s.daily_stop_id is null
  ) then
    raise exception using errcode = '22023', message = 'A supplied stop does not belong to this plan.';
  end if;

  if exists (
    with incoming as (
      select x.actual_route_id
      from jsonb_to_recordset(p_stops) as x(actual_route_id uuid)
      where x.actual_route_id is not null
    )
    select 1
    from incoming i
    left join public.distribution_routes r
      on r.route_id = i.actual_route_id
     and r.active = true
     and r.deleted_at is null
    where r.route_id is null
  ) then
    raise exception using errcode = '22023', message = 'An assigned route is inactive or does not exist.';
  end if;

  if exists (
    with incoming as (
      select
        x.actual_route_id,
        x.stop_order,
        upper(coalesce(x.stop_status, 'PLANNED')) as stop_status
      from jsonb_to_recordset(p_stops) as x(
        actual_route_id uuid,
        stop_order integer,
        stop_status text
      )
    )
    select 1
    from incoming
    where stop_status not in ('PLANNED', 'REMOVED', 'SKIPPED', 'COMPLETED')
       or stop_order is null
       or stop_order <= 0
  ) then
    raise exception using errcode = '22023', message = 'Each stop needs a valid status and positive order.';
  end if;

  if exists (
    with incoming as (
      select
        x.actual_route_id,
        x.stop_order,
        upper(coalesce(x.stop_status, 'PLANNED')) as stop_status
      from jsonb_to_recordset(p_stops) as x(
        actual_route_id uuid,
        stop_order integer,
        stop_status text
      )
    )
    select 1
    from incoming
    where stop_status = 'PLANNED'
    group by actual_route_id, stop_order
    having count(*) > 1
  ) then
    raise exception using errcode = '22023', message = 'Two planned stops cannot use the same order on one route.';
  end if;

  with incoming as (
    select
      x.daily_stop_id,
      x.actual_route_id,
      x.stop_order,
      x.delivery_window_start,
      x.delivery_window_end,
      nullif(trim(x.planner_notes), '') as planner_notes,
      upper(coalesce(x.stop_status, 'PLANNED')) as stop_status
    from jsonb_to_recordset(p_stops) as x(
      daily_stop_id uuid,
      actual_route_id uuid,
      stop_order integer,
      delivery_window_start time,
      delivery_window_end time,
      planner_notes text,
      stop_status text
    )
  )
  update public.distribution_daily_stops s
  set
    actual_route_id = i.actual_route_id,
    stop_order = i.stop_order,
    delivery_window_start = i.delivery_window_start,
    delivery_window_end = i.delivery_window_end,
    planner_notes = i.planner_notes,
    stop_status = i.stop_status,
    updated_by = auth.uid(),
    row_version = s.row_version + 1
  from incoming i
  where s.daily_stop_id = i.daily_stop_id
    and s.plan_id = p_plan_id;

  update public.distribution_daily_plans
  set
    plan_notes = nullif(trim(p_plan_notes), ''),
    updated_by = auth.uid(),
    row_version = row_version + 1
  where plan_id = p_plan_id
  returning row_version into v_new_row_version;

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
  ) values (
    auth.uid(),
    public.current_staff_id(),
    'DISTRIBUTION_DAILY_PLAN_SAVED',
    'distribution_daily_plans',
    p_plan_id::text,
    jsonb_build_object('row_version', v_plan.row_version, 'plan_notes', v_plan.plan_notes),
    jsonb_build_object('row_version', v_new_row_version, 'plan_notes', nullif(trim(p_plan_notes), ''), 'stop_count', v_total),
    v_reason,
    coalesce(nullif(trim(p_source_application), ''), 'DISTRIBUTION_DAILY_UI')
  );

  return public.get_distribution_daily_plan(v_plan.business_date);
end;
$$;

-- ---------------------------------------------------------------------
-- Mark ready or reopen planning
-- ---------------------------------------------------------------------

create or replace function public.set_distribution_daily_plan_status(
  p_plan_id uuid,
  p_expected_row_version integer,
  p_status text,
  p_change_reason text,
  p_source_application text default 'DISTRIBUTION_DAILY_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_plan public.distribution_daily_plans%rowtype;
  v_status text := upper(trim(coalesce(p_status, '')));
  v_reason text := nullif(trim(p_change_reason), '');
begin
  perform public.require_any_customer_read_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']
  );

  if v_status not in ('READY', 'PLANNING') then
    raise exception using errcode = '22023', message = 'Allowed statuses are READY and PLANNING.';
  end if;

  if v_reason is null then
    raise exception using errcode = '22023', message = 'A reason is required.';
  end if;

  select * into v_plan
  from public.distribution_daily_plans
  where plan_id = p_plan_id
  for update;

  if v_plan.plan_id is null then
    raise exception using errcode = 'P0002', message = 'Distribution daily plan not found.';
  end if;

  if v_plan.row_version <> p_expected_row_version then
    raise exception using
      errcode = '40001',
      message = 'This daily plan was changed by another user.',
      hint = 'Reload the plan before continuing.';
  end if;

  if v_status = 'READY' then
    if v_plan.status <> 'PLANNING' then
      raise exception using errcode = '55000', message = 'Only a Planning plan can be marked Ready.';
    end if;

    if exists (
      select 1
      from public.distribution_daily_stops
      where plan_id = p_plan_id
        and stop_status = 'PLANNED'
        and actual_route_id is null
    ) then
      raise exception using
        errcode = '22023',
        message = 'Every planned stop must have an actual route before the plan is marked Ready.';
    end if;

    update public.distribution_daily_plans
    set
      status = 'READY',
      ready_at = now(),
      ready_by = auth.uid(),
      updated_by = auth.uid(),
      row_version = row_version + 1
    where plan_id = p_plan_id;
  else
    if v_plan.status <> 'READY' then
      raise exception using errcode = '55000', message = 'Only a Ready plan can be reopened.';
    end if;

    update public.distribution_daily_plans
    set
      status = 'PLANNING',
      ready_at = null,
      ready_by = null,
      updated_by = auth.uid(),
      row_version = row_version + 1
    where plan_id = p_plan_id;
  end if;

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
  ) values (
    auth.uid(),
    public.current_staff_id(),
    case when v_status = 'READY'
      then 'DISTRIBUTION_DAILY_PLAN_READY'
      else 'DISTRIBUTION_DAILY_PLAN_REOPENED'
    end,
    'distribution_daily_plans',
    p_plan_id::text,
    jsonb_build_object('status', v_plan.status, 'row_version', v_plan.row_version),
    jsonb_build_object('status', v_status),
    v_reason,
    coalesce(nullif(trim(p_source_application), ''), 'DISTRIBUTION_DAILY_UI')
  );

  return public.get_distribution_daily_plan(v_plan.business_date);
end;
$$;

-- ---------------------------------------------------------------------
-- Capability discovery
-- ---------------------------------------------------------------------

create or replace function public.get_customer_read_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_can_manage_schedules boolean;
  v_can_view_distribution boolean;
  v_can_manage_distribution boolean;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR',
      'SORTING_OPERATOR', 'FINISH_OPERATOR', 'MOP_OPERATOR',
      'DISTRIBUTION_OPERATOR'
    ]
  );

  v_can_manage_schedules := public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER']
  );
  v_can_view_distribution := public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR', 'AUDITOR']
  );
  v_can_manage_distribution := public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'DISTRIBUTION_OPERATOR']
  );

  return jsonb_build_object(
    'business_date', public.current_business_date(),
    'can_view_customer_directory', public.has_any_role(
      array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
    ),
    'can_edit_customers', public.has_any_role(
      array['ADMIN', 'MANAGER', 'PLANNER']
    ),
    'can_deactivate_customers', public.has_any_role(
      array['ADMIN', 'MANAGER']
    ),
    'can_edit_schedules', v_can_manage_schedules,
    'can_create_schedule_draft', v_can_manage_schedules,
    'can_save_schedule_draft', v_can_manage_schedules,
    'can_compare_schedule_draft', v_can_manage_schedules,
    'can_publish_schedule_draft', v_can_manage_schedules,
    'can_cancel_schedule_draft', v_can_manage_schedules,
    'can_restore_schedule_version', v_can_manage_schedules,
    'can_view_schedule_history', public.has_any_role(
      array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
    ),
    'can_view_clothes_planner', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
        'SORTING_OPERATOR', 'FINISH_OPERATOR', 'AUDITOR'
      ]
    ),
    'can_view_mop_planner', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
        'MOP_OPERATOR', 'AUDITOR'
      ]
    ),
    'can_view_distribution', v_can_view_distribution,
    'can_view_distribution_daily', v_can_view_distribution,
    'can_edit_distribution_daily', v_can_manage_distribution,
    'can_mark_distribution_ready', v_can_manage_distribution
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------

revoke all on function public.get_distribution_daily_plan(date)
  from public, anon;
revoke all on function public.create_distribution_daily_plan(date, text, text)
  from public, anon;
revoke all on function public.save_distribution_daily_plan(uuid, integer, jsonb, text, text, text)
  from public, anon;
revoke all on function public.set_distribution_daily_plan_status(uuid, integer, text, text, text)
  from public, anon;

grant execute on function public.get_distribution_daily_plan(date)
  to authenticated;
grant execute on function public.create_distribution_daily_plan(date, text, text)
  to authenticated;
grant execute on function public.save_distribution_daily_plan(uuid, integer, jsonb, text, text, text)
  to authenticated;
grant execute on function public.set_distribution_daily_plan_status(uuid, integer, text, text, text)
  to authenticated;

comment on table public.distribution_daily_plans
  is 'One controlled actual Distribution plan per business date. It snapshots Customer Schedule defaults without rewriting them.';
comment on table public.distribution_daily_stops
  is 'Daily Distribution stop snapshots with actual route assignment and stop order.';
comment on function public.get_distribution_daily_plan(date)
  is 'Protected Distribution Daily Planning read model.';
comment on function public.create_distribution_daily_plan(date, text, text)
  is 'Creates a daily plan by snapshotting Customer Schedule stops delivered on the selected date.';
comment on function public.save_distribution_daily_plan(uuid, integer, jsonb, text, text, text)
  is 'Saves all daily route assignments and orders transactionally with optimistic concurrency.';
comment on function public.set_distribution_daily_plan_status(uuid, integer, text, text, text)
  is 'Marks a daily Distribution plan Ready or reopens it for planning.';

commit;
