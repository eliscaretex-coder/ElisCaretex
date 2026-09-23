-- ElisCaretex V2 - Migration 046 - Finish Auto Shift and trolley scan control
-- PREPARED: owner executes in Development.
--
-- Purpose:
-- - Resolve Finish shift from the governed Production Roster work profile, matching Sorting Auto Shift behavior.
-- - Add a trolley scan/precheck contract that shows planned quantity/type against physical scanned trolleys.
-- - Preserve the MOP-style Operational Report path for incorrect trolley quantity/type.
-- - Allow a trolley already assigned by an earlier Finish contribution of the SAME Production Flow
--   to be reused by a continuation without opening a duplicate customer stay.
-- - No published Roster or Customer Schedule row is changed.

begin;

create or replace function public.get_finish_auto_shift_context(
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_reference_at timestamptz := coalesce(p_at,now());
  v_timezone text := 'Europe/Dublin';
  v_rollover time := time '03:00';
  v_local timestamp;
  v_local_date date;
  v_local_time time;
  v_evening_profile jsonb;
  v_evening_start time;
  v_shift_code text;
  v_business_date date;
  v_reason text;
  v_next_change timestamp;
begin
  perform public.require_finish_production_access();

  select coalesce(nullif(value_json #>> '{}',''),'Europe/Dublin')
  into v_timezone
  from public.app_config
  where config_key='business_timezone';
  v_timezone := coalesce(v_timezone,'Europe/Dublin');

  select coalesce(nullif(value_json #>> '{}','')::time,time '03:00')
  into v_rollover
  from public.app_config
  where config_key='evening_shift_rollover_time';
  v_rollover := coalesce(v_rollover,time '03:00');

  v_local := v_reference_at at time zone v_timezone;
  v_local_date := v_local::date;
  v_local_time := v_local::time;

  if v_local_time < v_rollover then
    v_shift_code := 'EVENING';
    v_business_date := v_local_date - 1;
    v_reason := 'EVENING_OVERNIGHT_CONTINUATION';
    v_next_change := (v_local_date::text || ' ' || v_rollover::text)::timestamp;
  else
    v_evening_profile := public.production_roster_work_profile_context(v_local_date,'EVENING');
    v_evening_start := nullif(v_evening_profile ->> 'default_start_time','')::time;

    if v_evening_start is null then
      select sh.start_time
      into v_evening_start
      from public.shifts sh
      where sh.shift_code='EVENING' and sh.active=true and sh.deleted_at is null
      limit 1;
    end if;

    if v_evening_start is null then
      raise exception using errcode='P0002', message='Evening shift start time could not be resolved from the Roster work profile or Shift master.';
    end if;

    if v_local_time >= v_evening_start then
      v_shift_code := 'EVENING';
      v_business_date := v_local_date;
      v_reason := case when v_evening_profile is null then 'EVENING_SHIFT_MASTER_START' else 'EVENING_WORK_PROFILE_START' end;
      v_next_change := ((v_local_date + 1)::text || ' ' || v_rollover::text)::timestamp;
    else
      v_shift_code := 'MORNING';
      v_business_date := v_local_date;
      v_reason := case when v_evening_profile is null then 'BEFORE_EVENING_SHIFT_MASTER_START' else 'BEFORE_EVENING_WORK_PROFILE_START' end;
      v_next_change := (v_local_date::text || ' ' || v_evening_start::text)::timestamp;
    end if;
  end if;

  return jsonb_build_object(
    'recommended_shift_code',v_shift_code,
    'business_date',v_business_date,
    'local_date',v_local_date,
    'local_time',v_local_time,
    'timezone',v_timezone,
    'evening_rollover_time',v_rollover,
    'evening_standard_start',v_evening_start,
    'evening_work_profile',v_evening_profile,
    'reason',v_reason,
    'next_auto_change_local',v_next_change,
    'reference_at',v_reference_at
  );
end;
$$;

create or replace function public.validate_finish_trolley_selection(
  p_production_flow_item_id uuid,
  p_trolley_codes text[] default array[]::text[],
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype;
  v_delivery date;
  v_cutoff timestamptz;
  v_plan jsonb := '[]'::jsonb;
  v_plan_total integer := 0;
  v_scanned jsonb := '[]'::jsonb;
  v_hard_issues jsonb := '[]'::jsonb;
  v_plan_issues jsonb := '[]'::jsonb;
  v_code text;
  v_trolley public.trolleys%rowtype;
  v_type public.trolley_types%rowtype;
  v_open_stay public.trolley_customer_stays%rowtype;
  v_same_flow boolean;
  v_have integer;
  v_req record;
  v_extra record;
  v_scanned_total integer := 0;
  v_matches_plan boolean := true;
begin
  perform public.require_finish_production_access();

  select * into v_flow
  from public.production_flow_items
  where production_flow_item_id=p_production_flow_item_id;

  if not found or v_flow.product_code<>'CLOTHES' then
    raise exception using errcode='22023', message='A valid CLOTHES Production Flow item is required.';
  end if;

  select x.delivery_date,x.edit_cutoff_at
  into v_delivery,v_cutoff
  from public.finish_assert_entry_open(v_flow.production_flow_item_id,coalesce(p_at,now())) x;

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
    v_scanned_total := v_scanned_total + 1;
    v_same_flow := false;

    select * into v_trolley
    from public.trolleys t
    where lower(t.trolley_code)=lower(v_code)
      and t.deleted_at is null;

    if not found then
      v_scanned := v_scanned || jsonb_build_array(jsonb_build_object(
        'trolley_code',v_code,'exists',false,'usable',false,'issue','NOT_FOUND'
      ));
      v_hard_issues := v_hard_issues || jsonb_build_array(format('%s: trolley not found.',v_code));
      continue;
    end if;

    select * into v_type
    from public.trolley_types tt
    where tt.trolley_type_id=v_trolley.trolley_type_id;

    select * into v_open_stay
    from public.trolley_customer_stays s
    where s.trolley_id=v_trolley.trolley_id
      and s.received_on is null
    order by s.created_at desc
    limit 1;

    select exists(
      select 1
      from public.finish_production_trolleys ft
      join public.finish_production_entries e on e.finish_production_entry_id=ft.finish_production_entry_id
      where ft.trolley_id=v_trolley.trolley_id
        and e.production_flow_item_id=v_flow.production_flow_item_id
        and e.status='ACTIVE'
    ) into v_same_flow;

    if not coalesce(v_trolley.active,false) or v_trolley.status in ('OUT_OF_SERVICE','RETIRED') then
      v_hard_issues := v_hard_issues || jsonb_build_array(format('%s: trolley is %s.',v_trolley.trolley_code,v_trolley.status));
    elsif v_open_stay.stay_id is not null
          and (not v_same_flow or v_open_stay.outbound_customer_id is distinct from v_flow.customer_id) then
      v_hard_issues := v_hard_issues || jsonb_build_array(format('%s: trolley already has an open customer stay for another production/customer.',v_trolley.trolley_code));
    elsif v_open_stay.stay_id is null and v_trolley.status not in ('AVAILABLE','LOCATION_UNCONFIRMED') then
      v_hard_issues := v_hard_issues || jsonb_build_array(format('%s: trolley cannot be assigned from Finish while status is %s.',v_trolley.trolley_code,v_trolley.status));
    end if;

    v_scanned := v_scanned || jsonb_build_array(jsonb_build_object(
      'trolley_id',v_trolley.trolley_id,
      'trolley_code',v_trolley.trolley_code,
      'exists',true,
      'active',v_trolley.active,
      'stored_status',v_trolley.status,
      'trolley_type_id',v_type.trolley_type_id,
      'trolley_type_code',v_type.trolley_type_code,
      'display_code',coalesce(v_type.display_code,v_type.trolley_type_code),
      'trolley_type_name',v_type.trolley_type_name,
      'same_finish_flow',v_same_flow,
      'open_stay_id',v_open_stay.stay_id,
      'open_stay_customer_id',v_open_stay.outbound_customer_id,
      'usable',(
        coalesce(v_trolley.active,false)
        and v_trolley.status not in ('OUT_OF_SERVICE','RETIRED')
        and (
          (v_open_stay.stay_id is not null and v_same_flow and v_open_stay.outbound_customer_id=v_flow.customer_id)
          or (v_open_stay.stay_id is null and v_trolley.status in ('AVAILABLE','LOCATION_UNCONFIRMED'))
        )
      )
    ));
  end loop;

  for v_req in
    select r.trolley_type_id,r.quantity,tt.trolley_type_code,coalesce(tt.display_code,tt.trolley_type_code) display_code,tt.trolley_type_name
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
      v_matches_plan := false;
      v_plan_issues := v_plan_issues || jsonb_build_array(
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
        select 1
        from public.customer_schedule_trolley_requirements r
        where r.active=true
          and r.owner_schedule_product_id=v_flow.source_schedule_product_id
          and r.trolley_type_id=(d->>'trolley_type_id')::uuid
      )
    group by d->>'trolley_type_id',coalesce(d->>'display_code',d->>'trolley_type_code','Unknown')
  loop
    v_matches_plan := false;
    v_plan_issues := v_plan_issues || jsonb_build_array(
      format('%s: %s scanned but this type is not in the published plan.',v_extra.display_code,v_extra.qty)
    );
  end loop;

  if v_plan_total=0 and v_scanned_total>0 then
    v_matches_plan := false;
    v_plan_issues := v_plan_issues || jsonb_build_array(
      format('Published plan has no trolley requirement, but %s trolley(s) were scanned.',v_scanned_total)
    );
  elsif v_plan_total>0 and v_scanned_total<>v_plan_total and jsonb_array_length(v_plan_issues)=0 then
    v_matches_plan := false;
    v_plan_issues := v_plan_issues || jsonb_build_array(
      format('Published plan expects %s trolley(s); %s were scanned.',v_plan_total,v_scanned_total)
    );
  end if;

  return jsonb_build_object(
    'schema_version','FINISH_TROLLEY_SCAN_V1',
    'production_flow_item_id',v_flow.production_flow_item_id,
    'customer_id',v_flow.customer_id,
    'customer_name',v_flow.customer_name_snapshot,
    'scheduled_for_date',v_flow.scheduled_for_date,
    'delivery_date',v_delivery,
    'edit_cutoff_at',v_cutoff,
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

create or replace function public.finish_enforce_new_entry_current_shift()
returns trigger
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_auto jsonb;
  v_expected_shift text;
begin
  -- A correction keeps the original shift lineage. Only a brand-new contribution
  -- must match the governed operational shift at the actual record timestamp.
  if coalesce(new.revision_no,1)=1 then
    v_auto := public.get_finish_auto_shift_context(coalesce(new.recorded_at,now()));
    v_expected_shift := upper(coalesce(v_auto->>'recommended_shift_code',''));
    if v_expected_shift not in ('MORNING','EVENING') then
      raise exception using errcode='P0002', message='Current Finish operational shift could not be resolved.';
    end if;
    if upper(coalesce(new.shift_code_snapshot,''))<>v_expected_shift then
      raise exception using errcode='23514',
        message=format('New Finish production must use the current operational shift (%s). Switch Finish back to Auto/current shift and try again.',initcap(lower(v_expected_shift)));
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.finish_enforce_new_entry_current_shift() from public,anon,authenticated;

drop trigger if exists trg_finish_enforce_new_entry_current_shift on public.finish_production_entries;
create trigger trg_finish_enforce_new_entry_current_shift
before insert on public.finish_production_entries
for each row execute function public.finish_enforce_new_entry_current_shift();

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
     or p_production_business_date<v_flow.scheduled_for_date
     or p_production_business_date>v_delivery then
    raise exception using errcode='22023', message='Finish trolley contribution date must be between the scheduled production date and Delivery Date.';
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

revoke all on function public.get_finish_auto_shift_context(timestamptz) from public,anon,authenticated;
revoke all on function public.validate_finish_trolley_selection(uuid,text[],timestamptz) from public,anon,authenticated;
revoke all on function public.assign_finish_trolley_to_flow(text,uuid,date,text) from public,anon,authenticated;

grant execute on function public.get_finish_auto_shift_context(timestamptz) to authenticated;
grant execute on function public.validate_finish_trolley_selection(uuid,text[],timestamptz) to authenticated;
-- assignment remains an internal helper called only from governed Finish save/correction RPCs.

comment on function public.get_finish_auto_shift_context(timestamptz) is
'Authoritative Finish Auto Shift context. Uses Europe/Dublin, the 03:00 rollover and the active Production Roster Evening work-profile start (Shift master fallback).';

comment on function public.validate_finish_trolley_selection(uuid,text[],timestamptz) is
'Finish trolley scan precheck. Returns published quantity/type plan, physical scanned trolley type/status and plan mismatch evidence without mutating Customer Schedule.';

comment on function public.assign_finish_trolley_to_flow(text,uuid,date,text) is
'Internal Finish trolley lifecycle helper. Reuses an existing open stay only when the trolley is already linked to the same active Finish Production Flow and same customer; otherwise normal lifecycle safety rules apply.';

comment on function public.finish_enforce_new_entry_current_shift() is
'Guards new Finish production contributions so their shift matches the governed current Finish Auto Shift. Corrections preserve original shift lineage.';

commit;
