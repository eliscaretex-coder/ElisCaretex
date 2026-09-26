-- ElisCaretex V2
-- MOP trolley quantity/type validation and terminal-safe ABS attribution.

begin;

create or replace function public.validate_mop_trolley_selection(
  p_production_flow_item_id uuid,
  p_trolley_codes text[] default array[]::text[]
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_plan jsonb:='[]'::jsonb;
  v_plan_total integer:=0;
  v_scanned jsonb:='[]'::jsonb;
  v_hard_issues jsonb:='[]'::jsonb;
  v_plan_issues jsonb:='[]'::jsonb;
  v_code text;
  v_trolley public.trolleys%rowtype;
  v_type public.trolley_types%rowtype;
  v_open_stay public.trolley_customer_stays%rowtype;
  v_req record;
  v_extra record;
  v_have integer;
  v_scanned_total integer:=0;
  v_matches_plan boolean:=true;
begin
  perform public.begin_mop_operational_scope();

  select * into v_flow
  from public.production_flow_items
  where production_flow_item_id=p_production_flow_item_id;

  if not found or v_flow.product_code<>'MOP' then
    raise exception using errcode='22023',message='A valid MOP Production Flow item is required.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'trolley_type_id',tt.trolley_type_id,
      'trolley_type_code',tt.trolley_type_code,
      'display_code',coalesce(tt.display_code,tt.trolley_type_code),
      'trolley_type_name',tt.trolley_type_name,
      'quantity',r.quantity,
      'empty_trolley',r.empty_trolley
    ) order by tt.sort_order,tt.trolley_type_code),'[]'::jsonb),
    coalesce(sum(r.quantity),0)::integer
  into v_plan,v_plan_total
  from public.customer_schedule_trolley_requirements r
  join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id
  where r.active=true
    and r.owner_schedule_product_id=v_flow.source_schedule_product_id;

  for v_code in
    select distinct upper(trim(x))
    from unnest(coalesce(p_trolley_codes,array[]::text[])) x
    where nullif(trim(x),'') is not null
    order by upper(trim(x))
  loop
    v_scanned_total:=v_scanned_total+1;
    v_open_stay:=null;

    select * into v_trolley
    from public.trolleys t
    where lower(t.trolley_code)=lower(v_code)
      and t.deleted_at is null;

    if not found then
      v_scanned:=v_scanned||jsonb_build_array(jsonb_build_object(
        'trolley_code',v_code,'exists',false,'usable',false,'issue','NOT_FOUND'
      ));
      v_hard_issues:=v_hard_issues||jsonb_build_array(format('%s: trolley not found.',v_code));
      continue;
    end if;

    select * into v_type
    from public.trolley_types tt
    where tt.trolley_type_id=v_trolley.trolley_type_id;

    select * into v_open_stay
    from public.trolley_customer_stays s
    where s.trolley_id=v_trolley.trolley_id and s.received_on is null
    order by s.created_at desc limit 1;

    if not coalesce(v_trolley.active,false) or v_trolley.status in ('OUT_OF_SERVICE','RETIRED') then
      v_hard_issues:=v_hard_issues||jsonb_build_array(format('%s: trolley is %s.',v_trolley.trolley_code,v_trolley.status));
    elsif v_open_stay.stay_id is not null then
      v_hard_issues:=v_hard_issues||jsonb_build_array(format('%s: trolley already has an open customer stay.',v_trolley.trolley_code));
    elsif v_trolley.status not in ('AVAILABLE','LOCATION_UNCONFIRMED') then
      v_hard_issues:=v_hard_issues||jsonb_build_array(format('%s: trolley cannot be assigned from MOP while status is %s.',v_trolley.trolley_code,v_trolley.status));
    end if;

    v_scanned:=v_scanned||jsonb_build_array(jsonb_build_object(
      'trolley_id',v_trolley.trolley_id,
      'trolley_code',v_trolley.trolley_code,
      'exists',true,
      'active',v_trolley.active,
      'stored_status',v_trolley.status,
      'trolley_type_id',v_type.trolley_type_id,
      'trolley_type_code',v_type.trolley_type_code,
      'display_code',coalesce(v_type.display_code,v_type.trolley_type_code),
      'trolley_type_name',v_type.trolley_type_name,
      'open_stay_id',v_open_stay.stay_id,
      'usable',coalesce(v_trolley.active,false)
        and v_trolley.status in ('AVAILABLE','LOCATION_UNCONFIRMED')
        and v_open_stay.stay_id is null
    ));
  end loop;

  for v_req in
    select r.trolley_type_id,r.quantity,tt.trolley_type_code,
      coalesce(tt.display_code,tt.trolley_type_code) display_code
    from public.customer_schedule_trolley_requirements r
    join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id
    where r.active=true and r.owner_schedule_product_id=v_flow.source_schedule_product_id
    order by tt.sort_order,tt.trolley_type_code
  loop
    select count(*)::integer into v_have
    from jsonb_array_elements(v_scanned) d
    where coalesce((d->>'exists')::boolean,false)=true
      and d->>'trolley_type_id'=v_req.trolley_type_id::text;

    if v_have<>v_req.quantity then
      v_matches_plan:=false;
      v_plan_issues:=v_plan_issues||jsonb_build_array(
        format('%s: planned %s, scanned %s.',v_req.display_code,v_req.quantity,v_have)
      );
    end if;
  end loop;

  for v_extra in
    select d->>'trolley_type_id' trolley_type_id,
      coalesce(d->>'display_code',d->>'trolley_type_code','Unknown') display_code,
      count(*)::integer qty
    from jsonb_array_elements(v_scanned) d
    where coalesce((d->>'exists')::boolean,false)=true
      and nullif(d->>'trolley_type_id','') is not null
      and not exists(
        select 1 from public.customer_schedule_trolley_requirements r
        where r.active=true
          and r.owner_schedule_product_id=v_flow.source_schedule_product_id
          and r.trolley_type_id=(d->>'trolley_type_id')::uuid
      )
    group by d->>'trolley_type_id',coalesce(d->>'display_code',d->>'trolley_type_code','Unknown')
  loop
    v_matches_plan:=false;
    v_plan_issues:=v_plan_issues||jsonb_build_array(
      format('%s: %s scanned but this type is not in the published plan.',v_extra.display_code,v_extra.qty)
    );
  end loop;

  if v_plan_total=0 and v_scanned_total>0 then
    v_matches_plan:=false;
    v_plan_issues:=v_plan_issues||jsonb_build_array(
      format('Published plan has no trolley requirement, but %s trolley(s) were scanned.',v_scanned_total)
    );
  elsif v_plan_total>0 and v_scanned_total<>v_plan_total and jsonb_array_length(v_plan_issues)=0 then
    v_matches_plan:=false;
    v_plan_issues:=v_plan_issues||jsonb_build_array(
      format('Published plan expects %s trolley(s); %s were scanned.',v_plan_total,v_scanned_total)
    );
  end if;

  return jsonb_build_object(
    'schema_version','MOP_TROLLEY_SCAN_V1',
    'production_flow_item_id',v_flow.production_flow_item_id,
    'customer_id',v_flow.customer_id,
    'customer_name',v_flow.customer_name_snapshot,
    'planned_requirements',v_plan,
    'planned_total',v_plan_total,
    'scanned',v_scanned,
    'scanned_total',v_scanned_total,
    'matches_plan',v_matches_plan,
    'plan_issues',v_plan_issues,
    'hard_issues',v_hard_issues,
    'hard_block',jsonb_array_length(v_hard_issues)>0,
    'can_use_selection',jsonb_array_length(v_hard_issues)=0
  );
end;
$$;

revoke all on function public.validate_mop_trolley_selection(uuid,text[]) from public,anon,authenticated;
grant execute on function public.validate_mop_trolley_selection(uuid,text[]) to authenticated;

create or replace function public.save_sorting_mop_production_v2(
  p_shift_code text,
  p_production_flow_item_id uuid,
  p_operator_staff_id uuid,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_trolley_unknown boolean default false,
  p_physical_processed_on date default null,
  p_physical_processed_time time default null,
  p_entry_mode text default 'LIVE',
  p_notes text default null,
  p_accept_trolley_mismatch boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_validation jsonb;
  v_result jsonb;
begin
  perform public.begin_mop_operational_scope();

  if upper(trim(coalesce(p_entry_mode,'LIVE')))='LIVE' then
    v_validation:=public.validate_mop_trolley_selection(p_production_flow_item_id,p_trolley_codes);
    if coalesce((v_validation->>'hard_block')::boolean,false) then
      raise exception using errcode='23514',message='One or more scanned trolleys cannot be used. Review the MOP trolley scan.';
    end if;
    if not coalesce((v_validation->>'matches_plan')::boolean,false)
       and not coalesce(p_accept_trolley_mismatch,false) then
      raise exception using errcode='22023',message='MOP trolley quantity/type does not match the published plan. Review the scan or explicitly accept the mismatch.';
    end if;
  end if;

  v_result:=public.save_sorting_mop_production(
    p_shift_code,p_production_flow_item_id,p_operator_staff_id,p_lines,p_trolley_codes,
    p_trolley_unknown,p_physical_processed_on,p_physical_processed_time,p_entry_mode,p_notes
  );

  return v_result||jsonb_build_object(
    'trolley_validation',v_validation,
    'trolley_mismatch_accepted',coalesce(p_accept_trolley_mismatch,false)
  );
end;
$$;

revoke all on function public.save_sorting_mop_production_v2(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text,boolean)
  from public,anon,authenticated;
grant execute on function public.save_sorting_mop_production_v2(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text,boolean)
  to authenticated;
revoke execute on function public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text)
  from authenticated;

create or replace function public.record_sorting_mop_abs_batch(
  p_mop_production_batch_id uuid,
  p_batch_reference text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_mop_batch public.sorting_mop_production_batches%rowtype;
  v_flow public.production_flow_items%rowtype;
  v_existing public.production_flow_external_batches%rowtype;
  v_batch public.production_flow_external_batches%rowtype;
  v_reference text:=nullif(trim(coalesce(p_batch_reference,'')),'');
  v_notes text:=nullif(trim(coalesce(p_notes,'')),'');
  v_staff_id uuid;
  v_quantity numeric;
  v_unit_code text;
  v_result jsonb;
  v_terminal boolean:=false;
begin
  perform public.begin_mop_operational_scope();
  if v_reference is null then raise exception using errcode='22023',message='ABS batch number is required.'; end if;
  if length(v_reference)>120 then raise exception using errcode='22023',message='ABS batch number must be 120 characters or fewer.'; end if;
  if v_notes is not null and length(v_notes)>1000 then raise exception using errcode='22023',message='ABS notes must be 1000 characters or fewer.'; end if;

  select * into v_mop_batch from public.sorting_mop_production_batches mb
  where mb.mop_production_batch_id=p_mop_production_batch_id and mb.status='RECORDED' for update;
  if not found then raise exception using errcode='P0002',message='Recorded MOP Production batch was not found.'; end if;

  select * into v_flow from public.production_flow_items pfi
  where pfi.production_flow_item_id=v_mop_batch.production_flow_item_id for update;
  if not found or v_flow.product_code<>'MOP' then
    raise exception using errcode='22023',message='ABS posting from MOP Production requires an exact MOP Production Flow item.';
  end if;

  select b.* into v_existing from public.production_flow_external_batches b
  where b.production_flow_item_id=v_flow.production_flow_item_id
    and b.external_system_code='ABS' and b.status='ACTIVE'
  order by b.recorded_at desc,b.production_flow_external_batch_id desc limit 1;
  if found then
    if trim(v_existing.batch_reference)=v_reference then
      return jsonb_build_object('status','success','skipped',true,'production_flow_item_id',v_flow.production_flow_item_id,
        'mop_production_batch_id',v_mop_batch.mop_production_batch_id,'external_batch_id',v_existing.production_flow_external_batch_id,
        'batch_reference',v_existing.batch_reference,'quantity',v_existing.quantity,'unit_code',v_existing.unit_code,
        'message',format('ABS batch %s is already recorded for this MOP production.',v_existing.batch_reference));
    end if;
    raise exception using errcode='23505',message=format('This MOP production already has active ABS batch %s. Use the governed ABS correction workflow instead of adding a second batch.',v_existing.batch_reference);
  end if;

  if coalesce(v_mop_batch.total_weight_kg,0)>0 then v_quantity:=v_mop_batch.total_weight_kg;v_unit_code:='KG';
  elsif coalesce(v_mop_batch.total_units,0)>0 then v_quantity:=v_mop_batch.total_units;v_unit_code:='UNIT';
  else raise exception using errcode='22023',message='The recorded MOP Production has no positive KG or Units to anchor the ABS batch.';
  end if;

  v_staff_id:=public.current_staff_id();
  if v_staff_id is not null then
    v_result:=public.record_production_flow_abs_batch(v_flow.production_flow_item_id,v_reference,v_quantity,v_unit_code,v_notes);
    return v_result||jsonb_build_object('mop_production_batch_id',v_mop_batch.mop_production_batch_id,
      'source_application','SORTING_MOP_PRODUCTION','quantity_source',case when v_unit_code='KG' then 'MOP_PRODUCTION_TOTAL_KG' else 'MOP_PRODUCTION_TOTAL_UNITS' end);
  end if;

  v_terminal:=coalesce(public.production_station_device_context('SORTING')->>'device_code','')<>'';
  v_staff_id:=v_mop_batch.operator_staff_id;
  if not v_terminal or v_staff_id is null or not exists(
    select 1 from public.staff_members sm where sm.staff_id=v_staff_id and sm.active=true and sm.deleted_at is null
  ) then
    raise exception using errcode='42501',message='A registered Sorting terminal and the staff recorded on this MOP production are required for ABS batch entry.';
  end if;

  insert into public.production_flow_external_batches(
    production_flow_item_id,external_system_code,batch_reference,quantity,unit_code,capture_source,status,notes,
    recorded_by_staff_id,recorded_by_auth_user_id
  ) values(v_flow.production_flow_item_id,'ABS',v_reference,v_quantity,v_unit_code,'MANUAL','ACTIVE',v_notes,v_staff_id,auth.uid())
  returning * into v_batch;

  perform public.append_production_flow_event(
    v_flow.production_flow_item_id,'ABS_BATCH_RECORDED','PRODUCTION',40,'MOP',public.current_business_date(),v_batch.recorded_at,
    v_staff_id,v_staff_id,auth.uid(),'SORTING_MOP_PRODUCTION','production_flow_external_batches',v_batch.production_flow_external_batch_id::text,
    jsonb_build_object('external_system_code','ABS','batch_reference',v_batch.batch_reference,'quantity',v_batch.quantity,
      'unit_code',v_batch.unit_code,'capture_source',v_batch.capture_source,'attribution_source','MOP_PRODUCTION_OPERATOR')
  );

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application)
  values(auth.uid(),v_staff_id,'PRODUCTION_FLOW_ABS_BATCH_RECORDED','production_flow_external_batches',
    v_batch.production_flow_external_batch_id::text,to_jsonb(v_batch),v_notes,'SORTING_MOP_PRODUCTION');

  return jsonb_build_object('status','success','production_flow_item_id',v_flow.production_flow_item_id,
    'mop_production_batch_id',v_mop_batch.mop_production_batch_id,'external_batch_id',v_batch.production_flow_external_batch_id,
    'batch_reference',v_batch.batch_reference,'quantity',v_batch.quantity,'unit_code',v_batch.unit_code,
    'capture_source',v_batch.capture_source,'quantity_source',case when v_unit_code='KG' then 'MOP_PRODUCTION_TOTAL_KG' else 'MOP_PRODUCTION_TOTAL_UNITS' end,
    'staff_attribution_source','MOP_PRODUCTION_OPERATOR',
    'message',format('ABS batch %s recorded for %s.',v_batch.batch_reference,v_flow.flow_code));
end;
$$;

revoke all on function public.record_sorting_mop_abs_batch(uuid,text,text) from public,anon,authenticated;
grant execute on function public.record_sorting_mop_abs_batch(uuid,text,text) to authenticated;

commit;
