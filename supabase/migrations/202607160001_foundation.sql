-- =====================================================================
-- Laundry Platform V2
-- Migration: 202607160001_foundation.sql
-- Purpose:
--   Core master data, operational staff, customer schedule versioning,
--   roster foundation, trolley custody tracking and audit.
--
-- Run only in a NEW Supabase development project.
-- =====================================================================

begin;

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Governance and configuration
-- ---------------------------------------------------------------------

create table if not exists public.app_config (
  config_key text primary key,
  value_json jsonb not null,
  description text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists public.audit_log (
  audit_id uuid primary key default gen_random_uuid(),
  actor_auth_user_id uuid references auth.users(id) on delete set null,
  actor_staff_id uuid,
  action text not null,
  entity_table text not null,
  entity_id text,
  old_data jsonb,
  new_data jsonb,
  reason text,
  source_application text,
  request_id text,
  correlation_id uuid,
  occurred_at timestamptz not null default now()
);

create index if not exists audit_log_entity_idx
  on public.audit_log (entity_table, entity_id, occurred_at desc);

create index if not exists audit_log_actor_idx
  on public.audit_log (actor_staff_id, occurred_at desc);

-- ---------------------------------------------------------------------
-- Operational staff and permissions
-- No private HR or driver-private information is stored here.
-- ---------------------------------------------------------------------

create table if not exists public.staff_members (
  staff_id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  employee_code text unique,
  display_name text not null,
  active boolean not null default true,
  joined_on date,
  deactivated_on date,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  constraint staff_members_dates_check
    check (
      deactivated_on is null
      or joined_on is null
      or deactivated_on >= joined_on
    )
);

create table if not exists public.roles (
  role_id uuid primary key default gen_random_uuid(),
  role_code text not null unique,
  role_name text not null,
  description text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.staff_roles (
  staff_role_id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff_members(staff_id)
    on delete restrict,
  role_id uuid not null references public.roles(role_id)
    on delete restrict,
  effective_from date not null default current_date,
  effective_until date,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  constraint staff_roles_dates_check
    check (
      effective_until is null
      or effective_until >= effective_from
    )
);

create unique index if not exists staff_roles_active_unique
  on public.staff_roles (staff_id, role_id)
  where active and effective_until is null;

-- ---------------------------------------------------------------------
-- Master data
-- ---------------------------------------------------------------------

create table if not exists public.areas (
  area_id uuid primary key default gen_random_uuid(),
  area_code text not null unique,
  area_name text not null,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.stations (
  station_id uuid primary key default gen_random_uuid(),
  area_id uuid not null references public.areas(area_id)
    on delete restrict,
  station_code text not null unique,
  station_name text not null,
  station_type text,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.shifts (
  shift_id uuid primary key default gen_random_uuid(),
  shift_code text not null unique,
  shift_name text not null,
  start_time time,
  end_time time,
  crosses_midnight boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.customers (
  customer_id uuid primary key default gen_random_uuid(),
  customer_code text not null unique,
  customer_name text not null,
  eircode text,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz
);

create index if not exists customers_name_idx
  on public.customers (lower(customer_name));

create table if not exists public.product_types (
  product_type_id uuid primary key default gen_random_uuid(),
  product_code text not null unique,
  display_name text not null,
  processing_area_id uuid references public.areas(area_id)
    on delete restrict,
  uses_kg boolean not null default true,
  uses_units boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint product_types_measure_check
    check (uses_kg or uses_units)
);

-- ---------------------------------------------------------------------
-- Customer schedules
--
-- A schedule is versioned. Historical work will later copy the applicable
-- instructions into an operational job snapshot, so changing a future
-- schedule never rewrites old production history.
--
-- ISO weekday: Monday=1 ... Sunday=7
-- ---------------------------------------------------------------------

create table if not exists public.customer_schedule_versions (
  schedule_version_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(customer_id)
    on delete restrict,
  production_weekday smallint not null,
  delivery_weekday smallint,
  effective_from date not null,
  effective_until date,
  version_number integer not null default 1,
  active boolean not null default true,
  change_reason text,
  general_instructions text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint customer_schedule_production_weekday_check
    check (production_weekday between 1 and 7),
  constraint customer_schedule_delivery_weekday_check
    check (delivery_weekday is null or delivery_weekday between 1 and 7),
  constraint customer_schedule_dates_check
    check (
      effective_until is null
      or effective_until >= effective_from
    ),
  constraint customer_schedule_version_positive
    check (version_number > 0)
);

alter table public.customer_schedule_versions
  drop constraint if exists customer_schedule_no_overlap;

alter table public.customer_schedule_versions
  add constraint customer_schedule_no_overlap
  exclude using gist (
    customer_id with =,
    production_weekday with =,
    daterange(
      effective_from,
      coalesce(effective_until, 'infinity'::date),
      '[]'
    ) with &&
  )
  where (active);

create table if not exists public.customer_schedule_items (
  schedule_item_id uuid primary key default gen_random_uuid(),
  schedule_version_id uuid not null
    references public.customer_schedule_versions(schedule_version_id)
    on delete cascade,
  product_type_id uuid not null
    references public.product_types(product_type_id)
    on delete restrict,
  planned_trolley_quantity integer,
  expected_kg numeric(12,2),
  expected_units integer,
  production_order integer,
  instructions text,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint schedule_items_trolley_qty_check
    check (
      planned_trolley_quantity is null
      or planned_trolley_quantity >= 0
    ),
  constraint schedule_items_expected_kg_check
    check (expected_kg is null or expected_kg >= 0),
  constraint schedule_items_expected_units_check
    check (expected_units is null or expected_units >= 0),
  constraint schedule_items_product_unique
    unique (schedule_version_id, product_type_id)
);

-- ---------------------------------------------------------------------
-- Roster foundation
-- Planned roster and actual work are intentionally separate.
-- ---------------------------------------------------------------------

create table if not exists public.roster_periods (
  roster_period_id uuid primary key default gen_random_uuid(),
  week_start date not null unique,
  status text not null default 'DRAFT',
  published_at timestamptz,
  published_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint roster_period_status_check
    check (status in ('DRAFT', 'PUBLISHED', 'CLOSED', 'CANCELLED'))
);

create table if not exists public.roster_assignments (
  roster_assignment_id uuid primary key default gen_random_uuid(),
  roster_period_id uuid not null
    references public.roster_periods(roster_period_id)
    on delete restrict,
  work_date date not null,
  staff_id uuid not null references public.staff_members(staff_id)
    on delete restrict,
  area_id uuid not null references public.areas(area_id)
    on delete restrict,
  station_id uuid references public.stations(station_id)
    on delete restrict,
  shift_id uuid references public.shifts(shift_id)
    on delete restrict,
  planned_start_time time,
  planned_end_time time,
  assignment_role text,
  status text not null default 'PLANNED',
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint roster_assignment_status_check
    check (status in ('PLANNED', 'CONFIRMED', 'CANCELLED', 'ABSENT'))
);

create index if not exists roster_assignments_lookup_idx
  on public.roster_assignments
  (work_date, area_id, station_id, shift_id, status);

create table if not exists public.work_sessions (
  work_session_id uuid primary key default gen_random_uuid(),
  roster_assignment_id uuid
    references public.roster_assignments(roster_assignment_id)
    on delete set null,
  work_date date not null,
  staff_id uuid not null references public.staff_members(staff_id)
    on delete restrict,
  area_id uuid not null references public.areas(area_id)
    on delete restrict,
  station_id uuid references public.stations(station_id)
    on delete restrict,
  shift_id uuid references public.shifts(shift_id)
    on delete restrict,
  actual_start_at timestamptz,
  actual_end_at timestamptz,
  break_minutes integer not null default 0,
  status text not null default 'OPEN',
  source text,
  confirmed_by uuid references public.staff_members(staff_id)
    on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint work_sessions_break_check
    check (break_minutes >= 0),
  constraint work_sessions_time_check
    check (
      actual_end_at is null
      or actual_start_at is null
      or actual_end_at >= actual_start_at
    ),
  constraint work_sessions_status_check
    check (status in ('OPEN', 'CONFIRMED', 'CORRECTED', 'CANCELLED'))
);

-- ---------------------------------------------------------------------
-- Trolley master data and customer custody
--
-- Required business rule:
-- - store sent date and received date;
-- - calculate days outside;
-- - only one open customer stay per trolley;
-- - receiving without a recorded send is allowed as a tracked exception;
-- - never invent the missing send date;
-- - preserve outbound customer and received-from customer when they differ.
-- ---------------------------------------------------------------------

create table if not exists public.trolley_types (
  trolley_type_id uuid primary key default gen_random_uuid(),
  trolley_type_code text not null unique,
  trolley_type_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trolleys (
  trolley_id uuid primary key default gen_random_uuid(),
  trolley_code text not null unique,
  trolley_type_id uuid references public.trolley_types(trolley_type_id)
    on delete restrict,
  status text not null default 'AVAILABLE',
  active boolean not null default true,
  registered_on date not null default current_date,
  retired_on date,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  constraint trolleys_status_check
    check (
      status in (
        'AVAILABLE',
        'AT_CUSTOMER',
        'IN_PRODUCTION',
        'OUT_OF_SERVICE',
        'RETIRED'
      )
    ),
  constraint trolleys_dates_check
    check (retired_on is null or retired_on >= registered_on)
);

create table if not exists public.trolley_customer_stays (
  stay_id uuid primary key default gen_random_uuid(),
  trolley_id uuid not null references public.trolleys(trolley_id)
    on delete restrict,

  -- Customer recorded when the trolley was sent.
  -- Null only when an outbound record is missing.
  outbound_customer_id uuid references public.customers(customer_id)
    on delete restrict,

  -- Customer confirmed by the receiving operator.
  received_from_customer_id uuid references public.customers(customer_id)
    on delete restrict,

  sent_on date,
  received_on date,

  status text not null default 'OPEN',
  exception_type text,
  confirmation_source text,
  operator_confirmed boolean not null default false,

  sent_recorded_by uuid references public.staff_members(staff_id)
    on delete set null,
  received_recorded_by uuid references public.staff_members(staff_id)
    on delete set null,

  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint trolley_stay_status_check
    check (status in ('OPEN', 'RECEIVED', 'REVIEW_REQUIRED')),

  constraint trolley_stay_exception_check
    check (
      exception_type is null
      or exception_type in (
        'MISSING_OUTBOUND_RECORD',
        'CUSTOMER_MISMATCH',
        'DATE_CORRECTION',
        'OTHER'
      )
    ),

  constraint trolley_stay_confirmation_source_check
    check (
      confirmation_source is null
      or confirmation_source in (
        'OPEN_STAY',
        'LAST_KNOWN_CUSTOMER',
        'MANUAL_SELECTION',
        'SUPERVISOR_CORRECTION'
      )
    ),

  constraint trolley_stay_dates_check
    check (
      received_on is null
      or sent_on is null
      or received_on >= sent_on
    ),

  constraint trolley_stay_open_check
    check (
      (
        status = 'OPEN'
        and sent_on is not null
        and outbound_customer_id is not null
        and received_on is null
      )
      or
      (
        status in ('RECEIVED', 'REVIEW_REQUIRED')
        and received_on is not null
      )
    ),

  constraint trolley_stay_missing_outbound_check
    check (
      sent_on is not null
      or (
        received_on is not null
        and outbound_customer_id is null
        and exception_type = 'MISSING_OUTBOUND_RECORD'
      )
    )
);

create unique index if not exists trolley_one_open_stay_idx
  on public.trolley_customer_stays (trolley_id)
  where received_on is null;

create index if not exists trolley_stays_outbound_customer_idx
  on public.trolley_customer_stays
  (outbound_customer_id, sent_on desc);

create index if not exists trolley_stays_received_customer_idx
  on public.trolley_customer_stays
  (received_from_customer_id, received_on desc);

create table if not exists public.trolley_events (
  trolley_event_id uuid primary key default gen_random_uuid(),
  trolley_id uuid not null references public.trolleys(trolley_id)
    on delete restrict,
  stay_id uuid references public.trolley_customer_stays(stay_id)
    on delete set null,
  event_type text not null,
  customer_id uuid references public.customers(customer_id)
    on delete restrict,
  business_date date not null default current_date,
  performed_by uuid references public.staff_members(staff_id)
    on delete set null,
  source_application text,
  reason text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint trolley_event_type_check
    check (
      event_type in (
        'SENT_TO_CUSTOMER',
        'RECEIVED_FROM_CUSTOMER',
        'RECEIVED_WITHOUT_OUTBOUND',
        'CUSTOMER_MISMATCH',
        'RECORD_CORRECTED',
        'MARKED_OUT_OF_SERVICE',
        'RETURNED_TO_SERVICE'
      )
    )
);

create index if not exists trolley_events_history_idx
  on public.trolley_events (trolley_id, business_date desc, created_at desc);

-- ---------------------------------------------------------------------
-- Updated-at triggers
-- ---------------------------------------------------------------------

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'areas',
    'stations',
    'shifts',
    'customers',
    'product_types',
    'staff_members',
    'customer_schedule_versions',
    'customer_schedule_items',
    'roster_periods',
    'roster_assignments',
    'work_sessions',
    'trolley_types',
    'trolleys',
    'trolley_customer_stays'
  ]
  loop
    execute format(
      'drop trigger if exists %I on public.%I',
      table_name || '_set_updated_at',
      table_name
    );

    execute format(
      'create trigger %I before update on public.%I
       for each row execute function public.set_updated_at()',
      table_name || '_set_updated_at',
      table_name
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Authentication helpers
-- ---------------------------------------------------------------------

create or replace function public.current_staff_id()
returns uuid
language sql
stable
security definer
set search_path = public, auth
as $$
  select sm.staff_id
  from public.staff_members sm
  where sm.auth_user_id = auth.uid()
    and sm.active = true
    and sm.deleted_at is null
  limit 1;
$$;

create or replace function public.has_any_role(p_role_codes text[])
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.staff_members sm
    join public.staff_roles sr
      on sr.staff_id = sm.staff_id
    join public.roles r
      on r.role_id = sr.role_id
    where sm.auth_user_id = auth.uid()
      and sm.active = true
      and sm.deleted_at is null
      and sr.active = true
      and sr.effective_from <= current_date
      and (
        sr.effective_until is null
        or sr.effective_until >= current_date
      )
      and r.active = true
      and r.role_code = any (p_role_codes)
  );
$$;

revoke all on function public.current_staff_id() from public;
revoke all on function public.has_any_role(text[]) from public;
grant execute on function public.current_staff_id() to authenticated;
grant execute on function public.has_any_role(text[]) to authenticated;

-- ---------------------------------------------------------------------
-- Trolley views
-- ---------------------------------------------------------------------

create or replace view public.v_trolleys_at_customers
with (security_invoker = true)
as
select
  s.stay_id,
  t.trolley_id,
  t.trolley_code,
  t.status as trolley_status,
  s.outbound_customer_id as customer_id,
  c.customer_code,
  c.customer_name,
  s.sent_on,
  current_date - s.sent_on as days_out,
  case
    when current_date - s.sent_on >=
      coalesce(
        (select (value_json #>> '{}')::integer
         from public.app_config
         where config_key = 'trolley_overdue_days'),
        30
      )
      then 'OVERDUE'
    when current_date - s.sent_on >=
      coalesce(
        (select (value_json #>> '{}')::integer
         from public.app_config
         where config_key = 'trolley_warning_days'),
        14
      )
      then 'WARNING'
    else 'NORMAL'
  end as attention_status,
  s.sent_recorded_by,
  s.notes,
  s.created_at
from public.trolley_customer_stays s
join public.trolleys t
  on t.trolley_id = s.trolley_id
join public.customers c
  on c.customer_id = s.outbound_customer_id
where s.received_on is null
  and s.status = 'OPEN'
  and t.deleted_at is null;

create or replace view public.v_trolley_reconciliation_queue
with (security_invoker = true)
as
select
  s.stay_id,
  t.trolley_code,
  outbound.customer_name as outbound_customer_name,
  received.customer_name as received_from_customer_name,
  s.sent_on,
  s.received_on,
  case
    when s.sent_on is null then null
    else s.received_on - s.sent_on
  end as recorded_days_out,
  s.status,
  s.exception_type,
  s.confirmation_source,
  s.operator_confirmed,
  s.notes,
  s.created_at,
  s.updated_at
from public.trolley_customer_stays s
join public.trolleys t
  on t.trolley_id = s.trolley_id
left join public.customers outbound
  on outbound.customer_id = s.outbound_customer_id
left join public.customers received
  on received.customer_id = s.received_from_customer_id
where s.exception_type is not null
   or s.status = 'REVIEW_REQUIRED';

create or replace view public.v_trolley_customer_history
with (security_invoker = true)
as
select
  s.stay_id,
  t.trolley_code,
  outbound.customer_name as sent_to_customer,
  received.customer_name as received_from_customer,
  s.sent_on,
  s.received_on,
  case
    when s.sent_on is null then null
    when s.received_on is null then current_date - s.sent_on
    else s.received_on - s.sent_on
  end as days_out,
  s.status,
  s.exception_type,
  s.operator_confirmed,
  s.created_at,
  s.updated_at
from public.trolley_customer_stays s
join public.trolleys t
  on t.trolley_id = s.trolley_id
left join public.customers outbound
  on outbound.customer_id = s.outbound_customer_id
left join public.customers received
  on received.customer_id = s.received_from_customer_id;

-- ---------------------------------------------------------------------
-- Suggest the customer to the receiving operator.
--
-- Priority:
-- 1. customer from an open stay;
-- 2. most recent confirmed received-from customer;
-- 3. most recent outbound customer.
-- ---------------------------------------------------------------------

create or replace function public.suggest_trolley_customer(
  p_trolley_code text
)
returns table (
  trolley_id uuid,
  trolley_code text,
  open_stay_id uuid,
  suggested_customer_id uuid,
  suggested_customer_name text,
  suggestion_reason text,
  last_sent_on date,
  last_received_on date
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_trolley public.trolleys%rowtype;
begin
  select *
  into v_trolley
  from public.trolleys t
  where t.trolley_code = trim(p_trolley_code)
    and t.deleted_at is null;

  if not found then
    raise exception 'Trolley not found: %', p_trolley_code;
  end if;

  return query
  with open_record as (
    select
      s.stay_id,
      s.outbound_customer_id as customer_id,
      s.sent_on,
      s.received_on,
      1 as priority,
      'OPEN_STAY'::text as reason
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.received_on is null
    order by s.created_at desc
    limit 1
  ),
  last_confirmed as (
    select
      null::uuid as stay_id,
      s.received_from_customer_id as customer_id,
      s.sent_on,
      s.received_on,
      2 as priority,
      'LAST_CONFIRMED_RECEIPT'::text as reason
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.received_from_customer_id is not null
    order by s.received_on desc nulls last, s.created_at desc
    limit 1
  ),
  last_outbound as (
    select
      null::uuid as stay_id,
      s.outbound_customer_id as customer_id,
      s.sent_on,
      s.received_on,
      3 as priority,
      'LAST_OUTBOUND_RECORD'::text as reason
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.outbound_customer_id is not null
    order by s.sent_on desc nulls last, s.created_at desc
    limit 1
  ),
  suggestion as (
    select * from open_record
    union all
    select * from last_confirmed
    union all
    select * from last_outbound
    order by priority
    limit 1
  )
  select
    v_trolley.trolley_id,
    v_trolley.trolley_code,
    suggestion.stay_id,
    suggestion.customer_id,
    c.customer_name,
    coalesce(suggestion.reason, 'NO_HISTORY'),
    suggestion.sent_on,
    suggestion.received_on
  from (select 1) seed
  left join suggestion on true
  left join public.customers c
    on c.customer_id = suggestion.customer_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Send trolley to customer
-- Direct table writes should not be used by the frontend.
-- ---------------------------------------------------------------------

create or replace function public.send_trolley_to_customer(
  p_trolley_code text,
  p_customer_id uuid,
  p_sent_on date default current_date,
  p_notes text default null,
  p_source_application text default 'TROLLEY_CONTROL'
)
returns public.trolley_customer_stays
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_staff_id uuid;
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
begin
  if not public.has_any_role(
    array[
      'DISTRIBUTION_OPERATOR',
      'SORTING_OPERATOR',
      'SUPERVISOR',
      'ADMIN'
    ]
  ) then
    raise exception 'Permission denied for trolley outbound registration.';
  end if;

  v_staff_id := public.current_staff_id();

  select *
  into v_trolley
  from public.trolleys t
  where t.trolley_code = trim(p_trolley_code)
    and t.deleted_at is null
  for update;

  if not found then
    raise exception 'Trolley not found: %', p_trolley_code;
  end if;

  if not v_trolley.active
     or v_trolley.status in ('OUT_OF_SERVICE', 'RETIRED') then
    raise exception
      'Trolley % is not available for sending. Current status: %',
      v_trolley.trolley_code,
      v_trolley.status;
  end if;

  if not exists (
    select 1
    from public.customers c
    where c.customer_id = p_customer_id
      and c.active = true
      and c.deleted_at is null
  ) then
    raise exception 'Customer is not active or does not exist.';
  end if;

  if exists (
    select 1
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.received_on is null
  ) then
    raise exception
      'Trolley % already has an open customer stay.',
      v_trolley.trolley_code;
  end if;

  insert into public.trolley_customer_stays (
    trolley_id,
    outbound_customer_id,
    sent_on,
    status,
    sent_recorded_by,
    notes
  )
  values (
    v_trolley.trolley_id,
    p_customer_id,
    coalesce(p_sent_on, current_date),
    'OPEN',
    v_staff_id,
    p_notes
  )
  returning * into v_stay;

  update public.trolleys
  set
    status = 'AT_CUSTOMER',
    updated_by = auth.uid()
  where trolley_id = v_trolley.trolley_id;

  insert into public.trolley_events (
    trolley_id,
    stay_id,
    event_type,
    customer_id,
    business_date,
    performed_by,
    source_application,
    reason
  )
  values (
    v_trolley.trolley_id,
    v_stay.stay_id,
    'SENT_TO_CUSTOMER',
    p_customer_id,
    coalesce(p_sent_on, current_date),
    v_staff_id,
    p_source_application,
    p_notes
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
    'SEND_TROLLEY_TO_CUSTOMER',
    'trolley_customer_stays',
    v_stay.stay_id::text,
    to_jsonb(v_stay),
    p_notes,
    p_source_application
  );

  return v_stay;
end;
$$;

-- ---------------------------------------------------------------------
-- Receive trolley from customer
--
-- If an open stay exists:
--   it is closed and any customer mismatch is preserved for review.
--
-- If no open stay exists:
--   a received-only stay is created with sent_on = null.
--   The system never invents the missing send date.
-- ---------------------------------------------------------------------

create or replace function public.receive_trolley_from_customer(
  p_trolley_code text,
  p_received_from_customer_id uuid,
  p_received_on date default current_date,
  p_confirmation_source text default 'MANUAL_SELECTION',
  p_notes text default null,
  p_source_application text default 'SORTING_TROLLEY_RECEPTION'
)
returns public.trolley_customer_stays
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_staff_id uuid;
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_mismatch boolean := false;
  v_event_type text;
begin
  if not public.has_any_role(
    array[
      'SORTING_OPERATOR',
      'SUPERVISOR',
      'ADMIN'
    ]
  ) then
    raise exception 'Permission denied for trolley receipt.';
  end if;

  if p_confirmation_source not in (
    'OPEN_STAY',
    'LAST_KNOWN_CUSTOMER',
    'MANUAL_SELECTION',
    'SUPERVISOR_CORRECTION'
  ) then
    raise exception 'Invalid confirmation source.';
  end if;

  v_staff_id := public.current_staff_id();

  select *
  into v_trolley
  from public.trolleys t
  where t.trolley_code = trim(p_trolley_code)
    and t.deleted_at is null
  for update;

  if not found then
    raise exception 'Trolley not found: %', p_trolley_code;
  end if;

  if not exists (
    select 1
    from public.customers c
    where c.customer_id = p_received_from_customer_id
      and c.active = true
      and c.deleted_at is null
  ) then
    raise exception 'Confirmed customer is not active or does not exist.';
  end if;

  select *
  into v_stay
  from public.trolley_customer_stays s
  where s.trolley_id = v_trolley.trolley_id
    and s.received_on is null
  order by s.created_at desc
  limit 1
  for update;

  if found then
    v_mismatch :=
      v_stay.outbound_customer_id is distinct from
      p_received_from_customer_id;

    update public.trolley_customer_stays
    set
      received_from_customer_id = p_received_from_customer_id,
      received_on = coalesce(p_received_on, current_date),
      status = case
        when v_mismatch then 'REVIEW_REQUIRED'
        else 'RECEIVED'
      end,
      exception_type = case
        when v_mismatch then 'CUSTOMER_MISMATCH'
        else null
      end,
      confirmation_source = 'OPEN_STAY',
      operator_confirmed = true,
      received_recorded_by = v_staff_id,
      notes = case
        when p_notes is null or trim(p_notes) = '' then notes
        when notes is null or trim(notes) = '' then p_notes
        else notes || E'\nReceipt: ' || p_notes
      end
    where stay_id = v_stay.stay_id
    returning * into v_stay;

    v_event_type := case
      when v_mismatch then 'CUSTOMER_MISMATCH'
      else 'RECEIVED_FROM_CUSTOMER'
    end;
  else
    insert into public.trolley_customer_stays (
      trolley_id,
      outbound_customer_id,
      received_from_customer_id,
      sent_on,
      received_on,
      status,
      exception_type,
      confirmation_source,
      operator_confirmed,
      received_recorded_by,
      notes
    )
    values (
      v_trolley.trolley_id,
      null,
      p_received_from_customer_id,
      null,
      coalesce(p_received_on, current_date),
      'RECEIVED',
      'MISSING_OUTBOUND_RECORD',
      p_confirmation_source,
      true,
      v_staff_id,
      p_notes
    )
    returning * into v_stay;

    v_event_type := 'RECEIVED_WITHOUT_OUTBOUND';
  end if;

  update public.trolleys
  set
    status = 'AVAILABLE',
    updated_by = auth.uid()
  where trolley_id = v_trolley.trolley_id;

  insert into public.trolley_events (
    trolley_id,
    stay_id,
    event_type,
    customer_id,
    business_date,
    performed_by,
    source_application,
    reason,
    metadata
  )
  values (
    v_trolley.trolley_id,
    v_stay.stay_id,
    v_event_type,
    p_received_from_customer_id,
    coalesce(p_received_on, current_date),
    v_staff_id,
    p_source_application,
    p_notes,
    jsonb_build_object(
      'outbound_customer_id', v_stay.outbound_customer_id,
      'received_from_customer_id', v_stay.received_from_customer_id,
      'confirmation_source', v_stay.confirmation_source,
      'exception_type', v_stay.exception_type
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
    case
      when v_event_type = 'RECEIVED_WITHOUT_OUTBOUND'
        then 'RECEIVE_TROLLEY_WITHOUT_OUTBOUND'
      when v_event_type = 'CUSTOMER_MISMATCH'
        then 'RECEIVE_TROLLEY_CUSTOMER_MISMATCH'
      else 'RECEIVE_TROLLEY_FROM_CUSTOMER'
    end,
    'trolley_customer_stays',
    v_stay.stay_id::text,
    to_jsonb(v_stay),
    p_notes,
    p_source_application
  );

  return v_stay;
end;
$$;

revoke all on function public.suggest_trolley_customer(text) from public;
revoke all on function public.send_trolley_to_customer(text, uuid, date, text, text) from public;
revoke all on function public.receive_trolley_from_customer(text, uuid, date, text, text, text) from public;

grant execute on function public.suggest_trolley_customer(text)
  to authenticated;

grant execute on function public.send_trolley_to_customer(text, uuid, date, text, text)
  to authenticated;

grant execute on function public.receive_trolley_from_customer(text, uuid, date, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------

alter table public.app_config enable row level security;
alter table public.audit_log enable row level security;
alter table public.staff_members enable row level security;
alter table public.roles enable row level security;
alter table public.staff_roles enable row level security;
alter table public.areas enable row level security;
alter table public.stations enable row level security;
alter table public.shifts enable row level security;
alter table public.customers enable row level security;
alter table public.product_types enable row level security;
alter table public.customer_schedule_versions enable row level security;
alter table public.customer_schedule_items enable row level security;
alter table public.roster_periods enable row level security;
alter table public.roster_assignments enable row level security;
alter table public.work_sessions enable row level security;
alter table public.trolley_types enable row level security;
alter table public.trolleys enable row level security;
alter table public.trolley_customer_stays enable row level security;
alter table public.trolley_events enable row level security;

-- Shared authenticated read access to operational/reference data.
-- More restrictive area-level policies will be introduced with the application.
create policy "authenticated_read_areas"
  on public.areas for select
  to authenticated
  using (deleted_at is null);

create policy "authenticated_read_stations"
  on public.stations for select
  to authenticated
  using (deleted_at is null);

create policy "authenticated_read_shifts"
  on public.shifts for select
  to authenticated
  using (deleted_at is null);

create policy "authenticated_read_product_types"
  on public.product_types for select
  to authenticated
  using (deleted_at is null);

create policy "authenticated_read_customers"
  on public.customers for select
  to authenticated
  using (deleted_at is null);

create policy "authenticated_read_schedule_versions"
  on public.customer_schedule_versions for select
  to authenticated
  using (true);

create policy "authenticated_read_schedule_items"
  on public.customer_schedule_items for select
  to authenticated
  using (true);

create policy "authenticated_read_trolley_types"
  on public.trolley_types for select
  to authenticated
  using (true);

create policy "authenticated_read_trolleys"
  on public.trolleys for select
  to authenticated
  using (deleted_at is null);

create policy "authenticated_read_trolley_stays"
  on public.trolley_customer_stays for select
  to authenticated
  using (true);

create policy "authenticated_read_trolley_events"
  on public.trolley_events for select
  to authenticated
  using (true);

create policy "authenticated_read_roster_periods"
  on public.roster_periods for select
  to authenticated
  using (true);

create policy "authenticated_read_roster_assignments"
  on public.roster_assignments for select
  to authenticated
  using (true);

create policy "authenticated_read_work_sessions"
  on public.work_sessions for select
  to authenticated
  using (true);

create policy "staff_read_own_profile_or_management"
  on public.staff_members for select
  to authenticated
  using (
    auth_user_id = auth.uid()
    or public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'ROSTER_MANAGER', 'AUDITOR']
    )
  );

create policy "authenticated_read_roles"
  on public.roles for select
  to authenticated
  using (active = true);

create policy "staff_read_own_roles_or_management"
  on public.staff_roles for select
  to authenticated
  using (
    staff_id = public.current_staff_id()
    or public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'ROSTER_MANAGER', 'AUDITOR']
    )
  );

create policy "management_read_app_config"
  on public.app_config for select
  to authenticated
  using (
    public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR']
    )
  );

create policy "management_read_audit_log"
  on public.audit_log for select
  to authenticated
  using (
    public.has_any_role(
      array['ADMIN', 'MANAGER', 'AUDITOR']
    )
  );

commit;
