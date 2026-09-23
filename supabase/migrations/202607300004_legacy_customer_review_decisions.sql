-- =====================================================================
-- ElisCaretex V2
-- Migration: 202607300004_legacy_customer_review_decisions.sql
-- Purpose:
--   Record the project owner's review decisions inside the private staging
--   schema and produce a final blocker list before the operational import.
--
-- Important:
--   This migration does NOT insert customers or schedules into public
--   operational tables. It only records reviewed legacy decisions.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Safety guards
-- ---------------------------------------------------------------------

do $$
declare
  v_master_count integer;
  v_schedule_count integer;
  v_operational_count bigint;
begin
  if to_regclass('staging.legacy_customer_master') is null
     or to_regclass('staging.legacy_customer_schedule') is null
     or to_regclass('staging.legacy_customer_status_override') is null
     or to_regclass('staging.legacy_route_mapping') is null
     or to_regclass('staging.legacy_mop_variant_mapping') is null then
    raise exception
      'Run migration 202607300003_legacy_customer_staging.sql and its data seed first.';
  end if;

  select count(*) into v_master_count
  from staging.legacy_customer_master;

  select count(*) into v_schedule_count
  from staging.legacy_customer_schedule;

  if v_master_count <> 141 or v_schedule_count <> 417 then
    raise exception using
      message = 'Safety stop: staging source counts do not match the reviewed workbook.',
      detail = format(
        'legacy_customer_master=%s, legacy_customer_schedule=%s',
        v_master_count,
        v_schedule_count
      ),
      hint = 'Expected 141 CustomerMaster rows and 417 CustomerSchedule rows.';
  end if;

  select
      (select count(*) from public.customers)
    + (select count(*) from public.customer_product_services)
    + (select count(*) from public.distribution_routes)
    + (select count(*) from public.product_variants)
    + (select count(*) from public.customer_schedule_versions)
    + (select count(*) from public.customer_schedule_days)
    + (select count(*) from public.customer_schedule_products)
  into v_operational_count;

  if v_operational_count <> 0 then
    raise exception using
      message = 'Safety stop: operational customer data already exists.',
      detail = format('Combined operational row count=%s', v_operational_count),
      hint = 'Do not apply legacy review decisions against a database that has already been imported.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Add owner-confirmation fields to existing mapping tables
-- ---------------------------------------------------------------------

alter table staging.legacy_route_mapping
  add column if not exists owner_confirmed boolean not null default false,
  add column if not exists decision_note text,
  add column if not exists decision_updated_at timestamptz;

alter table staging.legacy_mop_variant_mapping
  add column if not exists owner_confirmed boolean not null default false,
  add column if not exists decision_note text,
  add column if not exists decision_updated_at timestamptz;

-- ---------------------------------------------------------------------
-- Structured trolley corrections
--
-- REPLACE:
--   Replace the ambiguous source value with a confirmed structured trolley.
-- IGNORE:
--   Preserve the source value for audit, but do not create a requirement.
-- ---------------------------------------------------------------------

create table if not exists staging.legacy_trolley_override (
  source_row integer not null,
  source_field text not null,
  decision_code text not null,
  trolley_type_code text,
  quantity integer,
  empty_trolley boolean not null default false,
  owner_product_code text,
  serves_product_codes text[],
  owner_confirmed boolean not null default false,
  decision_note text not null,
  updated_at timestamptz not null default now(),
  primary key (source_row, source_field),
  constraint legacy_trolley_override_source_field_check
    check (source_field in ('QtyClothes', 'TrolleyMop')),
  constraint legacy_trolley_override_decision_check
    check (decision_code in ('REPLACE', 'IGNORE')),
  constraint legacy_trolley_override_type_check
    check (
      trolley_type_code is null
      or trolley_type_code in ('SMALL', 'MEDIUM', 'LARGE', 'GRAY')
    ),
  constraint legacy_trolley_override_quantity_check
    check (quantity is null or quantity > 0),
  constraint legacy_trolley_override_owner_check
    check (
      owner_product_code is null
      or owner_product_code in ('CLOTHES', 'MOP')
    ),
  constraint legacy_trolley_override_shape_check
    check (
      (
        decision_code = 'REPLACE'
        and trolley_type_code is not null
        and quantity is not null
        and owner_product_code is not null
        and cardinality(serves_product_codes) >= 1
      )
      or
      (
        decision_code = 'IGNORE'
        and trolley_type_code is null
        and quantity is null
      )
    )
);

-- ---------------------------------------------------------------------
-- Customer status decisions from the reviewed workbook
--
-- Eleven legacy customers are confirmed inactive. The legacy Active field
-- was not maintained and must not be treated as the source of truth.
-- ---------------------------------------------------------------------

insert into staging.legacy_customer_status_override (
  legacy_customer_id,
  proposed_active,
  reason,
  owner_confirmed,
  notes,
  updated_at
)
values
  ('CID-BAND-4FC0A', false, 'Inactive in the legacy operation.', true, 'Confirmed in legacy_customer_import_review(1).xlsx.', now()),
  ('CID-BANT-29EC7', false, 'Inactive in the legacy operation.', true, 'Confirmed in legacy_customer_import_review(1).xlsx.', now()),
  ('CID-CLON-0A158', false, 'Inactive in the legacy operation.', true, 'Confirmed in legacy_customer_import_review(1).xlsx.', now()),
  ('CID-DUNM-FB493', false, 'Inactive in the legacy operation.', true, 'Confirmed in legacy_customer_import_review(1).xlsx.', now()),
  ('CID-KILL-9EEDD', false, 'Inactive in the legacy operation.', true, 'Confirmed in legacy_customer_import_review(1).xlsx.', now()),
  ('CID-KINS-A4C10', false, 'Inactive in the legacy operation.', true, 'Confirmed in legacy_customer_import_review(1).xlsx.', now()),
  ('CID-ORWE-C5210', false, 'Inactive in the legacy operation.', true, 'Confirmed in legacy_customer_import_review(1).xlsx.', now()),
  ('CID-SKIB-5182B', false, 'Inactive in the legacy operation.', true, 'Owner confirmed inactive even though the source ServiceType is MOP.', now()),
  ('CID-STGA-6C49A', false, 'Inactive in the legacy operation.', true, 'Owner confirmed inactive even though the source ServiceType is MOP.', now()),
  ('CID-WEST-3B664', false, 'Inactive in the legacy operation.', true, 'Confirmed in legacy_customer_import_review(1).xlsx.', now()),
  ('CID-WEST-2EFA9', false, 'Inactive in the legacy operation.', true, 'Confirmed in legacy_customer_import_review(1).xlsx.', now())
on conflict (legacy_customer_id)
do update set
  proposed_active = excluded.proposed_active,
  reason = excluded.reason,
  owner_confirmed = excluded.owner_confirmed,
  notes = excluded.notes,
  updated_at = excluded.updated_at;

-- ---------------------------------------------------------------------
-- Confirmed trolley corrections from the reviewed workbook
-- ---------------------------------------------------------------------

insert into staging.legacy_trolley_override (
  source_row,
  source_field,
  decision_code,
  trolley_type_code,
  quantity,
  empty_trolley,
  owner_product_code,
  serves_product_codes,
  owner_confirmed,
  decision_note,
  updated_at
)
values
  (
    81,
    'TrolleyMop',
    'REPLACE',
    'SMALL',
    5,
    false,
    'MOP',
    array['MOP']::text[],
    true,
    'ST JOSEPHS / Tuesday: legacy value 5 confirmed as 5 Small Mop trolleys.',
    now()
  ),
  (
    160,
    'QtyClothes',
    'REPLACE',
    'MEDIUM',
    1,
    false,
    'CLOTHES',
    array['CLOTHES']::text[],
    true,
    'OUR LADY OF LOURDES / Wednesday: legacy value 1 confirmed as 1 Medium Clothes trolley.',
    now()
  ),
  (
    416,
    'TrolleyMop',
    'IGNORE',
    null,
    null,
    false,
    null,
    null,
    true,
    'ST CATHERINES / Tuesday: customer has no MOP service; legacy value 74 is not a Mop trolley requirement.',
    now()
  ),
  (
    417,
    'TrolleyMop',
    'IGNORE',
    null,
    null,
    false,
    null,
    null,
    true,
    'ST CATHERINES / Thursday: customer has no MOP service; legacy value 74 is not a Mop trolley requirement.',
    now()
  ),
  (
    418,
    'TrolleyMop',
    'IGNORE',
    null,
    null,
    false,
    null,
    null,
    true,
    'ST CATHERINES / Saturday: customer has no MOP service; legacy value 74 is not a Mop trolley requirement.',
    now()
  )
on conflict (source_row, source_field)
do update set
  decision_code = excluded.decision_code,
  trolley_type_code = excluded.trolley_type_code,
  quantity = excluded.quantity,
  empty_trolley = excluded.empty_trolley,
  owner_product_code = excluded.owner_product_code,
  serves_product_codes = excluded.serves_product_codes,
  owner_confirmed = excluded.owner_confirmed,
  decision_note = excluded.decision_note,
  updated_at = excluded.updated_at;

-- ---------------------------------------------------------------------
-- Route master decisions
--
-- DisplayName and RouteColor are controlled by Route. All nine route-master
-- mappings are accepted as the canonical values for the initial import.
-- ---------------------------------------------------------------------

update staging.legacy_route_mapping
set
  owner_confirmed = true,
  decision_note = 'Accepted as the canonical route-master value. Source row display-name or colour differences will not be imported.',
  decision_updated_at = now();

-- ---------------------------------------------------------------------
-- Mop variant decisions
--
-- The reviewed workbook marked every proposed mapping as Accept Mapping.
-- BAG, MANORHAMILTON and SCRUB SUITS will therefore be created as active
-- MOP catalogue variants, with legacy-review metadata preserved.
-- ---------------------------------------------------------------------

update staging.legacy_mop_variant_mapping
set
  review_required = false,
  owner_confirmed = true,
  decision_note = case legacy_value
    when 'BAG' then 'Owner accepted BAG as a Mop catalogue variant.'
    when 'MANORHAMILTON' then 'Owner accepted MANORHAMILTON as a Mop catalogue variant.'
    when 'SCRUB SUITS' then 'Owner accepted SCRUB SUITS as a Mop catalogue variant.'
    else 'Owner accepted the proposed normalization mapping.'
  end,
  decision_updated_at = now();

-- ---------------------------------------------------------------------
-- Effective trolley interpretation
-- ---------------------------------------------------------------------

create or replace view staging.v_legacy_effective_trolley_review
as
with source_values as (
  select
    s.source_row,
    s.legacy_customer_id,
    s.customer_name,
    s.service_type,
    s.production_day,
    'QtyClothes'::text as source_field,
    'CLOTHES'::text as source_owner_product_code,
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
    'MOP'::text as source_owner_product_code,
    s.trolley_mop_text as raw_value,
    staging.parse_legacy_trolley_text(s.trolley_mop_text) as parsed_value
  from staging.legacy_customer_schedule s
),
effective as (
  select
    sv.*,
    o.decision_code,
    o.owner_confirmed,
    o.decision_note,
    case
      when o.decision_code = 'IGNORE' then
        jsonb_build_object(
          'status', 'IGNORED',
          'raw', sv.raw_value,
          'normalized', null,
          'total_quantity', 0,
          'owner_product_code', null,
          'serves_product_codes', '[]'::jsonb,
          'items', '[]'::jsonb
        )
      when o.decision_code = 'REPLACE' then
        jsonb_build_object(
          'status', 'PARSED_OVERRIDE',
          'raw', sv.raw_value,
          'normalized', concat(o.quantity, ':', o.trolley_type_code),
          'total_quantity', o.quantity,
          'owner_product_code', o.owner_product_code,
          'serves_product_codes', to_jsonb(o.serves_product_codes),
          'items', jsonb_build_array(
            jsonb_build_object(
              'trolley_type_code', o.trolley_type_code,
              'quantity', o.quantity,
              'empty_trolley', o.empty_trolley
            )
          )
        )
      else
        sv.parsed_value || jsonb_build_object(
          'owner_product_code', sv.source_owner_product_code,
          'serves_product_codes', jsonb_build_array(sv.source_owner_product_code)
        )
    end as effective_value
  from source_values sv
  left join staging.legacy_trolley_override o
    on o.source_row = sv.source_row
   and o.source_field = sv.source_field
)
select *
from effective;

-- ---------------------------------------------------------------------
-- Correct the earlier Mop variant review note behavior.
--
-- The previous COALESCE displayed "No normalization mapping exists" when a
-- valid mapping existed but its optional note was blank. This view now shows
-- that message only when the mapping row is genuinely missing.
-- ---------------------------------------------------------------------

create or replace view staging.v_legacy_mop_variant_review
as
with source_variants as (
  select
    trim(value) as legacy_value,
    count(*)::integer as usage_count
  from staging.legacy_customer_schedule s
  cross join lateral regexp_split_to_table(
    coalesce(s.mop_products_text, ''),
    '\s*;\s*'
  ) value
  where nullif(trim(value), '') is not null
  group by trim(value)
)
select
  sv.legacy_value,
  sv.usage_count,
  m.proposed_variant_code,
  m.proposed_display_name,
  case
    when m.legacy_value is null then true
    else m.review_required
  end as review_required,
  case
    when m.legacy_value is null
      then 'No normalization mapping exists for this legacy value.'
    else m.review_note
  end as review_note
from source_variants sv
left join staging.legacy_mop_variant_mapping m
  on m.legacy_value = sv.legacy_value;

-- ---------------------------------------------------------------------
-- Final import blockers
--
-- This view deliberately does not guess the meaning of a trolley value in
-- the Mop column for a CLOTHES-only customer. Those rows require an explicit
-- owner decision because the value could be:
--   1. an additional Clothes trolley;
--   2. an incorrect legacy value to ignore; or
--   3. evidence that the customer also has a Mop service.
-- ---------------------------------------------------------------------

create or replace view staging.v_legacy_import_blockers
as
select
  'UNRESOLVED_TROLLEY_PARSE'::text as blocker_code,
  t.source_row,
  t.legacy_customer_id,
  t.customer_name,
  t.production_day,
  t.source_field,
  t.raw_value,
  format(
    'The trolley value still has status %s.',
    t.effective_value ->> 'status'
  ) as blocker_detail
from staging.v_legacy_effective_trolley_review t
where t.effective_value ->> 'status' like 'REVIEW%'

union all

select
  'MOP_TROLLEY_ON_CLOTHES_ONLY_CUSTOMER'::text as blocker_code,
  t.source_row,
  t.legacy_customer_id,
  t.customer_name,
  t.production_day,
  t.source_field,
  t.raw_value,
  'The source contains a positive TrolleyMop value for a CLOTHES-only customer. Confirm whether it is an additional Clothes trolley, an incorrect value, or a missing Mop service.'::text
from staging.v_legacy_effective_trolley_review t
where upper(trim(coalesce(t.service_type, ''))) = 'CLOTHES'
  and t.source_field = 'TrolleyMop'
  and (t.effective_value ->> 'status') in ('PARSED', 'PARSED_OVERRIDE')
  and coalesce((t.effective_value ->> 'total_quantity')::integer, 0) > 0
  and coalesce(t.effective_value ->> 'owner_product_code', 'MOP') = 'MOP'

union all

select
  'UNCONFIRMED_INACTIVE_CUSTOMER'::text as blocker_code,
  m.source_row,
  m.legacy_customer_id,
  m.customer_name,
  null::text as production_day,
  null::text as source_field,
  m.service_type as raw_value,
  'The customer has no usable schedule or service decision and has not been owner-confirmed inactive.'::text
from staging.legacy_customer_master m
left join staging.legacy_customer_status_override o
  on o.legacy_customer_id = m.legacy_customer_id
left join (
  select legacy_customer_id, count(*) as schedule_count
  from staging.legacy_customer_schedule
  group by legacy_customer_id
) sc
  on sc.legacy_customer_id = m.legacy_customer_id
where coalesce(sc.schedule_count, 0) = 0
  and not (
    coalesce(o.proposed_active, true) = false
    and coalesce(o.owner_confirmed, false) = true
  )

union all

select
  'UNCONFIRMED_MOP_VARIANT'::text as blocker_code,
  null::integer as source_row,
  null::text as legacy_customer_id,
  v.proposed_display_name as customer_name,
  null::text as production_day,
  'MopProducts'::text as source_field,
  v.legacy_value as raw_value,
  coalesce(v.review_note, 'Mop variant mapping requires review.') as blocker_detail
from staging.legacy_mop_variant_mapping v
where v.review_required
   or not v.owner_confirmed

union all

select
  'UNCONFIRMED_ROUTE_MAPPING'::text as blocker_code,
  null::integer as source_row,
  null::text as legacy_customer_id,
  r.proposed_display_name as customer_name,
  null::text as production_day,
  'Route'::text as source_field,
  r.route_code as raw_value,
  coalesce(r.review_note, 'Route mapping requires owner confirmation.') as blocker_detail
from staging.legacy_route_mapping r
where r.review_required
   or not r.owner_confirmed;

comment on view staging.v_legacy_import_blockers is
  'Every row in this view must be resolved before the operational legacy customer import is allowed to publish.';

-- ---------------------------------------------------------------------
-- Private permissions
-- ---------------------------------------------------------------------

revoke all on staging.legacy_trolley_override from public, anon, authenticated;
revoke all on staging.v_legacy_effective_trolley_review from public, anon, authenticated;
revoke all on staging.v_legacy_import_blockers from public, anon, authenticated;

commit;
