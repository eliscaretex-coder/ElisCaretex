-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110002_production_flow_wash_weight_allocation_and_confirmation_guard
--
-- Washing KG allocation:
--   * one customer in a physical wash load -> 100% of load KG;
--   * two or more customers -> equal split estimate;
--   * allocation is stored to 0.01 KG;
--   * remainder cents are assigned deterministically so allocations always
--     reconcile exactly to the physical wash load total.
--
-- Production Flow:
--   * current Flow Item keeps active washed KG total + active load count;
--   * immutable WASH_WEIGHT_ALLOCATED events carry per-customer KG;
--   * CANCELLED wash runs do not count in the current Flow Item total.
--
-- ABS:
--   * batch number is usually 1..999 and commonly cycles weekly from Monday;
--   * this observed pattern is NOT enforced as a hard constraint;
--   * numeric batch + Business Date + week-start context is stored for Tracker;
--   * references outside 1..999 remain valid exceptions.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Customer-level wash allocation
-- ---------------------------------------------------------------------

alter table public.sorting_wash_run_customers
  add column if not exists allocated_weight_kg numeric(14,2),
  add column if not exists weight_allocation_method text,
  add column if not exists weight_allocation_customer_count integer,
  add column if not exists weight_allocation_calculated_at timestamptz;

alter table public.sorting_wash_run_customers
  drop constraint if exists sorting_wash_run_customers_allocation_method_check;

alter table public.sorting_wash_run_customers
  add constraint sorting_wash_run_customers_allocation_method_check
    check (
      weight_allocation_method is null
      or weight_allocation_method in ('FULL_LOAD','EQUAL_SPLIT_ESTIMATE')
    );

alter table public.sorting_wash_run_customers
  drop constraint if exists sorting_wash_run_customers_allocation_weight_check;

alter table public.sorting_wash_run_customers
  add constraint sorting_wash_run_customers_allocation_weight_check
    check (allocated_weight_kg is null or allocated_weight_kg >= 0);

alter table public.sorting_wash_run_customers
  drop constraint if exists sorting_wash_run_customers_allocation_count_check;

alter table public.sorting_wash_run_customers
  add constraint sorting_wash_run_customers_allocation_count_check
    check (
      weight_allocation_customer_count is null
      or weight_allocation_customer_count >= 1
    );

create index if not exists sorting_wash_run_customers_flow_weight_idx
  on public.sorting_wash_run_customers (
    production_flow_item_id,
    allocated_weight_kg
  )
  where production_flow_item_id is not null;

-- ---------------------------------------------------------------------
-- 2. Current Flow Item washing summary
-- ---------------------------------------------------------------------

alter table public.production_flow_items
  add column if not exists washed_kg_total numeric(14,2) not null default 0,
  add column if not exists washed_load_count integer not null default 0,
  add column if not exists washed_trace_count integer not null default 0,
  add column if not exists last_wash_at timestamptz;

alter table public.production_flow_items
  drop constraint if exists production_flow_items_washed_summary_check;

alter table public.production_flow_items
  add constraint production_flow_items_washed_summary_check
    check (
      washed_kg_total >= 0
      and washed_load_count >= 0
      and washed_trace_count >= 0
    );

-- ---------------------------------------------------------------------
-- 3. Typed event quantity for efficient Tracker queries
-- ---------------------------------------------------------------------

alter table public.production_flow_events
  add column if not exists quantity_value numeric(14,2),
  add column if not exists quantity_unit text,
  add column if not exists quantity_basis text;

alter table public.production_flow_events
  drop constraint if exists production_flow_events_quantity_check;

alter table public.production_flow_events
  add constraint production_flow_events_quantity_check
    check (
      (quantity_value is null and quantity_unit is null)
      or
      (quantity_value is not null and quantity_value >= 0 and quantity_unit in ('KG','UNIT'))
    );

create index if not exists production_flow_events_quantity_idx
  on public.production_flow_events (
    business_date,
    event_type,
    quantity_unit,
    quantity_value
  )
  where quantity_value is not null;

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
    event_data,
    quantity_value,
    quantity_unit,
    quantity_basis
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
    coalesce(p_event_data,'{}'::jsonb),
    case
      when coalesce(p_event_data,'{}'::jsonb) ? 'quantity_value'
        then nullif(p_event_data ->> 'quantity_value','')::numeric
      when coalesce(p_event_data,'{}'::jsonb) ? 'quantity'
        then nullif(p_event_data ->> 'quantity','')::numeric
      else null
    end,
    upper(nullif(trim(coalesce(
      p_event_data ->> 'quantity_unit',
      p_event_data ->> 'unit_code',
      ''
    )),'')),
    upper(nullif(trim(coalesce(p_event_data ->> 'quantity_basis','')),''))
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


-- ---------------------------------------------------------------------
-- 4. Deterministic equal-split allocator
-- ---------------------------------------------------------------------

create or replace function public.recalculate_sorting_wash_customer_allocations(
  p_wash_run_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_total_weight numeric;
  v_customer_count integer;
  v_total_cents bigint;
  v_base_cents bigint;
  v_remainder_cents integer;
  v_method text;
  v_flow_id uuid;
begin
  if p_wash_run_id is null then
    raise exception using errcode='22023', message='Wash run is required for KG allocation.';
  end if;

  select
    wr.total_weight_kg,
    count(wrc.wash_run_customer_id)::integer
  into
    v_total_weight,
    v_customer_count
  from public.sorting_wash_runs wr
  left join public.sorting_wash_run_customers wrc
    on wrc.wash_run_id=wr.wash_run_id
  where wr.wash_run_id=p_wash_run_id
  group by wr.wash_run_id,wr.total_weight_kg;

  if v_total_weight is null then
    raise exception using errcode='P0002', message='Wash run was not found for KG allocation.';
  end if;

  if coalesce(v_customer_count,0)=0 then
    return jsonb_build_object(
      'wash_run_id',p_wash_run_id,
      'customer_count',0,
      'allocated_weight_kg',0
    );
  end if;

  v_total_cents := round(v_total_weight * 100)::bigint;
  v_base_cents := v_total_cents / v_customer_count;
  v_remainder_cents := mod(v_total_cents,v_customer_count)::integer;
  v_method := case
    when v_customer_count=1 then 'FULL_LOAD'
    else 'EQUAL_SPLIT_ESTIMATE'
  end;

  with ranked as (
    select
      wrc.wash_run_customer_id,
      row_number() over (
        order by wrc.trace_code,wrc.wash_run_customer_id
      )::integer as rn
    from public.sorting_wash_run_customers wrc
    where wrc.wash_run_id=p_wash_run_id
  )
  update public.sorting_wash_run_customers wrc
  set
    allocated_weight_kg=(
      v_base_cents
      + case when ranked.rn <= v_remainder_cents then 1 else 0 end
    )::numeric / 100.0,
    weight_allocation_method=v_method,
    weight_allocation_customer_count=v_customer_count,
    weight_allocation_calculated_at=now(),
    metadata=coalesce(wrc.metadata,'{}'::jsonb) || jsonb_build_object(
      'customer_weight_allocation',v_method,
      'customer_weight_allocation_is_estimate',v_method='EQUAL_SPLIT_ESTIMATE',
      'customer_weight_allocation_customer_count',v_customer_count
    )
  from ranked
  where wrc.wash_run_customer_id=ranked.wash_run_customer_id;

  return jsonb_build_object(
    'wash_run_id',p_wash_run_id,
    'physical_load_weight_kg',round(v_total_weight,2),
    'customer_count',v_customer_count,
    'allocation_method',v_method,
    'allocated_weight_kg',(
      select coalesce(sum(wrc.allocated_weight_kg),0)
      from public.sorting_wash_run_customers wrc
      where wrc.wash_run_id=p_wash_run_id
    )
  );
end;
$$;

revoke all on function public.recalculate_sorting_wash_customer_allocations(uuid)
  from public, anon, authenticated;

-- New trace rows are inserted before V2 applies the exact scheduled-day snapshot.
-- Recalculate after every insert so the final insertion leaves a reconciled allocation
-- ready before the Production Flow linking update occurs.
create or replace function public.sorting_wash_customer_allocation_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_wash_run_id uuid;
begin
  v_wash_run_id := case when tg_op='DELETE' then old.wash_run_id else new.wash_run_id end;

  perform public.recalculate_sorting_wash_customer_allocations(v_wash_run_id);

  return case when tg_op='DELETE' then old else new end;
end;
$$;

revoke all on function public.sorting_wash_customer_allocation_trigger()
  from public, anon, authenticated;

drop trigger if exists sorting_wash_customer_allocation_after_change
  on public.sorting_wash_run_customers;

create trigger sorting_wash_customer_allocation_after_change
after insert or delete
on public.sorting_wash_run_customers
for each row
execute function public.sorting_wash_customer_allocation_trigger();

-- Future-proof a direct load-weight correction, even though current operational
-- correction creates a replacement Wash ID instead of rewriting the old one.
create or replace function public.sorting_wash_load_weight_allocation_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if old.total_weight_kg is distinct from new.total_weight_kg then
    perform public.recalculate_sorting_wash_customer_allocations(new.wash_run_id);
  end if;
  return new;
end;
$$;

revoke all on function public.sorting_wash_load_weight_allocation_trigger()
  from public, anon, authenticated;

drop trigger if exists sorting_wash_load_weight_allocation_after_update
  on public.sorting_wash_runs;

create trigger sorting_wash_load_weight_allocation_after_update
after update of total_weight_kg
on public.sorting_wash_runs
for each row
execute function public.sorting_wash_load_weight_allocation_trigger();

-- ---------------------------------------------------------------------
-- 5. Flow Item current washing total
-- ---------------------------------------------------------------------

create or replace function public.refresh_production_flow_wash_summary(
  p_production_flow_item_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_total numeric(14,2) := 0;
  v_load_count integer := 0;
  v_trace_count integer := 0;
  v_last_wash_at timestamptz;
begin
  if p_production_flow_item_id is null then
    return null;
  end if;

  select
    coalesce(sum(wrc.allocated_weight_kg),0)::numeric(14,2),
    count(distinct wr.wash_run_id)::integer,
    count(wrc.wash_run_customer_id)::integer,
    max(wr.started_at)
  into
    v_total,
    v_load_count,
    v_trace_count,
    v_last_wash_at
  from public.sorting_wash_run_customers wrc
  join public.sorting_wash_runs wr
    on wr.wash_run_id=wrc.wash_run_id
   and wr.status='RECORDED'
  where wrc.production_flow_item_id=p_production_flow_item_id;

  update public.production_flow_items pfi
  set
    washed_kg_total=coalesce(v_total,0),
    washed_load_count=coalesce(v_load_count,0),
    washed_trace_count=coalesce(v_trace_count,0),
    last_wash_at=v_last_wash_at,
    updated_at=now(),
    row_version=pfi.row_version+1
  where pfi.production_flow_item_id=p_production_flow_item_id;

  return jsonb_build_object(
    'production_flow_item_id',p_production_flow_item_id,
    'washed_kg_total',coalesce(v_total,0),
    'washed_load_count',coalesce(v_load_count,0),
    'washed_trace_count',coalesce(v_trace_count,0),
    'last_wash_at',v_last_wash_at
  );
end;
$$;

revoke all on function public.refresh_production_flow_wash_summary(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Immutable KG event for every customer wash trace
-- ---------------------------------------------------------------------

create or replace function public.append_sorting_wash_weight_allocation_event(
  p_wash_run_customer_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_row record;
  v_event_id uuid;
  v_recorded_by_staff_id uuid;
begin
  select
    wrc.wash_run_customer_id,
    wrc.production_flow_item_id,
    wrc.trace_code,
    wrc.customer_id,
    wrc.customer_name_snapshot,
    wrc.scheduled_for_date,
    wrc.allocated_weight_kg,
    wrc.weight_allocation_method,
    wrc.weight_allocation_customer_count,
    wr.wash_run_id,
    wr.wash_code,
    wr.business_date,
    wr.started_at,
    wr.registered_at,
    wr.total_weight_kg,
    wr.status,
    wr.operator_staff_id,
    wr.operator_name_snapshot,
    wr.recorded_by_auth_user_id
  into v_row
  from public.sorting_wash_run_customers wrc
  join public.sorting_wash_runs wr
    on wr.wash_run_id=wrc.wash_run_id
  where wrc.wash_run_customer_id=p_wash_run_customer_id
  limit 1;

  if not found or v_row.production_flow_item_id is null then
    return null;
  end if;

  select sm.staff_id
  into v_recorded_by_staff_id
  from public.staff_members sm
  where sm.auth_user_id=v_row.recorded_by_auth_user_id
    and sm.deleted_at is null
  order by sm.created_at
  limit 1;

  v_event_id := public.append_production_flow_event(
    v_row.production_flow_item_id,
    'WASH_WEIGHT_ALLOCATED',
    'WASHING',
    30,
    'SORTING',
    v_row.business_date,
    v_row.started_at,
    v_row.operator_staff_id,
    v_recorded_by_staff_id,
    v_row.recorded_by_auth_user_id,
    'SORTING_V2',
    'sorting_wash_run_customers',
    v_row.wash_run_customer_id::text,
    jsonb_build_object(
      'wash_run_id',v_row.wash_run_id,
      'wash_code',v_row.wash_code,
      'trace_code',v_row.trace_code,
      'customer_id',v_row.customer_id,
      'customer_name',v_row.customer_name_snapshot,
      'scheduled_for_date',v_row.scheduled_for_date,
      'physical_load_weight_kg',round(v_row.total_weight_kg,2),
      'customer_count',v_row.weight_allocation_customer_count,
      'customer_allocated_weight_kg',v_row.allocated_weight_kg,
      'allocation_method',v_row.weight_allocation_method,
      'allocation_is_estimate',v_row.weight_allocation_method='EQUAL_SPLIT_ESTIMATE',
      'quantity_value',v_row.allocated_weight_kg,
      'quantity_unit','KG',
      'quantity_basis',v_row.weight_allocation_method,
      'wash_status',v_row.status,
      'operator_name',v_row.operator_name_snapshot,
      'registered_at',v_row.registered_at
    )
  );

  perform public.refresh_production_flow_wash_summary(
    v_row.production_flow_item_id
  );

  return v_event_id;
end;
$$;

revoke all on function public.append_sorting_wash_weight_allocation_event(uuid)
  from public, anon, authenticated;

-- Production Flow linking is the moment when scheduled day/customer identity is final.
create or replace function public.sorting_wash_customer_weight_flow_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.production_flow_item_id is not null
     and old.production_flow_item_id is distinct from new.production_flow_item_id then
    perform public.append_sorting_wash_weight_allocation_event(
      new.wash_run_customer_id
    );
  end if;

  return new;
end;
$$;

revoke all on function public.sorting_wash_customer_weight_flow_trigger()
  from public, anon, authenticated;

drop trigger if exists sorting_wash_customer_weight_flow_after_link
  on public.sorting_wash_run_customers;

create trigger sorting_wash_customer_weight_flow_after_link
after update of production_flow_item_id
on public.sorting_wash_run_customers
for each row
execute function public.sorting_wash_customer_weight_flow_trigger();

-- Cancellation/correction changes current active KG summary without destroying history.
create or replace function public.sorting_wash_flow_summary_refresh_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_flow_id uuid;
begin
  if old.status is distinct from new.status
     or old.total_weight_kg is distinct from new.total_weight_kg then
    for v_flow_id in
      select distinct wrc.production_flow_item_id
      from public.sorting_wash_run_customers wrc
      where wrc.wash_run_id=new.wash_run_id
        and wrc.production_flow_item_id is not null
    loop
      perform public.refresh_production_flow_wash_summary(v_flow_id);
    end loop;
  end if;

  return new;
end;
$$;

revoke all on function public.sorting_wash_flow_summary_refresh_trigger()
  from public, anon, authenticated;

drop trigger if exists sorting_wash_flow_summary_refresh_after_update
  on public.sorting_wash_runs;

create trigger sorting_wash_flow_summary_refresh_after_update
after update of status,total_weight_kg
on public.sorting_wash_runs
for each row
execute function public.sorting_wash_flow_summary_refresh_trigger();

-- ---------------------------------------------------------------------
-- 7. Backfill allocations, KG events and Flow summaries
-- ---------------------------------------------------------------------

do $$
declare
  v_wash_run_id uuid;
  v_trace_id uuid;
  v_flow_id uuid;
begin
  for v_wash_run_id in
    select distinct wrc.wash_run_id
    from public.sorting_wash_run_customers wrc
    order by wrc.wash_run_id
  loop
    perform public.recalculate_sorting_wash_customer_allocations(v_wash_run_id);
  end loop;

  for v_trace_id in
    select wrc.wash_run_customer_id
    from public.sorting_wash_run_customers wrc
    where wrc.production_flow_item_id is not null
    order by wrc.created_at,wrc.wash_run_customer_id
  loop
    perform public.append_sorting_wash_weight_allocation_event(v_trace_id);
  end loop;

  for v_flow_id in
    select pfi.production_flow_item_id
    from public.production_flow_items pfi
    order by pfi.production_flow_item_id
  loop
    perform public.refresh_production_flow_wash_summary(v_flow_id);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. ABS batch weekly-cycle context (observed pattern, not hard rule)
-- ---------------------------------------------------------------------

alter table public.production_flow_external_batches
  add column if not exists batch_number integer,
  add column if not exists batch_business_date date,
  add column if not exists batch_week_start date;

alter table public.production_flow_external_batches
  drop constraint if exists production_flow_external_batches_batch_number_check;

alter table public.production_flow_external_batches
  add constraint production_flow_external_batches_batch_number_check
    check (batch_number is null or batch_number > 0);

create index if not exists production_flow_external_batches_week_number_idx
  on public.production_flow_external_batches (
    batch_week_start,
    batch_number,
    status
  )
  where batch_number is not null;

create or replace function public.production_flow_external_batch_context_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
begin
  select *
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=new.production_flow_item_id
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='Production Flow Item was not found for external batch.';
  end if;

  new.batch_number := case
    when trim(new.batch_reference) ~ '^[0-9]+$'
     and length(trim(new.batch_reference)) <= 9
      then trim(new.batch_reference)::integer
    else null
  end;

  new.batch_business_date := coalesce(
    v_flow.scheduled_for_date,
    v_flow.opened_business_date
  );

  new.batch_week_start := public.production_roster_week_start(
    new.batch_business_date
  );

  return new;
end;
$$;

revoke all on function public.production_flow_external_batch_context_trigger()
  from public, anon, authenticated;

drop trigger if exists production_flow_external_batch_context_before_write
  on public.production_flow_external_batches;

create trigger production_flow_external_batch_context_before_write
before insert or update of
  production_flow_item_id,
  batch_reference
on public.production_flow_external_batches
for each row
execute function public.production_flow_external_batch_context_trigger();

update public.production_flow_external_batches b
set
  batch_number=case
    when trim(b.batch_reference) ~ '^[0-9]+$'
     and length(trim(b.batch_reference)) <= 9
      then trim(b.batch_reference)::integer
    else null
  end,
  batch_business_date=coalesce(
    pfi.scheduled_for_date,
    pfi.opened_business_date
  ),
  batch_week_start=public.production_roster_week_start(
    coalesce(pfi.scheduled_for_date,pfi.opened_business_date)
  )
from public.production_flow_items pfi
where pfi.production_flow_item_id=b.production_flow_item_id;

alter table public.production_flow_external_batches
  alter column batch_business_date set not null,
  alter column batch_week_start set not null;

comment on column public.production_flow_external_batches.batch_number is
  'Numeric ABS batch reference when the entered reference is numeric. Observed operational pattern is commonly 1-999, but values outside that range are intentionally allowed as exceptions.';

comment on column public.production_flow_external_batches.batch_week_start is
  'Monday week context for ABS batch tracking. ABS numbering is observed to commonly restart weekly, but no restart/uniqueness rule is enforced.';

-- ---------------------------------------------------------------------
-- 9. Controlled Flow trace includes current total + per-customer allocation
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
      'batch_number',b.batch_number,
      'batch_business_date',b.batch_business_date,
      'batch_week_start',b.batch_week_start,
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
      'customer_allocated_weight_kg',wrc.allocated_weight_kg,
      'weight_allocation_method',wrc.weight_allocation_method,
      'weight_allocation_customer_count',wrc.weight_allocation_customer_count,
      'allocation_is_estimate',wrc.weight_allocation_method='EQUAL_SPLIT_ESTIMATE',
      'weight_scope','CUSTOMER_ALLOCATION_FROM_WASH_LOAD'
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
    'washing_summary',jsonb_build_object(
      'active_allocated_kg',coalesce((v_flow->>'washed_kg_total')::numeric,0),
      'active_wash_load_count',coalesce((v_flow->>'washed_load_count')::integer,0),
      'active_wash_trace_count',coalesce((v_flow->>'washed_trace_count')::integer,0),
      'last_wash_at',v_flow->>'last_wash_at',
      'allocation_basis','CUSTOMER_ALLOCATED_FROM_WASH_LOAD'
    ),
    'washing_traces',v_washes
  );
end;
$$;


comment on column public.sorting_wash_run_customers.allocated_weight_kg is
  'Approximate customer-level KG allocated from the physical wash load. Single customer receives full load KG; multi-customer load uses deterministic equal split to 0.01 KG.';

comment on column public.production_flow_items.washed_kg_total is
  'Current sum of allocated customer KG across RECORDED wash runs linked to this Flow Item. CANCELLED wash runs are excluded.';

comment on column public.production_flow_events.quantity_value is
  'Typed event quantity used by Tracker/reporting. WASH_WEIGHT_ALLOCATED uses customer allocated KG; ABS events use external batch quantity.';

commit;
