-- A delivery check marked as NOT_PROCESSED is a reminder, not a permanent
-- lock. When the customer is actually processed later, the normal Finish
-- ledger remains the authoritative production evidence for that real day.

create or replace function public.finish_assert_entry_open(
  p_flow_id uuid,
  p_at timestamptz default now()
)
returns table(delivery_date date, edit_cutoff_at timestamptz)
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_not_processed_acknowledged boolean:=false;
begin
  select * into v_flow
  from public.production_flow_items
  where production_flow_item_id=p_flow_id;

  if not found or v_flow.product_code<>'CLOTHES' or v_flow.scheduled_for_date is null then
    raise exception using errcode='22023', message='A scheduled Clothes customer is required for Finish production.';
  end if;

  delivery_date:=public.next_distribution_business_date(v_flow.scheduled_for_date);
  edit_cutoff_at:=public.finish_delivery_cutoff(delivery_date);

  if coalesce(p_at,now())>=edit_cutoff_at then
    select exists(
      select 1
      from public.finish_delivery_reconciliations rec
      where rec.production_flow_item_id=v_flow.production_flow_item_id
        and rec.outcome_code='NOT_PROCESSED'
        and rec.resolved_at is null
    ) into v_not_processed_acknowledged;

    if not v_not_processed_acknowledged then
      raise exception using errcode='23514', message=format('Finish production is locked from 12:00 on Delivery Date %s.',to_char(delivery_date,'DD Mon YYYY'));
    end if;
  end if;

  return next;
end;
$$;

revoke all on function public.finish_assert_entry_open(uuid,timestamptz) from public,anon,authenticated;

grant execute on function public.finish_assert_entry_open(uuid,timestamptz) to authenticated;

comment on function public.finish_assert_entry_open(uuid,timestamptz) is
  'Enforces the Finish delivery cutoff, while allowing a late real production record only after the delivery check explicitly acknowledged NOT_PROCESSED.';
