-- Complete the operational queue with the data needed to display future physical work.
create or replace function public.get_finish_operational_queue_context(
  p_shift_code text default 'MORNING',
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_business_date date;
  v_rows jsonb;
begin
  perform public.require_finish_production_access();
  v_business_date:=public.operational_business_date_for_shift(upper(trim(coalesce(p_shift_code,'MORNING'))));

  with candidate as (
    select
      pfi.production_flow_item_id,pfi.customer_name_snapshot,pfi.customer_code_snapshot,
      pfi.route_code_snapshot,pfi.route_display_name_snapshot,pfi.route_color_snapshot,pfi.production_order_snapshot,pfi.scheduled_for_date,
      public.next_distribution_business_date(pfi.scheduled_for_date) as delivery_date,
      pfi.washed_trace_count,pfi.washed_kg_total,
      coalesce(intake.intake_count,0) as trolley_intake_count,
      intake.last_at as trolley_intake_last_at,
      coalesce(finish_totals.processed_kg,0) as processed_kg,
      coalesce(finish_totals.processed_units,0) as processed_units,
      coalesce(finish_totals.contribution_count,0) as finish_contribution_count
    from public.production_flow_items pfi
    left join lateral (
      select count(*)::integer as intake_count,max(sti.arrived_at) as last_at
      from public.sorting_trolley_intakes sti
      where sti.customer_id=pfi.customer_id
        and sti.scheduled_for_date=pfi.scheduled_for_date
        and upper(coalesce(sti.product_scope,''))='CLOTHES'
    ) intake on true
    left join lateral (
      select
        coalesce(sum(line.quantity) filter(where line.unit_code='KG'),0) as processed_kg,
        coalesce(sum(line.quantity) filter(where line.unit_code='UNIT'),0) as processed_units,
        count(distinct entry.entry_group_id)::integer as contribution_count
      from public.finish_production_entries entry
      join public.finish_production_lines line on line.finish_production_entry_id=entry.finish_production_entry_id
      where entry.production_flow_item_id=pfi.production_flow_item_id
        and entry.status='ACTIVE'
    ) finish_totals on true
    where pfi.product_code='CLOTHES'
      and pfi.flow_status='OPEN'
      and pfi.scheduled_for_date>=v_business_date
  ), operational as (
    select *
    from candidate
    where scheduled_for_date=v_business_date
       or trolley_intake_count>0
       or washed_trace_count>0
       or finish_contribution_count>0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'production_flow_item_id',production_flow_item_id,
    'customer_name',customer_name_snapshot,
    'customer_code',customer_code_snapshot,
    'route_code',route_code_snapshot,
    'route_name',route_display_name_snapshot,
    'route_color',route_color_snapshot,
    'production_order',production_order_snapshot,
    'scheduled_for_date',scheduled_for_date,
    'delivery_date',delivery_date,
    'washed_trace_count',washed_trace_count,
    'washed_kg_total',washed_kg_total,
    'trolley_intake_count',trolley_intake_count,
    'trolley_intake_received',trolley_intake_count>0,
    'trolley_intake_last_at',trolley_intake_last_at,
    'processed_kg',processed_kg,
    'processed_units',processed_units,
    'finish_contribution_count',finish_contribution_count
  ) order by scheduled_for_date,production_flow_item_id),'[]'::jsonb)
  into v_rows
  from operational;

  return jsonb_build_object(
    'schema_version','FINISH_OPERATIONAL_QUEUE_V1',
    'business_date',v_business_date,
    'rows',v_rows
  );
end;
$$;

revoke all on function public.get_finish_operational_queue_context(text,timestamptz) from public,anon;
grant execute on function public.get_finish_operational_queue_context(text,timestamptz) to authenticated;
