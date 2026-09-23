-- =====================================================================
-- ElisCaretex V2
-- Remove temporary trolley location consultation demo
-- Marker: TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1
--
-- DEVELOPMENT ONLY.
-- This script removes only rows created by the paired temporary seed and
-- restores each trolley's previous master status from its metadata snapshot.
-- It aborts if a target trolley received later non-demo events.
-- =====================================================================

begin;

do $$
declare
  v_marker constant text := 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1';
  v_conflict text;
  v_demo_count integer;
begin
  select count(*) into v_demo_count
  from public.trolleys t
  where t.metadata #>> '{temporary_location_demo,marker}' = v_marker;

  if v_demo_count = 0 then
    raise exception 'Temporary trolley location demo is not installed.';
  end if;

  select string_agg(t.trolley_code, ', ' order by t.trolley_code)
  into v_conflict
  from public.trolleys t
  where t.metadata #>> '{temporary_location_demo,marker}' = v_marker
    and exists (
      select 1
      from public.trolley_events e
      where e.trolley_id = t.trolley_id
        and e.source_application is distinct from v_marker
        and e.created_at > (
          t.metadata #>> '{temporary_location_demo,seeded_at}'
        )::timestamptz
    );

  if v_conflict is not null then
    raise exception
      'Cleanup stopped because these demo trolleys have later non-demo events: %',
      v_conflict;
  end if;

  if exists (
    select 1
    from public.trolleys t
    join public.trolley_customer_stays s
      on s.trolley_id = t.trolley_id
     and s.received_on is null
    where t.metadata #>> '{temporary_location_demo,marker}' = v_marker
      and s.notes not like v_marker || ':%'
  ) then
    raise exception
      'Cleanup stopped because a marked trolley has a non-demo open stay.';
  end if;

  delete from public.trolley_events e
  using public.trolleys t
  where e.trolley_id = t.trolley_id
    and t.metadata #>> '{temporary_location_demo,marker}' = v_marker
    and (
      e.source_application = v_marker
      or e.metadata #>> '{marker}' = v_marker
    );

  delete from public.trolley_customer_stays s
  using public.trolleys t
  where s.trolley_id = t.trolley_id
    and t.metadata #>> '{temporary_location_demo,marker}' = v_marker
    and s.notes like v_marker || ':%';

  update public.trolleys t
  set
    status = coalesce(
      nullif(t.metadata #>> '{temporary_location_demo,original_status}', ''),
      'LOCATION_UNCONFIRMED'
    ),
    active = coalesce(
      (t.metadata #>> '{temporary_location_demo,original_active}')::boolean,
      true
    ),
    status_before_service_hold =
      nullif(
        t.metadata #>> '{temporary_location_demo,original_status_before_service_hold}',
        ''
      ),
    metadata = t.metadata - 'temporary_location_demo',
    updated_at = now()
  where t.metadata #>> '{temporary_location_demo,marker}' = v_marker;
end;
$$;

select jsonb_build_object(
  'status', 'TEMPORARY_DEMO_REMOVED',
  'marker', 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1',
  'remaining_marked_trolleys', (
    select count(*)
    from public.trolleys
    where metadata #>> '{temporary_location_demo,marker}' = 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1'
  ),
  'remaining_demo_stays', (
    select count(*)
    from public.trolley_customer_stays
    where notes like 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1:%'
  ),
  'remaining_demo_events', (
    select count(*)
    from public.trolley_events
    where source_application = 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1'
       or metadata #>> '{marker}' = 'TROLLEY_LOCATION_DEMO_WASHITEMS_20260804_V1'
  )
) as result;

commit;
