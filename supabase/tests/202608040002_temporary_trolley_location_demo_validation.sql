-- =====================================================================
-- ElisCaretex V2
-- Validation: temporary trolley location consultation demo
-- Marker: TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1
--
-- Run after the temporary seed. This validation does not modify data.
-- =====================================================================

do $$
declare
  v_marker constant text := 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1';
  v_count integer;
begin
  select count(*) into v_count
  from public.trolleys
  where metadata #>> '{temporary_location_demo,marker}' = v_marker;
  if v_count <> 44 then
    raise exception 'Expected 44 marked demo trolleys, found %.', v_count;
  end if;

  select count(*) into v_count
  from public.trolley_customer_stays
  where notes like v_marker || ':%'
    and received_on is null;
  if v_count <> 32 then
    raise exception 'Expected 32 demo trolleys at customers, found %.', v_count;
  end if;

  select count(distinct outbound_customer_id) into v_count
  from public.trolley_customer_stays
  where notes like v_marker || ':%'
    and received_on is null;
  if v_count <> 8 then
    raise exception 'Expected 8 demo customer locations, found %.', v_count;
  end if;

  select count(*) into v_count
  from public.trolley_events
  where source_application = v_marker
    and event_type = 'ARRIVED_AT_SORTING';
  if v_count <> 12 then
    raise exception 'Expected 12 demo trolleys at Elis Laundry, found %.', v_count;
  end if;

  select count(*) into v_count
  from public.trolley_customer_stays
  where notes like v_marker || ':%'
    and current_date - sent_on >= 14
    and current_date - sent_on < 30;
  if v_count <> 8 then
    raise exception 'Expected 8 warning demo trolleys, found %.', v_count;
  end if;

  select count(*) into v_count
  from public.trolley_customer_stays
  where notes like v_marker || ':%'
    and current_date - sent_on >= 30;
  if v_count <> 12 then
    raise exception 'Expected 12 overdue demo trolleys, found %.', v_count;
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608040002_temporary_trolley_location_demo_validation',
  'source', 'CentralDB (1)(4).xlsx / WashItems',
  'temporary_trolleys', 44,
  'at_customers', 32,
  'customer_locations', 8,
  'at_elis_laundry', 12,
  'normal_customer_trolleys', 12,
  'warning_customer_trolleys', 8,
  'overdue_customer_trolleys', 12,
  'data_is_temporary', true,
  'durations_are_synthetic', true
) as result;
