-- =====================================================================
-- ElisCaretex V2
-- Temporary seed: trolley location consultation demo from WashItems
-- Source: CentralDB (1)(4).xlsx / WashItems
-- Marker: TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1
--
-- DEVELOPMENT ONLY.
-- This is not a migration and must not be used in Production.
-- It creates reversible temporary location data so the Physical Trolleys
-- consultation page can be visually evaluated.
--
-- Data policy:
-- - trolley/customer associations come from WashItems;
-- - days at location are synthetic and intentionally varied;
-- - no real operational movement is asserted;
-- - run the paired removal script when the review is complete.
-- =====================================================================

begin;

create temporary table trolley_location_demo_source (
  trolley_code text primary key,
  customer_code text not null,
  source_customer_name text not null,
  location_kind text not null,
  days_at_location integer not null,
  source_wash_item_id text not null,
  source_area text not null,
  source_processed_at timestamptz,
  source_trolley_type text not null
) on commit drop;

insert into trolley_location_demo_source (
  trolley_code,
  customer_code,
  source_customer_name,
  location_kind,
  days_at_location,
  source_wash_item_id,
  source_area,
  source_processed_at,
  source_trolley_type
)
values
    ('T1102025T', 'CID-HIGH-93C6F', 'HIGHFIELD', 'CUSTOMER', 2, 'WI20260804-01-HI2VENQK', 'MOP', '2026-08-04 18:43:22'::timestamptz, 'Large'),
    ('T6142025T', 'CID-HIGH-93C6F', 'HIGHFIELD', 'CUSTOMER', 2, 'WI20260804-01-HI2VENQK', 'MOP', '2026-08-04 18:43:22'::timestamptz, 'Large'),
    ('T6132025T', 'CID-HIGH-93C6F', 'HIGHFIELD', 'CUSTOMER', 2, 'WI20260804-01-HI2VENQK', 'MOP', '2026-08-04 18:43:22'::timestamptz, 'Large'),
    ('T4852025T', 'CID-HIGH-93C6F', 'HIGHFIELD', 'CUSTOMER', 2, 'WI20260803-01-P21F9AT9', 'FINISH', '2026-08-04 10:07:28'::timestamptz, 'Small'),
    ('T7922025T', 'CID-LEOP-D2657', 'LEOPARDSTOWN', 'CUSTOMER', 5, 'WI20260801-01-T8PVR5Q1', 'FINISH', '2026-08-03 19:57:02'::timestamptz, 'Small'),
    ('T4972025T', 'CID-LEOP-D2657', 'LEOPARDSTOWN', 'CUSTOMER', 5, 'WI20260801-01-T8PVR5Q1', 'FINISH', '2026-08-03 19:57:02'::timestamptz, 'Small'),
    ('T2962025T', 'CID-LEOP-D2657', 'LEOPARDSTOWN', 'CUSTOMER', 5, 'WI20260801-01-T8PVR5Q1', 'FINISH', '2026-08-03 19:57:02'::timestamptz, 'Small'),
    ('T3162025T', 'CID-LEOP-D2657', 'LEOPARDSTOWN', 'CUSTOMER', 5, 'WI20260801-01-T8PVR5Q1', 'FINISH', '2026-08-03 19:57:02'::timestamptz, 'Small'),
    ('T4942025T', 'CID-STFI-78BBA', 'ST FINBARRS', 'CUSTOMER', 9, 'WI20260804-01-1PYDHGKY', 'FINISH', '2026-08-04 18:08:25'::timestamptz, 'Small'),
    ('T2582025T', 'CID-STFI-78BBA', 'ST FINBARRS', 'CUSTOMER', 9, 'WI20260804-01-1PYDHGKY', 'FINISH', '2026-08-04 18:08:25'::timestamptz, 'Small'),
    ('T6062025T', 'CID-STFI-78BBA', 'ST FINBARRS', 'CUSTOMER', 9, 'WI20260804-01-1PYDHGKY', 'FINISH', '2026-08-04 18:08:25'::timestamptz, 'Small'),
    ('T1352025T', 'CID-STFI-78BBA', 'ST FINBARRS', 'CUSTOMER', 9, 'WI20260804-01-1PYDHGKY', 'FINISH', '2026-08-04 18:08:25'::timestamptz, 'Small'),
    ('T2052025T', 'CID-BLOO-F6FA0', 'BLOOMFIELD', 'CUSTOMER', 14, 'WI20260803-01-N513QL3C', 'FINISH', '2026-08-04 08:27:10'::timestamptz, 'Large'),
    ('T3252025T', 'CID-BLOO-F6FA0', 'BLOOMFIELD', 'CUSTOMER', 14, 'WI20260803-01-N513QL3C', 'FINISH', '2026-08-04 08:27:10'::timestamptz, 'Small'),
    ('T3182025T', 'CID-BLOO-F6FA0', 'BLOOMFIELD', 'CUSTOMER', 14, 'WI20260803-01-N513QL3C', 'FINISH', '2026-08-04 08:27:10'::timestamptz, 'Small'),
    ('T4762025T', 'CID-BLOO-F6FA0', 'BLOOMFIELD', 'CUSTOMER', 14, 'WI20260803-01-N513QL3C', 'FINISH', '2026-08-04 08:27:10'::timestamptz, 'Small'),
    ('T4802025T', 'CID-STCO-F304C', 'ST COLUMBAS HOSPITAL', 'CUSTOMER', 18, 'WI20260804-01-TBXH0TVH', 'FINISH', '2026-08-04 14:57:44'::timestamptz, 'Large'),
    ('T3512025T', 'CID-STCO-F304C', 'ST COLUMBAS HOSPITAL', 'CUSTOMER', 18, 'WI20260804-01-TBXH0TVH', 'FINISH', '2026-08-04 14:57:44'::timestamptz, 'Small'),
    ('T1052025T', 'CID-STCO-F304C', 'ST COLUMBAS HOSPITAL', 'CUSTOMER', 18, 'WI20260804-01-TBXH0TVH', 'FINISH', '2026-08-04 14:57:44'::timestamptz, 'Small'),
    ('T2252025T', 'CID-STCO-F304C', 'ST COLUMBAS HOSPITAL', 'CUSTOMER', 18, 'WI20260804-01-WHIB862W', 'MOP', '2026-08-03 16:45:01'::timestamptz, 'Small'),
    ('T2062025T', 'CID-FARR-2003F', 'FARRANLEA', 'CUSTOMER', 30, 'WI20260804-01-4K017PE5', 'MOP', '2026-08-04 18:42:15'::timestamptz, 'Large'),
    ('T3932025T', 'CID-FARR-2003F', 'FARRANLEA', 'CUSTOMER', 30, 'WI20260804-01-NZVPDZBC', 'FINISH', '2026-08-04 17:10:20'::timestamptz, 'Small'),
    ('T3752025T', 'CID-FARR-2003F', 'FARRANLEA', 'CUSTOMER', 30, 'WI20260804-01-NZVPDZBC', 'FINISH', '2026-08-04 17:10:20'::timestamptz, 'Small'),
    ('T3312025T', 'CID-FARR-2003F', 'FARRANLEA', 'CUSTOMER', 30, 'WI20260804-01-NZVPDZBC', 'FINISH', '2026-08-04 17:10:20'::timestamptz, 'Small'),
    ('T7272025T', 'CID-STJO-96335', 'ST JOSEPHS', 'CUSTOMER', 37, 'WI20260804-01-T33U5LKU', 'MOP', '2026-08-04 08:00:40'::timestamptz, 'Small'),
    ('T4582025T', 'CID-STJO-96335', 'ST JOSEPHS', 'CUSTOMER', 37, 'WI20260804-01-T33U5LKU', 'MOP', '2026-08-04 08:00:40'::timestamptz, 'Small'),
    ('T4112025T', 'CID-STJO-96335', 'ST JOSEPHS', 'CUSTOMER', 37, 'WI20260804-01-T33U5LKU', 'MOP', '2026-08-04 08:00:40'::timestamptz, 'Small'),
    ('T0742025T', 'CID-STJO-96335', 'ST JOSEPHS', 'CUSTOMER', 37, 'WI20260804-01-T33U5LKU', 'MOP', '2026-08-04 08:00:40'::timestamptz, 'Small'),
    ('T7362025T', 'CID-HEAT-20E55', 'HEATHER HOUSE', 'CUSTOMER', 52, 'WI20260804-01-RV112WSY', 'FINISH', '2026-08-04 19:30:47'::timestamptz, 'Medium'),
    ('T4402025T', 'CID-HEAT-20E55', 'HEATHER HOUSE', 'CUSTOMER', 52, 'WI20260804-01-RV112WSY', 'FINISH', '2026-08-04 19:30:47'::timestamptz, 'Medium'),
    ('T1342025T', 'CID-HEAT-20E55', 'HEATHER HOUSE', 'CUSTOMER', 52, 'WI20260804-01-RV112WSY', 'FINISH', '2026-08-04 19:30:47'::timestamptz, 'Small'),
    ('T0222025T', 'CID-HEAT-20E55', 'HEATHER HOUSE', 'CUSTOMER', 52, 'WI20260804-01-OOXKK6J3', 'MOP', '2026-08-04 11:48:11'::timestamptz, 'Small'),
    ('T3172025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 0, 'WI20260803-01-KD4W4FPQ', 'FINISH', '2026-08-04 09:49:05'::timestamptz, 'Large'),
    ('T0022025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 1, 'WI20260803-01-KD4W4FPQ', 'FINISH', '2026-08-04 09:49:05'::timestamptz, 'Large'),
    ('T5022025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 2, 'WI20260801-01-7SOGGZRE', 'FINISH', '2026-08-03 13:13:02'::timestamptz, 'Large'),
    ('T2872025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 3, 'WI20260801-01-7SOGGZRE', 'FINISH', '2026-08-03 13:13:02'::timestamptz, 'Medium'),
    ('T1262025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 5, 'WI20260729-01-GW34AV8N', 'FINISH', '2026-07-30 09:13:39'::timestamptz, 'Large'),
    ('T3522025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 7, 'WI20260729-01-GW34AV8N', 'FINISH', '2026-07-30 09:13:39'::timestamptz, 'Large'),
    ('T3642025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 10, 'WI20260728-01-M78WIC', 'FINISH', '2026-07-29 11:22:27'::timestamptz, 'Large'),
    ('T1882025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 14, 'WI20260728-01-M78WIC', 'FINISH', '2026-07-29 11:22:27'::timestamptz, 'Medium'),
    ('T2522025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 21, 'WI20260727-01-WQ9U25', 'FINISH', '2026-07-27 22:14:47'::timestamptz, 'Medium'),
    ('T4682025T', 'CID-ASHB-C5099', 'ASHBURY', 'ELIS_LAUNDRY', 30, 'WI20260727-01-WQ9U25', 'FINISH', '2026-07-27 22:14:47'::timestamptz, 'Large'),
    ('T1872025T', 'CID-THEP-F25CD', 'THE PARK', 'ELIS_LAUNDRY', 45, 'WI20260804-01-GRYLGF0F', 'FINISH', '2026-08-04 15:00:43'::timestamptz, 'Medium'),
    ('T7842025T', 'CID-THEP-F25CD', 'THE PARK', 'ELIS_LAUNDRY', 60, 'WI20260804-01-GRYLGF0F', 'FINISH', '2026-08-04 15:00:43'::timestamptz, 'Small');

do $$
declare
  v_marker constant text := 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1';
  v_expected integer := 44;
  v_found integer;
  v_missing text;
  v_invalid text;
begin
  if to_regclass('public.trolleys') is null
     or to_regclass('public.trolley_customer_stays') is null
     or to_regclass('public.trolley_events') is null then
    raise exception 'Physical Trolley Lifecycle tables are missing.';
  end if;

  select count(*) into v_found
  from trolley_location_demo_source;

  if v_found <> v_expected then
    raise exception 'Temporary demo source count mismatch. Expected %, found %.',
      v_expected, v_found;
  end if;

  if exists (
    select 1
    from public.trolleys t
    where t.metadata ? 'temporary_location_demo'
  ) or exists (
    select 1
    from public.trolley_events e
    where e.source_application = v_marker
  ) then
    raise exception
      'Temporary trolley location demo is already installed. Run the removal script first.';
  end if;

  select string_agg(s.trolley_code, ', ' order by s.trolley_code)
  into v_missing
  from trolley_location_demo_source s
  left join public.trolleys t
    on lower(t.trolley_code) = lower(s.trolley_code)
   and t.deleted_at is null
  where t.trolley_id is null;

  if v_missing is not null then
    raise exception 'Demo trolleys are missing from the registry: %', v_missing;
  end if;

  select string_agg(distinct s.customer_code, ', ' order by s.customer_code)
  into v_missing
  from trolley_location_demo_source s
  left join public.customers c
    on c.customer_code = s.customer_code
   and c.deleted_at is null
  where c.customer_id is null;

  if v_missing is not null then
    raise exception 'Demo customers are missing from Customer Master: %', v_missing;
  end if;

  select string_agg(t.trolley_code || ' [' || t.status || ']', ', ' order by t.trolley_code)
  into v_invalid
  from trolley_location_demo_source s
  join public.trolleys t
    on lower(t.trolley_code) = lower(s.trolley_code)
  where t.deleted_at is not null
     or t.active is not true
     or t.status not in ('LOCATION_UNCONFIRMED', 'AVAILABLE');

  if v_invalid is not null then
    raise exception
      'Demo requires active unassigned trolleys. Invalid targets: %', v_invalid;
  end if;

  select string_agg(t.trolley_code, ', ' order by t.trolley_code)
  into v_invalid
  from trolley_location_demo_source s
  join public.trolleys t
    on lower(t.trolley_code) = lower(s.trolley_code)
  join public.trolley_customer_stays stay_row
    on stay_row.trolley_id = t.trolley_id
   and stay_row.received_on is null;

  if v_invalid is not null then
    raise exception
      'Demo cannot overwrite open trolley stays. Trolleys with open stays: %', v_invalid;
  end if;

  update public.trolleys t
  set
    metadata = jsonb_set(
      coalesce(t.metadata, '{}'::jsonb),
      '{temporary_location_demo}',
      jsonb_build_object(
        'marker', v_marker,
        'seeded_at', clock_timestamp(),
        'original_status', t.status,
        'original_active', t.active,
        'original_status_before_service_hold', t.status_before_service_hold,
        'source_file', 'CentralDB (1)(4).xlsx',
        'source_sheet', 'WashItems'
      ),
      true
    ),
    status = case
      when s.location_kind = 'CUSTOMER' then 'AT_CUSTOMER'
      else 'AVAILABLE'
    end,
    updated_at = now()
  from trolley_location_demo_source s
  where lower(t.trolley_code) = lower(s.trolley_code);

  insert into public.trolley_customer_stays (
    trolley_id,
    outbound_customer_id,
    sent_on,
    status,
    confirmation_source,
    operator_confirmed,
    review_status,
    notes
  )
  select
    t.trolley_id,
    c.customer_id,
    current_date - s.days_at_location,
    'OPEN',
    'SUPERVISOR_CORRECTION',
    false,
    'NOT_REQUIRED',
    v_marker || ':' || s.source_wash_item_id
  from trolley_location_demo_source s
  join public.trolleys t
    on lower(t.trolley_code) = lower(s.trolley_code)
  join public.customers c
    on c.customer_code = s.customer_code
  where s.location_kind = 'CUSTOMER';

  insert into public.trolley_events (
    trolley_id,
    stay_id,
    event_type,
    customer_id,
    business_date,
    source_application,
    reason,
    metadata
  )
  select
    t.trolley_id,
    stay_row.stay_id,
    'SENT_TO_CUSTOMER',
    c.customer_id,
    current_date - s.days_at_location,
    v_marker,
    'Temporary visual demo generated from WashItems. Location duration is synthetic.',
    jsonb_build_object(
      'temporary_demo', true,
      'marker', v_marker,
      'source_file', 'CentralDB (1)(4).xlsx',
      'source_sheet', 'WashItems',
      'source_wash_item_id', s.source_wash_item_id,
      'source_customer_name', s.source_customer_name,
      'source_area', s.source_area,
      'source_processed_at', s.source_processed_at,
      'source_trolley_type', s.source_trolley_type,
      'synthetic_days_at_location', s.days_at_location
    )
  from trolley_location_demo_source s
  join public.trolleys t
    on lower(t.trolley_code) = lower(s.trolley_code)
  join public.customers c
    on c.customer_code = s.customer_code
  join public.trolley_customer_stays stay_row
    on stay_row.trolley_id = t.trolley_id
   and stay_row.notes = v_marker || ':' || s.source_wash_item_id
  where s.location_kind = 'CUSTOMER';

  insert into public.trolley_events (
    trolley_id,
    event_type,
    customer_id,
    business_date,
    source_application,
    reason,
    metadata
  )
  select
    t.trolley_id,
    'ARRIVED_AT_SORTING',
    c.customer_id,
    current_date - s.days_at_location,
    v_marker,
    'Temporary Elis Laundry location demo generated from WashItems. Duration is synthetic.',
    jsonb_build_object(
      'temporary_demo', true,
      'marker', v_marker,
      'source_file', 'CentralDB (1)(4).xlsx',
      'source_sheet', 'WashItems',
      'source_wash_item_id', s.source_wash_item_id,
      'source_customer_name', s.source_customer_name,
      'source_area', s.source_area,
      'source_processed_at', s.source_processed_at,
      'source_trolley_type', s.source_trolley_type,
      'synthetic_days_at_location', s.days_at_location
    )
  from trolley_location_demo_source s
  join public.trolleys t
    on lower(t.trolley_code) = lower(s.trolley_code)
  join public.customers c
    on c.customer_code = s.customer_code
  where s.location_kind = 'ELIS_LAUNDRY';
end;
$$;

select jsonb_build_object(
  'status', 'TEMPORARY_DEMO_INSTALLED',
  'marker', 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1',
  'source', 'CentralDB (1)(4).xlsx / WashItems',
  'temporary_trolleys', (
    select count(*)
    from public.trolleys
    where metadata #>> '{temporary_location_demo,marker}' = 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1'
  ),
  'at_customers', (
    select count(*)
    from public.trolley_customer_stays
    where notes like 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1:%'
      and received_on is null
  ),
  'customer_locations', (
    select count(distinct outbound_customer_id)
    from public.trolley_customer_stays
    where notes like 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1:%'
      and received_on is null
  ),
  'at_elis_laundry', (
    select count(*)
    from public.trolley_events
    where source_application = 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1'
      and event_type = 'ARRIVED_AT_SORTING'
  ),
  'warning_demo_trolleys', (
    select count(*)
    from public.trolley_customer_stays
    where notes like 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1:%'
      and current_date - sent_on >= 14
      and current_date - sent_on < 30
  ),
  'overdue_demo_trolleys', (
    select count(*)
    from public.trolley_customer_stays
    where notes like 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1:%'
      and current_date - sent_on >= 30
  ),
  'removal_script', '202608040002_remove_temporary_trolley_location_demo.sql'
) as result;

commit;
