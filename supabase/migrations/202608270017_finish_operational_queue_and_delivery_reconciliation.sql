-- Finish operational queue: physical continuation plus delivery-day reconciliation.

create table if not exists public.finish_delivery_reconciliations (
  finish_delivery_reconciliation_id uuid primary key default gen_random_uuid(),
  production_flow_item_id uuid not null unique references public.production_flow_items(production_flow_item_id) on delete restrict,
  delivery_date date not null,
  outcome_code text not null check (outcome_code in ('PROCESSED_CONFIRMED','NOT_PROCESSED')),
  approximate_processed_on date,
  approximate_processed_kg numeric(12,2),
  batch_reference text,
  notes text,
  acknowledged_at timestamptz not null default now(),
  next_prompt_at timestamptz,
  resolved_at timestamptz,
  recorded_by_auth_user_id uuid references auth.users(id) on delete set null,
  recorded_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by_auth_user_id uuid references auth.users(id) on delete set null,
  constraint finish_delivery_reconciliations_kg_ck check (approximate_processed_kg is null or approximate_processed_kg > 0),
  constraint finish_delivery_reconciliations_processed_ck check (
    (outcome_code='PROCESSED_CONFIRMED' and approximate_processed_on is not null and approximate_processed_kg is not null and resolved_at is not null and next_prompt_at is null)
    or (outcome_code='NOT_PROCESSED' and approximate_processed_on is null and approximate_processed_kg is null and resolved_at is null and next_prompt_at is not null)
  )
);

create index if not exists finish_delivery_reconciliations_prompt_idx
  on public.finish_delivery_reconciliations(next_prompt_at)
  where outcome_code='NOT_PROCESSED';

alter table public.finish_delivery_reconciliations enable row level security;
revoke all on public.finish_delivery_reconciliations from public,anon,authenticated;

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
      pfi.production_flow_item_id,pfi.scheduled_for_date,
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
    left join public.finish_delivery_reconciliations rec on rec.production_flow_item_id=pfi.production_flow_item_id
    where pfi.product_code='CLOTHES'
      and pfi.flow_status='OPEN'
      and pfi.scheduled_for_date is not null
      and public.next_distribution_business_date(pfi.scheduled_for_date)=v_local_date
      and coalesce(pfi.washed_trace_count,0)>0
      and not exists (
        select 1
        from public.finish_production_entries entry
        join public.finish_production_lines line on line.finish_production_entry_id=entry.finish_production_entry_id
        where entry.production_flow_item_id=pfi.production_flow_item_id
          and entry.status='ACTIVE'
          and line.quantity>0
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
    'route_code',route_code_snapshot,
    'route_name',route_display_name_snapshot,
    'washed_kg_total',washed_kg_total,
    'washed_trace_count',washed_trace_count,
    'previous_outcome_code',outcome_code,
    'previous_acknowledged_at',acknowledged_at
  ) order by customer_name_snapshot),'[]'::jsonb)
  into v_items
  from due
  where v_now>=public.finish_delivery_cutoff(delivery_date);

  return jsonb_build_object(
    'schema_version','FINISH_DELIVERY_RECONCILIATION_V1',
    'local_date',v_local_date,
    'items',v_items
  );
end;
$$;

create or replace function public.resolve_finish_delivery_reconciliation_v1(
  p_production_flow_item_id uuid,
  p_outcome_code text,
  p_approximate_processed_on date default null,
  p_approximate_processed_kg numeric default null,
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
  v_flow public.production_flow_items%rowtype;
  v_delivery_date date;
  v_before jsonb;
  v_record public.finish_delivery_reconciliations%rowtype;
  v_batch text:=nullif(trim(coalesce(p_batch_reference,'')),'');
  v_notes text:=nullif(trim(coalesce(p_notes,'')),'');
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
    if p_approximate_processed_kg is null or p_approximate_processed_kg<=0 or p_approximate_processed_kg>10000 then
      raise exception using errcode='22023',message='Enter an approximate processed KG greater than zero.';
    end if;
  else
    p_approximate_processed_on:=null;
    p_approximate_processed_kg:=null;
    v_batch:=null;
  end if;

  select to_jsonb(rec) into v_before
  from public.finish_delivery_reconciliations rec
  where rec.production_flow_item_id=v_flow.production_flow_item_id;

  insert into public.finish_delivery_reconciliations(
    production_flow_item_id,delivery_date,outcome_code,approximate_processed_on,approximate_processed_kg,
    batch_reference,notes,acknowledged_at,next_prompt_at,resolved_at,
    recorded_by_auth_user_id,recorded_by_staff_id,updated_at,updated_by_auth_user_id
  ) values (
    v_flow.production_flow_item_id,v_delivery_date,v_outcome,p_approximate_processed_on,p_approximate_processed_kg,
    v_batch,v_notes,v_now,
    case when v_outcome='NOT_PROCESSED' then v_now+interval '2 hours' else null end,
    case when v_outcome='PROCESSED_CONFIRMED' then v_now else null end,
    auth.uid(),public.current_staff_id(),v_now,auth.uid()
  )
  on conflict (production_flow_item_id) do update set
    delivery_date=excluded.delivery_date,
    outcome_code=excluded.outcome_code,
    approximate_processed_on=excluded.approximate_processed_on,
    approximate_processed_kg=excluded.approximate_processed_kg,
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

create or replace function public.terminal_resolve_finish_delivery_reconciliation_v1(
  p_production_flow_item_id uuid,
  p_outcome_code text,
  p_approximate_processed_on date default null,
  p_approximate_processed_kg numeric default null,
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
  return public.resolve_finish_delivery_reconciliation_v1(
    p_production_flow_item_id,p_outcome_code,p_approximate_processed_on,
    p_approximate_processed_kg,p_batch_reference,p_notes
  );
end;
$$;

revoke all on function public.get_finish_operational_queue_context(text,timestamptz) from public,anon;
revoke all on function public.get_finish_delivery_reconciliation_context(timestamptz) from public,anon;
revoke all on function public.resolve_finish_delivery_reconciliation_v1(uuid,text,date,numeric,text,text) from public,anon;
revoke all on function public.terminal_resolve_finish_delivery_reconciliation_v1(uuid,text,date,numeric,text,text) from public,anon;
grant execute on function public.get_finish_operational_queue_context(text,timestamptz) to authenticated;
grant execute on function public.get_finish_delivery_reconciliation_context(timestamptz) to authenticated;
grant execute on function public.resolve_finish_delivery_reconciliation_v1(uuid,text,date,numeric,text,text) to authenticated;
grant execute on function public.terminal_resolve_finish_delivery_reconciliation_v1(uuid,text,date,numeric,text,text) to authenticated;
