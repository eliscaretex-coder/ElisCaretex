-- Finish needs to distinguish a planned customer from one received in Sorting Trolley Intake.

create or replace function public.get_production_tracker_v4(p_business_date date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb;
  v_items jsonb;
begin
  v_base:=public.get_production_tracker_v3(p_business_date);

  with base_items as (
    select item,ordinality
    from jsonb_array_elements(coalesce(v_base->'items','[]'::jsonb)) with ordinality x(item,ordinality)
  ), enriched as (
    select b.ordinality,
      case when upper(coalesce(b.item->>'product_code',''))='CLOTHES' then
        b.item || jsonb_build_object(
          'processed_quantity_kg',coalesce(f.kg,0),
          'processed_quantity_units',coalesce(f.units,0),
          'processed_quantity_source',case when coalesce(f.contributions,0)>0 then 'FINISH_PRODUCTION' else 'FINISH_PENDING' end,
          'product_status',case when coalesce(f.contributions,0)>0 then 'TRACKER_OK' else coalesce(b.item->>'product_status','WASHED_ONLY') end,
          'finish_contribution_count',coalesce(f.contributions,0),
          'finish_last_processed_at',f.last_at,
          'finish_tables',coalesce(f.tables,'[]'::jsonb),
          'finish_trolleys',coalesce(f.trolleys,'[]'::jsonb),
          'trolley_intake_count',coalesce(ti.intake_count,0),
          'trolley_intake_received',coalesce(ti.intake_count,0)>0,
          'trolley_intake_last_at',ti.last_at
        )
      else b.item end as item
    from base_items b
    left join lateral (
      select
        coalesce(sum(l.quantity) filter(where l.unit_code='KG'),0) kg,
        coalesce(sum(l.quantity) filter(where l.unit_code='UNIT'),0) units,
        count(distinct e.entry_group_id) contributions,
        max(e.recorded_at) last_at,
        coalesce(jsonb_agg(distinct e.table_code_snapshot),'[]'::jsonb) tables,
        coalesce((
          select jsonb_agg(distinct jsonb_build_object('trolley_code',ft.trolley_code_snapshot,'stay_id',ft.stay_id))
          from public.finish_production_entries ee
          join public.finish_production_trolleys ft on ft.finish_production_entry_id=ee.finish_production_entry_id
          where ee.status='ACTIVE'
            and ee.production_flow_item_id=nullif(b.item->>'production_flow_item_id','')::uuid
        ),'[]'::jsonb) trolleys
      from public.finish_production_entries e
      join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
      where e.status='ACTIVE'
        and e.production_flow_item_id=nullif(b.item->>'production_flow_item_id','')::uuid
    ) f on true
    left join lateral (
      select count(*)::integer intake_count,max(sti.arrived_at) last_at
      from public.sorting_trolley_intakes sti
      where sti.customer_id=nullif(b.item->>'customer_id','')::uuid
        and sti.scheduled_for_date=nullif(b.item->>'scheduled_for_date','')::date
        and upper(coalesce(sti.product_scope,''))='CLOTHES'
    ) ti on true
  )
  select coalesce(jsonb_agg(item order by ordinality),'[]'::jsonb) into v_items from enriched;

  return (v_base-'schema_version'-'source_contract'-'items') || jsonb_build_object(
    'schema_version','PRODUCTION_TRACKER_V4',
    'source_contract','PRODUCTION_FLOW_SHARED_TRACKER_V4',
    'finish_processed_actual_contract','FINISH_PRODUCTION_LEDGER',
    'items',v_items
  );
end;
$$;

revoke all on function public.get_production_tracker_v4(date) from public,anon;
grant execute on function public.get_production_tracker_v4(date) to authenticated;

comment on function public.get_production_tracker_v4(date) is
  'Shared Production Tracker V4 including Finish actuals and Clothes trolley-intake evidence for Finish queue status.';
