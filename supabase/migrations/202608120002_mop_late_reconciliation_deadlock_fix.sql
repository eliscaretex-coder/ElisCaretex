-- ElisCaretex V2
-- Migration 038: allow an overdue MOP item to resolve itself through late reconciliation.
-- Date: 2026-08-12
-- Owner-run SQL.

begin;

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
  perform public.require_sorting_operational_access();
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

revoke all on function public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text)
  from public,anon,authenticated;
grant execute on function public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text)
  to authenticated;

commit;
