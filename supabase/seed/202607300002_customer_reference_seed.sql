-- =====================================================================
-- ElisCaretex V2
-- Seed: 202607300002_customer_reference_seed.sql
-- Run after 202607300002_customers_and_schedules.sql
-- =====================================================================

begin;

insert into public.product_types (
  product_code,
  display_name,
  processing_area_id,
  uses_kg,
  uses_units,
  sort_order,
  metadata
)
values
  (
    'CLOTHES',
    'Clothes',
    (select area_id from public.areas where area_code = 'FINISH'),
    true,
    false,
    10,
    jsonb_build_object(
      'schedule_enabled', true,
      'operational_view', 'FINISH'
    )
  ),
  (
    'MOP',
    'Mop',
    (select area_id from public.areas where area_code = 'MOP'),
    true,
    true,
    20,
    jsonb_build_object(
      'schedule_enabled', true,
      'operational_view', 'MOP'
    )
  )
on conflict (product_code) do update
set
  display_name = excluded.display_name,
  processing_area_id = excluded.processing_area_id,
  uses_kg = excluded.uses_kg,
  uses_units = excluded.uses_units,
  active = true,
  sort_order = excluded.sort_order,
  metadata = excluded.metadata,
  updated_at = now(),
  deleted_at = null;

insert into public.trolley_types (
  trolley_type_code,
  trolley_type_name,
  display_code,
  trolley_category,
  allowed_in_customer_schedule,
  active,
  sort_order,
  metadata
)
values
  (
    'SMALL',
    'Small Trolley',
    'S',
    'STANDARD',
    true,
    true,
    10,
    jsonb_build_object('legacy_codes', jsonb_build_array('S'))
  ),
  (
    'MEDIUM',
    'Medium Trolley',
    'M',
    'STANDARD',
    true,
    true,
    20,
    jsonb_build_object('legacy_codes', jsonb_build_array('M'))
  ),
  (
    'LARGE',
    'Large Trolley',
    'L',
    'STANDARD',
    true,
    true,
    30,
    jsonb_build_object('legacy_codes', jsonb_build_array('L'))
  ),
  (
    'GRAY',
    'Gray Trolley',
    'GRAY',
    'SPECIAL',
    true,
    true,
    40,
    jsonb_build_object(
      'legacy_codes', jsonb_build_array('GRAY', 'GREY'),
      'restricted_special_type', true
    )
  )
on conflict (trolley_type_code) do update
set
  trolley_type_name = excluded.trolley_type_name,
  display_code = excluded.display_code,
  trolley_category = excluded.trolley_category,
  allowed_in_customer_schedule = excluded.allowed_in_customer_schedule,
  active = true,
  sort_order = excluded.sort_order,
  metadata = excluded.metadata,
  updated_at = now(),
  deleted_at = null;

insert into public.app_config (
  config_key,
  value_json,
  description
)
values
  (
    'business_timezone',
    '"Europe/Dublin"'::jsonb,
    'Timezone used to calculate the ElisCaretex operational business date.'
  ),
  (
    'customer_schedule_require_change_reason',
    'true'::jsonb,
    'Require a reason when customer or customer schedule information is changed.'
  ),
  (
    'customer_schedule_standard_trolley_types',
    '["SMALL", "MEDIUM", "LARGE", "GRAY"]'::jsonb,
    'Trolley types allowed in the customer production schedule.'
  ),
  (
    'customer_schedule_shared_trolley_default_owner',
    '"CLOTHES"'::jsonb,
    'Default owner and display group for a trolley shared by Clothes and Mop.'
  )
on conflict (config_key) do update
set
  value_json = excluded.value_json,
  description = excluded.description,
  updated_at = now();

commit;
