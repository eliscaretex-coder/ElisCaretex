-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110001_production_flow_foundation_and_wash_trace
--
-- Production Flow principle:
--   One stable flow item represents one customer + product production
--   occurrence. Operational modules append traceable events to that item.
--
-- Detailed module tables remain the source of truth. The flow layer stores:
--   * stable identity / current summary;
--   * immutable cross-module event references;
--   * external production batch references (ABS today, integration-ready later).
--
-- Scheduled identity:
--   customer + product + scheduled_for_date
--
-- Unscheduled identity:
--   customer + product + originating Business Date
--
-- Washing:
--   Every V2 customer trace is linked automatically to one Production Flow Item.
--   Multiple physical Wash IDs for the same customer/product/scheduled date
--   therefore share the same Production Flow Item.
--
-- ABS:
--   Manual capture is supported now.
--   capture_source is designed for future INTEGRATION without schema replacement.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Production Flow master
-- ---------------------------------------------------------------------

create table if not exists public.production_flow_items (
  production_flow_item_id uuid primary key default gen_random_uuid(),
  flow_code text not null unique,

  customer_id uuid not null
    references public.customers(customer_id) on delete restrict,
  customer_code_snapshot text,
  customer_name_snapshot text not null,

  product_code text not null,
  flow_origin text not null,

  scheduled_for_date date,
  opened_business_date date not null,

  source_schedule_version_id uuid
    references public.customer_schedule_versions(schedule_version_id) on delete restrict,
  source_schedule_day_id uuid
    references public.customer_schedule_days(schedule_day_id) on delete restrict,
  source_schedule_product_id uuid
    references public.customer_schedule_products(schedule_product_id) on delete restrict,

  production_order_snapshot integer,
  route_id_snapshot uuid
    references public.distribution_routes(route_id) on delete restrict,
  route_code_snapshot text,
  route_display_name_snapshot text,
  route_color_snapshot text,

  current_stage_code text not null default 'PLANNED',
  current_stage_rank integer not null default 10,
  flow_status text not null default 'OPEN',

  last_event_type text,
  last_event_at timestamptz,
  last_area_code text,
  last_performed_by_staff_id uuid
    references public.staff_members(staff_id) on delete set null,
  event_count integer not null default 0,

  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  row_version integer not null default 1,

  constraint production_flow_items_product_code_check
    check (product_code in ('CLOTHES','MOP','OTHERS')),
  constraint production_flow_items_origin_check
    check (flow_origin in ('SCHEDULED','UNSCHEDULED','NOT_APPLICABLE')),
  constraint production_flow_items_stage_check
    check (current_stage_code in (
      'PLANNED','INTAKE','WASHING','PRODUCTION','OUTBOUND','DELIVERY','COMPLETED'
    )),
  constraint production_flow_items_stage_rank_check
    check (current_stage_rank in (10,20,30,40,50,60,70)),
  constraint production_flow_items_status_check
    check (flow_status in ('OPEN','COMPLETED','CANCELLED')),
  constraint production_flow_items_schedule_origin_check
    check (
      (flow_origin='SCHEDULED' and scheduled_for_date is not null)
      or
      (flow_origin in ('UNSCHEDULED','NOT_APPLICABLE') and scheduled_for_date is null)
    )
);

create unique index if not exists production_flow_items_scheduled_uidx
  on public.production_flow_items (
    customer_id,
    product_code,
    scheduled_for_date
  )
  where scheduled_for_date is not null;

create unique index if not exists production_flow_items_unscheduled_uidx
  on public.production_flow_items (
    customer_id,
    product_code,
    opened_business_date
  )
  where scheduled_for_date is null;

create index if not exists production_flow_items_tracker_idx
  on public.production_flow_items (
    opened_business_date,
    current_stage_rank,
    flow_status,
    customer_name_snapshot
  );

create index if not exists production_flow_items_schedule_idx
  on public.production_flow_items (
    scheduled_for_date,
    product_code,
    production_order_snapshot
  )
  where scheduled_for_date is not null;

alter table public.production_flow_items enable row level security;
revoke all on table public.production_flow_items
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Immutable cross-module events
-- ---------------------------------------------------------------------

create table if not exists public.production_flow_events (
  production_flow_event_id uuid primary key default gen_random_uuid(),
  production_flow_item_id uuid not null
    references public.production_flow_items(production_flow_item_id) on delete restrict,

  event_type text not null,
  stage_code text not null,
  stage_rank integer not null,
  area_code text not null,

  business_date date not null,
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default now(),

  performed_by_staff_id uuid
    references public.staff_members(staff_id) on delete set null,
  recorded_by_staff_id uuid
    references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid
    references auth.users(id) on delete set null,

  source_application text not null,
  source_entity_table text not null,
  source_entity_id text not null,

  event_data jsonb not null default '{}'::jsonb,

  constraint production_flow_events_stage_check
    check (stage_code in (
      'PLANNED','INTAKE','WASHING','PRODUCTION','OUTBOUND','DELIVERY','COMPLETED'
    )),
  constraint production_flow_events_stage_rank_check
    check (stage_rank in (10,20,30,40,50,60,70))
);

create unique index if not exists production_flow_events_source_uidx
  on public.production_flow_events (
    production_flow_item_id,
    event_type,
    source_entity_table,
    source_entity_id
  );

create index if not exists production_flow_events_daily_tracker_idx
  on public.production_flow_events (
    business_date,
    occurred_at,
    stage_rank,
    event_type
  );

create index if not exists production_flow_events_item_timeline_idx
  on public.production_flow_events (
    production_flow_item_id,
    occurred_at,
    recorded_at
  );

alter table public.production_flow_events enable row level security;
revoke all on table public.production_flow_events
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. External production batches (ABS)
-- ---------------------------------------------------------------------

create table if not exists public.production_flow_external_batches (
  production_flow_external_batch_id uuid primary key default gen_random_uuid(),
  production_flow_item_id uuid not null
    references public.production_flow_items(production_flow_item_id) on delete restrict,

  external_system_code text not null default 'ABS',
  batch_reference text not null,
  quantity numeric(14,2) not null,
  unit_code text not null,

  capture_source text not null default 'MANUAL',
  status text not null default 'ACTIVE',

  supersedes_external_batch_id uuid
    references public.production_flow_external_batches(production_flow_external_batch_id)
    on delete restrict,

  notes text,
  correction_reason text,
  integration_metadata jsonb not null default '{}'::jsonb,

  recorded_at timestamptz not null default now(),
  recorded_by_staff_id uuid
    references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid
    references auth.users(id) on delete set null,

  cancelled_at timestamptz,
  cancelled_by_staff_id uuid
    references public.staff_members(staff_id) on delete set null,
  cancelled_by_auth_user_id uuid
    references auth.users(id) on delete set null,

  constraint production_flow_external_batches_system_check
    check (length(trim(external_system_code)) between 1 and 40),
  constraint production_flow_external_batches_reference_check
    check (length(trim(batch_reference)) between 1 and 120),
  constraint production_flow_external_batches_quantity_check
    check (quantity > 0),
  constraint production_flow_external_batches_unit_check
    check (unit_code in ('KG','UNIT')),
  constraint production_flow_external_batches_unit_integer_check
    check (unit_code <> 'UNIT' or quantity = trunc(quantity)),
  constraint production_flow_external_batches_capture_check
    check (capture_source in ('MANUAL','INTEGRATION')),
  constraint production_flow_external_batches_status_check
    check (status in ('ACTIVE','SUPERSEDED','CANCELLED'))
);

create unique index if not exists production_flow_external_batches_active_uidx
  on public.production_flow_external_batches (
    production_flow_item_id,
    external_system_code,
    batch_reference
  )
  where status='ACTIVE';

create index if not exists production_flow_external_batches_reference_idx
  on public.production_flow_external_batches (
    external_system_code,
    batch_reference,
    status
  );

alter table public.production_flow_external_batches enable row level security;
revoke all on table public.production_flow_external_batches
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Washing trace -> Production Flow
-- ---------------------------------------------------------------------

alter table public.sorting_wash_run_customers
  add column if not exists production_flow_item_id uuid
    references public.production_flow_items(production_flow_item_id) on delete restrict;

create index if not exists sorting_wash_run_customers_flow_idx
  on public.sorting_wash_run_customers(production_flow_item_id)
  where production_flow_item_id is not null;

-- ---------------------------------------------------------------------
-- 5. Private authorization helpers
-- ---------------------------------------------------------------------

create or replace function public.require_production_flow_read_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null
     or public.current_staff_id() is null
     or not public.has_any_role(array[
       'ADMIN','MANAGER','SUPERVISOR','AUDITOR',
       'SORTING_OPERATOR','FINISH_OPERATOR','MOP_OPERATOR','DISTRIBUTION_OPERATOR'
     ]) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow access to Production Flow.';
  end if;
end;
$$;

create or replace function public.require_production_flow_batch_write_role()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null
     or public.current_staff_id() is null
     or not public.has_any_role(array[
       'ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR','MOP_OPERATOR'
     ]) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow ABS production batch entry.';
  end if;
end;
$$;

revoke all on function public.require_production_flow_read_role()
  from public, anon, authenticated;
revoke all on function public.require_production_flow_batch_write_role()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Flow identity resolver
-- ---------------------------------------------------------------------

create or replace function public.ensure_production_flow_item(
  p_customer_id uuid,
  p_product_code text,
  p_scheduled_for_date date,
  p_opened_business_date date,
  p_source_schedule_version_id uuid default null,
  p_source_schedule_day_id uuid default null,
  p_source_schedule_product_id uuid default null,
  p_production_order integer default null,
  p_route_id uuid default null,
  p_route_code text default null,
  p_route_display_name text default null,
  p_route_color text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_product_code text := upper(trim(coalesce(p_product_code,'')));
  v_customer public.customers%rowtype;
  v_origin text;
  v_flow_id uuid;
  v_flow_code text;
begin
  if p_customer_id is null then
    raise exception using errcode='22023', message='Production Flow customer is required.';
  end if;

  if v_product_code not in ('CLOTHES','MOP','OTHERS') then
    raise exception using errcode='22023', message='Production Flow product must be CLOTHES, MOP or OTHERS.';
  end if;

  if p_opened_business_date is null then
    raise exception using errcode='22023', message='Production Flow originating Business Date is required.';
  end if;

  select *
  into v_customer
  from public.customers c
  where c.customer_id=p_customer_id
    and c.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Production Flow customer was not found.';
  end if;

  v_origin := case
    when p_scheduled_for_date is not null then 'SCHEDULED'
    when v_product_code='OTHERS' then 'NOT_APPLICABLE'
    else 'UNSCHEDULED'
  end;

  if p_scheduled_for_date is not null then
    insert into public.production_flow_items (
      flow_code,
      customer_id,
      customer_code_snapshot,
      customer_name_snapshot,
      product_code,
      flow_origin,
      scheduled_for_date,
      opened_business_date,
      source_schedule_version_id,
      source_schedule_day_id,
      source_schedule_product_id,
      production_order_snapshot,
      route_id_snapshot,
      route_code_snapshot,
      route_display_name_snapshot,
      route_color_snapshot,
      created_by_auth_user_id
    )
    values (
      'PF' || to_char(p_scheduled_for_date,'YYYYMMDD') || '-' ||
        upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
      v_customer.customer_id,
      v_customer.customer_code,
      v_customer.customer_name,
      v_product_code,
      v_origin,
      p_scheduled_for_date,
      p_opened_business_date,
      p_source_schedule_version_id,
      p_source_schedule_day_id,
      p_source_schedule_product_id,
      p_production_order,
      p_route_id,
      nullif(trim(coalesce(p_route_code,'')),''),
      nullif(trim(coalesce(p_route_display_name,'')),''),
      nullif(trim(coalesce(p_route_color,'')),''),
      auth.uid()
    )
    on conflict (
      customer_id,
      product_code,
      scheduled_for_date
    )
    where scheduled_for_date is not null
    do update
    set source_schedule_version_id =
          coalesce(public.production_flow_items.source_schedule_version_id,
                   excluded.source_schedule_version_id),
        source_schedule_day_id =
          coalesce(public.production_flow_items.source_schedule_day_id,
                   excluded.source_schedule_day_id),
        source_schedule_product_id =
          coalesce(public.production_flow_items.source_schedule_product_id,
                   excluded.source_schedule_product_id),
        production_order_snapshot =
          coalesce(public.production_flow_items.production_order_snapshot,
                   excluded.production_order_snapshot),
        route_id_snapshot =
          coalesce(public.production_flow_items.route_id_snapshot,
                   excluded.route_id_snapshot),
        route_code_snapshot =
          coalesce(public.production_flow_items.route_code_snapshot,
                   excluded.route_code_snapshot),
        route_display_name_snapshot =
          coalesce(public.production_flow_items.route_display_name_snapshot,
                   excluded.route_display_name_snapshot),
        route_color_snapshot =
          coalesce(public.production_flow_items.route_color_snapshot,
                   excluded.route_color_snapshot),
        updated_at=now(),
        row_version=public.production_flow_items.row_version+1
    returning production_flow_item_id into v_flow_id;
  else
    insert into public.production_flow_items (
      flow_code,
      customer_id,
      customer_code_snapshot,
      customer_name_snapshot,
      product_code,
      flow_origin,
      scheduled_for_date,
      opened_business_date,
      created_by_auth_user_id
    )
    values (
      'PF' || to_char(p_opened_business_date,'YYYYMMDD') || '-' ||
        upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
      v_customer.customer_id,
      v_customer.customer_code,
      v_customer.customer_name,
      v_product_code,
      v_origin,
      null,
      p_opened_business_date,
      auth.uid()
    )
    on conflict (
      customer_id,
      product_code,
      opened_business_date
    )
    where scheduled_for_date is null
    do update
    set updated_at=now(),
        row_version=public.production_flow_items.row_version+1
    returning production_flow_item_id into v_flow_id;
  end if;

  return v_flow_id;
end;
$$;

revoke all on function public.ensure_production_flow_item(
  uuid,text,date,date,uuid,uuid,uuid,integer,uuid,text,text,text
) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Immutable event append
-- ---------------------------------------------------------------------

create or replace function public.append_production_flow_event(
  p_production_flow_item_id uuid,
  p_event_type text,
  p_stage_code text,
  p_stage_rank integer,
  p_area_code text,
  p_business_date date,
  p_occurred_at timestamptz,
  p_performed_by_staff_id uuid,
  p_recorded_by_staff_id uuid,
  p_recorded_by_auth_user_id uuid,
  p_source_application text,
  p_source_entity_table text,
  p_source_entity_id text,
  p_event_data jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_event_id uuid;
  v_event_type text := upper(trim(coalesce(p_event_type,'')));
  v_stage_code text := upper(trim(coalesce(p_stage_code,'')));
  v_area_code text := upper(trim(coalesce(p_area_code,'')));
begin
  if p_production_flow_item_id is null
     or v_event_type=''
     or v_stage_code=''
     or v_area_code=''
     or p_business_date is null
     or p_occurred_at is null
     or nullif(trim(coalesce(p_source_application,'')),'') is null
     or nullif(trim(coalesce(p_source_entity_table,'')),'') is null
     or nullif(trim(coalesce(p_source_entity_id,'')),'') is null then
    raise exception using errcode='22023', message='Production Flow event identity is incomplete.';
  end if;

  if v_stage_code not in (
    'PLANNED','INTAKE','WASHING','PRODUCTION','OUTBOUND','DELIVERY','COMPLETED'
  ) or p_stage_rank not in (10,20,30,40,50,60,70) then
    raise exception using errcode='22023', message='Invalid Production Flow stage.';
  end if;

  insert into public.production_flow_events (
    production_flow_item_id,
    event_type,
    stage_code,
    stage_rank,
    area_code,
    business_date,
    occurred_at,
    performed_by_staff_id,
    recorded_by_staff_id,
    recorded_by_auth_user_id,
    source_application,
    source_entity_table,
    source_entity_id,
    event_data
  )
  values (
    p_production_flow_item_id,
    v_event_type,
    v_stage_code,
    p_stage_rank,
    v_area_code,
    p_business_date,
    p_occurred_at,
    p_performed_by_staff_id,
    p_recorded_by_staff_id,
    p_recorded_by_auth_user_id,
    trim(p_source_application),
    trim(p_source_entity_table),
    trim(p_source_entity_id),
    coalesce(p_event_data,'{}'::jsonb)
  )
  on conflict (
    production_flow_item_id,
    event_type,
    source_entity_table,
    source_entity_id
  )
  do nothing
  returning production_flow_event_id into v_event_id;

  if v_event_id is not null then
    update public.production_flow_items pfi
    set
      current_stage_code = case
        when p_stage_rank >= pfi.current_stage_rank then v_stage_code
        else pfi.current_stage_code
      end,
      current_stage_rank = greatest(pfi.current_stage_rank,p_stage_rank),
      last_event_type = v_event_type,
      last_event_at = greatest(coalesce(pfi.last_event_at,p_occurred_at),p_occurred_at),
      last_area_code = v_area_code,
      last_performed_by_staff_id = p_performed_by_staff_id,
      event_count = pfi.event_count + 1,
      updated_at = now(),
      row_version = pfi.row_version + 1
    where pfi.production_flow_item_id=p_production_flow_item_id;
  else
    select pfe.production_flow_event_id
    into v_event_id
    from public.production_flow_events pfe
    where pfe.production_flow_item_id=p_production_flow_item_id
      and pfe.event_type=v_event_type
      and pfe.source_entity_table=trim(p_source_entity_table)
      and pfe.source_entity_id=trim(p_source_entity_id)
    limit 1;
  end if;

  return v_event_id;
end;
$$;

revoke all on function public.append_production_flow_event(
  uuid,text,text,integer,text,date,timestamptz,uuid,uuid,uuid,text,text,text,jsonb
) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. Link one Washing customer trace to a Flow Item
-- ---------------------------------------------------------------------

create or replace function public.link_sorting_wash_customer_to_production_flow(
  p_wash_run_customer_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_row record;
  v_flow_id uuid;
  v_recorded_by_staff_id uuid;
begin
  select
    wrc.wash_run_customer_id,
    wrc.customer_id,
    wrc.customer_code_snapshot,
    wrc.customer_name_snapshot,
    wrc.wash_type_snapshot,
    wrc.source_schedule_version_id,
    wrc.source_schedule_day_id,
    wrc.source_schedule_product_id,
    wrc.production_order_snapshot,
    wrc.scheduled_for_date,
    wrc.route_id_snapshot,
    wrc.route_code_snapshot,
    wrc.route_display_name_snapshot,
    wrc.route_color_snapshot,
    wrc.trace_code,
    wrc.production_flow_item_id,
    wr.wash_run_id,
    wr.wash_code,
    wr.business_date,
    wr.shift_code_snapshot,
    wr.washer_id,
    wr.washer_code_snapshot,
    wr.washer_name_snapshot,
    wr.operator_staff_id,
    wr.operator_name_snapshot,
    wr.started_at,
    wr.registered_at,
    wr.total_weight_kg,
    wr.status,
    wr.entry_mode,
    wr.replaces_wash_run_id,
    wr.recorded_by_auth_user_id,
    (
      select sm.staff_id
      from public.staff_members sm
      where sm.auth_user_id=wr.recorded_by_auth_user_id
        and sm.deleted_at is null
      order by sm.created_at
      limit 1
    ) as recorded_by_staff_id
  into v_row
  from public.sorting_wash_run_customers wrc
  join public.sorting_wash_runs wr
    on wr.wash_run_id=wrc.wash_run_id
  where wrc.wash_run_customer_id=p_wash_run_customer_id
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Sorting wash customer trace was not found.';
  end if;

  v_flow_id := public.ensure_production_flow_item(
    v_row.customer_id,
    v_row.wash_type_snapshot,
    v_row.scheduled_for_date,
    v_row.business_date,
    v_row.source_schedule_version_id,
    v_row.source_schedule_day_id,
    v_row.source_schedule_product_id,
    v_row.production_order_snapshot,
    v_row.route_id_snapshot,
    v_row.route_code_snapshot,
    v_row.route_display_name_snapshot,
    v_row.route_color_snapshot
  );

  if v_row.production_flow_item_id is distinct from v_flow_id then
    update public.sorting_wash_run_customers
    set production_flow_item_id=v_flow_id,
        metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
          'production_flow_linked',true,
          'production_flow_linked_at',now()
        )
    where wash_run_customer_id=v_row.wash_run_customer_id;
  end if;

  perform public.append_production_flow_event(
    v_flow_id,
    'WASH_RECORDED',
    'WASHING',
    30,
    'SORTING',
    v_row.business_date,
    v_row.started_at,
    v_row.operator_staff_id,
    v_row.recorded_by_staff_id,
    v_row.recorded_by_auth_user_id,
    'SORTING_V2',
    'sorting_wash_run_customers',
    v_row.wash_run_customer_id::text,
    jsonb_build_object(
      'wash_run_id',v_row.wash_run_id,
      'wash_code',v_row.wash_code,
      'trace_code',v_row.trace_code,
      'shift_code',v_row.shift_code_snapshot,
      'washer_id',v_row.washer_id,
      'washer_code',v_row.washer_code_snapshot,
      'washer_name',v_row.washer_name_snapshot,
      'operator_staff_id',v_row.operator_staff_id,
      'operator_name',v_row.operator_name_snapshot,
      'wash_type',v_row.wash_type_snapshot,
      'wash_load_total_kg',v_row.total_weight_kg,
      'weight_scope','WASH_LOAD_TOTAL_NOT_CUSTOMER_ALLOCATION',
      'registered_at',v_row.registered_at,
      'entry_mode',v_row.entry_mode
    )
  );

  if v_row.entry_mode='LATE_ENTRY' then
    perform public.append_production_flow_event(
      v_flow_id,
      'WASH_LATE_ENTRY',
      'WASHING',
      30,
      'SORTING',
      v_row.business_date,
      v_row.registered_at,
      v_row.operator_staff_id,
      v_row.recorded_by_staff_id,
      v_row.recorded_by_auth_user_id,
      'SORTING_V2',
      'sorting_wash_run_customers',
      v_row.wash_run_customer_id::text,
      jsonb_build_object(
        'wash_run_id',v_row.wash_run_id,
        'wash_code',v_row.wash_code,
        'physical_wash_started_at',v_row.started_at,
        'registered_at',v_row.registered_at
      )
    );
  elsif v_row.entry_mode='CORRECTION' then
    perform public.append_production_flow_event(
      v_flow_id,
      'WASH_CORRECTION_REPLACEMENT',
      'WASHING',
      30,
      'SORTING',
      v_row.business_date,
      v_row.registered_at,
      v_row.operator_staff_id,
      v_row.recorded_by_staff_id,
      v_row.recorded_by_auth_user_id,
      'SORTING_V2',
      'sorting_wash_run_customers',
      v_row.wash_run_customer_id::text,
      jsonb_build_object(
        'wash_run_id',v_row.wash_run_id,
        'wash_code',v_row.wash_code,
        'replaces_wash_run_id',v_row.replaces_wash_run_id
      )
    );
  end if;

  if v_row.status='CANCELLED' then
    perform public.append_production_flow_event(
      v_flow_id,
      'WASH_CANCELLED',
      'WASHING',
      30,
      'SORTING',
      v_row.business_date,
      coalesce(
        (
          select wr2.cancelled_at
          from public.sorting_wash_runs wr2
          where wr2.wash_run_id=v_row.wash_run_id
        ),
        v_row.registered_at
      ),
      v_row.operator_staff_id,
      v_row.recorded_by_staff_id,
      v_row.recorded_by_auth_user_id,
      'SORTING_V2',
      'sorting_wash_run_customers',
      v_row.wash_run_customer_id::text,
      jsonb_build_object(
        'wash_run_id',v_row.wash_run_id,
        'wash_code',v_row.wash_code
      )
    );
  end if;

  return v_flow_id;
end;
$$;

revoke all on function public.link_sorting_wash_customer_to_production_flow(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. Automatic linking after V2 final schedule snapshot update
-- ---------------------------------------------------------------------

create or replace function public.sorting_wash_customer_flow_link_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.link_sorting_wash_customer_to_production_flow(
    new.wash_run_customer_id
  );
  return new;
end;
$$;

revoke all on function public.sorting_wash_customer_flow_link_trigger()
  from public, anon, authenticated;

drop trigger if exists sorting_wash_customer_flow_link_after_snapshot
  on public.sorting_wash_run_customers;

create trigger sorting_wash_customer_flow_link_after_snapshot
after update of
  source_schedule_version_id,
  source_schedule_day_id,
  source_schedule_product_id,
  production_order_snapshot,
  schedule_relation,
  scheduled_for_date,
  route_id_snapshot,
  route_code_snapshot,
  route_display_name_snapshot,
  route_color_snapshot
on public.sorting_wash_run_customers
for each row
execute function public.sorting_wash_customer_flow_link_trigger();

-- ---------------------------------------------------------------------
-- 10. Washing status / correction events
-- ---------------------------------------------------------------------

create or replace function public.sorting_wash_run_flow_event_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_link record;
  v_recorded_by_staff_id uuid;
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  select sm.staff_id
  into v_recorded_by_staff_id
  from public.staff_members sm
  where sm.auth_user_id=new.recorded_by_auth_user_id
    and sm.deleted_at is null
  order by sm.created_at
  limit 1;

  for v_link in
    select
      wrc.wash_run_customer_id,
      wrc.production_flow_item_id,
      wrc.trace_code
    from public.sorting_wash_run_customers wrc
    where wrc.wash_run_id=new.wash_run_id
      and wrc.production_flow_item_id is not null
  loop
    if old.status is distinct from new.status
       and new.status='CANCELLED' then
      perform public.append_production_flow_event(
        v_link.production_flow_item_id,
        'WASH_CANCELLED',
        'WASHING',
        30,
        'SORTING',
        new.business_date,
        coalesce(new.cancelled_at,now()),
        new.operator_staff_id,
        v_recorded_by_staff_id,
        new.cancelled_by_auth_user_id,
        'SORTING_V2',
        'sorting_wash_run_customers',
        v_link.wash_run_customer_id::text,
        jsonb_build_object(
          'wash_run_id',new.wash_run_id,
          'wash_code',new.wash_code,
          'trace_code',v_link.trace_code,
          'reason',new.cancellation_reason
        )
      );
    end if;

    if old.entry_mode is distinct from new.entry_mode
       and new.entry_mode='LATE_ENTRY' then
      perform public.append_production_flow_event(
        v_link.production_flow_item_id,
        'WASH_LATE_ENTRY',
        'WASHING',
        30,
        'SORTING',
        new.business_date,
        new.registered_at,
        new.operator_staff_id,
        v_recorded_by_staff_id,
        new.recorded_by_auth_user_id,
        'SORTING_V2',
        'sorting_wash_run_customers',
        v_link.wash_run_customer_id::text,
        jsonb_build_object(
          'wash_run_id',new.wash_run_id,
          'wash_code',new.wash_code,
          'trace_code',v_link.trace_code,
          'physical_wash_started_at',new.started_at,
          'registered_at',new.registered_at,
          'late_entry_reason',new.correction_reason
        )
      );
    elsif old.entry_mode is distinct from new.entry_mode
       and new.entry_mode='CORRECTION' then
      perform public.append_production_flow_event(
        v_link.production_flow_item_id,
        'WASH_CORRECTION_REPLACEMENT',
        'WASHING',
        30,
        'SORTING',
        new.business_date,
        new.registered_at,
        new.operator_staff_id,
        v_recorded_by_staff_id,
        new.recorded_by_auth_user_id,
        'SORTING_V2',
        'sorting_wash_run_customers',
        v_link.wash_run_customer_id::text,
        jsonb_build_object(
          'wash_run_id',new.wash_run_id,
          'wash_code',new.wash_code,
          'trace_code',v_link.trace_code,
          'replaces_wash_run_id',new.replaces_wash_run_id,
          'correction_reason',new.correction_reason
        )
      );
    end if;
  end loop;

  return new;
end;
$$;

revoke all on function public.sorting_wash_run_flow_event_trigger()
  from public, anon, authenticated;

drop trigger if exists sorting_wash_run_flow_event_after_update
  on public.sorting_wash_runs;

create trigger sorting_wash_run_flow_event_after_update
after update of
  status,
  entry_mode,
  replaces_wash_run_id
on public.sorting_wash_runs
for each row
execute function public.sorting_wash_run_flow_event_trigger();

-- ---------------------------------------------------------------------
-- 11. Backfill existing Washing traces
-- ---------------------------------------------------------------------

do $$
declare
  v_trace record;
begin
  for v_trace in
    select wrc.wash_run_customer_id
    from public.sorting_wash_run_customers wrc
    order by wrc.created_at, wrc.wash_run_customer_id
  loop
    perform public.link_sorting_wash_customer_to_production_flow(
      v_trace.wash_run_customer_id
    );
  end loop;
end;
$$;

-- Flow-aware V2 is the only browser write path.
revoke execute on function public.save_sorting_wash_run(
  text,uuid,uuid,time,numeric,text,uuid[],text
) from authenticated;

-- ---------------------------------------------------------------------
-- 12. ABS manual entry APIs
-- ---------------------------------------------------------------------

create or replace function public.record_production_flow_abs_batch(
  p_production_flow_item_id uuid,
  p_batch_reference text,
  p_quantity numeric,
  p_unit_code text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_unit text := upper(trim(coalesce(p_unit_code,'')));
  v_reference text := nullif(trim(coalesce(p_batch_reference,'')),'');
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_staff_id uuid;
  v_batch public.production_flow_external_batches%rowtype;
begin
  perform public.require_production_flow_batch_write_role();

  if v_reference is null then
    raise exception using errcode='22023', message='ABS batch number is required.';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception using errcode='22023', message='ABS batch quantity must be greater than zero.';
  end if;

  if v_unit not in ('KG','UNIT') then
    raise exception using errcode='22023', message='ABS batch unit must be KG or UNIT.';
  end if;

  if v_unit='UNIT' and p_quantity <> trunc(p_quantity) then
    raise exception using errcode='22023', message='ABS UNIT quantity must be a whole number.';
  end if;

  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023', message='ABS batch notes must be 1000 characters or fewer.';
  end if;

  select *
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=p_production_flow_item_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Production Flow Item was not found.';
  end if;

  v_staff_id := public.current_staff_id();

  insert into public.production_flow_external_batches (
    production_flow_item_id,
    external_system_code,
    batch_reference,
    quantity,
    unit_code,
    capture_source,
    status,
    notes,
    recorded_by_staff_id,
    recorded_by_auth_user_id
  )
  values (
    v_flow.production_flow_item_id,
    'ABS',
    v_reference,
    p_quantity,
    v_unit,
    'MANUAL',
    'ACTIVE',
    v_notes,
    v_staff_id,
    auth.uid()
  )
  returning * into v_batch;

  perform public.append_production_flow_event(
    v_flow.production_flow_item_id,
    'ABS_BATCH_RECORDED',
    'PRODUCTION',
    40,
    case when v_flow.product_code='MOP' then 'MOP' else 'FINISH' end,
    public.current_business_date(),
    v_batch.recorded_at,
    v_staff_id,
    v_staff_id,
    auth.uid(),
    'ELISCARETEXT_V2',
    'production_flow_external_batches',
    v_batch.production_flow_external_batch_id::text,
    jsonb_build_object(
      'external_system_code','ABS',
      'batch_reference',v_batch.batch_reference,
      'quantity',v_batch.quantity,
      'unit_code',v_batch.unit_code,
      'capture_source',v_batch.capture_source
    )
  );

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
    v_staff_id,
    'PRODUCTION_FLOW_ABS_BATCH_RECORDED',
    'production_flow_external_batches',
    v_batch.production_flow_external_batch_id::text,
    to_jsonb(v_batch),
    v_notes,
    'ELISCARETEXT_V2'
  );

  return jsonb_build_object(
    'status','success',
    'production_flow_item_id',v_flow.production_flow_item_id,
    'flow_code',v_flow.flow_code,
    'external_batch_id',v_batch.production_flow_external_batch_id,
    'batch_reference',v_batch.batch_reference,
    'quantity',v_batch.quantity,
    'unit_code',v_batch.unit_code,
    'capture_source',v_batch.capture_source,
    'message',format(
      'ABS batch %s recorded manually for %s.',
      v_batch.batch_reference,
      v_flow.flow_code
    )
  );
end;
$$;

create or replace function public.correct_production_flow_abs_batch(
  p_external_batch_id uuid,
  p_batch_reference text,
  p_quantity numeric,
  p_unit_code text,
  p_reason text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_old public.production_flow_external_batches%rowtype;
  v_new public.production_flow_external_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_reference text := nullif(trim(coalesce(p_batch_reference,'')),'');
  v_unit text := upper(trim(coalesce(p_unit_code,'')));
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_staff_id uuid;
begin
  perform public.require_production_flow_batch_write_role();

  if v_reason is null then
    raise exception using errcode='22023', message='Reason is required to correct an ABS batch.';
  end if;

  if v_reference is null
     or p_quantity is null
     or p_quantity<=0
     or v_unit not in ('KG','UNIT')
     or (v_unit='UNIT' and p_quantity<>trunc(p_quantity)) then
    raise exception using errcode='22023', message='Corrected ABS batch data is invalid.';
  end if;

  select *
  into v_old
  from public.production_flow_external_batches b
  where b.production_flow_external_batch_id=p_external_batch_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='ABS batch entry was not found.';
  end if;

  if v_old.status<>'ACTIVE' then
    raise exception using errcode='22023', message='Only an active ABS batch can be corrected.';
  end if;

  select *
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_old.production_flow_item_id
  for update;

  v_staff_id := public.current_staff_id();

  update public.production_flow_external_batches
  set status='SUPERSEDED',
      correction_reason=v_reason,
      cancelled_at=now(),
      cancelled_by_staff_id=v_staff_id,
      cancelled_by_auth_user_id=auth.uid()
  where production_flow_external_batch_id=v_old.production_flow_external_batch_id;

  insert into public.production_flow_external_batches (
    production_flow_item_id,
    external_system_code,
    batch_reference,
    quantity,
    unit_code,
    capture_source,
    status,
    supersedes_external_batch_id,
    notes,
    correction_reason,
    recorded_by_staff_id,
    recorded_by_auth_user_id
  )
  values (
    v_old.production_flow_item_id,
    v_old.external_system_code,
    v_reference,
    p_quantity,
    v_unit,
    'MANUAL',
    'ACTIVE',
    v_old.production_flow_external_batch_id,
    v_notes,
    v_reason,
    v_staff_id,
    auth.uid()
  )
  returning * into v_new;

  perform public.append_production_flow_event(
    v_flow.production_flow_item_id,
    'ABS_BATCH_CORRECTED',
    'PRODUCTION',
    40,
    case when v_flow.product_code='MOP' then 'MOP' else 'FINISH' end,
    public.current_business_date(),
    v_new.recorded_at,
    v_staff_id,
    v_staff_id,
    auth.uid(),
    'ELISCARETEXT_V2',
    'production_flow_external_batches',
    v_new.production_flow_external_batch_id::text,
    jsonb_build_object(
      'external_system_code',v_new.external_system_code,
      'old_external_batch_id',v_old.production_flow_external_batch_id,
      'old_batch_reference',v_old.batch_reference,
      'old_quantity',v_old.quantity,
      'old_unit_code',v_old.unit_code,
      'batch_reference',v_new.batch_reference,
      'quantity',v_new.quantity,
      'unit_code',v_new.unit_code,
      'reason',v_reason
    )
  );

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
    v_staff_id,
    'PRODUCTION_FLOW_ABS_BATCH_CORRECTED',
    'production_flow_external_batches',
    v_new.production_flow_external_batch_id::text,
    to_jsonb(v_old),
    to_jsonb(v_new),
    v_reason,
    'ELISCARETEXT_V2'
  );

  return jsonb_build_object(
    'status','success',
    'production_flow_item_id',v_flow.production_flow_item_id,
    'flow_code',v_flow.flow_code,
    'external_batch_id',v_new.production_flow_external_batch_id,
    'batch_reference',v_new.batch_reference,
    'quantity',v_new.quantity,
    'unit_code',v_new.unit_code,
    'capture_source',v_new.capture_source,
    'supersedes_external_batch_id',v_old.production_flow_external_batch_id,
    'message',format('ABS batch corrected for %s.',v_flow.flow_code)
  );
end;
$$;

create or replace function public.cancel_production_flow_abs_batch(
  p_external_batch_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_batch public.production_flow_external_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason,'')),'');
  v_staff_id uuid;
begin
  perform public.require_production_flow_batch_write_role();

  if v_reason is null then
    raise exception using errcode='22023', message='Reason is required to cancel an ABS batch.';
  end if;

  select *
  into v_batch
  from public.production_flow_external_batches b
  where b.production_flow_external_batch_id=p_external_batch_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='ABS batch entry was not found.';
  end if;

  if v_batch.status<>'ACTIVE' then
    raise exception using errcode='22023', message='Only an active ABS batch can be cancelled.';
  end if;

  select *
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_batch.production_flow_item_id
  for update;

  v_staff_id := public.current_staff_id();

  update public.production_flow_external_batches
  set status='CANCELLED',
      correction_reason=v_reason,
      cancelled_at=now(),
      cancelled_by_staff_id=v_staff_id,
      cancelled_by_auth_user_id=auth.uid()
  where production_flow_external_batch_id=v_batch.production_flow_external_batch_id
  returning * into v_batch;

  perform public.append_production_flow_event(
    v_flow.production_flow_item_id,
    'ABS_BATCH_CANCELLED',
    'PRODUCTION',
    40,
    case when v_flow.product_code='MOP' then 'MOP' else 'FINISH' end,
    public.current_business_date(),
    coalesce(v_batch.cancelled_at,now()),
    v_staff_id,
    v_staff_id,
    auth.uid(),
    'ELISCARETEXT_V2',
    'production_flow_external_batches',
    v_batch.production_flow_external_batch_id::text,
    jsonb_build_object(
      'external_system_code',v_batch.external_system_code,
      'batch_reference',v_batch.batch_reference,
      'quantity',v_batch.quantity,
      'unit_code',v_batch.unit_code,
      'reason',v_reason
    )
  );

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
    v_staff_id,
    'PRODUCTION_FLOW_ABS_BATCH_CANCELLED',
    'production_flow_external_batches',
    v_batch.production_flow_external_batch_id::text,
    null,
    to_jsonb(v_batch),
    v_reason,
    'ELISCARETEXT_V2'
  );

  return jsonb_build_object(
    'status','success',
    'production_flow_item_id',v_flow.production_flow_item_id,
    'flow_code',v_flow.flow_code,
    'external_batch_id',v_batch.production_flow_external_batch_id,
    'batch_reference',v_batch.batch_reference,
    'message',format('ABS batch %s cancelled.',v_batch.batch_reference)
  );
end;
$$;

revoke all on function public.record_production_flow_abs_batch(uuid,text,numeric,text,text)
  from public, anon, authenticated;
revoke all on function public.correct_production_flow_abs_batch(uuid,text,numeric,text,text,text)
  from public, anon, authenticated;
revoke all on function public.cancel_production_flow_abs_batch(uuid,text)
  from public, anon, authenticated;

grant execute on function public.record_production_flow_abs_batch(uuid,text,numeric,text,text)
  to authenticated;
grant execute on function public.correct_production_flow_abs_batch(uuid,text,numeric,text,text,text)
  to authenticated;
grant execute on function public.cancel_production_flow_abs_batch(uuid,text)
  to authenticated;

-- ---------------------------------------------------------------------
-- 13. Controlled trace read API — future Tracker foundation
-- ---------------------------------------------------------------------

create or replace function public.get_production_flow_trace(
  p_production_flow_item_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_flow jsonb;
  v_events jsonb := '[]'::jsonb;
  v_batches jsonb := '[]'::jsonb;
  v_washes jsonb := '[]'::jsonb;
begin
  perform public.require_production_flow_read_role();

  select to_jsonb(pfi)
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=p_production_flow_item_id;

  if v_flow is null then
    raise exception using errcode='P0002', message='Production Flow Item was not found.';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'production_flow_event_id',pfe.production_flow_event_id,
      'event_type',pfe.event_type,
      'stage_code',pfe.stage_code,
      'stage_rank',pfe.stage_rank,
      'area_code',pfe.area_code,
      'business_date',pfe.business_date,
      'occurred_at',pfe.occurred_at,
      'recorded_at',pfe.recorded_at,
      'performed_by_staff_id',pfe.performed_by_staff_id,
      'performed_by_staff_name',performed.display_name,
      'recorded_by_staff_id',pfe.recorded_by_staff_id,
      'recorded_by_staff_name',recorded.display_name,
      'source_application',pfe.source_application,
      'source_entity_table',pfe.source_entity_table,
      'source_entity_id',pfe.source_entity_id,
      'event_data',pfe.event_data
    )
    order by pfe.occurred_at,pfe.recorded_at,pfe.production_flow_event_id
  ),'[]'::jsonb)
  into v_events
  from public.production_flow_events pfe
  left join public.staff_members performed
    on performed.staff_id=pfe.performed_by_staff_id
  left join public.staff_members recorded
    on recorded.staff_id=pfe.recorded_by_staff_id
  where pfe.production_flow_item_id=p_production_flow_item_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'external_batch_id',b.production_flow_external_batch_id,
      'external_system_code',b.external_system_code,
      'batch_reference',b.batch_reference,
      'quantity',b.quantity,
      'unit_code',b.unit_code,
      'capture_source',b.capture_source,
      'status',b.status,
      'supersedes_external_batch_id',b.supersedes_external_batch_id,
      'notes',b.notes,
      'correction_reason',b.correction_reason,
      'recorded_at',b.recorded_at,
      'recorded_by_staff_id',b.recorded_by_staff_id,
      'recorded_by_staff_name',sm.display_name
    )
    order by b.recorded_at,b.production_flow_external_batch_id
  ),'[]'::jsonb)
  into v_batches
  from public.production_flow_external_batches b
  left join public.staff_members sm
    on sm.staff_id=b.recorded_by_staff_id
  where b.production_flow_item_id=p_production_flow_item_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'wash_run_customer_id',wrc.wash_run_customer_id,
      'trace_code',wrc.trace_code,
      'wash_run_id',wr.wash_run_id,
      'wash_code',wr.wash_code,
      'business_date',wr.business_date,
      'status',wr.status,
      'entry_mode',wr.entry_mode,
      'washer_code',wr.washer_code_snapshot,
      'operator_staff_id',wr.operator_staff_id,
      'operator_name',wr.operator_name_snapshot,
      'started_at',wr.started_at,
      'registered_at',wr.registered_at,
      'wash_load_total_kg',wr.total_weight_kg,
      'weight_scope','WASH_LOAD_TOTAL_NOT_CUSTOMER_ALLOCATION'
    )
    order by wr.started_at,wr.registered_at,wrc.trace_code
  ),'[]'::jsonb)
  into v_washes
  from public.sorting_wash_run_customers wrc
  join public.sorting_wash_runs wr
    on wr.wash_run_id=wrc.wash_run_id
  where wrc.production_flow_item_id=p_production_flow_item_id;

  return jsonb_build_object(
    'status','success',
    'flow_item',v_flow,
    'events',v_events,
    'external_batches',v_batches,
    'washing_traces',v_washes
  );
end;
$$;

revoke all on function public.get_production_flow_trace(uuid)
  from public, anon, authenticated;
grant execute on function public.get_production_flow_trace(uuid)
  to authenticated;

comment on table public.production_flow_items is
  'Stable cross-module production identity. Scheduled items are customer + product + scheduled date; unscheduled items are customer + product + originating Business Date.';

comment on table public.production_flow_events is
  'Immutable cross-module Production Flow timeline. Detailed operational data remains in source module tables; events store who/when/reference and compact snapshots for Tracker reconstruction.';

comment on table public.production_flow_external_batches is
  'External production batch references linked to Production Flow. ABS is captured manually today; capture_source supports future INTEGRATION without replacing the data model.';

comment on column public.sorting_wash_run_customers.production_flow_item_id is
  'Cross-module Production Flow identity shared by multiple physical wash loads for the same customer/product production occurrence.';

commit;
