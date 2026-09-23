-- ElisCaretex V2 Development cleanup
-- Removes ONLY the reversible simulation tagged SIM_FULL_DAY_20260806_V1.
-- Simulation Business Date: 2026-08-06
-- IMPORTANT: the script aborts if any simulated trolley received later non-simulation activity.

BEGIN;

DO $$
DECLARE
  v_marker constant text := 'SIM_FULL_DAY_20260806_V1';
  v_started_at timestamptz;
  v_flow_count integer;
  v_conflicts integer;
BEGIN
  SELECT min(occurred_at)
  INTO v_started_at
  FROM public.audit_log
  WHERE source_application=v_marker
    AND action='SIMULATE_SORTING_FULL_DAY';

  SELECT count(*)
  INTO v_flow_count
  FROM public.production_flow_items
  WHERE flow_code LIKE 'SIMPF20260806-%';

  IF v_flow_count=0 THEN
    RAISE EXCEPTION 'Cleanup aborted: no simulated Production Flow rows were found for %.', v_marker;
  END IF;

  CREATE TEMP TABLE cleanup_flow_ids ON COMMIT DROP AS
  SELECT production_flow_item_id
  FROM public.production_flow_items
  WHERE flow_code LIKE 'SIMPF20260806-%';

  CREATE TEMP TABLE cleanup_mop_ids ON COMMIT DROP AS
  SELECT mop_production_batch_id
  FROM public.sorting_mop_production_batches
  WHERE production_flow_item_id IN (SELECT production_flow_item_id FROM cleanup_flow_ids)
    AND notes LIKE '%'||v_marker||'%';

  CREATE TEMP TABLE cleanup_stays ON COMMIT DROP AS
  SELECT stay_id,trolley_id
  FROM public.trolley_customer_stays
  WHERE notes LIKE '%'||v_marker||'%';

  CREATE TEMP TABLE cleanup_trolleys ON COMMIT DROP AS
  SELECT DISTINCT trolley_id FROM cleanup_stays;

  -- Safety gate: do not restore/delete a trolley if it has been touched by a real
  -- workflow after this simulation was created.
  SELECT count(*)
  INTO v_conflicts
  FROM (
    SELECT e.trolley_id
    FROM public.trolley_events e
    WHERE e.trolley_id IN (SELECT trolley_id FROM cleanup_trolleys)
      AND coalesce(e.source_application,'') <> v_marker
      AND v_started_at IS NOT NULL
      AND e.created_at > v_started_at
    UNION ALL
    SELECT s.trolley_id
    FROM public.trolley_customer_stays s
    WHERE s.trolley_id IN (SELECT trolley_id FROM cleanup_trolleys)
      AND s.stay_id NOT IN (SELECT stay_id FROM cleanup_stays)
      AND v_started_at IS NOT NULL
      AND s.created_at > v_started_at
  ) q;

  IF v_conflicts>0 THEN
    RAISE EXCEPTION 'Cleanup aborted: % later non-simulation trolley activities were detected. Review before deleting test data.',v_conflicts;
  END IF;

  -- MOP production children.
  DELETE FROM public.sorting_mop_production_trolleys
  WHERE mop_production_batch_id IN (SELECT mop_production_batch_id FROM cleanup_mop_ids)
     OR stay_id IN (SELECT stay_id FROM cleanup_stays);

  DELETE FROM public.sorting_mop_production_lines
  WHERE mop_production_batch_id IN (SELECT mop_production_batch_id FROM cleanup_mop_ids);

  DELETE FROM public.sorting_mop_reconciliations
  WHERE linked_mop_production_batch_id IN (SELECT mop_production_batch_id FROM cleanup_mop_ids)
     OR production_flow_item_id IN (SELECT production_flow_item_id FROM cleanup_flow_ids);

  DELETE FROM public.production_flow_external_batches
  WHERE production_flow_item_id IN (SELECT production_flow_item_id FROM cleanup_flow_ids)
    AND integration_metadata->>'simulation_marker'=v_marker;

  DELETE FROM public.sorting_mop_production_batches
  WHERE mop_production_batch_id IN (SELECT mop_production_batch_id FROM cleanup_mop_ids);

  -- Washing children before parent runs.
  DELETE FROM public.sorting_wash_reception_exceptions
  WHERE wash_run_id IN (
    SELECT wash_run_id
    FROM public.sorting_wash_runs
    WHERE source_application='SIM_SORTING_FULL_DAY'
      AND business_date=date '2026-08-06'
  );

  DELETE FROM public.sorting_wash_run_customers
  WHERE metadata->>'simulation_marker'=v_marker
     OR wash_run_id IN (
       SELECT wash_run_id
       FROM public.sorting_wash_runs
       WHERE source_application='SIM_SORTING_FULL_DAY'
         AND business_date=date '2026-08-06'
     );

  DELETE FROM public.sorting_wash_runs
  WHERE source_application='SIM_SORTING_FULL_DAY'
    AND business_date=date '2026-08-06';

  -- Trolley simulation history.
  DELETE FROM public.trolley_events
  WHERE source_application=v_marker
     OR stay_id IN (SELECT stay_id FROM cleanup_stays);

  DELETE FROM public.trolley_customer_stays
  WHERE stay_id IN (SELECT stay_id FROM cleanup_stays);

  -- All trolleys chosen for this simulation were LOCATION_UNCONFIRMED immediately
  -- before the simulation started. Restore that master status only when no other
  -- open stay exists.
  UPDATE public.trolleys t
  SET status='LOCATION_UNCONFIRMED',
      updated_at=now(),
      updated_by=NULL
  WHERE t.trolley_id IN (SELECT trolley_id FROM cleanup_trolleys)
    AND NOT EXISTS (
      SELECT 1
      FROM public.trolley_customer_stays s
      WHERE s.trolley_id=t.trolley_id
        AND s.received_on IS NULL
    );

  -- Delete Production Flow events AFTER operational children, because child delete
  -- triggers may refresh the Production Flow summary.
  DELETE FROM public.production_flow_events
  WHERE production_flow_item_id IN (SELECT production_flow_item_id FROM cleanup_flow_ids);

  DELETE FROM public.production_flow_items
  WHERE production_flow_item_id IN (SELECT production_flow_item_id FROM cleanup_flow_ids);

  DELETE FROM public.audit_log
  WHERE source_application=v_marker
     OR (action='SIMULATE_SORTING_FULL_DAY' AND entity_id='2026-08-06');
END $$;

COMMIT;

-- Expected result: every value below is zero.
SELECT jsonb_build_object(
  'marker','SIM_FULL_DAY_20260806_V1',
  'remaining_flow_items',(SELECT count(*) FROM public.production_flow_items WHERE flow_code LIKE 'SIMPF20260806-%'),
  'remaining_wash_runs',(SELECT count(*) FROM public.sorting_wash_runs WHERE source_application='SIM_SORTING_FULL_DAY' AND business_date=date '2026-08-06'),
  'remaining_wash_rows',(SELECT count(*) FROM public.sorting_wash_run_customers WHERE metadata->>'simulation_marker'='SIM_FULL_DAY_20260806_V1'),
  'remaining_mop_batches',(SELECT count(*) FROM public.sorting_mop_production_batches WHERE notes LIKE '%SIM_FULL_DAY_20260806_V1%'),
  'remaining_abs_batches',(SELECT count(*) FROM public.production_flow_external_batches WHERE integration_metadata->>'simulation_marker'='SIM_FULL_DAY_20260806_V1'),
  'remaining_trolley_stays',(SELECT count(*) FROM public.trolley_customer_stays WHERE notes LIKE '%SIM_FULL_DAY_20260806_V1%'),
  'remaining_trolley_events',(SELECT count(*) FROM public.trolley_events WHERE source_application='SIM_FULL_DAY_20260806_V1')
) AS cleanup_summary;
