-- =====================================================================
-- ElisCaretex V2
-- Migration: 202607300005_final_legacy_trolley_decisions.sql
-- Purpose:
--   Record the final ownership decision for the six ambiguous legacy
--   TrolleyMop values belonging to MILLBROOK and WOODLAWNS.
--
-- Confirmed business decision:
--   These customers do not have a MOP service. The legacy 1M value in
--   TrolleyMop is an additional Medium CLOTHES trolley.
--
-- This migration does not import operational customer data.
-- =====================================================================

begin;

do $$
declare
  v_master_count integer;
  v_schedule_count integer;
  v_operational_count bigint;
begin
  select count(*) into v_master_count
  from staging.legacy_customer_master;

  select count(*) into v_schedule_count
  from staging.legacy_customer_schedule;

  if v_master_count <> 141 or v_schedule_count <> 417 then
    raise exception using
      message = 'Safety stop: staging source counts are unexpected.',
      detail = format(
        'legacy_customer_master=%s, legacy_customer_schedule=%s',
        v_master_count,
        v_schedule_count
      ),
      hint = 'Expected 141 customers and 417 schedule rows.';
  end if;

  select
      (select count(*) from public.customers)
    + (select count(*) from public.customer_product_services)
    + (select count(*) from public.distribution_routes)
    + (select count(*) from public.product_variants)
    + (select count(*) from public.customer_schedule_versions)
    + (select count(*) from public.customer_schedule_days)
    + (select count(*) from public.customer_schedule_products)
    + (select count(*) from public.customer_schedule_product_variants)
    + (select count(*) from public.customer_schedule_trolley_requirements)
    + (select count(*) from public.customer_schedule_trolley_requirement_products)
  into v_operational_count;

  if v_operational_count <> 0 then
    raise exception using
      message = 'Safety stop: operational customer data already exists.',
      detail = format('Combined operational row count=%s', v_operational_count),
      hint = 'Do not apply legacy staging decisions after an operational import.';
  end if;
end;
$$;

-- Confirm that every reviewed source row is still exactly the expected
-- CLOTHES-only customer with a one-Medium value in TrolleyMop.
do $$
declare
  v_invalid_count integer;
begin
  select count(*)
  into v_invalid_count
  from (
    values
      (40,  'CID-MILL-ACD25', 'MILLBROOK', 'Monday'),
      (181, 'CID-MILL-ACD25', 'MILLBROOK', 'Wednesday'),
      (309, 'CID-MILL-ACD25', 'MILLBROOK', 'Friday'),
      (131, 'CID-WOOD-64502', 'WOODLAWNS', 'Tuesday'),
      (269, 'CID-WOOD-64502', 'WOODLAWNS', 'Thursday'),
      (400, 'CID-WOOD-64502', 'WOODLAWNS', 'Saturday')
  ) expected(source_row, legacy_customer_id, customer_name, production_day)
  left join staging.legacy_customer_schedule s
    on s.source_row = expected.source_row
   and s.legacy_customer_id = expected.legacy_customer_id
   and s.customer_name = expected.customer_name
   and s.production_day = expected.production_day
   and upper(trim(coalesce(s.service_type, ''))) = 'CLOTHES'
   and regexp_replace(upper(coalesce(s.trolley_mop_text, '')), '\s+', '', 'g') = '1M'
  where s.source_row is null;

  if v_invalid_count <> 0 then
    raise exception using
      message = 'Safety stop: one or more final trolley decision source rows changed.',
      detail = format('Unexpected source rows=%s', v_invalid_count),
      hint = 'Review the staging source instead of forcing the decision.';
  end if;
end;
$$;

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
    40,
    'TrolleyMop',
    'REPLACE',
    'MEDIUM',
    1,
    false,
    'CLOTHES',
    array['CLOTHES']::text[],
    true,
    'MILLBROOK / Monday: the legacy 1M in TrolleyMop is an additional Medium Clothes trolley. The customer has no MOP service.',
    now()
  ),
  (
    181,
    'TrolleyMop',
    'REPLACE',
    'MEDIUM',
    1,
    false,
    'CLOTHES',
    array['CLOTHES']::text[],
    true,
    'MILLBROOK / Wednesday: the legacy 1M in TrolleyMop is an additional Medium Clothes trolley. The customer has no MOP service.',
    now()
  ),
  (
    309,
    'TrolleyMop',
    'REPLACE',
    'MEDIUM',
    1,
    false,
    'CLOTHES',
    array['CLOTHES']::text[],
    true,
    'MILLBROOK / Friday: the legacy 1M in TrolleyMop is an additional Medium Clothes trolley. The customer has no MOP service.',
    now()
  ),
  (
    131,
    'TrolleyMop',
    'REPLACE',
    'MEDIUM',
    1,
    false,
    'CLOTHES',
    array['CLOTHES']::text[],
    true,
    'WOODLAWNS / Tuesday: the legacy 1M in TrolleyMop is an additional Medium Clothes trolley. The customer has no MOP service.',
    now()
  ),
  (
    269,
    'TrolleyMop',
    'REPLACE',
    'MEDIUM',
    1,
    false,
    'CLOTHES',
    array['CLOTHES']::text[],
    true,
    'WOODLAWNS / Thursday: the legacy 1M in TrolleyMop is an additional Medium Clothes trolley. The customer has no MOP service.',
    now()
  ),
  (
    400,
    'TrolleyMop',
    'REPLACE',
    'MEDIUM',
    1,
    false,
    'CLOTHES',
    array['CLOTHES']::text[],
    true,
    'WOODLAWNS / Saturday: the legacy 1M in TrolleyMop is an additional Medium Clothes trolley. The customer has no MOP service.',
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

-- No unresolved decision may remain after this migration.
do $$
declare
  v_blocker_count integer;
  v_blockers jsonb;
begin
  select count(*), coalesce(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
  into v_blocker_count, v_blockers
  from staging.v_legacy_import_blockers b;

  if v_blocker_count <> 0 then
    raise exception using
      message = 'Legacy customer import still has unresolved blockers.',
      detail = left(v_blockers::text, 7000),
      hint = 'Resolve every blocker before running the operational import.';
  end if;
end;
$$;

commit;
