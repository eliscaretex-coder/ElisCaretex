-- Delivery reconciliation is an operational acknowledgement, never Finish production.
-- It records a positive approximate quantity in the unit stated by the operator.

alter table public.finish_delivery_reconciliations
  add column if not exists approximate_processed_quantity numeric(12,2),
  add column if not exists approximate_processed_unit text;

update public.finish_delivery_reconciliations
set approximate_processed_quantity=approximate_processed_kg,
    approximate_processed_unit='KG'
where outcome_code='PROCESSED_CONFIRMED'
  and approximate_processed_quantity is null;

alter table public.finish_delivery_reconciliations
  drop constraint if exists finish_delivery_reconciliations_processed_ck;

alter table public.finish_delivery_reconciliations
  add constraint finish_delivery_reconciliations_processed_ck check (
    (
      outcome_code='PROCESSED_CONFIRMED'
      and approximate_processed_on is not null
      and approximate_processed_quantity is not null
      and approximate_processed_quantity>0
      and approximate_processed_unit in ('KG','UNIT')
      and resolved_at is not null
      and next_prompt_at is null
      and (
        (approximate_processed_unit='KG' and approximate_processed_kg=approximate_processed_quantity)
        or (approximate_processed_unit='UNIT' and approximate_processed_kg is null)
      )
    )
    or (
      outcome_code='NOT_PROCESSED'
      and approximate_processed_on is null
      and approximate_processed_kg is null
      and approximate_processed_quantity is null
      and approximate_processed_unit is null
      and resolved_at is null
      and next_prompt_at is not null
    )
  );

create or replace function public.resolve_finish_delivery_reconciliation_v2(
  p_production_flow_item_id uuid,
  p_outcome_code text,
  p_approximate_processed_on date default null,
  p_approximate_processed_quantity numeric default null,
  p_approximate_processed_unit text default null,
  p_batch_reference text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_now timestamptz:=now();
  v_local_date date:=(now() at time zone 'Europe/Dublin')::date;
  v_outcome text:=upper(trim(coalesce(p_outcome_code,'')));
  v_unit text:=upper(trim(coalesce(p_approximate_processed_unit,'')));
  v_flow public.production_flow_items%rowtype;
  v_delivery_date date;
  v_before jsonb;
  v_record public.finish_delivery_reconciliations%rowtype;
  v_batch text:=nullif(trim(coalesce(p_batch_reference,'')), '');
  v_notes text:=nullif(trim(coalesce(p_notes,'')), '');
  v_kg numeric(12,2);
begin
  perform public.require_finish_production_access();

  if p_production_flow_item_id is null then
    raise exception using errcode='22023',message='A Finish customer is required.';
  end if;
  if v_outcome not in ('PROCESSED_CONFIRMED','NOT_PROCESSED') then
    raise exception using errcode='22023',message='Choose whether the customer was processed.';
  end if;

  select * into v_flow
  from public.production_flow_items
  where production_flow_item_id=p_production_flow_item_id
  for update;
  if not found or v_flow.product_code<>'CLOTHES' then
    raise exception using errcode='22023',message='This Finish reconciliation customer was not found.';
  end if;

  v_delivery_date:=public.next_distribution_business_date(v_flow.scheduled_for_date);
  if v_delivery_date<>v_local_date or v_now<public.finish_delivery_cutoff(v_delivery_date) then
    raise exception using errcode='22023',message='Finish reconciliation is available only after 12:00 on the Delivery Date.';
  end if;
  if coalesce(v_flow.washed_trace_count,0)<=0 then
    raise exception using errcode='22023',message='Only a washed customer can be reconciled for Finish.';
  end if;
  if exists (
    select 1
    from public.finish_production_entries entry
    join public.finish_production_lines line on line.finish_production_entry_id=entry.finish_production_entry_id
    where entry.production_flow_item_id=v_flow.production_flow_item_id
      and entry.status='ACTIVE'
      and line.quantity>0
  ) then
    raise exception using errcode='22023',message='Finish production is already recorded for this customer.';
  end if;

  if v_outcome='PROCESSED_CONFIRMED' then
    if p_approximate_processed_on is null or p_approximate_processed_on>v_local_date then
      raise exception using errcode='22023',message='Enter an approximate processing date no later than today.';
    end if;
    if p_approximate_processed_quantity is null or p_approximate_processed_quantity<=0 then
      raise exception using errcode='22023',message='Enter an approximate processed quantity greater than zero.';
    end if;
    if v_unit not in ('KG','UNIT') then
      raise exception using errcode='22023',message='Choose KG or Units for the approximate processed quantity.';
    end if;
    v_kg:=case when v_unit='KG' then p_approximate_processed_quantity else null end;
  else
    p_approximate_processed_on:=null;
    p_approximate_processed_quantity:=null;
    v_unit:=null;
    v_kg:=null;
    v_batch:=null;
  end if;

  select to_jsonb(rec) into v_before
  from public.finish_delivery_reconciliations rec
  where rec.production_flow_item_id=v_flow.production_flow_item_id;

  insert into public.finish_delivery_reconciliations(
    production_flow_item_id,delivery_date,outcome_code,approximate_processed_on,approximate_processed_kg,
    approximate_processed_quantity,approximate_processed_unit,batch_reference,notes,
    acknowledged_at,next_prompt_at,resolved_at,recorded_by_auth_user_id,recorded_by_staff_id,updated_at,updated_by_auth_user_id
  ) values (
    v_flow.production_flow_item_id,v_delivery_date,v_outcome,p_approximate_processed_on,v_kg,
    p_approximate_processed_quantity,v_unit,v_batch,v_notes,v_now,
    case when v_outcome='NOT_PROCESSED' then v_now+interval '2 hours' else null end,
    case when v_outcome='PROCESSED_CONFIRMED' then v_now else null end,
    auth.uid(),public.current_staff_id(),v_now,auth.uid()
  )
  on conflict (production_flow_item_id) do update set
    delivery_date=excluded.delivery_date,
    outcome_code=excluded.outcome_code,
    approximate_processed_on=excluded.approximate_processed_on,
    approximate_processed_kg=excluded.approximate_processed_kg,
    approximate_processed_quantity=excluded.approximate_processed_quantity,
    approximate_processed_unit=excluded.approximate_processed_unit,
    batch_reference=excluded.batch_reference,
    notes=excluded.notes,
    acknowledged_at=excluded.acknowledged_at,
    next_prompt_at=excluded.next_prompt_at,
    resolved_at=excluded.resolved_at,
    updated_at=excluded.updated_at,
    updated_by_auth_user_id=excluded.updated_by_auth_user_id
  returning * into v_record;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application
  ) values (
    auth.uid(),public.current_staff_id(),
    case when v_outcome='PROCESSED_CONFIRMED' then 'FINISH_DELIVERY_PROCESSED_CONFIRMED' else 'FINISH_DELIVERY_NOT_PROCESSED_ACKNOWLEDGED' end,
    'finish_delivery_reconciliations',v_record.finish_delivery_reconciliation_id::text,
    v_before,to_jsonb(v_record),v_notes,'FINISH_DELIVERY_RECONCILIATION'
  );

  return jsonb_build_object(
    'finish_delivery_reconciliation_id',v_record.finish_delivery_reconciliation_id,
    'outcome_code',v_record.outcome_code,
    'next_prompt_at',v_record.next_prompt_at,
    'message',case when v_outcome='PROCESSED_CONFIRMED' then 'Approximate Finish processing was confirmed and the delivery check is closed.' else 'Not processed was acknowledged. This customer will block Finish again in two hours.' end
  );
end;
$$;

create or replace function public.terminal_resolve_finish_delivery_reconciliation_v2(
  p_production_flow_item_id uuid,
  p_outcome_code text,
  p_approximate_processed_on date default null,
  p_approximate_processed_quantity numeric default null,
  p_approximate_processed_unit text default null,
  p_batch_reference text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
begin
  perform public.require_production_terminal('FINISH');
  return public.resolve_finish_delivery_reconciliation_v2(
    p_production_flow_item_id,p_outcome_code,p_approximate_processed_on,
    p_approximate_processed_quantity,p_approximate_processed_unit,p_batch_reference,p_notes
  );
end;
$$;

revoke all on function public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text) from public,anon;
revoke all on function public.terminal_resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text) from public,anon;
grant execute on function public.resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text) to authenticated;
grant execute on function public.terminal_resolve_finish_delivery_reconciliation_v2(uuid,text,date,numeric,text,text,text) to authenticated;
