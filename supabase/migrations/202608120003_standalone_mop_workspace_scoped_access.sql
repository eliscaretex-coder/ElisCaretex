-- ElisCaretex V2
-- Migration 039: standalone MOP Production workspace and scoped MOP_OPERATOR backend access.
-- Date: 2026-08-12
-- Owner-run SQL.
--
-- Security contract:
-- - MOP_OPERATOR may execute the existing MOP Production RPC family.
-- - MOP_OPERATOR does NOT gain direct Sorting/Washing/Staff/Trolley Intake access.
-- - A transaction-local internal scope is set only inside authorized MOP RPCs so
--   existing Sorting staff-resolution helpers can be reused without widening them.

begin;

create or replace function public.begin_mop_operational_scope()
returns void
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
begin
  if auth.uid() is null
     or public.current_staff_id() is null
     or not public.has_any_role(array[
       'ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR','MOP_OPERATOR'
     ]) then
    raise exception using
      errcode='42501',
      message='Your active role does not allow access to MOP Production.';
  end if;

  perform set_config('eliscaretex.mop_operational_scope','on',true);
end;
$$;

revoke all on function public.begin_mop_operational_scope() from public,anon,authenticated;

create or replace function public.require_sorting_operational_access()
returns void
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
begin
  if public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','SORTING_OPERATOR']) then
    return;
  end if;

  if current_setting('eliscaretex.mop_operational_scope',true)='on'
     and public.has_any_role(array['MOP_OPERATOR']) then
    return;
  end if;

  raise exception using
    errcode='42501',
    message='Your active role does not allow access to Sorting Area.';
end;
$$;

-- Standalone MOP page needs the same Auto Shift calculation without exposing
-- the Sorting Auto Shift RPC directly to MOP_OPERATOR.
create or replace function public.get_mop_auto_shift_context(
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
begin
  perform public.begin_mop_operational_scope();
  return public.get_sorting_auto_shift_context(p_at);
end;
$$;

revoke all on function public.get_mop_auto_shift_context(timestamptz) from public,anon,authenticated;
grant execute on function public.get_mop_auto_shift_context(timestamptz) to authenticated;

create or replace function public.get_sorting_mop_production_context(
  p_shift_code text default 'MORNING',
  p_at timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_now timestamptz := coalesce(p_at,now());
  v_local timestamp;
  v_local_date date;
  v_local_time time;
  v_cfg jsonb := public.sorting_mop_reconciliation_config();
  v_cutoff time;
  v_enforcement_from date;
  v_queue jsonb := '[]'::jsonb;
  v_recent jsonb := '[]'::jsonb;
  v_staff_ctx jsonb;
  v_mop_staff_id uuid;
  v_mop_staff_name text;
  v_overdue integer:=0;
  v_due_soon integer:=0;
begin
  perform public.begin_mop_operational_scope();
  v_local:=v_now at time zone coalesce(nullif(v_cfg->>'timezone',''),'Europe/Dublin');
  v_local_date:=v_local::date;
  v_local_time:=v_local::time;
  v_cutoff:=coalesce(nullif(v_cfg->>'cutoff_local_time','')::time,time '12:00');
  v_enforcement_from:=coalesce(nullif(v_cfg->>'enforcement_from','')::date,v_local_date);
  v_staff_ctx:=public.get_sorting_staff_dashboard_context_v2(p_shift_code);
  v_mop_staff_id:=nullif(v_staff_ctx->>'operational_mop_staff_id','')::uuid;
  v_mop_staff_name:=v_staff_ctx->>'operational_mop_staff_name';

  with candidate as (
    select
      pfi.production_flow_item_id,pfi.flow_code,pfi.customer_id,
      pfi.customer_code_snapshot,pfi.customer_name_snapshot as customer_name,
      pfi.scheduled_for_date,pfi.opened_business_date,
      public.next_distribution_business_date(coalesce(pfi.scheduled_for_date,pfi.opened_business_date)) as delivery_due_date,
      pfi.source_schedule_product_id,pfi.production_order_snapshot as production_order,
      pfi.route_code_snapshot as route_code,pfi.route_display_name_snapshot as route_display_name,
      pfi.route_color_snapshot as route_color,pfi.washed_kg_total,pfi.washed_load_count,pfi.washed_trace_count,pfi.last_wash_at,
      sp.production_instructions,
      coalesce(treq.planned_qty,0) as planned_output_trolley_quantity,
      coalesce(treq.requirements,'[]'::jsonb) as output_trolley_requirements,
      coalesce(models.models,'[]'::jsonb) as models,
      rec.decision as latest_reconciliation_decision,
      rec.reason as latest_reconciliation_reason,
      rec.recorded_at as latest_reconciliation_at
    from public.production_flow_items pfi
    left join public.customer_schedule_products sp on sp.schedule_product_id=pfi.source_schedule_product_id
    left join lateral (
      select
        coalesce(sum(req.quantity),0)::integer as planned_qty,
        coalesce(jsonb_agg(jsonb_build_object(
          'trolley_type_id',req.trolley_type_id,
          'trolley_type_code',tt.trolley_type_code,
          'display_code',tt.display_code,
          'trolley_type_name',tt.trolley_type_name,
          'quantity',req.quantity,
          'empty_trolley',req.empty_trolley
        ) order by tt.sort_order,tt.display_code,tt.trolley_type_code),'[]'::jsonb) as requirements
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt on tt.trolley_type_id=req.trolley_type_id and tt.active=true and tt.deleted_at is null
      where req.owner_schedule_product_id=pfi.source_schedule_product_id and req.active=true
    ) treq on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product_variant_id',pv.product_variant_id,
        'variant_code',pv.variant_code,
        'display_name',pv.display_name,
        'unit_weight_grams',case
          when coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
            then coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams')::numeric
          else null end,
        'image_url',nullif(coalesce(pv.metadata->>'image_url',pv.metadata->>'photo_url',''),''),
        'notes',nullif(coalesce(pv.metadata->>'notes',''),''),
        'sort_order',pv.sort_order
      ) order by pv.sort_order,pv.display_name),'[]'::jsonb) as models
      from public.customer_schedule_product_variants spv
      join public.product_variants pv
        on pv.product_variant_id=spv.product_variant_id
       and pv.active=true and pv.deleted_at is null
      where spv.schedule_product_id=pfi.source_schedule_product_id
    ) models on true
    left join lateral (
      select r.decision,r.reason,r.recorded_at
      from public.sorting_mop_reconciliations r
      where r.production_flow_item_id=pfi.production_flow_item_id
      order by r.recorded_at desc limit 1
    ) rec on true
    where pfi.product_code='MOP'
      and pfi.flow_status='OPEN'
      and pfi.washed_trace_count>0
      and coalesce(pfi.scheduled_for_date,pfi.opened_business_date)>=v_enforcement_from
      and not exists(
        select 1 from public.sorting_mop_production_batches mb
        where mb.production_flow_item_id=pfi.production_flow_item_id and mb.status='RECORDED'
      )
  ), classified as (
    select c.*,
      (c.planned_output_trolley_quantity>0) as output_trolley_required,
      case
        when c.latest_reconciliation_decision='NOT_PROCESSED' then 'NOT_PROCESSED_CONFIRMED'
        when c.delivery_due_date<v_local_date
          or (c.delivery_due_date=v_local_date and v_local_time>=v_cutoff)
          then 'RECONCILIATION_REQUIRED'
        when c.delivery_due_date=v_local_date and v_local_time<v_cutoff then 'DUE_BY_NOON'
        else 'READY'
      end as production_status
    from candidate c
  )
  select coalesce(jsonb_agg(to_jsonb(c) order by
    case c.production_status when 'RECONCILIATION_REQUIRED' then 0 when 'DUE_BY_NOON' then 1 when 'NOT_PROCESSED_CONFIRMED' then 2 else 3 end,
    c.delivery_due_date,c.production_order nulls last,lower(c.customer_name)
  ),'[]'::jsonb),
  count(*) filter(where c.production_status='RECONCILIATION_REQUIRED')::integer,
  count(*) filter(where c.production_status='DUE_BY_NOON')::integer
  into v_queue,v_overdue,v_due_soon
  from classified c;

  select coalesce(jsonb_agg(jsonb_build_object(
    'mop_production_batch_id',mb.mop_production_batch_id,
    'production_flow_item_id',mb.production_flow_item_id,
    'customer_id',mb.customer_id,
    'customer_name',mb.customer_name_snapshot,
    'business_date',mb.business_date,
    'scheduled_for_date',mb.scheduled_for_date,
    'delivery_due_date',mb.delivery_due_date,
    'operator_staff_id',mb.operator_staff_id,
    'operator_name',sm.display_name,
    'entry_mode',mb.entry_mode,
    'physical_processed_on',mb.physical_processed_on,
    'physical_processed_time',mb.physical_processed_time,
    'total_kg',mb.total_weight_kg,
    'total_units',mb.total_units,
    'trolley_capture_status',mb.trolley_capture_status,
    'trolley_codes',coalesce((select jsonb_agg(mt.trolley_code_snapshot order by mt.created_at) from public.sorting_mop_production_trolleys mt where mt.mop_production_batch_id=mb.mop_production_batch_id),'[]'::jsonb),
    'lines',coalesce((select jsonb_agg(jsonb_build_object(
      'variant_code',ml.variant_code_snapshot,'variant_name',ml.variant_name_snapshot,
      'weight_kg',ml.weight_kg,'units',ml.units,'unit_weight_grams',ml.unit_weight_grams_snapshot
    ) order by ml.created_at) from public.sorting_mop_production_lines ml where ml.mop_production_batch_id=mb.mop_production_batch_id),'[]'::jsonb),
    'recorded_at',mb.recorded_at,
    'notes',mb.notes
  ) order by mb.recorded_at desc),'[]'::jsonb)
  into v_recent
  from (
    select * from public.sorting_mop_production_batches
    where status='RECORDED'
    order by recorded_at desc limit 20
  ) mb
  left join public.staff_members sm on sm.staff_id=mb.operator_staff_id;

  return jsonb_build_object(
    'business_date',v_business_date,
    'shift_code',upper(trim(p_shift_code)),
    'generated_at',v_now,
    'local_now',v_local,
    'cutoff_local_time',v_cutoff,
    'enforcement_from',v_enforcement_from,
    'operational_mop_staff_id',v_mop_staff_id,
    'operational_mop_staff_name',v_mop_staff_name,
    'operational_mop_coverage',v_staff_ctx->>'operational_mop_coverage',
    'queue',v_queue,
    'overdue_unresolved_count',v_overdue,
    'due_today_before_cutoff_count',v_due_soon,
    'reconciliation_blocked',v_overdue>0,
    'recent_production',v_recent,
    'source','PRODUCTION_FLOW_WASHED_MOP_PLUS_MOP_PRODUCTION'
  );
end;
$$;


create or replace function public.record_sorting_mop_reconciliation(
  p_shift_code text,
  p_production_flow_item_id uuid,
  p_operator_staff_id uuid,
  p_decision text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,'')));
  v_cfg jsonb:=public.sorting_mop_reconciliation_config();
  v_local timestamp;
  v_cutoff time;
  v_enforcement date;
  v_due date;
  v_rec public.sorting_mop_reconciliations%rowtype;
  v_actor_staff_id uuid:=public.current_staff_id();
begin
  perform public.begin_mop_operational_scope();
  perform public.sorting_assert_current_mop_staff(p_shift_code,p_operator_staff_id);
  if v_decision<>'NOT_PROCESSED' then
    raise exception using errcode='22023', message='This RPC records only the NOT_PROCESSED delivery-day decision.';
  end if;
  if length(trim(coalesce(p_reason,'')))<3 then
    raise exception using errcode='22023', message='A short reason is required.';
  end if;

  select * into v_flow from public.production_flow_items
  where production_flow_item_id=p_production_flow_item_id for update;
  if not found or v_flow.product_code<>'MOP' or v_flow.washed_trace_count<=0 then
    raise exception using errcode='22023', message='Only a washed MOP Production Flow item can be reconciled.';
  end if;
  if exists(select 1 from public.sorting_mop_production_batches mb where mb.production_flow_item_id=v_flow.production_flow_item_id and mb.status='RECORDED') then
    raise exception using errcode='23505', message='MOP production is already recorded for this item.';
  end if;

  v_local:=now() at time zone coalesce(nullif(v_cfg->>'timezone',''),'Europe/Dublin');
  v_cutoff:=coalesce(nullif(v_cfg->>'cutoff_local_time','')::time,time '12:00');
  v_enforcement:=coalesce(nullif(v_cfg->>'enforcement_from','')::date,v_local::date);
  v_due:=public.next_distribution_business_date(coalesce(v_flow.scheduled_for_date,v_flow.opened_business_date));
  if coalesce(v_flow.scheduled_for_date,v_flow.opened_business_date)<v_enforcement
     or v_local < (v_due+v_cutoff) then
    raise exception using errcode='22023', message='Delivery-day reconciliation is not due yet.';
  end if;

  select * into v_rec from public.sorting_mop_reconciliations r
  where r.production_flow_item_id=v_flow.production_flow_item_id and r.decision='NOT_PROCESSED'
  limit 1;
  if found then
    return jsonb_build_object('mop_reconciliation_id',v_rec.mop_reconciliation_id,'decision',v_rec.decision,'already_recorded',true,'message','Not processed was already confirmed for this MOP item.');
  end if;

  insert into public.sorting_mop_reconciliations(
    production_flow_item_id,delivery_due_date,decision,reason,operator_staff_id,
    recorded_by_staff_id,recorded_by_auth_user_id
  ) values (
    v_flow.production_flow_item_id,v_due,'NOT_PROCESSED',trim(p_reason),p_operator_staff_id,
    v_actor_staff_id,auth.uid()
  ) returning * into v_rec;

  perform public.append_production_flow_event(
    v_flow.production_flow_item_id,'MOP_NOT_PROCESSED_CONFIRMED','WASHING',30,'MOP',
    public.operational_business_date_for_shift(p_shift_code),now(),p_operator_staff_id,
    v_actor_staff_id,auth.uid(),'SORTING_MOP_PRODUCTION','sorting_mop_reconciliations',
    v_rec.mop_reconciliation_id::text,
    jsonb_build_object('delivery_due_date',v_due,'decision','NOT_PROCESSED','reason',trim(p_reason))
  );

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application)
  values(auth.uid(),v_actor_staff_id,'MOP_DELIVERY_RECONCILIATION_NOT_PROCESSED','sorting_mop_reconciliations',v_rec.mop_reconciliation_id::text,to_jsonb(v_rec),p_reason,'SORTING_MOP_PRODUCTION');

  return jsonb_build_object('mop_reconciliation_id',v_rec.mop_reconciliation_id,'decision','NOT_PROCESSED','delivery_due_date',v_due,'message','Not processed confirmed. The customer remains outstanding in the MOP queue.');
end;
$$;


create or replace function public.save_sorting_mop_production(
  p_shift_code text,
  p_production_flow_item_id uuid,
  p_operator_staff_id uuid,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_trolley_unknown boolean default false,
  p_physical_processed_on date default null,
  p_physical_processed_time time default null,
  p_entry_mode text default 'LIVE',
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_entry_mode text:=upper(trim(coalesce(p_entry_mode,'LIVE')));
  v_business_date date:=public.operational_business_date_for_shift(p_shift_code);
  v_shift record;
  v_actor_staff_id uuid:=public.current_staff_id();
  v_cfg jsonb:=public.sorting_mop_reconciliation_config();
  v_local timestamp;
  v_cutoff time;
  v_enforcement date;
  v_due date;
  v_base_date date;
  v_first_wash_date date;
  v_prior_not_processed boolean:=false;
  v_other_overdue integer:=0;
  v_batch public.sorting_mop_production_batches%rowtype;
  v_line record;
  v_variant uuid;
  v_variant_code text;
  v_variant_name text;
  v_kg numeric;
  v_units integer;
  v_unit_grams numeric;
  v_total_kg numeric:=0;
  v_total_units integer:=0;
  v_line_count integer:=0;
  v_planned_trolley_qty integer:=0;
  v_trolley_codes text[]:=array[]::text[];
  v_code text;
  v_assign jsonb;
  v_trolley_status text;
  v_recorded_on date;
  v_recorded_time time;
  v_event_type text;
begin
  perform public.begin_mop_operational_scope();
  perform public.sorting_assert_current_mop_staff(p_shift_code,p_operator_staff_id);

  if v_entry_mode not in ('LIVE','LATE_RECONCILIATION') then
    raise exception using errcode='22023', message='Entry mode must be LIVE or LATE_RECONCILIATION.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then
    raise exception using errcode='22023', message='Enter KG or Units for at least one MOP type.';
  end if;

  select * into v_shift from public.shifts sh
  where sh.shift_code=upper(trim(coalesce(p_shift_code,''))) and sh.active=true and sh.deleted_at is null limit 1;
  if v_shift.shift_id is null then raise exception using errcode='P0002', message='Selected shift is not available.'; end if;

  select * into v_flow from public.production_flow_items
  where production_flow_item_id=p_production_flow_item_id for update;
  if not found or v_flow.product_code<>'MOP' then
    raise exception using errcode='P0002', message='MOP Production Flow item was not found.';
  end if;
  if v_flow.washed_trace_count<=0 or v_flow.washed_load_count<=0 then
    raise exception using errcode='22023', message='MOP Production is locked until this exact Production Flow item has recorded Washing.';
  end if;
  if exists(select 1 from public.sorting_mop_production_batches mb where mb.production_flow_item_id=v_flow.production_flow_item_id and mb.status='RECORDED') then
    raise exception using errcode='23505', message='MOP production is already recorded for this washed item.';
  end if;

  v_local:=now() at time zone coalesce(nullif(v_cfg->>'timezone',''),'Europe/Dublin');
  v_cutoff:=coalesce(nullif(v_cfg->>'cutoff_local_time','')::time,time '12:00');
  v_enforcement:=coalesce(nullif(v_cfg->>'enforcement_from','')::date,v_local::date);
  v_base_date:=coalesce(v_flow.scheduled_for_date,v_flow.opened_business_date);
  v_due:=public.next_distribution_business_date(v_base_date);

  select exists(select 1 from public.sorting_mop_reconciliations r where r.production_flow_item_id=v_flow.production_flow_item_id and r.decision='NOT_PROCESSED') into v_prior_not_processed;

  select count(*)::integer into v_other_overdue
  from public.production_flow_items q
  where q.product_code='MOP' and q.flow_status='OPEN' and q.washed_trace_count>0
    and coalesce(q.scheduled_for_date,q.opened_business_date)>=v_enforcement
    and q.production_flow_item_id<>v_flow.production_flow_item_id
    and (v_local >= (public.next_distribution_business_date(coalesce(q.scheduled_for_date,q.opened_business_date))+v_cutoff))
    and not exists(select 1 from public.sorting_mop_production_batches mb where mb.production_flow_item_id=q.production_flow_item_id and mb.status='RECORDED')
    and not exists(select 1 from public.sorting_mop_reconciliations r where r.production_flow_item_id=q.production_flow_item_id and r.decision='NOT_PROCESSED');
  -- The current overdue item must be allowed to resolve itself through
  -- LATE_RECONCILIATION. Only normal LIVE production is blocked by other
  -- unresolved overdue confirmations. This avoids a deadlock where every
  -- overdue item is prevented from recording its own missed production.
  if v_base_date>=v_enforcement and v_local >= (v_due+v_cutoff)
     and not v_prior_not_processed and v_entry_mode='LIVE' then
    raise exception using errcode='22023', message='This delivery-day MOP item requires reconciliation. Choose Already processed — missed entry or Not processed.';
  end if;

  if v_entry_mode='LIVE' and v_other_overdue>0 then
    raise exception using errcode='22023', message=format('Resolve %s overdue MOP delivery-day confirmation(s) before recording another MOP customer.',v_other_overdue);
  end if;

  select min((wr.started_at at time zone 'Europe/Dublin')::date)
  into v_first_wash_date
  from public.sorting_wash_run_customers wrc
  join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id and wr.status='RECORDED'
  where wrc.production_flow_item_id=v_flow.production_flow_item_id;

  if v_entry_mode='LATE_RECONCILIATION' then
    if length(trim(coalesce(p_notes,'')))<3 then
      raise exception using errcode='22023', message='A short missed-entry reason is required for late MOP production.';
    end if;
    if p_physical_processed_on is null then
      raise exception using errcode='22023', message='Processed-on date is required for a missed MOP entry.';
    end if;
    if p_physical_processed_on>v_local::date then
      raise exception using errcode='22023', message='Processed-on date cannot be in the future.';
    end if;
    if v_first_wash_date is not null and p_physical_processed_on<v_first_wash_date then
      raise exception using errcode='22023', message='MOP processing date cannot be before its recorded Washing date.';
    end if;
    v_recorded_on:=p_physical_processed_on;
    v_recorded_time:=p_physical_processed_time;
  else
    v_recorded_on:=v_local::date;
    v_recorded_time:=v_local::time;
  end if;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_variant:=nullif(v_line.value->>'product_variant_id','')::uuid;

    -- Variant identity, name and unit conversion come from master data, never
    -- from browser-provided labels/weights. A generic MOP total line is allowed
    -- only when no concrete variant is supplied.
    if v_variant is not null then
      select
        pv.variant_code,
        pv.display_name,
        case
          when coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
            then coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams')::numeric
          else null
        end
      into v_variant_code,v_variant_name,v_unit_grams
      from public.product_variants pv
      join public.product_types pt
        on pt.product_type_id=pv.product_type_id
       and pt.active=true and pt.deleted_at is null and pt.product_code='MOP'
      where pv.product_variant_id=v_variant
        and pv.active=true and pv.deleted_at is null;

      if not found then
        raise exception using errcode='22023', message='Selected MOP variant is not active MOP master data.';
      end if;
      if v_flow.source_schedule_product_id is not null and not exists(
        select 1 from public.customer_schedule_product_variants spv
        where spv.schedule_product_id=v_flow.source_schedule_product_id
          and spv.product_variant_id=v_variant
      ) then
        raise exception using errcode='22023', message=format('MOP variant %s is not linked to this published Customer Schedule product.',v_variant_name);
      end if;
    else
      v_variant_code:='MOP_TOTAL';
      v_variant_name:='MOP total';
      v_unit_grams:=null;
    end if;

    v_kg:=case when coalesce(v_line.value->>'weight_kg','') ~ '^[0-9]+([.][0-9]+)?$' then (v_line.value->>'weight_kg')::numeric else 0 end;
    v_units:=case when coalesce(v_line.value->>'units','') ~ '^[0-9]+$' then (v_line.value->>'units')::integer else 0 end;
    if v_kg<=0 and v_units>0 and coalesce(v_unit_grams,0)>0 then v_kg:=round((v_units*v_unit_grams/1000.0)::numeric,3); end if;
    if v_units<=0 and v_kg>0 and coalesce(v_unit_grams,0)>0 then v_units:=round(v_kg*1000.0/v_unit_grams)::integer; end if;
    if v_kg<=0 and v_units<=0 then continue; end if;
    v_total_kg:=v_total_kg+greatest(v_kg,0);
    v_total_units:=v_total_units+greatest(v_units,0);
    v_line_count:=v_line_count+1;
  end loop;
  if v_line_count=0 or (v_total_kg<=0 and v_total_units<=0) then
    raise exception using errcode='22023', message='Enter KG or Units for at least one MOP type.';
  end if;

  if v_flow.source_schedule_product_id is not null then
    select coalesce(sum(req.quantity),0)::integer into v_planned_trolley_qty
    from public.customer_schedule_trolley_requirements req
    where req.owner_schedule_product_id=v_flow.source_schedule_product_id and req.active=true;
  end if;

  select coalesce(array_agg(code order by code),array[]::text[]) into v_trolley_codes
  from (
    select distinct upper(trim(x)) as code
    from unnest(coalesce(p_trolley_codes,array[]::text[])) x
    where nullif(trim(x),'') is not null
  ) q;

  if exists(select 1 from unnest(v_trolley_codes) x where x !~ '^T[0-9]{1,10}T$') then
    raise exception using errcode='22023', message='Invalid trolley code in MOP Production.';
  end if;

  if p_trolley_unknown and v_entry_mode<>'LATE_RECONCILIATION' then
    raise exception using errcode='22023', message='Unknown trolley is allowed only for a late reconciliation entry.';
  end if;
  if p_trolley_unknown and cardinality(v_trolley_codes)>0 then
    raise exception using errcode='22023', message='Choose either known trolley codes or Trolley number no longer available, not both.';
  end if;

  if v_entry_mode='LATE_RECONCILIATION' then
    if p_trolley_unknown and v_planned_trolley_qty>0 then v_trolley_status:='UNKNOWN_LATE_ENTRY';
    elsif cardinality(v_trolley_codes)>0 then v_trolley_status:='LATE_RECORDED_CODE';
    elsif v_planned_trolley_qty=0 then v_trolley_status:='NOT_REQUIRED';
    else v_trolley_status:='UNKNOWN_LATE_ENTRY'; end if;
  else
    if v_planned_trolley_qty=0 and cardinality(v_trolley_codes)=0 then v_trolley_status:='NOT_REQUIRED';
    elsif v_planned_trolley_qty=0 and cardinality(v_trolley_codes)>0 then v_trolley_status:='UNPLANNED_RECORDED';
    elsif cardinality(v_trolley_codes)=v_planned_trolley_qty then v_trolley_status:='RECORDED';
    elsif cardinality(v_trolley_codes)>0 then v_trolley_status:='RECORDED_MISMATCH';
    else raise exception using errcode='22023', message='Scan the clean trolley used for this MOP customer before saving.'; end if;
  end if;

  insert into public.sorting_mop_production_batches(
    production_flow_item_id,customer_id,customer_code_snapshot,customer_name_snapshot,
    business_date,shift_id,shift_code_snapshot,scheduled_for_date,delivery_due_date,
    operator_staff_id,entry_mode,physical_processed_on,physical_processed_time,physical_time_precision,
    total_weight_kg,total_units,trolley_capture_status,planned_output_trolley_quantity,
    recorded_by_staff_id,recorded_by_auth_user_id,notes
  ) values (
    v_flow.production_flow_item_id,v_flow.customer_id,v_flow.customer_code_snapshot,v_flow.customer_name_snapshot,
    v_business_date,v_shift.shift_id,v_shift.shift_code,v_flow.scheduled_for_date,v_due,
    p_operator_staff_id,v_entry_mode,v_recorded_on,v_recorded_time,case when v_recorded_time is null then 'DATE_ONLY' else 'EXACT' end,
    round(v_total_kg,3),v_total_units,v_trolley_status,v_planned_trolley_qty,
    v_actor_staff_id,auth.uid(),nullif(trim(coalesce(p_notes,'')),'')
  ) returning * into v_batch;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_variant:=nullif(v_line.value->>'product_variant_id','')::uuid;
    if v_variant is not null then
      select
        pv.variant_code,
        pv.display_name,
        case
          when coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
            then coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams')::numeric
          else null
        end
      into v_variant_code,v_variant_name,v_unit_grams
      from public.product_variants pv
      join public.product_types pt
        on pt.product_type_id=pv.product_type_id
       and pt.active=true and pt.deleted_at is null and pt.product_code='MOP'
      where pv.product_variant_id=v_variant
        and pv.active=true and pv.deleted_at is null;
    else
      v_variant_code:='MOP_TOTAL';
      v_variant_name:='MOP total';
      v_unit_grams:=null;
    end if;
    v_kg:=case when coalesce(v_line.value->>'weight_kg','') ~ '^[0-9]+([.][0-9]+)?$' then (v_line.value->>'weight_kg')::numeric else 0 end;
    v_units:=case when coalesce(v_line.value->>'units','') ~ '^[0-9]+$' then (v_line.value->>'units')::integer else 0 end;
    if v_kg<=0 and v_units>0 and coalesce(v_unit_grams,0)>0 then v_kg:=round((v_units*v_unit_grams/1000.0)::numeric,3); end if;
    if v_units<=0 and v_kg>0 and coalesce(v_unit_grams,0)>0 then v_units:=round(v_kg*1000.0/v_unit_grams)::integer; end if;
    if v_kg<=0 and v_units<=0 then continue; end if;
    insert into public.sorting_mop_production_lines(
      mop_production_batch_id,product_variant_id,variant_code_snapshot,variant_name_snapshot,weight_kg,units,unit_weight_grams_snapshot
    ) values(v_batch.mop_production_batch_id,v_variant,v_variant_code,v_variant_name,nullif(v_kg,0),nullif(v_units,0),v_unit_grams);
  end loop;

  foreach v_code in array v_trolley_codes
  loop
    if v_entry_mode='LIVE' then
      if v_flow.scheduled_for_date is null then
        raise exception using errcode='22023', message='Live trolley assignment requires a scheduled MOP customer.';
      end if;
      v_assign:=public.assign_trolley_to_customer_from_production(
        v_code,v_flow.customer_id,v_flow.scheduled_for_date,'MOP',
        format('MOP Production %s',v_batch.mop_production_batch_id),
        'SORTING_MOP_PRODUCTION'
      );
      insert into public.sorting_mop_production_trolleys(
        mop_production_batch_id,trolley_id,trolley_code_snapshot,stay_id,lifecycle_action
      ) values(
        v_batch.mop_production_batch_id,nullif(v_assign->>'trolley_id','')::uuid,v_code,
        nullif(v_assign->>'stay_id','')::uuid,'LIVE_ASSIGNMENT'
      );
    else
      insert into public.sorting_mop_production_trolleys(
        mop_production_batch_id,trolley_id,trolley_code_snapshot,stay_id,lifecycle_action
      ) values(
        v_batch.mop_production_batch_id,
        (select t.trolley_id from public.trolleys t where upper(t.trolley_code)=v_code and t.deleted_at is null limit 1),
        v_code,null,'LATE_REFERENCE_ONLY'
      );
    end if;
  end loop;

  if v_entry_mode='LATE_RECONCILIATION' then
    insert into public.sorting_mop_reconciliations(
      production_flow_item_id,delivery_due_date,decision,reason,operator_staff_id,
      linked_mop_production_batch_id,recorded_by_staff_id,recorded_by_auth_user_id
    ) values(
      v_flow.production_flow_item_id,v_due,'PROCESSED_MISSED_ENTRY',
      coalesce(nullif(trim(coalesce(p_notes,'')),''),'Late MOP production entry recorded by operator.'),
      p_operator_staff_id,v_batch.mop_production_batch_id,v_actor_staff_id,auth.uid()
    );
  end if;

  v_event_type:=case when v_entry_mode='LATE_RECONCILIATION' then 'MOP_PRODUCTION_LATE_RECORDED' else 'MOP_PRODUCTION_RECORDED' end;
  perform public.append_production_flow_event(
    v_flow.production_flow_item_id,v_event_type,'PRODUCTION',40,'MOP',v_business_date,now(),
    p_operator_staff_id,v_actor_staff_id,auth.uid(),'SORTING_MOP_PRODUCTION','sorting_mop_production_batches',
    v_batch.mop_production_batch_id::text,
    jsonb_build_object(
      'entry_mode',v_entry_mode,
      'physical_processed_on',v_recorded_on,
      'physical_processed_time',v_recorded_time,
      'physical_time_precision',case when v_recorded_time is null then 'DATE_ONLY' else 'EXACT' end,
      'total_kg',round(v_total_kg,3),
      'total_units',v_total_units,
      'quantity_value',case when v_total_kg>0 then round(v_total_kg,2) else v_total_units end,
      'quantity_unit',case when v_total_kg>0 then 'KG' else 'UNIT' end,
      'quantity_basis','MOP_PRODUCTION_REPORTED',
      'trolley_capture_status',v_trolley_status,
      'trolley_codes',to_jsonb(v_trolley_codes),
      'planned_output_trolley_quantity',v_planned_trolley_qty
    )
  );

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application)
  values(auth.uid(),v_actor_staff_id,'RECORD_SORTING_MOP_PRODUCTION','sorting_mop_production_batches',v_batch.mop_production_batch_id::text,to_jsonb(v_batch),p_notes,'SORTING_MOP_PRODUCTION');

  return jsonb_build_object(
    'mop_production_batch_id',v_batch.mop_production_batch_id,
    'production_flow_item_id',v_flow.production_flow_item_id,
    'customer_id',v_flow.customer_id,
    'customer_name',v_flow.customer_name_snapshot,
    'total_kg',round(v_total_kg,3),
    'total_units',v_total_units,
    'entry_mode',v_entry_mode,
    'trolley_capture_status',v_trolley_status,
    'trolley_codes',to_jsonb(v_trolley_codes),
    'delivery_due_date',v_due,
    'message',case when v_entry_mode='LATE_RECONCILIATION' then 'Missed MOP production entry recorded with traceable late-entry evidence.' else 'MOP production recorded.' end
  );
end;
$$;


create or replace function public.get_sorting_mop_type_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_types jsonb;
begin
  perform public.begin_mop_operational_scope();

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'product_variant_id', pv.product_variant_id,
        'variant_code', pv.variant_code,
        'display_name', pv.display_name,
        'active', pv.active,
        'sort_order', pv.sort_order,
        'category', nullif(coalesce(pv.metadata->>'category', pv.metadata->>'type', ''), ''),
        'unit_weight_grams', case
          when coalesce(pv.metadata->>'unit_weight_grams', pv.metadata->>'weight_per_unit_grams', '') ~ '^[0-9]+([.][0-9]+)?$'
            then coalesce(pv.metadata->>'unit_weight_grams', pv.metadata->>'weight_per_unit_grams')::numeric
          else null
        end,
        'image_url', nullif(coalesce(pv.metadata->>'image_url', pv.metadata->>'photo_url', ''), ''),
        'notes', nullif(coalesce(pv.metadata->>'notes', ''), ''),
        'source', nullif(coalesce(pv.metadata->>'source', ''), ''),
        'unit_weight_source', nullif(coalesce(pv.metadata->>'unit_weight_source', ''), ''),
        'unit_weight_evidence_count', case
          when coalesce(pv.metadata->>'unit_weight_evidence_count','') ~ '^[0-9]+$'
            then (pv.metadata->>'unit_weight_evidence_count')::integer
          else null
        end,
        'unit_weight_review_required', coalesce((pv.metadata->>'unit_weight_review_required')::boolean,false),
        'legacy_weight_observations', coalesce(pv.metadata->'legacy_weight_observations','{}'::jsonb),
        'schedule_link_count', coalesce(links.schedule_link_count, 0),
        'production_line_count', coalesce(prod.production_line_count, 0),
        'created_at', pv.created_at,
        'updated_at', pv.updated_at
      )
      order by pv.sort_order, pv.display_name, pv.variant_code
    ),
    '[]'::jsonb
  )
  into v_types
  from public.product_variants pv
  join public.product_types pt
    on pt.product_type_id = pv.product_type_id
   and pt.active = true
   and pt.deleted_at is null
   and pt.product_code = 'MOP'
  left join lateral (
    select count(*)::integer as schedule_link_count
    from public.customer_schedule_product_variants cspv
    where cspv.product_variant_id = pv.product_variant_id
  ) links on true
  left join lateral (
    select count(*)::integer as production_line_count
    from public.sorting_mop_production_lines mpl
    where mpl.product_variant_id = pv.product_variant_id
  ) prod on true
  where pv.deleted_at is null;

  return jsonb_build_object(
    'bucket_id', 'mop-type-photos',
    'max_file_bytes', 2097152,
    'allowed_mime_types', jsonb_build_array('image/jpeg','image/png','image/webp'),
    'can_manage', public.has_any_role(array['ADMIN','MANAGER']),
    'can_create', public.has_any_role(array['ADMIN','MANAGER']),
    'types', v_types
  );
end;
$$;


create or replace function public.record_sorting_mop_abs_batch(
  p_mop_production_batch_id uuid,
  p_batch_reference text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_mop_batch public.sorting_mop_production_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_existing public.production_flow_external_batches%rowtype;
  v_reference text := nullif(trim(coalesce(p_batch_reference,'')),'');
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_quantity numeric;
  v_unit_code text;
  v_result jsonb;
begin
  perform public.begin_mop_operational_scope();

  if v_reference is null then
    raise exception using errcode='22023', message='ABS batch number is required.';
  end if;

  if length(v_reference)>120 then
    raise exception using errcode='22023', message='ABS batch number must be 120 characters or fewer.';
  end if;

  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023', message='ABS notes must be 1000 characters or fewer.';
  end if;

  select *
  into v_mop_batch
  from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id=p_mop_production_batch_id
    and mb.status='RECORDED'
  for update;

  if not found then
    raise exception using errcode='P0002', message='Recorded MOP Production batch was not found.';
  end if;

  select *
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_mop_batch.production_flow_item_id
  for update;

  if not found or v_flow.product_code<>'MOP' then
    raise exception using errcode='22023', message='ABS posting from MOP Production requires an exact MOP Production Flow item.';
  end if;

  select b.*
  into v_existing
  from public.production_flow_external_batches b
  where b.production_flow_item_id=v_flow.production_flow_item_id
    and b.external_system_code='ABS'
    and b.status='ACTIVE'
  order by b.recorded_at desc,b.production_flow_external_batch_id desc
  limit 1;

  if found then
    if trim(v_existing.batch_reference)=v_reference then
      return jsonb_build_object(
        'status','success',
        'skipped',true,
        'production_flow_item_id',v_flow.production_flow_item_id,
        'mop_production_batch_id',v_mop_batch.mop_production_batch_id,
        'external_batch_id',v_existing.production_flow_external_batch_id,
        'batch_reference',v_existing.batch_reference,
        'quantity',v_existing.quantity,
        'unit_code',v_existing.unit_code,
        'message',format('ABS batch %s is already recorded for this MOP production.',v_existing.batch_reference)
      );
    end if;

    raise exception using
      errcode='23505',
      message=format(
        'This MOP production already has active ABS batch %s. Use the governed ABS correction workflow instead of adding a second batch.',
        v_existing.batch_reference
      );
  end if;

  if coalesce(v_mop_batch.total_weight_kg,0)>0 then
    v_quantity:=v_mop_batch.total_weight_kg;
    v_unit_code:='KG';
  elsif coalesce(v_mop_batch.total_units,0)>0 then
    v_quantity:=v_mop_batch.total_units;
    v_unit_code:='UNIT';
  else
    raise exception using
      errcode='22023',
      message='The recorded MOP Production has no positive KG or Units to anchor the ABS batch.';
  end if;

  v_result:=public.record_production_flow_abs_batch(
    v_flow.production_flow_item_id,
    v_reference,
    v_quantity,
    v_unit_code,
    v_notes
  );

  return v_result || jsonb_build_object(
    'mop_production_batch_id',v_mop_batch.mop_production_batch_id,
    'source_application','SORTING_MOP_PRODUCTION',
    'quantity_source',case when v_unit_code='KG' then 'MOP_PRODUCTION_TOTAL_KG' else 'MOP_PRODUCTION_TOTAL_UNITS' end
  );
end;
$$;


create or replace function public.get_sorting_mop_production_correction_context(
  p_mop_production_batch_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_batch public.sorting_mop_production_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_lines jsonb:='[]'::jsonb;
  v_variants jsonb:='[]'::jsonb;
  v_trolleys jsonb:='[]'::jsonb;
  v_abs jsonb:='[]'::jsonb;
  v_history jsonb:='[]'::jsonb;
  v_live_trolley_locked boolean:=false;
  v_cancel_block_reason text;
begin
  perform public.begin_mop_operational_scope();

  select * into v_batch
  from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id=p_mop_production_batch_id;

  if not found then
    raise exception using errcode='P0002',message='MOP Production batch was not found.';
  end if;

  select * into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_batch.production_flow_item_id;

  if not found or v_flow.product_code<>'MOP' then
    raise exception using errcode='22023',message='Correction context requires a MOP Production Flow item.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'mop_production_line_id',ml.mop_production_line_id,
    'product_variant_id',ml.product_variant_id,
    'variant_code',ml.variant_code_snapshot,
    'variant_name',ml.variant_name_snapshot,
    'weight_kg',ml.weight_kg,
    'units',ml.units,
    'unit_weight_grams',ml.unit_weight_grams_snapshot
  ) order by ml.created_at,ml.mop_production_line_id),'[]'::jsonb)
  into v_lines
  from public.sorting_mop_production_lines ml
  where ml.mop_production_batch_id=v_batch.mop_production_batch_id;

  if v_flow.source_schedule_product_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'product_variant_id',pv.product_variant_id,
      'variant_code',pv.variant_code,
      'display_name',pv.display_name,
      'unit_weight_grams',case
        when coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
          then coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams')::numeric
        else null
      end,
      'image_url',nullif(coalesce(pv.metadata->>'image_url',pv.metadata->>'photo_url',''),''),
      'active',pv.active
    ) order by pv.sort_order,pv.display_name,pv.variant_code),'[]'::jsonb)
    into v_variants
    from public.customer_schedule_product_variants spv
    join public.product_variants pv on pv.product_variant_id=spv.product_variant_id
    join public.product_types pt on pt.product_type_id=pv.product_type_id
    where spv.schedule_product_id=v_flow.source_schedule_product_id
      and pv.deleted_at is null
      and pt.deleted_at is null
      and pt.product_code='MOP';
  end if;

  if jsonb_array_length(v_variants)=0 then
    v_variants:=jsonb_build_array(jsonb_build_object(
      'product_variant_id',null,
      'variant_code','MOP_TOTAL',
      'display_name','MOP total',
      'unit_weight_grams',null,
      'image_url',null,
      'active',true,
      'generic',true
    ));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'trolley_code',mt.trolley_code_snapshot,
    'trolley_id',mt.trolley_id,
    'stay_id',mt.stay_id,
    'lifecycle_action',mt.lifecycle_action
  ) order by mt.created_at,mt.mop_production_trolley_id),'[]'::jsonb),
  coalesce(bool_or(mt.lifecycle_action='LIVE_ASSIGNMENT'),false)
  into v_trolleys,v_live_trolley_locked
  from public.sorting_mop_production_trolleys mt
  where mt.mop_production_batch_id=v_batch.mop_production_batch_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'external_batch_id',b.production_flow_external_batch_id,
    'batch_reference',b.batch_reference,
    'quantity',b.quantity,
    'unit_code',b.unit_code,
    'capture_source',b.capture_source,
    'status',b.status,
    'recorded_at',b.recorded_at,
    'recorded_by_staff_id',b.recorded_by_staff_id,
    'recorded_by_name',sm.display_name,
    'notes',b.notes
  ) order by b.recorded_at desc,b.production_flow_external_batch_id desc),'[]'::jsonb)
  into v_abs
  from public.production_flow_external_batches b
  left join public.staff_members sm on sm.staff_id=b.recorded_by_staff_id
  where b.production_flow_item_id=v_batch.production_flow_item_id
    and b.external_system_code='ABS'
    and b.status='ACTIVE';

  select coalesce(jsonb_agg(jsonb_build_object(
    'mop_production_batch_id',h.mop_production_batch_id,
    'revision_no',h.revision_no,
    'status',h.status,
    'total_kg',h.total_weight_kg,
    'total_units',h.total_units,
    'recorded_at',h.recorded_at,
    'recorded_by_name',rec.display_name,
    'change_reason',h.change_reason,
    'cancellation_kind',h.cancellation_kind,
    'cancellation_reason',h.cancellation_reason,
    'cancelled_at',h.cancelled_at,
    'cancelled_by_name',can.display_name
  ) order by h.revision_no desc,h.recorded_at desc),'[]'::jsonb)
  into v_history
  from public.sorting_mop_production_batches h
  left join public.staff_members rec on rec.staff_id=h.recorded_by_staff_id
  left join public.staff_members can on can.staff_id=h.cancelled_by_staff_id
  where h.production_flow_item_id=v_batch.production_flow_item_id;

  if v_live_trolley_locked then
    v_cancel_block_reason:='This production owns live physical trolley lifecycle evidence. Use correction for MOP quantities/types. Full cancellation requires Trolley Control review so custody is not falsified.';
  end if;

  return jsonb_build_object(
    'batch',jsonb_build_object(
      'mop_production_batch_id',v_batch.mop_production_batch_id,
      'production_flow_item_id',v_batch.production_flow_item_id,
      'customer_id',v_batch.customer_id,
      'customer_name',v_batch.customer_name_snapshot,
      'business_date',v_batch.business_date,
      'scheduled_for_date',v_batch.scheduled_for_date,
      'delivery_due_date',v_batch.delivery_due_date,
      'operator_staff_id',v_batch.operator_staff_id,
      'entry_mode',v_batch.entry_mode,
      'physical_processed_on',v_batch.physical_processed_on,
      'physical_processed_time',v_batch.physical_processed_time,
      'physical_time_precision',v_batch.physical_time_precision,
      'total_kg',v_batch.total_weight_kg,
      'total_units',v_batch.total_units,
      'trolley_capture_status',v_batch.trolley_capture_status,
      'planned_output_trolley_quantity',v_batch.planned_output_trolley_quantity,
      'notes',v_batch.notes,
      'status',v_batch.status,
      'revision_no',v_batch.revision_no,
      'change_reason',v_batch.change_reason,
      'cancellation_kind',v_batch.cancellation_kind,
      'cancellation_reason',v_batch.cancellation_reason
    ),
    'flow',jsonb_build_object(
      'route_code',v_flow.route_code_snapshot,
      'route_display_name',v_flow.route_display_name_snapshot,
      'route_color',v_flow.route_color_snapshot,
      'source_schedule_product_id',v_flow.source_schedule_product_id
    ),
    'lines',v_lines,
    'available_variants',v_variants,
    'trolleys',v_trolleys,
    'live_trolley_locked',v_live_trolley_locked,
    'late_trolley_reference_editable',v_batch.entry_mode='LATE_RECONCILIATION',
    'active_abs_batches',v_abs,
    'revision_history',v_history,
    'can_correct',v_batch.status='RECORDED',
    'can_cancel',v_batch.status='RECORDED' and not v_live_trolley_locked,
    'cancel_block_reason',v_cancel_block_reason,
    'correction_contract','APPEND_ONLY_REPLACEMENT'
  );
end;
$$;


create or replace function public.correct_sorting_mop_production(
  p_mop_production_batch_id uuid,
  p_reason text,
  p_lines jsonb,
  p_notes text default null,
  p_trolley_codes text[] default null,
  p_trolley_unknown boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_old public.sorting_mop_production_batches%rowtype;
  v_new public.sorting_mop_production_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_actor_staff_id uuid:=public.current_staff_id();
  v_reason text:=nullif(trim(coalesce(p_reason,'')),'');
  v_notes text:=nullif(trim(coalesce(p_notes,'')),'');
  v_line record;
  v_variant uuid;
  v_variant_code text;
  v_variant_name text;
  v_unit_grams numeric;
  v_kg numeric;
  v_units integer;
  v_total_kg numeric:=0;
  v_total_units integer:=0;
  v_line_count integer:=0;
  v_normalized_lines jsonb:='[]'::jsonb;
  v_seen_keys text[]:=array[]::text[];
  v_variant_key text;
  v_old_trolley_codes text[]:=array[]::text[];
  v_new_trolley_codes text[]:=array[]::text[];
  v_old_live_trolley boolean:=false;
  v_trolley_unknown boolean:=false;
  v_trolley_status text;
  v_code text;
  v_old_trolley record;
  v_abs_count integer:=0;
  v_abs_old public.production_flow_external_batches%rowtype;
  v_abs_new public.production_flow_external_batches%rowtype;
  v_new_abs_quantity numeric;
  v_new_abs_unit text;
  v_abs_synced boolean:=false;
begin
  perform public.begin_mop_operational_scope();

  if v_reason is null or length(v_reason)<5 then
    raise exception using errcode='22023',message='Correction reason must contain at least 5 characters.';
  end if;
  if length(v_reason)>1000 then
    raise exception using errcode='22023',message='Correction reason must be 1000 characters or fewer.';
  end if;
  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023',message='MOP notes must be 1000 characters or fewer.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then
    raise exception using errcode='22023',message='Enter KG or Units for at least one MOP type.';
  end if;

  select * into v_old
  from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id=p_mop_production_batch_id
    and mb.status='RECORDED'
  for update;

  if not found then
    raise exception using errcode='P0002',message='Only the current active MOP Production revision can be corrected.';
  end if;

  select * into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_old.production_flow_item_id
  for update;

  if not found or v_flow.product_code<>'MOP' then
    raise exception using errcode='22023',message='MOP Production correction requires an exact MOP Production Flow item.';
  end if;

  -- Server-authoritative line normalization. Browser names/weights are never trusted.
  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_variant:=nullif(v_line.value->>'product_variant_id','')::uuid;
    if v_variant is not null then
      select pv.variant_code,pv.display_name,
        case
          when coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams','') ~ '^[0-9]+([.][0-9]+)?$'
            then coalesce(pv.metadata->>'unit_weight_grams',pv.metadata->>'weight_per_unit_grams')::numeric
          else null
        end
      into v_variant_code,v_variant_name,v_unit_grams
      from public.product_variants pv
      join public.product_types pt on pt.product_type_id=pv.product_type_id
      where pv.product_variant_id=v_variant
        and pv.active=true and pv.deleted_at is null
        and pt.active=true and pt.deleted_at is null and pt.product_code='MOP';

      if not found then
        raise exception using errcode='22023',message='Selected MOP variant is not active MOP master data.';
      end if;

      if v_flow.source_schedule_product_id is not null and not exists(
        select 1 from public.customer_schedule_product_variants spv
        where spv.schedule_product_id=v_flow.source_schedule_product_id
          and spv.product_variant_id=v_variant
      ) then
        raise exception using errcode='22023',message=format('MOP variant %s is not linked to the original published Customer Schedule product.',v_variant_name);
      end if;
      v_variant_key:=v_variant::text;
    else
      -- Generic MOP total is only valid when the original published schedule product
      -- has no explicit MOP variant mapping. Do not let a crafted browser payload erase
      -- schedule-authoritative type identity.
      if v_flow.source_schedule_product_id is not null and exists(
        select 1
        from public.customer_schedule_product_variants spv
        join public.product_variants pv on pv.product_variant_id=spv.product_variant_id
        join public.product_types pt on pt.product_type_id=pv.product_type_id
        where spv.schedule_product_id=v_flow.source_schedule_product_id
          and pv.deleted_at is null
          and pt.deleted_at is null
          and pt.product_code='MOP'
      ) then
        raise exception using errcode='22023',message='Generic MOP total cannot replace MOP types linked to the original published Customer Schedule.';
      end if;
      v_variant_code:='MOP_TOTAL';
      v_variant_name:='MOP total';
      v_unit_grams:=null;
      v_variant_key:='MOP_TOTAL';
    end if;

    if v_variant_key=any(v_seen_keys) then
      raise exception using errcode='22023',message=format('MOP type %s was submitted more than once.',v_variant_name);
    end if;
    v_seen_keys:=array_append(v_seen_keys,v_variant_key);

    v_kg:=case when coalesce(v_line.value->>'weight_kg','') ~ '^[0-9]+([.][0-9]+)?$' then (v_line.value->>'weight_kg')::numeric else 0 end;
    v_units:=case when coalesce(v_line.value->>'units','') ~ '^[0-9]+$' then (v_line.value->>'units')::integer else 0 end;
    if v_kg<=0 and v_units>0 and coalesce(v_unit_grams,0)>0 then v_kg:=round((v_units*v_unit_grams/1000.0)::numeric,3); end if;
    if v_units<=0 and v_kg>0 and coalesce(v_unit_grams,0)>0 then v_units:=round(v_kg*1000.0/v_unit_grams)::integer; end if;
    if v_kg<=0 and v_units<=0 then continue; end if;

    v_total_kg:=v_total_kg+greatest(v_kg,0);
    v_total_units:=v_total_units+greatest(v_units,0);
    v_line_count:=v_line_count+1;
    v_normalized_lines:=v_normalized_lines || jsonb_build_array(jsonb_build_object(
      'product_variant_id',v_variant,
      'variant_code',v_variant_code,
      'variant_name',v_variant_name,
      'weight_kg',nullif(v_kg,0),
      'units',nullif(v_units,0),
      'unit_weight_grams',v_unit_grams
    ));
  end loop;

  if v_line_count=0 or (v_total_kg<=0 and v_total_units<=0) then
    raise exception using errcode='22023',message='Enter KG or Units for at least one MOP type.';
  end if;

  select coalesce(array_agg(mt.trolley_code_snapshot order by mt.trolley_code_snapshot),array[]::text[]),
         coalesce(bool_or(mt.lifecycle_action='LIVE_ASSIGNMENT'),false)
  into v_old_trolley_codes,v_old_live_trolley
  from public.sorting_mop_production_trolleys mt
  where mt.mop_production_batch_id=v_old.mop_production_batch_id;

  if p_trolley_codes is null then
    v_new_trolley_codes:=v_old_trolley_codes;
  else
    select coalesce(array_agg(code order by code),array[]::text[])
    into v_new_trolley_codes
    from (
      select distinct upper(trim(x)) as code
      from unnest(coalesce(p_trolley_codes,array[]::text[])) x
      where nullif(trim(x),'') is not null
    ) q;
  end if;

  if exists(select 1 from unnest(v_new_trolley_codes) x where x !~ '^T[0-9]{1,10}T$') then
    raise exception using errcode='22023',message='Invalid trolley code in MOP Production correction.';
  end if;

  v_trolley_unknown:=coalesce(p_trolley_unknown,v_old.trolley_capture_status='UNKNOWN_LATE_ENTRY');

  if v_old.entry_mode='LIVE' then
    if v_trolley_unknown then
      raise exception using errcode='22023',message='Unknown trolley cannot replace live physical trolley lifecycle evidence.';
    end if;
    if v_new_trolley_codes is distinct from v_old_trolley_codes then
      raise exception using errcode='22023',message='Live trolley codes are lifecycle evidence and cannot be changed in MOP Production correction. Use Trolley Control review for a wrong physical trolley.';
    end if;
    v_trolley_status:=v_old.trolley_capture_status;
  else
    if v_trolley_unknown and cardinality(v_new_trolley_codes)>0 then
      raise exception using errcode='22023',message='Choose known late trolley references or Trolley number unavailable, not both.';
    end if;
    if v_trolley_unknown and v_old.planned_output_trolley_quantity>0 then v_trolley_status:='UNKNOWN_LATE_ENTRY';
    elsif cardinality(v_new_trolley_codes)>0 then v_trolley_status:='LATE_RECORDED_CODE';
    elsif v_old.planned_output_trolley_quantity=0 then v_trolley_status:='NOT_REQUIRED';
    else v_trolley_status:='UNKNOWN_LATE_ENTRY'; end if;
  end if;

  -- Supersede original evidence first; the whole transaction rolls back on any later error.
  update public.sorting_mop_production_batches
  set status='CANCELLED',
      cancellation_kind='CORRECTED',
      cancellation_reason=v_reason,
      cancelled_at=now(),
      cancelled_by_staff_id=v_actor_staff_id,
      cancelled_by_auth_user_id=auth.uid()
  where mop_production_batch_id=v_old.mop_production_batch_id;

  insert into public.sorting_mop_production_batches(
    production_flow_item_id,customer_id,customer_code_snapshot,customer_name_snapshot,
    business_date,shift_id,shift_code_snapshot,scheduled_for_date,delivery_due_date,
    operator_staff_id,entry_mode,physical_processed_on,physical_processed_time,physical_time_precision,
    total_weight_kg,total_units,trolley_capture_status,planned_output_trolley_quantity,
    recorded_by_staff_id,recorded_by_auth_user_id,notes,status,
    supersedes_mop_production_batch_id,revision_no,change_reason
  ) values (
    v_old.production_flow_item_id,v_old.customer_id,v_old.customer_code_snapshot,v_old.customer_name_snapshot,
    v_old.business_date,v_old.shift_id,v_old.shift_code_snapshot,v_old.scheduled_for_date,v_old.delivery_due_date,
    v_old.operator_staff_id,v_old.entry_mode,v_old.physical_processed_on,v_old.physical_processed_time,v_old.physical_time_precision,
    round(v_total_kg,3),v_total_units,v_trolley_status,v_old.planned_output_trolley_quantity,
    v_actor_staff_id,auth.uid(),v_notes,'RECORDED',
    v_old.mop_production_batch_id,coalesce(v_old.revision_no,1)+1,v_reason
  ) returning * into v_new;

  for v_line in select value from jsonb_array_elements(v_normalized_lines)
  loop
    insert into public.sorting_mop_production_lines(
      mop_production_batch_id,product_variant_id,variant_code_snapshot,variant_name_snapshot,
      weight_kg,units,unit_weight_grams_snapshot
    ) values(
      v_new.mop_production_batch_id,
      nullif(v_line.value->>'product_variant_id','')::uuid,
      v_line.value->>'variant_code',v_line.value->>'variant_name',
      nullif(v_line.value->>'weight_kg','')::numeric,
      nullif(v_line.value->>'units','')::integer,
      nullif(v_line.value->>'unit_weight_grams','')::numeric
    );
  end loop;

  if v_old.entry_mode='LIVE' then
    for v_old_trolley in
      select * from public.sorting_mop_production_trolleys mt
      where mt.mop_production_batch_id=v_old.mop_production_batch_id
      order by mt.created_at,mt.mop_production_trolley_id
    loop
      insert into public.sorting_mop_production_trolleys(
        mop_production_batch_id,trolley_id,trolley_code_snapshot,stay_id,lifecycle_action
      ) values(
        v_new.mop_production_batch_id,v_old_trolley.trolley_id,v_old_trolley.trolley_code_snapshot,
        v_old_trolley.stay_id,v_old_trolley.lifecycle_action
      );
    end loop;
  else
    foreach v_code in array v_new_trolley_codes
    loop
      insert into public.sorting_mop_production_trolleys(
        mop_production_batch_id,trolley_id,trolley_code_snapshot,stay_id,lifecycle_action
      ) values(
        v_new.mop_production_batch_id,
        (select t.trolley_id from public.trolleys t where upper(t.trolley_code)=v_code and t.deleted_at is null limit 1),
        v_code,null,'LATE_REFERENCE_ONLY'
      );
    end loop;
  end if;

  -- The MOP ABS quantity is local trace evidence derived from recorded MOP Production.
  -- If exactly one active ABS record exists and the corrected total changed, supersede
  -- that local evidence with the same batch reference and corrected quantity.
  select count(*)::integer into v_abs_count
  from public.production_flow_external_batches b
  where b.production_flow_item_id=v_old.production_flow_item_id
    and b.external_system_code='ABS' and b.status='ACTIVE';

  if v_total_kg>0 then
    v_new_abs_quantity:=round(v_total_kg,2);
    v_new_abs_unit:='KG';
  else
    v_new_abs_quantity:=v_total_units;
    v_new_abs_unit:='UNIT';
  end if;

  if v_abs_count>1 then
    raise exception using errcode='23505',message='Multiple active ABS batches are linked to this Production Flow. Manager review is required before MOP Production can be corrected.';
  elsif v_abs_count=1 then
    select * into v_abs_old
    from public.production_flow_external_batches b
    where b.production_flow_item_id=v_old.production_flow_item_id
      and b.external_system_code='ABS' and b.status='ACTIVE'
    order by b.recorded_at desc,b.production_flow_external_batch_id desc
    limit 1
    for update;

    if v_abs_old.quantity is distinct from v_new_abs_quantity or v_abs_old.unit_code is distinct from v_new_abs_unit then
      if v_abs_old.capture_source='INTEGRATION' then
        raise exception using errcode='22023',message='Integrated ABS evidence cannot be changed from MOP Production correction. Correct the external integration source first.';
      end if;
      update public.production_flow_external_batches
      set status='SUPERSEDED',correction_reason=v_reason,cancelled_at=now(),
          cancelled_by_staff_id=v_actor_staff_id,cancelled_by_auth_user_id=auth.uid()
      where production_flow_external_batch_id=v_abs_old.production_flow_external_batch_id;

      insert into public.production_flow_external_batches(
        production_flow_item_id,external_system_code,batch_reference,quantity,unit_code,
        capture_source,status,supersedes_external_batch_id,notes,correction_reason,
        integration_metadata,recorded_by_staff_id,recorded_by_auth_user_id
      ) values (
        v_abs_old.production_flow_item_id,v_abs_old.external_system_code,v_abs_old.batch_reference,
        v_new_abs_quantity,v_new_abs_unit,v_abs_old.capture_source,'ACTIVE',
        v_abs_old.production_flow_external_batch_id,v_abs_old.notes,v_reason,
        coalesce(v_abs_old.integration_metadata,'{}'::jsonb) || jsonb_build_object(
          'mop_production_revision_sync',true,
          'source_mop_production_batch_id',v_new.mop_production_batch_id
        ),
        v_actor_staff_id,auth.uid()
      ) returning * into v_abs_new;

      v_abs_synced:=true;

      perform public.append_production_flow_event(
        v_old.production_flow_item_id,'ABS_BATCH_CORRECTED','PRODUCTION',40,'MOP',
        v_old.business_date,v_abs_new.recorded_at,v_actor_staff_id,v_actor_staff_id,auth.uid(),
        'SORTING_MOP_PRODUCTION','production_flow_external_batches',v_abs_new.production_flow_external_batch_id::text,
        jsonb_build_object(
          'old_external_batch_id',v_abs_old.production_flow_external_batch_id,
          'batch_reference',v_abs_new.batch_reference,
          'old_quantity',v_abs_old.quantity,'old_unit_code',v_abs_old.unit_code,
          'quantity',v_abs_new.quantity,'unit_code',v_abs_new.unit_code,
          'reason',v_reason,'source','MOP_PRODUCTION_CORRECTION'
        )
      );

      insert into public.audit_log(
        actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
        old_data,new_data,reason,source_application
      ) values(
        auth.uid(),v_actor_staff_id,'MOP_CORRECTION_SYNC_ABS_EVIDENCE','production_flow_external_batches',
        v_abs_new.production_flow_external_batch_id::text,to_jsonb(v_abs_old),to_jsonb(v_abs_new),
        v_reason,'SORTING_MOP_PRODUCTION'
      );
    end if;
  end if;

  perform public.append_production_flow_event(
    v_old.production_flow_item_id,'MOP_PRODUCTION_CORRECTED','PRODUCTION',40,'MOP',
    v_old.business_date,now(),v_old.operator_staff_id,v_actor_staff_id,auth.uid(),
    'SORTING_MOP_PRODUCTION','sorting_mop_production_batches',v_new.mop_production_batch_id::text,
    jsonb_build_object(
      'supersedes_mop_production_batch_id',v_old.mop_production_batch_id,
      'revision_no',v_new.revision_no,
      'old_total_kg',v_old.total_weight_kg,'old_total_units',v_old.total_units,
      'total_kg',v_new.total_weight_kg,'total_units',v_new.total_units,
      'trolley_capture_status',v_new.trolley_capture_status,
      'trolley_codes',to_jsonb(v_new_trolley_codes),
      'live_trolley_lifecycle_preserved',v_old.entry_mode='LIVE',
      'abs_evidence_synced',v_abs_synced,
      'reason',v_reason
    )
  );

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
    old_data,new_data,reason,source_application
  ) values(
    auth.uid(),v_actor_staff_id,'CORRECT_SORTING_MOP_PRODUCTION','sorting_mop_production_batches',
    v_new.mop_production_batch_id::text,to_jsonb(v_old),to_jsonb(v_new),v_reason,'SORTING_MOP_PRODUCTION'
  );

  return jsonb_build_object(
    'status','success',
    'mop_production_batch_id',v_new.mop_production_batch_id,
    'supersedes_mop_production_batch_id',v_old.mop_production_batch_id,
    'production_flow_item_id',v_new.production_flow_item_id,
    'revision_no',v_new.revision_no,
    'total_kg',v_new.total_weight_kg,
    'total_units',v_new.total_units,
    'trolley_capture_status',v_new.trolley_capture_status,
    'abs_evidence_synced',v_abs_synced,
    'message',format('MOP Production corrected as revision %s. Original evidence was preserved.',v_new.revision_no)
  );
end;
$$;


create or replace function public.cancel_sorting_mop_production(
  p_mop_production_batch_id uuid,
  p_reason text,
  p_cancel_abs_evidence boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_batch public.sorting_mop_production_batches%rowtype;
  v_actor_staff_id uuid:=public.current_staff_id();
  v_reason text:=nullif(trim(coalesce(p_reason,'')),'');
  v_abs record;
  v_abs_count integer:=0;
  v_old_data jsonb;
begin
  perform public.begin_mop_operational_scope();

  if v_reason is null or length(v_reason)<5 then
    raise exception using errcode='22023',message='Cancellation reason must contain at least 5 characters.';
  end if;
  if length(v_reason)>1000 then
    raise exception using errcode='22023',message='Cancellation reason must be 1000 characters or fewer.';
  end if;

  select * into v_batch
  from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id=p_mop_production_batch_id
    and mb.status='RECORDED'
  for update;

  if not found then
    raise exception using errcode='P0002',message='Only the current active MOP Production revision can be cancelled.';
  end if;
  v_old_data:=to_jsonb(v_batch);

  if exists(
    select 1 from public.sorting_mop_production_trolleys mt
    where mt.mop_production_batch_id=v_batch.mop_production_batch_id
      and mt.lifecycle_action='LIVE_ASSIGNMENT'
  ) then
    raise exception using
      errcode='22023',
      message='Cancellation is blocked because this production owns live physical trolley lifecycle evidence. Correct MOP quantities/types here; a wrong trolley/customer assignment requires Trolley Control review.';
  end if;

  select count(*)::integer into v_abs_count
  from public.production_flow_external_batches b
  where b.production_flow_item_id=v_batch.production_flow_item_id
    and b.external_system_code='ABS' and b.status='ACTIVE';

  if v_abs_count>1 then
    raise exception using errcode='23505',message='Multiple active ABS batches are linked to this Production Flow. Manager review is required before MOP Production can be cancelled.';
  end if;

  if exists(
    select 1 from public.production_flow_external_batches b
    where b.production_flow_item_id=v_batch.production_flow_item_id
      and b.external_system_code='ABS' and b.status='ACTIVE'
      and b.capture_source='INTEGRATION'
  ) then
    raise exception using errcode='22023',message='Integrated ABS evidence is active for this MOP Production and cannot be cancelled from Sorting. Correct the integration source first.';
  end if;

  if v_abs_count>0 and not coalesce(p_cancel_abs_evidence,false) then
    raise exception using
      errcode='22023',
      message='This MOP Production has active ABS evidence. Confirm cancellation of the linked ElisCaretex ABS trace before cancelling the production record.';
  end if;

  if v_abs_count>0 then
    for v_abs in
      select b.* from public.production_flow_external_batches b
      where b.production_flow_item_id=v_batch.production_flow_item_id
        and b.external_system_code='ABS' and b.status='ACTIVE'
      order by b.recorded_at,b.production_flow_external_batch_id
      for update
    loop
      update public.production_flow_external_batches
      set status='CANCELLED',correction_reason=v_reason,cancelled_at=now(),
          cancelled_by_staff_id=v_actor_staff_id,cancelled_by_auth_user_id=auth.uid()
      where production_flow_external_batch_id=v_abs.production_flow_external_batch_id;

      perform public.append_production_flow_event(
        v_batch.production_flow_item_id,'ABS_BATCH_CANCELLED','PRODUCTION',40,'MOP',
        v_batch.business_date,now(),v_actor_staff_id,v_actor_staff_id,auth.uid(),
        'SORTING_MOP_PRODUCTION','production_flow_external_batches',v_abs.production_flow_external_batch_id::text,
        jsonb_build_object(
          'batch_reference',v_abs.batch_reference,'quantity',v_abs.quantity,'unit_code',v_abs.unit_code,
          'reason',v_reason,'source','MOP_PRODUCTION_CANCELLATION',
          'external_system_not_modified',true
        )
      );

      insert into public.audit_log(
        actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
        old_data,new_data,reason,source_application
      ) values(
        auth.uid(),v_actor_staff_id,'MOP_CANCELLATION_CANCEL_ABS_EVIDENCE','production_flow_external_batches',
        v_abs.production_flow_external_batch_id::text,to_jsonb(v_abs),
        (select to_jsonb(b) from public.production_flow_external_batches b where b.production_flow_external_batch_id=v_abs.production_flow_external_batch_id),
        v_reason,'SORTING_MOP_PRODUCTION'
      );
    end loop;
  end if;

  update public.sorting_mop_production_batches
  set status='CANCELLED',cancellation_kind='CANCELLED',cancellation_reason=v_reason,
      cancelled_at=now(),cancelled_by_staff_id=v_actor_staff_id,cancelled_by_auth_user_id=auth.uid()
  where mop_production_batch_id=v_batch.mop_production_batch_id
  returning * into v_batch;

  perform public.append_production_flow_event(
    v_batch.production_flow_item_id,'MOP_PRODUCTION_CANCELLED','PRODUCTION',40,'MOP',
    v_batch.business_date,coalesce(v_batch.cancelled_at,now()),v_batch.operator_staff_id,v_actor_staff_id,auth.uid(),
    'SORTING_MOP_PRODUCTION','sorting_mop_production_batches',v_batch.mop_production_batch_id::text,
    jsonb_build_object(
      'revision_no',v_batch.revision_no,'total_kg',v_batch.total_weight_kg,'total_units',v_batch.total_units,
      'reason',v_reason,'linked_abs_evidence_cancelled',v_abs_count>0,
      'returns_to_mop_queue',true
    )
  );

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,
    old_data,new_data,reason,source_application
  ) values(
    auth.uid(),v_actor_staff_id,'CANCEL_SORTING_MOP_PRODUCTION','sorting_mop_production_batches',
    v_batch.mop_production_batch_id::text,v_old_data,to_jsonb(v_batch),v_reason,'SORTING_MOP_PRODUCTION'
  );

  return jsonb_build_object(
    'status','success','mop_production_batch_id',v_batch.mop_production_batch_id,
    'production_flow_item_id',v_batch.production_flow_item_id,'revision_no',v_batch.revision_no,
    'abs_evidence_cancelled',v_abs_count>0,'returns_to_queue',true,
    'message','MOP Production cancelled. Original evidence remains in Trace history and the washed customer can return to the MOP queue.'
  );
end;
$$;


create or replace function public.get_sorting_mop_recent_trace(
  p_limit integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_limit integer:=least(greatest(coalesce(p_limit,30),1),100);
  v_rows jsonb:='[]'::jsonb;
  v_pending integer:=0;
  v_posted integer:=0;
  v_cancelled integer:=0;
begin
  perform public.begin_mop_operational_scope();

  with flow_activity as (
    select mb.production_flow_item_id,
           max(coalesce(mb.cancelled_at,mb.recorded_at)) as activity_at
    from public.sorting_mop_production_batches mb
    group by mb.production_flow_item_id
    order by max(coalesce(mb.cancelled_at,mb.recorded_at)) desc,mb.production_flow_item_id
    limit v_limit
  ), selected as (
    select distinct on (mb.production_flow_item_id) mb.*
    from public.sorting_mop_production_batches mb
    join flow_activity fa on fa.production_flow_item_id=mb.production_flow_item_id
    order by mb.production_flow_item_id,
      case when mb.status='RECORDED' then 0 else 1 end,
      mb.revision_no desc,coalesce(mb.cancelled_at,mb.recorded_at) desc,mb.mop_production_batch_id desc
  ), trace_rows as (
    select
      mb.mop_production_batch_id,
      mb.production_flow_item_id,
      mb.customer_id,
      mb.customer_name_snapshot as customer_name,
      pfi.route_code_snapshot as route_code,
      pfi.route_display_name_snapshot as route_display_name,
      pfi.route_color_snapshot as route_color,
      mb.business_date,mb.scheduled_for_date,mb.delivery_due_date,
      mb.operator_staff_id,sm.display_name as operator_name,
      mb.entry_mode,mb.physical_processed_on,mb.physical_processed_time,mb.physical_time_precision,
      mb.total_weight_kg as total_kg,mb.total_units,mb.trolley_capture_status,
      mb.planned_output_trolley_quantity,mb.recorded_at,mb.notes,mb.status,
      mb.revision_no,mb.supersedes_mop_production_batch_id,mb.change_reason,
      mb.cancellation_kind,mb.cancellation_reason,mb.cancelled_at,
      cancel_staff.display_name as cancelled_by_name,
      coalesce(lines.lines,'[]'::jsonb) as lines,
      coalesce(trolleys.trolley_codes,'[]'::jsonb) as trolley_codes,
      coalesce(abs_data.active_abs_batches,'[]'::jsonb) as active_abs_batches,
      coalesce(abs_data.abs_history_count,0)::integer as abs_history_count,
      coalesce(revisions.revision_history,'[]'::jsonb) as revision_history,
      coalesce(trolleys.live_trolley_locked,false) as live_trolley_locked,
      case
        when mb.status='CANCELLED' then 'CANCELLED'
        when coalesce(abs_data.active_abs_count,0)>0 then 'POSTED'
        else 'PENDING'
      end as abs_status
    from selected mb
    join public.production_flow_items pfi on pfi.production_flow_item_id=mb.production_flow_item_id
    left join public.staff_members sm on sm.staff_id=mb.operator_staff_id
    left join public.staff_members cancel_staff on cancel_staff.staff_id=mb.cancelled_by_staff_id
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product_variant_id',ml.product_variant_id,'variant_code',ml.variant_code_snapshot,
        'variant_name',ml.variant_name_snapshot,'weight_kg',ml.weight_kg,'units',ml.units,
        'unit_weight_grams',ml.unit_weight_grams_snapshot
      ) order by ml.created_at,ml.mop_production_line_id),'[]'::jsonb) as lines
      from public.sorting_mop_production_lines ml
      where ml.mop_production_batch_id=mb.mop_production_batch_id
    ) lines on true
    left join lateral (
      select coalesce(jsonb_agg(mt.trolley_code_snapshot order by mt.created_at,mt.mop_production_trolley_id),'[]'::jsonb) as trolley_codes,
             coalesce(bool_or(mt.lifecycle_action='LIVE_ASSIGNMENT'),false) as live_trolley_locked
      from public.sorting_mop_production_trolleys mt
      where mt.mop_production_batch_id=mb.mop_production_batch_id
    ) trolleys on true
    left join lateral (
      select count(*) filter(where b.status='ACTIVE')::integer as active_abs_count,
             count(*)::integer as abs_history_count,
             coalesce(jsonb_agg(jsonb_build_object(
               'external_batch_id',b.production_flow_external_batch_id,'batch_reference',b.batch_reference,
               'batch_number',b.batch_number,'batch_business_date',b.batch_business_date,
               'batch_week_start',b.batch_week_start,'quantity',b.quantity,'unit_code',b.unit_code,
               'capture_source',b.capture_source,'status',b.status,'recorded_at',b.recorded_at,
               'recorded_by_staff_id',b.recorded_by_staff_id,'recorded_by_name',abs_staff.display_name,
               'notes',b.notes,'supersedes_external_batch_id',b.supersedes_external_batch_id,
               'correction_reason',b.correction_reason,'cancelled_at',b.cancelled_at
             ) order by b.recorded_at desc,b.production_flow_external_batch_id desc)
             filter(where b.status='ACTIVE'),'[]'::jsonb) as active_abs_batches
      from public.production_flow_external_batches b
      left join public.staff_members abs_staff on abs_staff.staff_id=b.recorded_by_staff_id
      where b.production_flow_item_id=mb.production_flow_item_id and b.external_system_code='ABS'
    ) abs_data on true
    left join lateral (
      select coalesce(jsonb_agg(jsonb_build_object(
        'mop_production_batch_id',h.mop_production_batch_id,'revision_no',h.revision_no,
        'status',h.status,'total_kg',h.total_weight_kg,'total_units',h.total_units,
        'recorded_at',h.recorded_at,'recorded_by_name',rec.display_name,
        'change_reason',h.change_reason,'cancellation_kind',h.cancellation_kind,
        'cancellation_reason',h.cancellation_reason,'cancelled_at',h.cancelled_at,
        'cancelled_by_name',can.display_name
      ) order by h.revision_no desc,h.recorded_at desc),'[]'::jsonb) as revision_history
      from public.sorting_mop_production_batches h
      left join public.staff_members rec on rec.staff_id=h.recorded_by_staff_id
      left join public.staff_members can on can.staff_id=h.cancelled_by_staff_id
      where h.production_flow_item_id=mb.production_flow_item_id
    ) revisions on true
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by coalesce(t.cancelled_at,t.recorded_at) desc,t.mop_production_batch_id desc),'[]'::jsonb),
         count(*) filter(where t.status='RECORDED' and t.abs_status='PENDING')::integer,
         count(*) filter(where t.status='RECORDED' and t.abs_status='POSTED')::integer,
         count(*) filter(where t.status='CANCELLED')::integer
  into v_rows,v_pending,v_posted,v_cancelled
  from trace_rows t;

  return jsonb_build_object(
    'rows',v_rows,'pending_abs_count',v_pending,'posted_abs_count',v_posted,
    'cancelled_count',v_cancelled,'limit',v_limit,
    'source','MOP_PRODUCTION_REVISION_TRACE_PLUS_SHARED_PRODUCTION_FLOW_ABS',
    'correction_contract','APPEND_ONLY_REPLACEMENT'
  );
end;
$$;


-- ---------------------------------------------------------------------
-- Shared ABS authorization is product-scoped. MOP_OPERATOR cannot use the
-- generic ABS RPC against CLOTHES, and MOP quantity remains server-derived.
-- ---------------------------------------------------------------------

create or replace function public.require_production_flow_abs_batch_write_access(
  p_production_flow_item_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_product_code text;
  v_has_mop_production boolean:=false;
begin
  if auth.uid() is null or public.current_staff_id() is null then
    raise exception using
      errcode='42501',
      message='An authenticated staff profile is required for ABS production batch entry.';
  end if;

  select pfi.product_code into v_product_code
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=p_production_flow_item_id;

  if not found then
    raise exception using errcode='P0002',message='Production Flow Item was not found.';
  end if;

  if public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR']) then
    return;
  end if;

  if public.has_any_role(array['FINISH_OPERATOR']) and v_product_code='CLOTHES' then
    return;
  end if;

  if public.has_any_role(array['MOP_OPERATOR']) and v_product_code='MOP' then
    return;
  end if;

  if public.has_any_role(array['SORTING_OPERATOR']) and v_product_code='MOP' then
    select exists(
      select 1 from public.sorting_mop_production_batches mb
      where mb.production_flow_item_id=p_production_flow_item_id
        and mb.status='RECORDED'
    ) into v_has_mop_production;
    if v_has_mop_production then return; end if;
  end if;

  raise exception using
    errcode='42501',
    message='Your active role does not allow ABS production batch entry for this Production Flow item.';
end;
$$;

create or replace function public.record_production_flow_abs_batch(
  p_production_flow_item_id uuid,
  p_batch_reference text,
  p_quantity numeric,
  p_unit_code text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_unit text := upper(trim(coalesce(p_unit_code,'')));
  v_reference text := nullif(trim(coalesce(p_batch_reference,'')),'');
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_staff_id uuid;
  v_batch public.production_flow_external_batches%rowtype;
  v_effective_quantity numeric := p_quantity;
  v_effective_unit text := upper(trim(coalesce(p_unit_code,'')));
  v_sorting_constrained boolean := false;
  v_mop_total_kg numeric;
  v_mop_total_units integer;
begin
  perform public.require_production_flow_abs_batch_write_access(
    p_production_flow_item_id
  );

  if v_reference is null then
    raise exception using errcode='22023', message='ABS batch number is required.';
  end if;

  if v_notes is not null and length(v_notes)>1000 then
    raise exception using errcode='22023', message='ABS batch notes must be 1000 characters or fewer.';
  end if;

  select *
  into v_flow
  from public.production_flow_items pfi
  where pfi.production_flow_item_id=p_production_flow_item_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Production Flow Item was not found.';
  end if;

  -- Authenticated users share one database role in the browser, so authorization
  -- cannot rely on GRANT alone. A staff member whose only applicable batch-write
  -- path is SORTING_OPERATOR must never be able to bypass the MOP wrapper by
  -- calling this shared function with a browser-supplied quantity. For that path
  -- the authoritative quantity/unit are derived again from RECORDED MOP Production.
  v_sorting_constrained :=
    v_flow.product_code='MOP'
    and public.has_any_role(array['SORTING_OPERATOR','MOP_OPERATOR'])
    and not public.has_any_role(array[
      'ADMIN','MANAGER','SUPERVISOR'
    ]);

  if v_sorting_constrained then
    if v_flow.product_code<>'MOP' then
      raise exception using
        errcode='42501',
        message='Operational MOP roles may post ABS only for recorded MOP Production.';
    end if;

    select mb.total_weight_kg, mb.total_units
    into v_mop_total_kg, v_mop_total_units
    from public.sorting_mop_production_batches mb
    where mb.production_flow_item_id=v_flow.production_flow_item_id
      and mb.status='RECORDED'
    order by mb.recorded_at desc, mb.mop_production_batch_id desc
    limit 1;

    if not found then
      raise exception using
        errcode='42501',
        message='MOP ABS entry requires an already-recorded MOP Production batch.';
    end if;

    if coalesce(v_mop_total_kg,0)>0 then
      v_effective_quantity:=v_mop_total_kg;
      v_effective_unit:='KG';
    elsif coalesce(v_mop_total_units,0)>0 then
      v_effective_quantity:=v_mop_total_units;
      v_effective_unit:='UNIT';
    else
      raise exception using
        errcode='22023',
        message='Recorded MOP Production has no positive KG or Units for ABS batch entry.';
    end if;
  else
    v_effective_quantity:=p_quantity;
    v_effective_unit:=v_unit;
  end if;

  if v_effective_quantity is null or v_effective_quantity <= 0 then
    raise exception using errcode='22023', message='ABS batch quantity must be greater than zero.';
  end if;

  if v_effective_unit not in ('KG','UNIT') then
    raise exception using errcode='22023', message='ABS batch unit must be KG or UNIT.';
  end if;

  if v_effective_unit='UNIT' and v_effective_quantity <> trunc(v_effective_quantity) then
    raise exception using errcode='22023', message='ABS UNIT quantity must be a whole number.';
  end if;

  v_staff_id := public.current_staff_id();

  insert into public.production_flow_external_batches (
    production_flow_item_id,
    external_system_code,
    batch_reference,
    quantity,
    unit_code,
    capture_source,
    status,
    notes,
    recorded_by_staff_id,
    recorded_by_auth_user_id
  )
  values (
    v_flow.production_flow_item_id,
    'ABS',
    v_reference,
    v_effective_quantity,
    v_effective_unit,
    'MANUAL',
    'ACTIVE',
    v_notes,
    v_staff_id,
    auth.uid()
  )
  returning * into v_batch;

  perform public.append_production_flow_event(
    v_flow.production_flow_item_id,
    'ABS_BATCH_RECORDED',
    'PRODUCTION',
    40,
    case when v_flow.product_code='MOP' then 'MOP' else 'FINISH' end,
    public.current_business_date(),
    v_batch.recorded_at,
    v_staff_id,
    v_staff_id,
    auth.uid(),
    'ELISCARETEXT_V2',
    'production_flow_external_batches',
    v_batch.production_flow_external_batch_id::text,
    jsonb_build_object(
      'external_system_code','ABS',
      'batch_reference',v_batch.batch_reference,
      'quantity',v_batch.quantity,
      'unit_code',v_batch.unit_code,
      'capture_source',v_batch.capture_source
    )
  );

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    v_staff_id,
    'PRODUCTION_FLOW_ABS_BATCH_RECORDED',
    'production_flow_external_batches',
    v_batch.production_flow_external_batch_id::text,
    to_jsonb(v_batch),
    v_notes,
    'ELISCARETEXT_V2'
  );

  return jsonb_build_object(
    'status','success',
    'production_flow_item_id',v_flow.production_flow_item_id,
    'flow_code',v_flow.flow_code,
    'external_batch_id',v_batch.production_flow_external_batch_id,
    'batch_reference',v_batch.batch_reference,
    'quantity',v_batch.quantity,
    'unit_code',v_batch.unit_code,
    'capture_source',v_batch.capture_source,
    'quantity_source',case when v_sorting_constrained then 'RECORDED_MOP_PRODUCTION' else 'CALLER_AUTHORIZED' end,
    'message',format(
      'ABS batch %s recorded manually for %s.',
      v_batch.batch_reference,
      v_flow.flow_code
    )
  );
end;
$$;

-- Preserve browser execute only on the governed MOP surface. Existing MOP RPC
-- grants are retained by CREATE OR REPLACE; this section makes the new entry
-- point explicit.
revoke all on function public.get_mop_auto_shift_context(timestamptz) from anon;

commit;
