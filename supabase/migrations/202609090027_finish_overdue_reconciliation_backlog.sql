-- A missed Finish record can be found after its original Delivery Date.
-- It must be reconciled rather than silently remaining in the physical queue.

create or replace function public.get_finish_delivery_reconciliation_context(
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_now timestamptz:=coalesce(p_at,now());
  v_local_date date:=(coalesce(p_at,now()) at time zone 'Europe/Dublin')::date;
  v_items jsonb;
begin
  perform public.require_finish_production_access();

  with due as (
    select
      pfi.production_flow_item_id,pfi.customer_name_snapshot,pfi.customer_code_snapshot,
      pfi.scheduled_for_date,pfi.route_code_snapshot,pfi.route_display_name_snapshot,
      pfi.washed_kg_total,pfi.washed_trace_count,
      public.next_distribution_business_date(pfi.scheduled_for_date) as delivery_date,
      rec.outcome_code,rec.next_prompt_at,rec.acknowledged_at
    from public.production_flow_items pfi
    left join public.finish_delivery_reconciliations rec
      on rec.production_flow_item_id=pfi.production_flow_item_id
    where pfi.product_code='CLOTHES'
      and pfi.flow_status='OPEN'
      and pfi.scheduled_for_date is not null
      and coalesce(pfi.washed_trace_count,0)>0
      and public.next_distribution_business_date(pfi.scheduled_for_date)<=v_local_date
      and v_now>=public.finish_delivery_cutoff(public.next_distribution_business_date(pfi.scheduled_for_date))
      and not exists (
        select 1
        from public.finish_production_entries entry
        join public.finish_production_lines line on line.finish_production_entry_id=entry.finish_production_entry_id
        where entry.production_flow_item_id=pfi.production_flow_item_id
          and entry.status='ACTIVE' and line.quantity>0
      )
      and coalesce(rec.outcome_code,'')<>'PROCESSED_CONFIRMED'
      and (rec.next_prompt_at is null or rec.next_prompt_at<=v_now)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'production_flow_item_id',production_flow_item_id,
    'customer_name',customer_name_snapshot,
    'customer_code',customer_code_snapshot,
    'scheduled_for_date',scheduled_for_date,
    'delivery_date',delivery_date,
    'overdue_days',greatest(v_local_date-delivery_date,0),
    'route_code',route_code_snapshot,
    'route_name',route_display_name_snapshot,
    'washed_kg_total',washed_kg_total,
    'washed_trace_count',washed_trace_count,
    'previous_outcome_code',outcome_code,
    'previous_acknowledged_at',acknowledged_at
  ) order by delivery_date,scheduled_for_date,customer_name_snapshot),'[]'::jsonb)
  into v_items
  from due;

  return jsonb_build_object(
    'schema_version','FINISH_DELIVERY_RECONCILIATION_V1',
    'local_date',v_local_date,
    'pending_count',jsonb_array_length(v_items),
    'items',v_items
  );
end;
$$;

-- Preserve the existing validated reconciliation flow, but permit it to resolve
-- an overdue customer as well as one whose deadline passed today.
do $$
declare
  v_definition text;
  v_old_guard constant text:='if v_delivery_date<>v_local_date or v_now<public.finish_delivery_cutoff(v_delivery_date) then';
  v_new_guard constant text:='if v_delivery_date>v_local_date or v_now<public.finish_delivery_cutoff(v_delivery_date) then';
begin
  select pg_get_functiondef('public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text)'::regprocedure)
  into v_definition;
  if position(v_old_guard in v_definition)=0 then
    raise exception 'Expected Finish delivery reconciliation guard was not found.';
  end if;
  execute replace(v_definition,v_old_guard,v_new_guard);
end;
$$;

revoke all on function public.get_finish_delivery_reconciliation_context(timestamptz) from public,anon;
revoke all on function public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text) from public,anon;
grant execute on function public.get_finish_delivery_reconciliation_context(timestamptz) to authenticated;
grant execute on function public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text) to authenticated;

comment on function public.get_finish_delivery_reconciliation_context(timestamptz) is
  'Returns every washed Clothes customer past its Delivery Date noon cutoff until a real Finish record or controlled reconciliation resolves it.';
