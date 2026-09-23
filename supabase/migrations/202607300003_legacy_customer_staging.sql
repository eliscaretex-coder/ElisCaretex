-- =====================================================================
-- ElisCaretex V2
-- Migration: 202607300003_legacy_customer_staging.sql
-- Purpose:
--   Create a private staging area for the legacy CustomerMaster and
--   CustomerSchedule data. This migration does not insert anything into
--   the operational customer and schedule tables.
-- =====================================================================

begin;

do $$
declare
  v_customers bigint;
  v_services bigint;
  v_routes bigint;
  v_versions bigint;
  v_days bigint;
  v_products bigint;
begin
  select count(*) into v_customers from public.customers;
  select count(*) into v_services from public.customer_product_services;
  select count(*) into v_routes from public.distribution_routes;
  select count(*) into v_versions from public.customer_schedule_versions;
  select count(*) into v_days from public.customer_schedule_days;
  select count(*) into v_products from public.customer_schedule_products;

  if v_customers <> 0
     or v_services <> 0
     or v_routes <> 0
     or v_versions <> 0
     or v_days <> 0
     or v_products <> 0 then
    raise exception using
      message = 'Safety stop: operational customer tables are no longer empty.',
      detail = format(
        'customers=%s, services=%s, routes=%s, versions=%s, days=%s, products=%s',
        v_customers,
        v_services,
        v_routes,
        v_versions,
        v_days,
        v_products
      ),
      hint = 'Do not overwrite operational data. Review the current database state before continuing.';
  end if;

  if not exists (
    select 1
    from public.product_types
    where product_code = 'CLOTHES'
      and active = true
      and deleted_at is null
  ) or not exists (
    select 1
    from public.product_types
    where product_code = 'MOP'
      and active = true
      and deleted_at is null
  ) then
    raise exception 'CLOTHES and MOP product types must exist before staging the legacy data.';
  end if;

  if (
    select count(*)
    from public.trolley_types
    where trolley_type_code in ('SMALL', 'MEDIUM', 'LARGE', 'GRAY')
      and active = true
      and allowed_in_customer_schedule = true
      and deleted_at is null
  ) <> 4 then
    raise exception 'The four approved customer schedule trolley types are missing or inactive.';
  end if;
end;
$$;

create schema if not exists staging;

revoke all on schema staging from public;
revoke all on schema staging from anon;
revoke all on schema staging from authenticated;

comment on schema staging is
  'Private data preparation area. Never expose this schema directly to the frontend.';

create table if not exists staging.legacy_customer_master (
  source_row integer primary key,
  source_file text not null,
  legacy_customer_id text not null unique,
  customer_name text not null,
  service_type text,
  customer_type text,
  eircode text,
  kg_estimated numeric(12,2),
  stops integer,
  information text,
  legacy_active_text text,
  loaded_at timestamptz not null default now(),
  constraint legacy_customer_master_stops_check
    check (stops is null or stops >= 0),
  constraint legacy_customer_master_kg_check
    check (kg_estimated is null or kg_estimated >= 0)
);

create table if not exists staging.legacy_customer_schedule (
  source_row integer primary key,
  source_file text not null,
  legacy_customer_id text not null,
  customer_name text not null,
  service_type text,
  production_day text,
  delivery_day text,
  route_code text,
  route_color text,
  display_name text,
  delivery_time_text text,
  qty_clothes_text text,
  clothes_order integer,
  trolley_mop_text text,
  mop_order integer,
  mop_products_text text,
  clothes_notes text,
  mop_instructions text,
  information text,
  delivery_order integer,
  delivery_notes text,
  loaded_at timestamptz not null default now()
);

create index if not exists legacy_customer_schedule_customer_idx
  on staging.legacy_customer_schedule (legacy_customer_id);

create index if not exists legacy_customer_schedule_day_idx
  on staging.legacy_customer_schedule (production_day, delivery_day);

create table if not exists staging.legacy_customer_status_override (
  legacy_customer_id text primary key,
  proposed_active boolean not null,
  reason text not null,
  owner_confirmed boolean not null default false,
  notes text,
  updated_at timestamptz not null default now()
);

create table if not exists staging.legacy_route_mapping (
  route_code text primary key,
  proposed_display_name text not null,
  proposed_route_color text not null,
  route_kind text not null default 'STANDARD',
  allow_as_default boolean not null default true,
  review_required boolean not null default false,
  review_note text,
  constraint legacy_route_mapping_color_check
    check (proposed_route_color ~ '^#[0-9A-Fa-f]{6}$'),
  constraint legacy_route_mapping_kind_check
    check (route_kind in ('STANDARD', 'COLLECTION', 'AD_HOC', 'SUPPORT'))
);

create table if not exists staging.legacy_mop_variant_mapping (
  legacy_value text primary key,
  proposed_variant_code text not null,
  proposed_display_name text not null,
  review_required boolean not null default false,
  review_note text
);

create or replace function staging.parse_legacy_trolley_text(p_text text)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_normalized text;
  v_work text;
  v_part text;
  v_parts text[];
  v_match text[];
  v_items jsonb := '[]'::jsonb;
  v_total integer := 0;
  v_quantity integer;
  v_type_code text;
  v_empty boolean := false;
begin
  if nullif(trim(p_text), '') is null then
    return jsonb_build_object(
      'status', 'BLANK',
      'raw', p_text,
      'normalized', null,
      'total_quantity', 0,
      'items', '[]'::jsonb
    );
  end if;

  v_normalized := upper(regexp_replace(trim(p_text), '\s+', '', 'g'));
  v_normalized := replace(v_normalized, 'GREY', 'GRAY');

  if v_normalized = '0' then
    return jsonb_build_object(
      'status', 'NONE',
      'raw', p_text,
      'normalized', v_normalized,
      'total_quantity', 0,
      'items', '[]'::jsonb
    );
  end if;

  v_match := regexp_match(v_normalized, '^([0-9]+)GRAY(TROLLEY)?$');

  if v_match is not null then
    v_quantity := v_match[1]::integer;

    return jsonb_build_object(
      'status', 'PARSED',
      'raw', p_text,
      'normalized', v_normalized,
      'total_quantity', v_quantity,
      'items', jsonb_build_array(
        jsonb_build_object(
          'trolley_type_code', 'GRAY',
          'quantity', v_quantity,
          'empty_trolley', false
        )
      )
    );
  end if;

  v_work := v_normalized;

  if right(v_work, length('EMPTYTROLLEY')) = 'EMPTYTROLLEY' then
    v_empty := true;
    v_work := left(v_work, length(v_work) - length('EMPTYTROLLEY'));
  end if;

  v_parts := string_to_array(v_work, '+');

  foreach v_part in array v_parts
  loop
    v_match := regexp_match(v_part, '^([0-9]+)([SML])$');

    if v_match is null then
      if v_part ~ '^[0-9]+$' then
        return jsonb_build_object(
          'status', 'REVIEW_MISSING_SIZE',
          'raw', p_text,
          'normalized', v_normalized,
          'total_quantity', null,
          'items', '[]'::jsonb
        );
      end if;

      return jsonb_build_object(
        'status', 'REVIEW_UNRECOGNISED',
        'raw', p_text,
        'normalized', v_normalized,
        'total_quantity', null,
        'items', '[]'::jsonb
      );
    end if;

    v_quantity := v_match[1]::integer;
    v_type_code := case v_match[2]
      when 'S' then 'SMALL'
      when 'M' then 'MEDIUM'
      when 'L' then 'LARGE'
    end;

    v_items := v_items || jsonb_build_array(
      jsonb_build_object(
        'trolley_type_code', v_type_code,
        'quantity', v_quantity,
        'empty_trolley', v_empty
      )
    );

    v_total := v_total + v_quantity;
  end loop;

  return jsonb_build_object(
    'status', 'PARSED',
    'raw', p_text,
    'normalized', v_normalized,
    'total_quantity', v_total,
    'items', v_items
  );
end;
$$;

create or replace function staging.parse_legacy_delivery_window(p_text text)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_match text[];
  v_start time;
  v_end time;
begin
  if nullif(trim(p_text), '') is null then
    return jsonb_build_object(
      'status', 'BLANK',
      'raw', p_text,
      'start_time', null,
      'end_time', null
    );
  end if;

  v_match := regexp_match(
    trim(p_text),
    '^\s*([0-9]{1,2}):([0-9]{2})\s*-\s*([0-9]{1,2}):([0-9]{2})\s*$'
  );

  if v_match is null then
    return jsonb_build_object(
      'status', 'REVIEW_FORMAT',
      'raw', p_text,
      'start_time', null,
      'end_time', null
    );
  end if;

  begin
    v_start := make_time(v_match[1]::integer, v_match[2]::integer, 0);
    v_end := make_time(v_match[3]::integer, v_match[4]::integer, 0);
  exception
    when others then
      return jsonb_build_object(
        'status', 'REVIEW_INVALID_TIME',
        'raw', p_text,
        'start_time', null,
        'end_time', null
      );
  end;

  if v_end <= v_start then
    return jsonb_build_object(
      'status', 'REVIEW_END_NOT_AFTER_START',
      'raw', p_text,
      'start_time', to_jsonb(v_start),
      'end_time', to_jsonb(v_end)
    );
  end if;

  return jsonb_build_object(
    'status', 'PARSED',
    'raw', p_text,
    'start_time', to_jsonb(v_start),
    'end_time', to_jsonb(v_end)
  );
end;
$$;

create or replace view staging.v_legacy_customer_review
as
with schedule_counts as (
  select
    legacy_customer_id,
    count(*)::integer as schedule_row_count
  from staging.legacy_customer_schedule
  group by legacy_customer_id
),
prepared as (
  select
    m.source_row,
    m.legacy_customer_id,
    m.customer_name,
    m.service_type,
    m.customer_type,
    m.eircode,
    m.kg_estimated,
    m.stops,
    m.information,
    m.legacy_active_text,
    coalesce(sc.schedule_row_count, 0) as schedule_row_count,
    coalesce(
      o.proposed_active,
      case
        when nullif(trim(m.service_type), '') is null then false
        when lower(coalesce(m.legacy_active_text, '')) in ('yes', 'true', 'active', '1') then true
        else false
      end
    ) as proposed_active,
    o.reason as override_reason,
    o.owner_confirmed,
    array_remove(
      array[
        case
          when nullif(trim(m.service_type), '') is null
          then 'MISSING_SERVICE_TYPE'
        end,
        case
          when coalesce(sc.schedule_row_count, 0) = 0
          then 'NO_SCHEDULE'
        end,
        case
          when nullif(trim(m.service_type), '') is not null
           and coalesce(sc.schedule_row_count, 0) = 0
          then 'ACTIVE_SERVICE_WITHOUT_SCHEDULE'
        end,
        case
          when lower(coalesce(m.legacy_active_text, '')) = 'yes'
           and coalesce(
             o.proposed_active,
             case when nullif(trim(m.service_type), '') is null then false else true end
           ) = false
          then 'LEGACY_ACTIVE_FLAG_CONFLICT'
        end,
        case
          when nullif(trim(m.service_type), '') is not null
           and upper(trim(m.service_type)) not in ('CLOTHES', 'MOP', 'CLOTHES + MOP')
          then 'UNKNOWN_SERVICE_TYPE'
        end
      ],
      null
    ) as issue_codes
  from staging.legacy_customer_master m
  left join schedule_counts sc
    on sc.legacy_customer_id = m.legacy_customer_id
  left join staging.legacy_customer_status_override o
    on o.legacy_customer_id = m.legacy_customer_id
)
select
  *,
  cardinality(issue_codes) > 0 as review_required
from prepared;

create or replace view staging.v_legacy_trolley_review
as
select
  s.source_row,
  s.legacy_customer_id,
  s.customer_name,
  s.service_type,
  s.production_day,
  'QtyClothes'::text as source_field,
  'CLOTHES'::text as owner_product_code,
  s.qty_clothes_text as raw_value,
  staging.parse_legacy_trolley_text(s.qty_clothes_text) as parsed_value
from staging.legacy_customer_schedule s

union all

select
  s.source_row,
  s.legacy_customer_id,
  s.customer_name,
  s.service_type,
  s.production_day,
  'TrolleyMop'::text as source_field,
  'MOP'::text as owner_product_code,
  s.trolley_mop_text as raw_value,
  staging.parse_legacy_trolley_text(s.trolley_mop_text) as parsed_value
from staging.legacy_customer_schedule s;

create or replace view staging.v_legacy_route_review
as
select
  s.route_code,
  count(*)::integer as source_row_count,
  m.proposed_display_name,
  m.proposed_route_color,
  array_agg(distinct coalesce(s.display_name, '(blank)') order by coalesce(s.display_name, '(blank)'))
    as observed_display_names,
  array_agg(distinct coalesce(lower(s.route_color), '(blank)') order by coalesce(lower(s.route_color), '(blank)'))
    as observed_route_colors,
  count(*) filter (
    where coalesce(s.display_name, '') <> m.proposed_display_name
       or coalesce(lower(s.route_color), '') <> lower(m.proposed_route_color)
  )::integer as mismatched_source_rows,
  m.review_required,
  m.review_note
from staging.legacy_customer_schedule s
left join staging.legacy_route_mapping m
  on m.route_code = s.route_code
group by
  s.route_code,
  m.proposed_display_name,
  m.proposed_route_color,
  m.review_required,
  m.review_note;

create or replace view staging.v_legacy_mop_variant_review
as
with source_variants as (
  select
    trim(split_value.legacy_value) as legacy_value,
    count(*)::integer as usage_count
  from staging.legacy_customer_schedule s
  cross join lateral regexp_split_to_table(
    coalesce(s.mop_products_text, ''),
    '\s*;\s*'
  ) as split_value(legacy_value)
  where nullif(trim(split_value.legacy_value), '') is not null
  group by trim(split_value.legacy_value)
)
select
  sv.legacy_value,
  sv.usage_count,
  m.proposed_variant_code,
  m.proposed_display_name,
  coalesce(m.review_required, true) as review_required,
  coalesce(
    m.review_note,
    'No normalization mapping exists for this legacy value.'
  ) as review_note
from source_variants sv
left join staging.legacy_mop_variant_mapping m
  on m.legacy_value = sv.legacy_value;

create or replace view staging.v_legacy_schedule_review
as
with prepared as (
  select
    s.*,
    m.customer_name as master_customer_name,
    m.service_type as master_service_type,
    c.proposed_active as proposed_customer_active,
    staging.parse_legacy_trolley_text(s.qty_clothes_text) as clothes_trolley_parse,
    staging.parse_legacy_trolley_text(s.trolley_mop_text) as mop_trolley_parse,
    staging.parse_legacy_delivery_window(s.delivery_time_text) as delivery_window_parse,
    r.route_code as mapped_route_code
  from staging.legacy_customer_schedule s
  left join staging.legacy_customer_master m
    on m.legacy_customer_id = s.legacy_customer_id
  left join staging.v_legacy_customer_review c
    on c.legacy_customer_id = s.legacy_customer_id
  left join staging.legacy_route_mapping r
    on r.route_code = s.route_code
),
with_issues as (
  select
    p.*,
    array_remove(
      array[
        case when p.master_customer_name is null
          then 'CUSTOMER_NOT_FOUND'
        end,
        case when p.master_customer_name is not null
                   and trim(p.master_customer_name) <> trim(p.customer_name)
          then 'CUSTOMER_NAME_MISMATCH'
        end,
        case when p.master_service_type is distinct from p.service_type
          then 'SERVICE_TYPE_MISMATCH'
        end,
        case when lower(coalesce(p.production_day, '')) not in (
          'monday', 'tuesday', 'wednesday', 'thursday',
          'friday', 'saturday', 'sunday'
        ) then 'INVALID_PRODUCTION_DAY'
        end,
        case when p.delivery_day is not null
                   and lower(p.delivery_day) not in (
                     'monday', 'tuesday', 'wednesday', 'thursday',
                     'friday', 'saturday', 'sunday'
                   )
          then 'INVALID_DELIVERY_DAY'
        end,
        case when p.mapped_route_code is null
          then 'ROUTE_MAPPING_MISSING'
        end,
        case when p.delivery_window_parse ->> 'status' not in ('BLANK', 'PARSED')
          then 'DELIVERY_WINDOW_REVIEW'
        end,
        case when p.clothes_trolley_parse ->> 'status' like 'REVIEW%'
          then 'CLOTHES_TROLLEY_REVIEW'
        end,
        case when p.mop_trolley_parse ->> 'status' like 'REVIEW%'
          then 'MOP_TROLLEY_REVIEW'
        end,
        case when upper(coalesce(p.service_type, '')) = 'CLOTHES'
                   and p.mop_trolley_parse ->> 'status' not in ('BLANK', 'NONE')
          then 'MOP_TROLLEY_VALUE_ON_CLOTHES_ONLY_ROW'
        end,
        case when p.clothes_order is null and p.mop_order is null
          then 'NO_PRODUCT_ORDER'
        end,
        case when p.proposed_customer_active = false
          then 'SCHEDULE_FOR_INACTIVE_CUSTOMER'
        end
      ],
      null
    ) as issue_codes
  from prepared p
)
select
  *,
  cardinality(issue_codes) > 0 as review_required
from with_issues;

revoke all on all tables in schema staging from public;
revoke all on all tables in schema staging from anon;
revoke all on all tables in schema staging from authenticated;
revoke all on all sequences in schema staging from public;
revoke all on all sequences in schema staging from anon;
revoke all on all sequences in schema staging from authenticated;
revoke all on function staging.parse_legacy_trolley_text(text) from public;
revoke all on function staging.parse_legacy_trolley_text(text) from anon;
revoke all on function staging.parse_legacy_trolley_text(text) from authenticated;
revoke all on function staging.parse_legacy_delivery_window(text) from public;
revoke all on function staging.parse_legacy_delivery_window(text) from anon;
revoke all on function staging.parse_legacy_delivery_window(text) from authenticated;

commit;
