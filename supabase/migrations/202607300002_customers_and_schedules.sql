-- =====================================================================
-- ElisCaretex V2
-- Migration: 202607300002_customers_and_schedules.sql
-- Purpose:
--   Replace the empty foundation customer schedule structure with a
--   controlled weekly revision model, customer service configuration,
--   route master data, product variants, structured trolley requirements,
--   protected operational views and transactional management functions.
--
-- Important:
--   This migration intentionally stops if customer or schedule data already
--   exists. The current development database was verified as empty before
--   this file was prepared.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Safety guard
-- ---------------------------------------------------------------------

do $$
declare
  v_customers bigint;
  v_versions bigint;
  v_items bigint;
  v_product_types bigint;
  v_trolley_types bigint;
begin
  select count(*) into v_customers from public.customers;
  select count(*) into v_versions from public.customer_schedule_versions;
  select count(*) into v_items from public.customer_schedule_items;
  select count(*) into v_product_types from public.product_types;
  select count(*) into v_trolley_types from public.trolley_types;

  if v_customers <> 0
     or v_versions <> 0
     or v_items <> 0
     or v_product_types <> 0
     or v_trolley_types <> 0 then
    raise exception using
      message = 'Safety stop: customer foundation tables are not empty.',
      detail = format(
        'customers=%s, customer_schedule_versions=%s, customer_schedule_items=%s, product_types=%s, trolley_types=%s',
        v_customers,
        v_versions,
        v_items,
        v_product_types,
        v_trolley_types
      ),
      hint = 'Review the unexpected records before applying this migration. No migration changes were committed.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------

create or replace function public.set_updated_at_and_row_version()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  new.row_version := old.row_version + 1;
  return new;
end;
$$;

create or replace function public.weekday_name(p_weekday smallint)
returns text
language sql
immutable
strict
as $$
  select case p_weekday
    when 1 then 'Monday'
    when 2 then 'Tuesday'
    when 3 then 'Wednesday'
    when 4 then 'Thursday'
    when 5 then 'Friday'
    when 6 then 'Saturday'
    when 7 then 'Sunday'
  end;
$$;


create or replace function public.current_business_date()
returns date
language sql
stable
security definer
set search_path = public, auth
as $$
  select (
    now() at time zone coalesce(
      (
        select value_json #>> '{}'
        from public.app_config
        where config_key = 'business_timezone'
      ),
      'Europe/Dublin'
    )
  )::date;
$$;

-- ---------------------------------------------------------------------
-- Customer master data
-- ---------------------------------------------------------------------

alter table public.customers
  add column if not exists distribution_estimated_kg numeric(12,2),
  add column if not exists distribution_stop_count integer,
  add column if not exists operational_alert text,
  add column if not exists deactivated_at timestamptz,
  add column if not exists deactivated_by uuid references auth.users(id) on delete set null,
  add column if not exists deactivation_reason text,
  add column if not exists row_version integer not null default 1,
  add column if not exists legacy_metadata jsonb not null default '{}'::jsonb;

alter table public.customers
  drop constraint if exists customers_distribution_estimated_kg_check;

alter table public.customers
  add constraint customers_distribution_estimated_kg_check
  check (
    distribution_estimated_kg is null
    or distribution_estimated_kg >= 0
  );

alter table public.customers
  drop constraint if exists customers_distribution_stop_count_check;

alter table public.customers
  add constraint customers_distribution_stop_count_check
  check (
    distribution_stop_count is null
    or distribution_stop_count >= 0
  );

alter table public.customers
  drop constraint if exists customers_inactive_reason_check;

alter table public.customers
  add constraint customers_inactive_reason_check
  check (
    active
    or deactivated_at is not null
    or deleted_at is not null
  );

create index if not exists customers_active_name_idx
  on public.customers (active, lower(customer_name))
  where deleted_at is null;

-- ---------------------------------------------------------------------
-- Product and trolley reference data extensions
-- ---------------------------------------------------------------------

alter table public.trolley_types
  add column if not exists display_code text,
  add column if not exists trolley_category text not null default 'STANDARD',
  add column if not exists allowed_in_customer_schedule boolean not null default false,
  add column if not exists sort_order integer not null default 0,
  add column if not exists metadata jsonb not null default '{}'::jsonb,
  add column if not exists deleted_at timestamptz;

alter table public.trolley_types
  drop constraint if exists trolley_types_category_check;

alter table public.trolley_types
  add constraint trolley_types_category_check
  check (trolley_category in ('STANDARD', 'SPECIAL'));

create table public.product_variants (
  product_variant_id uuid primary key default gen_random_uuid(),
  product_type_id uuid not null
    references public.product_types(product_type_id) on delete restrict,
  variant_code text not null,
  display_name text not null,
  active boolean not null default true,
  sort_order integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  constraint product_variants_code_unique
    unique (product_type_id, variant_code)
);

-- ---------------------------------------------------------------------
-- Customer service eligibility
--
-- This records which product types a customer may supply. It is separate
-- from the days on which those products are scheduled.
-- ---------------------------------------------------------------------

create table public.customer_product_services (
  customer_product_service_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null
    references public.customers(customer_id) on delete restrict,
  product_type_id uuid not null
    references public.product_types(product_type_id) on delete restrict,
  effective_from date not null default public.current_business_date(),
  effective_until date,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  row_version integer not null default 1,
  constraint customer_product_services_dates_check
    check (
      effective_until is null
      or effective_until >= effective_from
    )
);

create unique index customer_product_services_open_unique
  on public.customer_product_services (customer_id, product_type_id)
  where active and effective_until is null and deleted_at is null;

create index customer_product_services_lookup_idx
  on public.customer_product_services
  (customer_id, product_type_id, effective_from, effective_until);

-- ---------------------------------------------------------------------
-- Distribution route master data
--
-- display_name and route_color belong to the route master and are never
-- independently editable schedule fields. Daily actual route assignment
-- will be implemented later in the Distribution module and will not
-- overwrite this default schedule route.
-- ---------------------------------------------------------------------

create table public.distribution_routes (
  route_id uuid primary key default gen_random_uuid(),
  route_code text not null unique,
  display_name text not null,
  route_color text,
  route_kind text not null default 'STANDARD',
  allow_as_default boolean not null default true,
  active boolean not null default true,
  sort_order integer not null default 0,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  row_version integer not null default 1,
  constraint distribution_routes_kind_check
    check (route_kind in ('STANDARD', 'COLLECTION', 'AD_HOC', 'SUPPORT')),
  constraint distribution_routes_color_check
    check (
      route_color is null
      or route_color ~ '^#[0-9A-Fa-f]{6}$'
    )
);

-- ---------------------------------------------------------------------
-- Replace the empty foundation schedule tables
-- ---------------------------------------------------------------------

drop table public.customer_schedule_items cascade;
drop table public.customer_schedule_versions cascade;

-- A version represents one complete weekly schedule revision for a customer.
create table public.customer_schedule_versions (
  schedule_version_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null
    references public.customers(customer_id) on delete restrict,
  version_number integer not null,
  status text not null default 'DRAFT',
  effective_from date not null,
  effective_until date,
  based_on_version_id uuid
    references public.customer_schedule_versions(schedule_version_id)
    on delete restrict,
  source_code text not null default 'MANUAL',
  change_reason text,
  general_instructions text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  published_at timestamptz,
  published_by uuid references auth.users(id) on delete set null,
  superseded_at timestamptz,
  superseded_by uuid references auth.users(id) on delete set null,
  cancelled_at timestamptz,
  cancelled_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint customer_schedule_versions_number_check
    check (version_number > 0),
  constraint customer_schedule_versions_status_check
    check (status in ('DRAFT', 'PUBLISHED', 'SUPERSEDED', 'CANCELLED')),
  constraint customer_schedule_versions_source_check
    check (source_code in ('MANUAL', 'LEGACY_IMPORT', 'RESTORE')),
  constraint customer_schedule_versions_dates_check
    check (
      effective_until is null
      or effective_until >= effective_from
    ),
  constraint customer_schedule_versions_customer_number_unique
    unique (customer_id, version_number)
);

create unique index customer_schedule_one_draft_idx
  on public.customer_schedule_versions (customer_id)
  where status = 'DRAFT';

alter table public.customer_schedule_versions
  add constraint customer_schedule_published_no_overlap
  exclude using gist (
    customer_id with =,
    daterange(
      effective_from,
      coalesce(effective_until, 'infinity'::date),
      '[]'
    ) with &&
  )
  where (status = 'PUBLISHED');

create index customer_schedule_versions_lookup_idx
  on public.customer_schedule_versions
  (customer_id, status, effective_from desc, version_number desc);

create table public.customer_schedule_days (
  schedule_day_id uuid primary key default gen_random_uuid(),
  schedule_version_id uuid not null
    references public.customer_schedule_versions(schedule_version_id)
    on delete cascade,
  production_weekday smallint not null,
  delivery_weekday smallint,
  default_route_id uuid
    references public.distribution_routes(route_id) on delete restrict,
  delivery_window_start time,
  delivery_window_end time,
  delivery_order integer,
  day_alert text,
  distribution_instructions text,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint customer_schedule_days_weekday_check
    check (production_weekday between 1 and 7),
  constraint customer_schedule_days_delivery_weekday_check
    check (delivery_weekday is null or delivery_weekday between 1 and 7),
  constraint customer_schedule_days_delivery_order_check
    check (delivery_order is null or delivery_order > 0),
  constraint customer_schedule_days_delivery_window_check
    check (
      delivery_window_start is null
      or delivery_window_end is null
      or delivery_window_end > delivery_window_start
    ),
  constraint customer_schedule_days_version_weekday_unique
    unique (schedule_version_id, production_weekday)
);

create index customer_schedule_days_lookup_idx
  on public.customer_schedule_days
  (production_weekday, active, schedule_version_id);

create table public.customer_schedule_products (
  schedule_product_id uuid primary key default gen_random_uuid(),
  schedule_day_id uuid not null
    references public.customer_schedule_days(schedule_day_id)
    on delete cascade,
  product_type_id uuid not null
    references public.product_types(product_type_id) on delete restrict,
  production_order integer,
  expected_kg numeric(12,2),
  expected_units integer,
  production_instructions text,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint customer_schedule_products_order_check
    check (production_order is null or production_order > 0),
  constraint customer_schedule_products_expected_kg_check
    check (expected_kg is null or expected_kg >= 0),
  constraint customer_schedule_products_expected_units_check
    check (expected_units is null or expected_units >= 0),
  constraint customer_schedule_products_day_product_unique
    unique (schedule_day_id, product_type_id)
);

create index customer_schedule_products_lookup_idx
  on public.customer_schedule_products
  (product_type_id, production_order, active, schedule_day_id);

create table public.customer_schedule_product_variants (
  schedule_product_id uuid not null
    references public.customer_schedule_products(schedule_product_id)
    on delete cascade,
  product_variant_id uuid not null
    references public.product_variants(product_variant_id)
    on delete restrict,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  primary key (schedule_product_id, product_variant_id)
);

-- A requirement is counted once in the Distribution total.
-- owner_schedule_product_id identifies which production stream owns and
-- displays the trolley requirement. A shared trolley has multiple mappings
-- in customer_schedule_trolley_requirement_products, but still one owner.
create table public.customer_schedule_trolley_requirements (
  schedule_trolley_requirement_id uuid primary key default gen_random_uuid(),
  schedule_day_id uuid not null
    references public.customer_schedule_days(schedule_day_id)
    on delete cascade,
  trolley_type_id uuid not null
    references public.trolley_types(trolley_type_id) on delete restrict,
  owner_schedule_product_id uuid not null
    references public.customer_schedule_products(schedule_product_id)
    on delete restrict,
  quantity integer not null,
  empty_trolley boolean not null default false,
  notes text,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint customer_schedule_trolley_quantity_check
    check (quantity > 0)
);

create index customer_schedule_trolley_requirements_day_idx
  on public.customer_schedule_trolley_requirements
  (schedule_day_id, owner_schedule_product_id, active);

-- The mapped products show every product stream served by the requirement.
-- Separate Clothes and Mop trolleys are separate requirement rows.
-- A shared trolley is one requirement row mapped to both products.
create table public.customer_schedule_trolley_requirement_products (
  schedule_trolley_requirement_id uuid not null
    references public.customer_schedule_trolley_requirements(
      schedule_trolley_requirement_id
    ) on delete cascade,
  schedule_product_id uuid not null
    references public.customer_schedule_products(schedule_product_id)
    on delete restrict,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  primary key (schedule_trolley_requirement_id, schedule_product_id)
);

-- ---------------------------------------------------------------------
-- Schedule integrity triggers
-- ---------------------------------------------------------------------

create or replace function public.validate_schedule_product_variant()
returns trigger
language plpgsql
as $$
declare
  v_schedule_product_type_id uuid;
  v_variant_product_type_id uuid;
begin
  select product_type_id
  into v_schedule_product_type_id
  from public.customer_schedule_products
  where schedule_product_id = new.schedule_product_id;

  select product_type_id
  into v_variant_product_type_id
  from public.product_variants
  where product_variant_id = new.product_variant_id;

  if v_schedule_product_type_id is null
     or v_variant_product_type_id is null
     or v_schedule_product_type_id <> v_variant_product_type_id then
    raise exception 'The selected product variant does not belong to the scheduled product type.';
  end if;

  return new;
end;
$$;

create trigger customer_schedule_product_variants_validate
before insert or update
on public.customer_schedule_product_variants
for each row execute function public.validate_schedule_product_variant();

create or replace function public.validate_schedule_trolley_requirement()
returns trigger
language plpgsql
as $$
declare
  v_owner_day_id uuid;
begin
  select schedule_day_id
  into v_owner_day_id
  from public.customer_schedule_products
  where schedule_product_id = new.owner_schedule_product_id
    and active = true;

  if v_owner_day_id is null or v_owner_day_id <> new.schedule_day_id then
    raise exception 'The trolley owner product must be active and belong to the same schedule day.';
  end if;

  return new;
end;
$$;

create trigger customer_schedule_trolley_requirements_validate
before insert or update
on public.customer_schedule_trolley_requirements
for each row execute function public.validate_schedule_trolley_requirement();

create or replace function public.validate_schedule_trolley_requirement_product()
returns trigger
language plpgsql
as $$
declare
  v_requirement_day_id uuid;
  v_product_day_id uuid;
begin
  select schedule_day_id
  into v_requirement_day_id
  from public.customer_schedule_trolley_requirements
  where schedule_trolley_requirement_id = new.schedule_trolley_requirement_id
    and active = true;

  select schedule_day_id
  into v_product_day_id
  from public.customer_schedule_products
  where schedule_product_id = new.schedule_product_id
    and active = true;

  if v_requirement_day_id is null
     or v_product_day_id is null
     or v_requirement_day_id <> v_product_day_id then
    raise exception 'A trolley requirement may serve only active products from the same schedule day.';
  end if;

  return new;
end;
$$;

create trigger customer_schedule_trolley_requirement_products_validate
before insert or update
on public.customer_schedule_trolley_requirement_products
for each row execute function public.validate_schedule_trolley_requirement_product();

-- Published and historical schedule children are immutable. Only DRAFT
-- revisions may have their day, product, variant and trolley details edited.
create or replace function public.require_draft_schedule_parent()
returns trigger
language plpgsql
as $$
declare
  v_row jsonb;
  v_schedule_version_id uuid;
  v_status text;
begin
  if tg_op = 'DELETE' then
    v_row := to_jsonb(old);
  else
    v_row := to_jsonb(new);
  end if;

  if tg_table_name = 'customer_schedule_days' then
    v_schedule_version_id := (v_row ->> 'schedule_version_id')::uuid;

  elsif tg_table_name = 'customer_schedule_products' then
    select d.schedule_version_id
    into v_schedule_version_id
    from public.customer_schedule_days d
    where d.schedule_day_id = (v_row ->> 'schedule_day_id')::uuid;

  elsif tg_table_name = 'customer_schedule_product_variants' then
    select d.schedule_version_id
    into v_schedule_version_id
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    where p.schedule_product_id = (v_row ->> 'schedule_product_id')::uuid;

  elsif tg_table_name = 'customer_schedule_trolley_requirements' then
    select d.schedule_version_id
    into v_schedule_version_id
    from public.customer_schedule_days d
    where d.schedule_day_id = (v_row ->> 'schedule_day_id')::uuid;

  elsif tg_table_name = 'customer_schedule_trolley_requirement_products' then
    select d.schedule_version_id
    into v_schedule_version_id
    from public.customer_schedule_trolley_requirements r
    join public.customer_schedule_days d
      on d.schedule_day_id = r.schedule_day_id
    where r.schedule_trolley_requirement_id =
      (v_row ->> 'schedule_trolley_requirement_id')::uuid;
  end if;

  select status
  into v_status
  from public.customer_schedule_versions
  where schedule_version_id = v_schedule_version_id;

  if v_status is distinct from 'DRAFT' then
    raise exception 'Only DRAFT schedule revisions may be edited.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

create trigger customer_schedule_days_require_draft
before insert or update or delete
on public.customer_schedule_days
for each row execute function public.require_draft_schedule_parent();

create trigger customer_schedule_products_require_draft
before insert or update or delete
on public.customer_schedule_products
for each row execute function public.require_draft_schedule_parent();

create trigger customer_schedule_product_variants_require_draft
before insert or update or delete
on public.customer_schedule_product_variants
for each row execute function public.require_draft_schedule_parent();

create trigger customer_schedule_trolley_requirements_require_draft
before insert or update or delete
on public.customer_schedule_trolley_requirements
for each row execute function public.require_draft_schedule_parent();

create trigger customer_schedule_trolley_requirement_products_require_draft
before insert or update or delete
on public.customer_schedule_trolley_requirement_products
for each row execute function public.require_draft_schedule_parent();

-- ---------------------------------------------------------------------
-- Updated-at and row-version triggers
-- ---------------------------------------------------------------------

drop trigger if exists customers_set_updated_at on public.customers;
create trigger customers_set_updated_at_and_row_version
before update on public.customers
for each row execute function public.set_updated_at_and_row_version();

do $$
declare
  v_table_name text;
begin
  foreach v_table_name in array array[
    'customer_product_services',
    'distribution_routes',
    'customer_schedule_versions',
    'customer_schedule_days',
    'customer_schedule_products',
    'customer_schedule_trolley_requirements'
  ]
  loop
    execute format(
      'create trigger %I before update on public.%I
       for each row execute function public.set_updated_at_and_row_version()',
      v_table_name || '_set_updated_at_and_row_version',
      v_table_name
    );
  end loop;
end;
$$;

create trigger product_variants_set_updated_at
before update on public.product_variants
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Customer management functions
-- ---------------------------------------------------------------------

create or replace function public.create_customer(
  p_customer_code text,
  p_customer_name text,
  p_eircode text default null,
  p_distribution_estimated_kg numeric default null,
  p_distribution_stop_count integer default null,
  p_notes text default null,
  p_operational_alert text default null,
  p_product_codes text[] default array[]::text[],
  p_change_reason text default null,
  p_source_application text default 'CUSTOMER_MANAGEMENT'
)
returns public.customers
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_customer public.customers%rowtype;
  v_product_code text;
  v_product_type_id uuid;
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']) then
    raise exception 'Permission denied for customer creation.';
  end if;

  if nullif(trim(p_customer_code), '') is null then
    raise exception 'Customer code is required.';
  end if;

  if nullif(trim(p_customer_name), '') is null then
    raise exception 'Customer name is required.';
  end if;

  if coalesce(array_length(p_product_codes, 1), 0) = 0 then
    raise exception 'At least one customer product service is required for an active customer.';
  end if;

  insert into public.customers (
    customer_code,
    customer_name,
    eircode,
    distribution_estimated_kg,
    distribution_stop_count,
    notes,
    operational_alert,
    active,
    created_by,
    updated_by
  )
  values (
    upper(trim(p_customer_code)),
    trim(p_customer_name),
    nullif(trim(p_eircode), ''),
    p_distribution_estimated_kg,
    p_distribution_stop_count,
    nullif(trim(p_notes), ''),
    nullif(trim(p_operational_alert), ''),
    true,
    auth.uid(),
    auth.uid()
  )
  returning * into v_customer;

  foreach v_product_code in array p_product_codes
  loop
    select product_type_id
    into v_product_type_id
    from public.product_types
    where product_code = upper(trim(v_product_code))
      and active = true
      and deleted_at is null;

    if v_product_type_id is null then
      raise exception 'Unknown or inactive product type: %', v_product_code;
    end if;

    if not exists (
      select 1
      from public.customer_product_services
      where customer_id = v_customer.customer_id
        and product_type_id = v_product_type_id
        and active = true
        and effective_until is null
        and deleted_at is null
    ) then
      insert into public.customer_product_services (
        customer_id,
        product_type_id,
        effective_from,
        active,
        created_by,
        updated_by
      )
      values (
        v_customer.customer_id,
        v_product_type_id,
        public.current_business_date(),
        true,
        auth.uid(),
        auth.uid()
      );
    end if;
  end loop;

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
    'CREATE_CUSTOMER',
    'customers',
    v_customer.customer_id::text,
    to_jsonb(v_customer),
    nullif(trim(p_change_reason), ''),
    p_source_application
  );

  return v_customer;
end;
$$;

create or replace function public.update_customer(
  p_customer_id uuid,
  p_expected_row_version integer,
  p_customer_code text,
  p_customer_name text,
  p_eircode text,
  p_distribution_estimated_kg numeric,
  p_distribution_stop_count integer,
  p_notes text,
  p_operational_alert text,
  p_product_codes text[],
  p_change_reason text,
  p_source_application text default 'CUSTOMER_MANAGEMENT'
)
returns public.customers
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_old public.customers%rowtype;
  v_customer public.customers%rowtype;
  v_product_code text;
  v_product_type_id uuid;
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']) then
    raise exception 'Permission denied for customer update.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception 'A change reason is required.';
  end if;

  if nullif(trim(p_customer_code), '') is null
     or nullif(trim(p_customer_name), '') is null then
    raise exception 'Customer code and customer name are required.';
  end if;

  if coalesce(array_length(p_product_codes, 1), 0) = 0 then
    raise exception 'At least one customer product service is required for an active customer.';
  end if;

  select *
  into v_old
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null
  for update;

  if not found then
    raise exception 'Customer not found.';
  end if;

  if not v_old.active then
    raise exception 'Inactive customers must be reactivated before normal editing.';
  end if;

  if v_old.row_version <> p_expected_row_version then
    raise exception 'This customer was changed by another user. Reload it before saving.';
  end if;

  update public.customers
  set
    customer_code = upper(trim(p_customer_code)),
    customer_name = trim(p_customer_name),
    eircode = nullif(trim(p_eircode), ''),
    distribution_estimated_kg = p_distribution_estimated_kg,
    distribution_stop_count = p_distribution_stop_count,
    notes = nullif(trim(p_notes), ''),
    operational_alert = nullif(trim(p_operational_alert), ''),
    updated_by = auth.uid()
  where customer_id = p_customer_id
  returning * into v_customer;

  update public.customer_product_services cps
  set
    active = false,
    effective_until = public.current_business_date(),
    updated_by = auth.uid()
  where cps.customer_id = p_customer_id
    and cps.active = true
    and cps.deleted_at is null
    and not exists (
      select 1
      from unnest(p_product_codes) as requested(product_code)
      join public.product_types pt
        on pt.product_code = upper(trim(requested.product_code))
      where pt.product_type_id = cps.product_type_id
    );

  foreach v_product_code in array p_product_codes
  loop
    select product_type_id
    into v_product_type_id
    from public.product_types
    where product_code = upper(trim(v_product_code))
      and active = true
      and deleted_at is null;

    if v_product_type_id is null then
      raise exception 'Unknown or inactive product type: %', v_product_code;
    end if;

    if not exists (
      select 1
      from public.customer_product_services
      where customer_id = p_customer_id
        and product_type_id = v_product_type_id
        and active = true
        and effective_until is null
        and deleted_at is null
    ) then
      insert into public.customer_product_services (
        customer_id,
        product_type_id,
        effective_from,
        active,
        created_by,
        updated_by
      )
      values (
        p_customer_id,
        v_product_type_id,
        public.current_business_date(),
        true,
        auth.uid(),
        auth.uid()
      );
    end if;
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
    'UPDATE_CUSTOMER',
    'customers',
    p_customer_id::text,
    to_jsonb(v_old),
    to_jsonb(v_customer),
    trim(p_change_reason),
    p_source_application
  );

  return v_customer;
end;
$$;

create or replace function public.deactivate_customer(
  p_customer_id uuid,
  p_reason text,
  p_source_application text default 'CUSTOMER_MANAGEMENT'
)
returns public.customers
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_old public.customers%rowtype;
  v_customer public.customers%rowtype;
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER']) then
    raise exception 'Permission denied for customer deactivation.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A deactivation reason is required.';
  end if;

  select *
  into v_old
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null
  for update;

  if not found then
    raise exception 'Customer not found.';
  end if;

  if not v_old.active then
    return v_old;
  end if;

  update public.customers
  set
    active = false,
    deactivated_at = now(),
    deactivated_by = auth.uid(),
    deactivation_reason = trim(p_reason),
    updated_by = auth.uid()
  where customer_id = p_customer_id
  returning * into v_customer;

  update public.customer_product_services
  set
    active = false,
    effective_until = public.current_business_date(),
    updated_by = auth.uid()
  where customer_id = p_customer_id
    and active = true
    and deleted_at is null;

  update public.customer_schedule_versions
  set
    status = 'CANCELLED',
    cancelled_at = now(),
    cancelled_by = auth.uid(),
    change_reason = concat_ws(' | ', change_reason, 'Customer deactivated: ' || trim(p_reason)),
    updated_by = auth.uid()
  where customer_id = p_customer_id
    and status = 'DRAFT';

  update public.customer_schedule_versions
  set
    status = 'SUPERSEDED',
    effective_until = case
      when effective_from < public.current_business_date()
        then least(coalesce(effective_until, public.current_business_date() - 1), public.current_business_date() - 1)
      else effective_until
    end,
    superseded_at = now(),
    superseded_by = auth.uid(),
    change_reason = concat_ws(' | ', change_reason, 'Customer deactivated: ' || trim(p_reason)),
    updated_by = auth.uid()
  where customer_id = p_customer_id
    and status = 'PUBLISHED';

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
    'DEACTIVATE_CUSTOMER',
    'customers',
    p_customer_id::text,
    to_jsonb(v_old),
    to_jsonb(v_customer),
    trim(p_reason),
    p_source_application
  );

  return v_customer;
end;
$$;

create or replace function public.reactivate_customer(
  p_customer_id uuid,
  p_product_codes text[],
  p_reason text,
  p_source_application text default 'CUSTOMER_MANAGEMENT'
)
returns public.customers
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_old public.customers%rowtype;
  v_customer public.customers%rowtype;
  v_product_code text;
  v_product_type_id uuid;
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER']) then
    raise exception 'Permission denied for customer reactivation.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A reactivation reason is required.';
  end if;

  if coalesce(array_length(p_product_codes, 1), 0) = 0 then
    raise exception 'At least one product service is required to reactivate a customer.';
  end if;

  select *
  into v_old
  from public.customers
  where customer_id = p_customer_id
    and deleted_at is null
  for update;

  if not found then
    raise exception 'Customer not found.';
  end if;

  if v_old.active then
    raise exception 'Customer is already active.';
  end if;

  update public.customers
  set
    active = true,
    deactivated_at = null,
    deactivated_by = null,
    deactivation_reason = null,
    updated_by = auth.uid()
  where customer_id = p_customer_id
  returning * into v_customer;

  foreach v_product_code in array p_product_codes
  loop
    select product_type_id
    into v_product_type_id
    from public.product_types
    where product_code = upper(trim(v_product_code))
      and active = true
      and deleted_at is null;

    if v_product_type_id is null then
      raise exception 'Unknown or inactive product type: %', v_product_code;
    end if;

    if not exists (
      select 1
      from public.customer_product_services
      where customer_id = p_customer_id
        and product_type_id = v_product_type_id
        and active = true
        and effective_until is null
        and deleted_at is null
    ) then
      insert into public.customer_product_services (
        customer_id,
        product_type_id,
        effective_from,
        active,
        created_by,
        updated_by
      )
      values (
        p_customer_id,
        v_product_type_id,
        public.current_business_date(),
        true,
        auth.uid(),
        auth.uid()
      );
    end if;
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
    'REACTIVATE_CUSTOMER',
    'customers',
    p_customer_id::text,
    to_jsonb(v_old),
    to_jsonb(v_customer),
    trim(p_reason),
    p_source_application
  );

  return v_customer;
end;
$$;

-- ---------------------------------------------------------------------
-- Schedule revision functions
-- ---------------------------------------------------------------------

create or replace function public.create_customer_schedule_draft(
  p_customer_id uuid,
  p_effective_from date,
  p_based_on_version_id uuid default null,
  p_change_reason text default null,
  p_source_application text default 'CUSTOMER_SCHEDULE_MANAGEMENT'
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_base_version_id uuid;
  v_new_version_id uuid;
  v_new_version_number integer;
  v_new_day_id uuid;
  v_new_product_id uuid;
  v_new_requirement_id uuid;
  v_day_map jsonb := '{}'::jsonb;
  v_product_map jsonb := '{}'::jsonb;
  v_old_day record;
  v_old_product record;
  v_old_requirement record;
  v_old_mapping record;
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']) then
    raise exception 'Permission denied for schedule draft creation.';
  end if;

  if p_effective_from is null then
    raise exception 'The proposed effective date is required.';
  end if;

  if not exists (
    select 1
    from public.customers
    where customer_id = p_customer_id
      and active = true
      and deleted_at is null
  ) then
    raise exception 'Customer is not active or does not exist.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_versions
    where customer_id = p_customer_id
      and status = 'DRAFT'
  ) then
    raise exception 'This customer already has an open schedule draft.';
  end if;

  v_base_version_id := p_based_on_version_id;

  if v_base_version_id is not null then
    if not exists (
      select 1
      from public.customer_schedule_versions
      where schedule_version_id = v_base_version_id
        and customer_id = p_customer_id
        and status in ('PUBLISHED', 'SUPERSEDED', 'CANCELLED')
    ) then
      raise exception 'The selected base schedule does not belong to this customer or cannot be copied.';
    end if;
  else
    select schedule_version_id
    into v_base_version_id
    from public.customer_schedule_versions
    where customer_id = p_customer_id
      and status = 'PUBLISHED'
      and effective_from <= p_effective_from
    order by effective_from desc, version_number desc
    limit 1;
  end if;

  select coalesce(max(version_number), 0) + 1
  into v_new_version_number
  from public.customer_schedule_versions
  where customer_id = p_customer_id;

  insert into public.customer_schedule_versions (
    customer_id,
    version_number,
    status,
    effective_from,
    based_on_version_id,
    source_code,
    change_reason,
    created_by,
    updated_by
  )
  values (
    p_customer_id,
    v_new_version_number,
    'DRAFT',
    p_effective_from,
    v_base_version_id,
    'MANUAL',
    nullif(trim(p_change_reason), ''),
    auth.uid(),
    auth.uid()
  )
  returning schedule_version_id into v_new_version_id;

  if v_base_version_id is not null then
    for v_old_day in
      select *
      from public.customer_schedule_days
      where schedule_version_id = v_base_version_id
        and active = true
      order by production_weekday
    loop
      insert into public.customer_schedule_days (
        schedule_version_id,
        production_weekday,
        delivery_weekday,
        default_route_id,
        delivery_window_start,
        delivery_window_end,
        delivery_order,
        day_alert,
        distribution_instructions,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        v_new_version_id,
        v_old_day.production_weekday,
        v_old_day.delivery_weekday,
        v_old_day.default_route_id,
        v_old_day.delivery_window_start,
        v_old_day.delivery_window_end,
        v_old_day.delivery_order,
        v_old_day.day_alert,
        v_old_day.distribution_instructions,
        v_old_day.active,
        v_old_day.metadata,
        auth.uid(),
        auth.uid()
      )
      returning schedule_day_id into v_new_day_id;

      v_day_map := jsonb_set(
        v_day_map,
        array[v_old_day.schedule_day_id::text],
        to_jsonb(v_new_day_id::text),
        true
      );

      for v_old_product in
        select *
        from public.customer_schedule_products
        where schedule_day_id = v_old_day.schedule_day_id
          and active = true
        order by production_order nulls last, created_at
      loop
        insert into public.customer_schedule_products (
          schedule_day_id,
          product_type_id,
          production_order,
          expected_kg,
          expected_units,
          production_instructions,
          active,
          metadata,
          created_by,
          updated_by
        )
        values (
          v_new_day_id,
          v_old_product.product_type_id,
          v_old_product.production_order,
          v_old_product.expected_kg,
          v_old_product.expected_units,
          v_old_product.production_instructions,
          v_old_product.active,
          v_old_product.metadata,
          auth.uid(),
          auth.uid()
        )
        returning schedule_product_id into v_new_product_id;

        v_product_map := jsonb_set(
          v_product_map,
          array[v_old_product.schedule_product_id::text],
          to_jsonb(v_new_product_id::text),
          true
        );

        insert into public.customer_schedule_product_variants (
          schedule_product_id,
          product_variant_id,
          created_by
        )
        select
          v_new_product_id,
          old_variant.product_variant_id,
          auth.uid()
        from public.customer_schedule_product_variants old_variant
        where old_variant.schedule_product_id = v_old_product.schedule_product_id;
      end loop;
    end loop;

    for v_old_requirement in
      select *
      from public.customer_schedule_trolley_requirements
      where schedule_day_id in (
        select schedule_day_id
        from public.customer_schedule_days
        where schedule_version_id = v_base_version_id
      )
        and active = true
      order by created_at
    loop
      insert into public.customer_schedule_trolley_requirements (
        schedule_day_id,
        trolley_type_id,
        owner_schedule_product_id,
        quantity,
        empty_trolley,
        notes,
        active,
        metadata,
        created_by,
        updated_by
      )
      values (
        (v_day_map ->> v_old_requirement.schedule_day_id::text)::uuid,
        v_old_requirement.trolley_type_id,
        (v_product_map ->> v_old_requirement.owner_schedule_product_id::text)::uuid,
        v_old_requirement.quantity,
        v_old_requirement.empty_trolley,
        v_old_requirement.notes,
        v_old_requirement.active,
        v_old_requirement.metadata,
        auth.uid(),
        auth.uid()
      )
      returning schedule_trolley_requirement_id into v_new_requirement_id;

      for v_old_mapping in
        select schedule_product_id
        from public.customer_schedule_trolley_requirement_products
        where schedule_trolley_requirement_id =
          v_old_requirement.schedule_trolley_requirement_id
      loop
        insert into public.customer_schedule_trolley_requirement_products (
          schedule_trolley_requirement_id,
          schedule_product_id,
          created_by
        )
        values (
          v_new_requirement_id,
          (v_product_map ->> v_old_mapping.schedule_product_id::text)::uuid,
          auth.uid()
        );
      end loop;
    end loop;
  end if;

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
    'CREATE_CUSTOMER_SCHEDULE_DRAFT',
    'customer_schedule_versions',
    v_new_version_id::text,
    jsonb_build_object(
      'customer_id', p_customer_id,
      'version_number', v_new_version_number,
      'effective_from', p_effective_from,
      'based_on_version_id', v_base_version_id
    ),
    nullif(trim(p_change_reason), ''),
    p_source_application
  );

  return v_new_version_id;
end;
$$;

create or replace function public.restore_customer_schedule_version(
  p_source_version_id uuid,
  p_effective_from date,
  p_reason text,
  p_source_application text default 'CUSTOMER_SCHEDULE_MANAGEMENT'
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_customer_id uuid;
  v_new_version_id uuid;
begin
  if nullif(trim(p_reason), '') is null then
    raise exception 'A restore reason is required.';
  end if;

  select customer_id
  into v_customer_id
  from public.customer_schedule_versions
  where schedule_version_id = p_source_version_id
    and status in ('PUBLISHED', 'SUPERSEDED', 'CANCELLED');

  if v_customer_id is null then
    raise exception 'The selected historical schedule version cannot be restored.';
  end if;

  v_new_version_id := public.create_customer_schedule_draft(
    v_customer_id,
    p_effective_from,
    p_source_version_id,
    p_reason,
    p_source_application
  );

  update public.customer_schedule_versions
  set
    source_code = 'RESTORE',
    updated_by = auth.uid()
  where schedule_version_id = v_new_version_id;

  return v_new_version_id;
end;
$$;

create or replace function public.cancel_customer_schedule_version(
  p_schedule_version_id uuid,
  p_reason text,
  p_source_application text default 'CUSTOMER_SCHEDULE_MANAGEMENT'
)
returns public.customer_schedule_versions
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_old public.customer_schedule_versions%rowtype;
  v_version public.customer_schedule_versions%rowtype;
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']) then
    raise exception 'Permission denied for schedule cancellation.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A cancellation reason is required.';
  end if;

  select *
  into v_old
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found then
    raise exception 'Schedule version not found.';
  end if;

  if v_old.status = 'PUBLISHED' and v_old.effective_from <= public.current_business_date() then
    raise exception 'A current or historical published version cannot be cancelled. Publish a replacement revision instead.';
  end if;

  if v_old.status not in ('DRAFT', 'PUBLISHED') then
    raise exception 'Only a draft or future published version can be cancelled.';
  end if;

  update public.customer_schedule_versions
  set
    status = 'CANCELLED',
    cancelled_at = now(),
    cancelled_by = auth.uid(),
    change_reason = concat_ws(' | ', change_reason, trim(p_reason)),
    updated_by = auth.uid()
  where schedule_version_id = p_schedule_version_id
  returning * into v_version;

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
    'CANCEL_CUSTOMER_SCHEDULE_VERSION',
    'customer_schedule_versions',
    p_schedule_version_id::text,
    to_jsonb(v_old),
    to_jsonb(v_version),
    trim(p_reason),
    p_source_application
  );

  return v_version;
end;
$$;

create or replace function public.publish_customer_schedule(
  p_schedule_version_id uuid,
  p_change_reason text,
  p_source_application text default 'CUSTOMER_SCHEDULE_MANAGEMENT'
)
returns public.customer_schedule_versions
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_version public.customer_schedule_versions%rowtype;
  v_published public.customer_schedule_versions%rowtype;
  v_previous record;
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'PLANNER']) then
    raise exception 'Permission denied for schedule publication.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception 'A publication reason is required.';
  end if;

  select *
  into v_version
  from public.customer_schedule_versions
  where schedule_version_id = p_schedule_version_id
  for update;

  if not found then
    raise exception 'Schedule version not found.';
  end if;

  if v_version.status <> 'DRAFT' then
    raise exception 'Only a DRAFT schedule revision can be published.';
  end if;

  if not exists (
    select 1
    from public.customers
    where customer_id = v_version.customer_id
      and active = true
      and deleted_at is null
  ) then
    raise exception 'The customer is inactive or does not exist.';
  end if;

  if not exists (
    select 1
    from public.customer_schedule_days
    where schedule_version_id = p_schedule_version_id
      and active = true
  ) then
    raise exception 'The schedule must contain at least one active production day.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_days d
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and not exists (
        select 1
        from public.customer_schedule_products p
        where p.schedule_day_id = d.schedule_day_id
          and p.active = true
      )
  ) then
    raise exception 'Every active production day must contain at least one active product.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    left join public.customer_product_services s
      on s.customer_id = v_version.customer_id
     and s.product_type_id = p.product_type_id
     and s.active = true
     and s.deleted_at is null
     and s.effective_from <= v_version.effective_from
     and (
       s.effective_until is null
       or s.effective_until >= v_version.effective_from
     )
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and p.active = true
      and s.customer_product_service_id is null
  ) then
    raise exception 'The schedule contains a product that is not enabled for this customer.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_products p
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    join public.product_types pt
      on pt.product_type_id = p.product_type_id
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and p.active = true
      and (not pt.active or pt.deleted_at is not null)
  ) then
    raise exception 'The schedule contains an inactive product type.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_product_variants spv
    join public.customer_schedule_products p
      on p.schedule_product_id = spv.schedule_product_id
    join public.customer_schedule_days d
      on d.schedule_day_id = p.schedule_day_id
    join public.product_variants pv
      on pv.product_variant_id = spv.product_variant_id
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and p.active = true
      and (not pv.active or pv.deleted_at is not null)
  ) then
    raise exception 'The schedule contains an inactive product variant.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_days d
    join public.distribution_routes r
      on r.route_id = d.default_route_id
    where d.schedule_version_id = p_schedule_version_id
      and d.active = true
      and (
        not r.active
        or r.deleted_at is not null
        or not r.allow_as_default
      )
  ) then
    raise exception 'The schedule contains an inactive route or a route that cannot be used as a default route.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_trolley_requirements req
    join public.customer_schedule_days d
      on d.schedule_day_id = req.schedule_day_id
    left join public.trolley_types tt
      on tt.trolley_type_id = req.trolley_type_id
    where d.schedule_version_id = p_schedule_version_id
      and req.active = true
      and (
        tt.trolley_type_id is null
        or not tt.active
        or not tt.allowed_in_customer_schedule
        or tt.deleted_at is not null
      )
  ) then
    raise exception 'The schedule contains an inactive or missing trolley type.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_trolley_requirements req
    join public.customer_schedule_days d
      on d.schedule_day_id = req.schedule_day_id
    where d.schedule_version_id = p_schedule_version_id
      and req.active = true
      and not exists (
        select 1
        from public.customer_schedule_trolley_requirement_products map
        where map.schedule_trolley_requirement_id =
          req.schedule_trolley_requirement_id
      )
  ) then
    raise exception 'Every trolley requirement must serve at least one scheduled product.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_trolley_requirements req
    join public.customer_schedule_days d
      on d.schedule_day_id = req.schedule_day_id
    where d.schedule_version_id = p_schedule_version_id
      and req.active = true
      and not exists (
        select 1
        from public.customer_schedule_trolley_requirement_products map
        where map.schedule_trolley_requirement_id =
          req.schedule_trolley_requirement_id
          and map.schedule_product_id = req.owner_schedule_product_id
      )
  ) then
    raise exception 'The trolley owner product must also be included in the products served by that trolley.';
  end if;

  if exists (
    select 1
    from public.customer_schedule_versions existing
    where existing.customer_id = v_version.customer_id
      and existing.status = 'PUBLISHED'
      and existing.effective_from >= v_version.effective_from
      and existing.schedule_version_id is distinct from v_version.based_on_version_id
      and daterange(
        existing.effective_from,
        coalesce(existing.effective_until, 'infinity'::date),
        '[]'
      ) && daterange(
        v_version.effective_from,
        coalesce(v_version.effective_until, 'infinity'::date),
        '[]'
      )
  ) then
    raise exception 'A future published schedule already overlaps this proposed period. Cancel or revise that future schedule first.';
  end if;

  for v_previous in
    select *
    from public.customer_schedule_versions existing
    where existing.customer_id = v_version.customer_id
      and existing.status = 'PUBLISHED'
      and daterange(
        existing.effective_from,
        coalesce(existing.effective_until, 'infinity'::date),
        '[]'
      ) && daterange(
        v_version.effective_from,
        coalesce(v_version.effective_until, 'infinity'::date),
        '[]'
      )
    for update
  loop
    update public.customer_schedule_versions
    set
      status = 'SUPERSEDED',
      effective_until = case
        when v_previous.effective_from < v_version.effective_from
          then least(
            coalesce(v_previous.effective_until, v_version.effective_from - 1),
            v_version.effective_from - 1
          )
        else v_previous.effective_until
      end,
      superseded_at = now(),
      superseded_by = auth.uid(),
      updated_by = auth.uid()
    where schedule_version_id = v_previous.schedule_version_id;
  end loop;

  update public.customer_schedule_versions
  set
    status = 'PUBLISHED',
    change_reason = trim(p_change_reason),
    published_at = now(),
    published_by = auth.uid(),
    updated_by = auth.uid()
  where schedule_version_id = p_schedule_version_id
  returning * into v_published;

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
    'PUBLISH_CUSTOMER_SCHEDULE',
    'customer_schedule_versions',
    p_schedule_version_id::text,
    to_jsonb(v_version),
    to_jsonb(v_published),
    trim(p_change_reason),
    p_source_application
  );

  return v_published;
end;
$$;

-- ---------------------------------------------------------------------
-- Protected views
-- ---------------------------------------------------------------------

create or replace view public.v_active_customers
with (security_barrier = true)
as
select
  c.customer_id,
  c.customer_code,
  c.customer_name,
  c.eircode,
  c.operational_alert,
  coalesce(
    array_agg(pt.product_code order by pt.sort_order, pt.product_code)
      filter (where pt.product_code is not null),
    array[]::text[]
  ) as product_services,
  c.row_version
from public.customers c
left join public.customer_product_services s
  on s.customer_id = c.customer_id
 and s.active = true
 and s.deleted_at is null
 and s.effective_from <= public.current_business_date()
 and (s.effective_until is null or s.effective_until >= public.current_business_date())
left join public.product_types pt
  on pt.product_type_id = s.product_type_id
 and pt.active = true
 and pt.deleted_at is null
where c.active = true
  and c.deleted_at is null
group by
  c.customer_id,
  c.customer_code,
  c.customer_name,
  c.eircode,
  c.operational_alert,
  c.row_version;

create or replace view public.v_customer_management
with (security_barrier = true)
as
select
  c.customer_id,
  c.customer_code,
  c.customer_name,
  c.eircode,
  c.notes,
  c.operational_alert,
  c.active,
  c.deactivated_at,
  c.deactivation_reason,
  c.created_at,
  c.updated_at,
  c.row_version,
  coalesce(
    array_agg(pt.product_code order by pt.sort_order, pt.product_code)
      filter (where pt.product_code is not null and s.active),
    array[]::text[]
  ) as active_product_services
from public.customers c
left join public.customer_product_services s
  on s.customer_id = c.customer_id
 and s.deleted_at is null
left join public.product_types pt
  on pt.product_type_id = s.product_type_id
where c.deleted_at is null
  and public.has_any_role(
    array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
  )
group by
  c.customer_id,
  c.customer_code,
  c.customer_name,
  c.eircode,
  c.notes,
  c.operational_alert,
  c.active,
  c.deactivated_at,
  c.deactivation_reason,
  c.created_at,
  c.updated_at,
  c.row_version;

create or replace view public.v_customer_distribution_management
with (security_barrier = true)
as
select
  c.customer_id,
  c.customer_code,
  c.customer_name,
  c.distribution_estimated_kg,
  c.distribution_stop_count,
  c.row_version
from public.customers c
where c.deleted_at is null
  and public.has_any_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER',
      'DISTRIBUTION_OPERATOR', 'AUDITOR'
    ]
  );

create or replace view public.v_finish_current_schedule
with (security_barrier = true)
as
select
  v.schedule_version_id,
  v.version_number,
  v.effective_from,
  v.effective_until,
  d.schedule_day_id,
  d.production_weekday,
  public.weekday_name(d.production_weekday) as production_day,
  c.customer_id,
  c.customer_code,
  c.customer_name,
  c.operational_alert,
  p.schedule_product_id,
  p.production_order,
  p.expected_kg,
  p.expected_units,
  p.production_instructions as finish_instructions,
  coalesce(trolley.total_quantity, 0) as planned_trolley_total,
  trolley.trolley_summary,
  coalesce(trolley.has_shared_trolley, false) as has_shared_trolley
from public.customer_schedule_versions v
join public.customers c
  on c.customer_id = v.customer_id
join public.customer_schedule_days d
  on d.schedule_version_id = v.schedule_version_id
join public.customer_schedule_products p
  on p.schedule_day_id = d.schedule_day_id
join public.product_types pt
  on pt.product_type_id = p.product_type_id
left join lateral (
  select
    sum(req.quantity)::integer as total_quantity,
    string_agg(
      concat(
        req.quantity,
        coalesce(tt.display_code, tt.trolley_type_code),
        case when req.empty_trolley then ' Empty' else '' end
      ),
      ' + ' order by tt.sort_order, req.created_at
    ) as trolley_summary,
    bool_or(
      (
        select count(*)
        from public.customer_schedule_trolley_requirement_products map
        where map.schedule_trolley_requirement_id =
          req.schedule_trolley_requirement_id
      ) > 1
    ) as has_shared_trolley
  from public.customer_schedule_trolley_requirements req
  join public.trolley_types tt
    on tt.trolley_type_id = req.trolley_type_id
  where req.schedule_day_id = d.schedule_day_id
    and req.owner_schedule_product_id = p.schedule_product_id
    and req.active = true
    and tt.active = true
    and tt.deleted_at is null
) trolley on true
where v.status = 'PUBLISHED'
  and public.current_business_date() >= v.effective_from
  and (v.effective_until is null or public.current_business_date() <= v.effective_until)
  and c.active = true
  and c.deleted_at is null
  and d.active = true
  and p.active = true
  and pt.product_code = 'CLOTHES'
  and public.has_any_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
      'FINISH_OPERATOR', 'AUDITOR'
    ]
  );

create or replace view public.v_mop_current_schedule
with (security_barrier = true)
as
select
  v.schedule_version_id,
  v.version_number,
  v.effective_from,
  v.effective_until,
  d.schedule_day_id,
  d.production_weekday,
  public.weekday_name(d.production_weekday) as production_day,
  c.customer_id,
  c.customer_code,
  c.customer_name,
  c.operational_alert,
  p.schedule_product_id,
  p.production_order,
  p.expected_kg,
  p.expected_units,
  p.production_instructions as mop_instructions,
  coalesce(
    variants.product_variants,
    array[]::text[]
  ) as mop_products,
  coalesce(trolley.total_quantity, 0) as planned_trolley_total,
  trolley.trolley_summary
from public.customer_schedule_versions v
join public.customers c
  on c.customer_id = v.customer_id
join public.customer_schedule_days d
  on d.schedule_version_id = v.schedule_version_id
join public.customer_schedule_products p
  on p.schedule_day_id = d.schedule_day_id
join public.product_types pt
  on pt.product_type_id = p.product_type_id
left join lateral (
  select array_agg(pv.display_name order by pv.sort_order, pv.display_name)
    as product_variants
  from public.customer_schedule_product_variants spv
  join public.product_variants pv
    on pv.product_variant_id = spv.product_variant_id
  where spv.schedule_product_id = p.schedule_product_id
    and pv.active = true
    and pv.deleted_at is null
) variants on true
left join lateral (
  select
    sum(req.quantity)::integer as total_quantity,
    string_agg(
      concat(
        req.quantity,
        coalesce(tt.display_code, tt.trolley_type_code),
        case when req.empty_trolley then ' Empty' else '' end
      ),
      ' + ' order by tt.sort_order, req.created_at
    ) as trolley_summary
  from public.customer_schedule_trolley_requirements req
  join public.trolley_types tt
    on tt.trolley_type_id = req.trolley_type_id
  where req.schedule_day_id = d.schedule_day_id
    and req.owner_schedule_product_id = p.schedule_product_id
    and req.active = true
    and tt.active = true
    and tt.deleted_at is null
) trolley on true
where v.status = 'PUBLISHED'
  and public.current_business_date() >= v.effective_from
  and (v.effective_until is null or public.current_business_date() <= v.effective_until)
  and c.active = true
  and c.deleted_at is null
  and d.active = true
  and p.active = true
  and pt.product_code = 'MOP'
  and public.has_any_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR',
      'MOP_OPERATOR', 'AUDITOR'
    ]
  );

create or replace view public.v_distribution_current_schedule
with (security_barrier = true)
as
select
  v.schedule_version_id,
  v.version_number,
  v.effective_from,
  v.effective_until,
  d.schedule_day_id,
  d.production_weekday,
  public.weekday_name(d.production_weekday) as production_day,
  d.delivery_weekday,
  public.weekday_name(d.delivery_weekday) as delivery_day,
  d.delivery_window_start,
  d.delivery_window_end,
  d.delivery_order,
  d.day_alert,
  d.distribution_instructions,
  c.customer_id,
  c.customer_code,
  c.customer_name,
  c.eircode,
  c.distribution_estimated_kg,
  c.distribution_stop_count,
  c.operational_alert,
  r.route_id as default_route_id,
  r.route_code as default_route_code,
  r.display_name as default_route_display_name,
  r.route_color as default_route_color,
  coalesce(products.product_codes, array[]::text[]) as scheduled_products,
  coalesce(trolley.total_quantity, 0) as planned_trolley_total,
  trolley.trolley_summary,
  coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown
from public.customer_schedule_versions v
join public.customers c
  on c.customer_id = v.customer_id
join public.customer_schedule_days d
  on d.schedule_version_id = v.schedule_version_id
left join public.distribution_routes r
  on r.route_id = d.default_route_id
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
    ) as trolley_summary,
    jsonb_agg(
      jsonb_build_object(
        'quantity', req.quantity,
        'trolley_type_code', tt.trolley_type_code,
        'display_code', coalesce(tt.display_code, tt.trolley_type_code),
        'owner_product_code', owner_pt.product_code,
        'serves_product_codes', served.product_codes,
        'shared', served.product_count > 1,
        'empty_trolley', req.empty_trolley,
        'notes', req.notes
      )
      order by tt.sort_order, req.created_at
    ) as trolley_breakdown
  from public.customer_schedule_trolley_requirements req
  join public.trolley_types tt
    on tt.trolley_type_id = req.trolley_type_id
  join public.customer_schedule_products owner_product
    on owner_product.schedule_product_id = req.owner_schedule_product_id
  join public.product_types owner_pt
    on owner_pt.product_type_id = owner_product.product_type_id
  left join lateral (
    select
      count(*)::integer as product_count,
      coalesce(
        jsonb_agg(pt2.product_code order by pt2.sort_order, pt2.product_code),
        '[]'::jsonb
      ) as product_codes
    from public.customer_schedule_trolley_requirement_products map
    join public.customer_schedule_products mapped_product
      on mapped_product.schedule_product_id = map.schedule_product_id
    join public.product_types pt2
      on pt2.product_type_id = mapped_product.product_type_id
    where map.schedule_trolley_requirement_id =
      req.schedule_trolley_requirement_id
  ) served on true
  where req.schedule_day_id = d.schedule_day_id
    and req.active = true
    and tt.active = true
    and tt.deleted_at is null
) trolley on true
where v.status = 'PUBLISHED'
  and public.current_business_date() >= v.effective_from
  and (v.effective_until is null or public.current_business_date() <= v.effective_until)
  and c.active = true
  and c.deleted_at is null
  and d.active = true
  and public.has_any_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER',
      'DISTRIBUTION_OPERATOR', 'AUDITOR'
    ]
  );

create or replace view public.v_customer_schedule_history
with (security_barrier = true)
as
select
  v.schedule_version_id,
  v.customer_id,
  c.customer_code,
  c.customer_name,
  v.version_number,
  v.status,
  v.effective_from,
  v.effective_until,
  v.based_on_version_id,
  v.source_code,
  v.change_reason,
  v.created_at,
  v.created_by,
  v.updated_at,
  v.published_at,
  v.published_by,
  v.superseded_at,
  v.superseded_by,
  v.cancelled_at,
  v.cancelled_by,
  v.row_version
from public.customer_schedule_versions v
join public.customers c
  on c.customer_id = v.customer_id
where public.has_any_role(
  array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
);

-- ---------------------------------------------------------------------
-- Row Level Security and grants
-- ---------------------------------------------------------------------

alter table public.product_variants enable row level security;
alter table public.customer_product_services enable row level security;
alter table public.distribution_routes enable row level security;
alter table public.customer_schedule_versions enable row level security;
alter table public.customer_schedule_days enable row level security;
alter table public.customer_schedule_products enable row level security;
alter table public.customer_schedule_product_variants enable row level security;
alter table public.customer_schedule_trolley_requirements enable row level security;
alter table public.customer_schedule_trolley_requirement_products enable row level security;

drop policy if exists "authenticated_read_customers" on public.customers;
create policy "read_active_customers_or_customer_management"
  on public.customers for select
  to authenticated
  using (
    deleted_at is null
    and (
      active = true
      or public.has_any_role(
        array['ADMIN', 'MANAGER', 'PLANNER', 'SUPERVISOR', 'AUDITOR']
      )
    )
  );

drop policy if exists "authenticated_read_trolley_types" on public.trolley_types;
create policy "authenticated_read_active_trolley_types"
  on public.trolley_types for select
  to authenticated
  using (active = true and deleted_at is null);

revoke all on public.customers from anon, authenticated;
grant select (
  customer_id,
  customer_code,
  customer_name,
  eircode,
  active
) on public.customers to authenticated;

revoke all on public.product_variants from anon, authenticated;
revoke all on public.customer_product_services from anon, authenticated;
revoke all on public.distribution_routes from anon, authenticated;
revoke all on public.customer_schedule_versions from anon, authenticated;
revoke all on public.customer_schedule_days from anon, authenticated;
revoke all on public.customer_schedule_products from anon, authenticated;
revoke all on public.customer_schedule_product_variants from anon, authenticated;
revoke all on public.customer_schedule_trolley_requirements from anon, authenticated;
revoke all on public.customer_schedule_trolley_requirement_products from anon, authenticated;

grant select on public.v_active_customers to authenticated;
grant select on public.v_customer_management to authenticated;
grant select on public.v_customer_distribution_management to authenticated;
grant select on public.v_finish_current_schedule to authenticated;
grant select on public.v_mop_current_schedule to authenticated;
grant select on public.v_distribution_current_schedule to authenticated;
grant select on public.v_customer_schedule_history to authenticated;

revoke all on function public.weekday_name(smallint) from public;
revoke all on function public.current_business_date() from public;
revoke all on function public.create_customer(
  text, text, text, numeric, integer, text, text, text[], text, text
) from public;
revoke all on function public.update_customer(
  uuid, integer, text, text, text, numeric, integer, text, text, text[], text, text
) from public;
revoke all on function public.deactivate_customer(uuid, text, text) from public;
revoke all on function public.reactivate_customer(uuid, text[], text, text) from public;
revoke all on function public.create_customer_schedule_draft(
  uuid, date, uuid, text, text
) from public;
revoke all on function public.restore_customer_schedule_version(
  uuid, date, text, text
) from public;
revoke all on function public.cancel_customer_schedule_version(
  uuid, text, text
) from public;
revoke all on function public.publish_customer_schedule(
  uuid, text, text
) from public;

grant execute on function public.weekday_name(smallint) to authenticated;
grant execute on function public.current_business_date() to authenticated;
grant execute on function public.create_customer(
  text, text, text, numeric, integer, text, text, text[], text, text
) to authenticated;
grant execute on function public.update_customer(
  uuid, integer, text, text, text, numeric, integer, text, text, text[], text, text
) to authenticated;
grant execute on function public.deactivate_customer(uuid, text, text)
  to authenticated;
grant execute on function public.reactivate_customer(uuid, text[], text, text)
  to authenticated;
grant execute on function public.create_customer_schedule_draft(
  uuid, date, uuid, text, text
) to authenticated;
grant execute on function public.restore_customer_schedule_version(
  uuid, date, text, text
) to authenticated;
grant execute on function public.cancel_customer_schedule_version(
  uuid, text, text
) to authenticated;
grant execute on function public.publish_customer_schedule(
  uuid, text, text
) to authenticated;

commit;
