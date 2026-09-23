-- A Finish flow can be opened before its planned production date so the area can
-- stage work for the next delivery. Keep the delivery cutoff, but allow records
-- from the date the Production Flow was opened.
create or replace function public.assign_finish_trolley_to_flow(
  p_trolley_code text,
  p_production_flow_item_id uuid,
  p_production_business_date date,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_existing_stay public.trolley_customer_stays%rowtype;
  v_staff uuid;
  v_delivery date;
  v_existing_link boolean := false;
begin
  perform public.require_finish_production_access();

  if nullif(trim(p_trolley_code),'') is null then
    raise exception using errcode='22023', message='Trolley code is required.';
  end if;

  select * into v_flow
  from public.production_flow_items
  where production_flow_item_id=p_production_flow_item_id;

  if not found or v_flow.product_code<>'CLOTHES' or v_flow.scheduled_for_date is null then
    raise exception using errcode='22023', message='A scheduled CLOTHES Production Flow item is required.';
  end if;

  v_delivery := public.next_distribution_business_date(v_flow.scheduled_for_date);
  if p_production_business_date is null
     or p_production_business_date < coalesce(v_flow.opened_business_date,v_flow.scheduled_for_date)
     or p_production_business_date > v_delivery then
    raise exception using errcode='22023', message='Finish trolley contribution date must be from the Production Flow opening date through the Delivery Date.';
  end if;

  if now()>=public.finish_delivery_cutoff(v_delivery) then
    raise exception using errcode='23514', message='Finish trolley assignment is locked after the Delivery Date 12:00 cutoff.';
  end if;

  v_staff := public.current_staff_id();

  select * into v_trolley
  from public.trolleys t
  where lower(t.trolley_code)=lower(trim(p_trolley_code))
    and t.deleted_at is null
  for update;

  if not found then
    raise exception using errcode='P0002', message=format('Trolley not found: %s',trim(p_trolley_code));
  end if;

  select exists(
    select 1
    from public.finish_production_trolleys ft
    join public.finish_production_entries e on e.finish_production_entry_id=ft.finish_production_entry_id
    where ft.trolley_id=v_trolley.trolley_id
      and e.production_flow_item_id=v_flow.production_flow_item_id
      and e.status='ACTIVE'
  ) into v_existing_link;

  if v_existing_link then
    select s.* into v_existing_stay
    from public.trolley_customer_stays s
    where s.trolley_id=v_trolley.trolley_id
      and s.received_on is null
      and s.outbound_customer_id=v_flow.customer_id
    order by s.created_at desc
    limit 1;

    if v_existing_stay.stay_id is not null then
      return jsonb_build_object(
        'trolley_id',v_trolley.trolley_id,
        'trolley_code',v_trolley.trolley_code,
        'stay_id',v_existing_stay.stay_id,
        'customer_id',v_flow.customer_id,
        'production_flow_item_id',v_flow.production_flow_item_id,
        'production_business_date',p_production_business_date,
        'planned_delivery_on',v_existing_stay.planned_delivery_on,
        'status','ALREADY_ASSIGNED_SAME_FINISH_FLOW',
        'lifecycle_reused',true
      );
    end if;
  end if;

  if not v_trolley.active or v_trolley.status not in ('AVAILABLE','LOCATION_UNCONFIRMED') then
    raise exception using errcode='23514', message=format('Trolley %s cannot be assigned from Finish. Current status: %s',v_trolley.trolley_code,v_trolley.status);
  end if;

  if exists(
    select 1 from public.trolley_customer_stays s
    where s.trolley_id=v_trolley.trolley_id and s.received_on is null
  ) then
    raise exception using errcode='23505', message=format('Trolley %s already has an open customer stay.',v_trolley.trolley_code);
  end if;

  insert into public.trolley_customer_stays(
    trolley_id,outbound_customer_id,sent_on,status,review_status,sent_recorded_by,notes,
    production_business_date,planned_delivery_on,production_area_code,custody_start_source,
    source_schedule_version_id,source_schedule_day_id,source_schedule_product_id,
    production_recorded_by,production_recorded_at
  )
  values(
    v_trolley.trolley_id,v_flow.customer_id,v_delivery,'OPEN','NOT_REQUIRED',v_staff,nullif(trim(p_notes),''),
    p_production_business_date,v_delivery,'FINISH','PRODUCTION_NEXT_DAY_INFERENCE',
    v_flow.source_schedule_version_id,v_flow.source_schedule_day_id,v_flow.source_schedule_product_id,
    v_staff,now()
  )
  returning * into v_stay;

  update public.trolleys
  set status='IN_PRODUCTION',updated_by=auth.uid()
  where trolley_id=v_trolley.trolley_id;

  insert into public.trolley_events(
    trolley_id,stay_id,event_type,customer_id,business_date,performed_by,source_application,reason,metadata
  )
  values(
    v_trolley.trolley_id,v_stay.stay_id,'ASSIGNED_IN_PRODUCTION',v_flow.customer_id,p_production_business_date,
    v_staff,'FINISH_V2',p_notes,
    jsonb_build_object(
      'production_flow_item_id',v_flow.production_flow_item_id,
      'scheduled_for_date',v_flow.scheduled_for_date,
      'production_business_date',p_production_business_date,
      'planned_delivery_on',v_delivery,
      'production_area_code','FINISH',
      'product_code','CLOTHES',
      'custody_start_source','PRODUCTION_NEXT_DAY_INFERENCE'
    )
  );

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application
  )
  values(
    auth.uid(),v_staff,'ASSIGN_TROLLEY_FROM_FINISH_PRODUCTION','trolley_customer_stays',v_stay.stay_id::text,
    to_jsonb(v_stay),p_notes,'FINISH_V2'
  );

  return jsonb_build_object(
    'trolley_id',v_trolley.trolley_id,
    'trolley_code',v_trolley.trolley_code,
    'stay_id',v_stay.stay_id,
    'customer_id',v_flow.customer_id,
    'production_flow_item_id',v_flow.production_flow_item_id,
    'production_business_date',p_production_business_date,
    'planned_delivery_on',v_delivery,
    'status','IN_PRODUCTION',
    'lifecycle_reused',false
  );
end;
$$;

revoke all on function public.assign_finish_trolley_to_flow(text,uuid,date,text) from public,anon,authenticated;

comment on function public.assign_finish_trolley_to_flow(text,uuid,date,text) is
  'Creates Finish trolley custody from the Production Flow opening date through its inferred Delivery Date.';
