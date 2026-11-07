-- Alert the customer that lost a trolley to another customer during production.
--
-- 202611070002 lets Finish / MOP Production take a clean trolley saved for customer A
-- and use it for customer B (with a reason). A's record then becomes Trolley pending,
-- but nobody at A's table was told. The owner asked (2026-11-07) for an alert there.
--
-- get_trolley_taken_alerts_v1(area): read-only list for the alert bar at the top of the
-- Finish and MOP Production screens (customer-alerts.js). One row per trolley taken from
-- a customer of that area while that customer is still missing it:
--   * the move was recorded by release_production_trolley_v1 (trolley_events
--     RECORD_CORRECTED, action RELEASED_FROM_PRODUCTION_CUSTOMER) in the last 7 days;
--   * the planned delivery of that customer is today or later;
--   * the customer's current record is still Trolley pending (Finish: the active
--     revision of the same entry group; MOP: the recorded batch of the same flow item).
-- The alert ends by itself when another trolley is scanned (Edit / Add trolley) or the
-- delivery date passes. Same audience as the production alerts (production read role).
-- No table or column changes.

create or replace function public.get_trolley_taken_alerts_v1(p_area_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_area text := upper(trim(coalesce(p_area_code,'')));
  v_today date := public.current_business_date();
begin
  perform public.require_production_flow_read_role();
  if v_area not in ('SORTING','FINISH','MOP','DISTRIBUTION') then
    raise exception using errcode = '22023', message = 'Unknown production area.';
  end if;
  if v_area not in ('FINISH','MOP') then
    return jsonb_build_object('area_code', v_area, 'items', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'area_code', v_area,
    'items', coalesce((
      select jsonb_agg(x.item order by x.moved_at desc)
      from (
        select ev.created_at as moved_at, jsonb_build_object(
          'trolley_event_id', ev.trolley_event_id,
          'trolley_code', t.trolley_code,
          'customer_id', ev.customer_id,
          'customer_code', c.customer_code,
          'customer_name', coalesce(c.customer_name, ev.metadata->>'from_customer_name'),
          'to_customer_name', ev.metadata->>'to_customer_name',
          'reason', ev.reason,
          'moved_at', ev.created_at,
          'moved_by', coalesce(sm.display_name, 'Operator'),
          'delivery_date', (ev.metadata->'removed_stay'->>'planned_delivery_on')::date,
          'table_name', fe.table_name_snapshot
        ) as item
        from public.trolley_events ev
        join public.trolleys t on t.trolley_id = ev.trolley_id
        left join public.customers c on c.customer_id = ev.customer_id
        left join public.staff_members sm on sm.staff_id = ev.performed_by
        left join public.finish_production_entries fe
          on ev.metadata->>'from_record_table' = 'finish_production_entries'
         and fe.finish_production_entry_id = (ev.metadata->>'from_record_id')::uuid
        left join public.sorting_mop_production_batches mb
          on ev.metadata->>'from_record_table' = 'sorting_mop_production_batches'
         and mb.mop_production_batch_id = (ev.metadata->>'from_record_id')::uuid
        where ev.event_type = 'RECORD_CORRECTED'
          and ev.metadata->>'action' = 'RELEASED_FROM_PRODUCTION_CUSTOMER'
          and ev.metadata->>'from_area_code' = v_area
          and ev.created_at >= now() - interval '7 days'
          and coalesce((ev.metadata->'removed_stay'->>'planned_delivery_on')::date, v_today) >= v_today
          and (
            (fe.finish_production_entry_id is not null and exists (
              select 1 from public.finish_production_entries cur
              where cur.entry_group_id = fe.entry_group_id
                and cur.status = 'ACTIVE'
                and cur.trolley_scan_status = 'PENDING'))
            or
            (mb.mop_production_batch_id is not null and exists (
              select 1 from public.sorting_mop_production_batches cur
              where cur.production_flow_item_id = mb.production_flow_item_id
                and cur.status = 'RECORDED'
                and cur.trolley_capture_status = 'PENDING'))
          )
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_trolley_taken_alerts_v1(text) from public, anon;
grant execute on function public.get_trolley_taken_alerts_v1(text) to authenticated;
