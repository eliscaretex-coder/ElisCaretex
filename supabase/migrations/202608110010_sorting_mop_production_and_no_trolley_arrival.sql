-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110010_sorting_mop_production_and_no_trolley_arrival
--
-- Scope:
--   1. Allow Reception evidence without a physical trolley only when the
--      published schedule confirms that the exact product has no trolley
--      mapped to it.
--   2. Keep Washing locked until either physical trolley CONTENTS evidence
--      or controlled NO_TROLLEY contents-arrival evidence exists.
--   3. Implement MOP Production from exact washed Production Flow items.
--   4. Record per-MOP-type KG / Units using Product Variant master data.
--   5. Enforce delivery-day reconciliation from 12:00 Europe/Dublin for
--      washed MOP that has no production record.
--   6. Preserve late-entry uncertainty: a missing historical trolley code is
--      recorded as UNKNOWN_LATE_ENTRY and is never invented.
--
-- IMPORTANT:
--   This migration is PREPARED for owner execution. Do not call it APPLIED
--   or SQL VALIDATED until its companion validation has been run successfully.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Configuration: enforcement begins on the date this migration is applied.
--    This avoids turning pre-existing historical rows into a blocking backlog.
-- ---------------------------------------------------------------------

insert into public.app_config(config_key,value_json,description)
values (
  'sorting_mop_reconciliation',
  jsonb_build_object(
    'timezone','Europe/Dublin',
    'cutoff_local_time','12:00:00',
    'enforcement_from',(now() at time zone 'Europe/Dublin')::date::text
  ),
  'MOP Production delivery-day reconciliation. Washed MOP without production requires an operator decision from local noon on its Distribution due date.'
)
on conflict (config_key) do nothing;

-- ---------------------------------------------------------------------
-- 2. Controlled contents-arrival evidence for customers with no trolley.
-- ---------------------------------------------------------------------

create table if not exists public.sorting_non_trolley_arrivals (
  sorting_non_trolley_arrival_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  customer_code_snapshot text,
  customer_name_snapshot text not null,
  product_code text not null,
  business_date date not null,
  physical_received_on date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  shift_code_snapshot text not null,
  arrived_at timestamptz not null default now(),
  scheduled_for_date date not null,
  source_schedule_version_id uuid not null references public.customer_schedule_versions(schedule_version_id) on delete restrict,
  source_schedule_day_id uuid not null references public.customer_schedule_days(schedule_day_id) on delete restrict,
  source_schedule_product_id uuid not null references public.customer_schedule_products(schedule_product_id) on delete restrict,
  production_flow_item_id uuid not null references public.production_flow_items(production_flow_item_id) on delete restrict,
  operator_staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  recorded_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid references auth.users(id) on delete set null,
  status text not null default 'RECORDED',
  notes text,
  created_at timestamptz not null default now(),
  constraint sorting_non_trolley_arrivals_product_check check (product_code in ('CLOTHES','MOP')),
  constraint sorting_non_trolley_arrivals_status_check check (status in ('RECORDED','CANCELLED'))
);

create unique index if not exists sorting_non_trolley_arrivals_active_uidx
  on public.sorting_non_trolley_arrivals(customer_id,source_schedule_product_id,scheduled_for_date)
  where status='RECORDED';

create index if not exists sorting_non_trolley_arrivals_daily_idx
  on public.sorting_non_trolley_arrivals(business_date,shift_id,operator_staff_id,arrived_at desc);

alter table public.sorting_non_trolley_arrivals enable row level security;
revoke all on table public.sorting_non_trolley_arrivals from public,anon,authenticated;

create or replace function public.sorting_schedule_product_has_trolley(
  p_schedule_product_id uuid
)
returns boolean
language sql
stable
security definer
set search_path=public,auth,pg_temp
as $$
  select exists(
    select 1
    from public.customer_schedule_trolley_requirements req
    where req.active=true
      and (
        req.owner_schedule_product_id=p_schedule_product_id
        or exists(
          select 1
          from public.customer_schedule_trolley_requirement_products rp
          where rp.schedule_trolley_requirement_id=req.schedule_trolley_requirement_id
            and rp.schedule_product_id=p_schedule_product_id
        )
      )
  );
$$;

revoke all on function public.sorting_schedule_product_has_trolley(uuid)
  from public,anon,authenticated;

create or replace function public.record_sorting_non_trolley_arrival(
  p_shift_code text,
  p_customer_id uuid,
  p_scheduled_for_date date,
  p_product_code text,
  p_operator_staff_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_shift record;
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_physical_received_on date := (now() at time zone 'Europe/Dublin')::date;
  v_product_code text := upper(trim(coalesce(p_product_code,'')));
  v_schedule record;
  v_flow_id uuid;
  v_arrival public.sorting_non_trolley_arrivals%rowtype;
  v_actor_staff_id uuid := public.current_staff_id();
  v_staff_context jsonb;
begin
  perform public.require_sorting_operational_access();

  if p_customer_id is null or p_scheduled_for_date is null or p_operator_staff_id is null then
    raise exception using errcode='22023', message='Customer, Scheduled Date and operator are required.';
  end if;
  if v_product_code not in ('CLOTHES','MOP') then
    raise exception using errcode='22023', message='Product must be CLOTHES or MOP.';
  end if;

  select sh.shift_id,sh.shift_code into v_shift
  from public.shifts sh
  where sh.shift_code=upper(trim(coalesce(p_shift_code,'')))
    and sh.active=true and sh.deleted_at is null
  limit 1;
  if v_shift.shift_id is null then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  v_staff_context := public.get_sorting_staff_dashboard_context_v2(v_shift.shift_code);
  if not exists(
    select 1
    from jsonb_array_elements(coalesce(v_staff_context->'staff','[]'::jsonb)) s
    where s.value->>'staff_id'=p_operator_staff_id::text
      and coalesce(s.value->>'attendance_status','') not in ('ABSENT','AUTO_ABSENT','MOVED')
      and coalesce((s.value->>'actual_in_sorting')::boolean,true)=true
  ) then
    raise exception using errcode='22023', message='Selected operator is not currently available in Sorting.';
  end if;

  select
    csv.schedule_version_id,sd.schedule_day_id,sp.schedule_product_id,
    sp.production_order,sp.production_instructions,
    c.customer_code,c.customer_name,
    r.route_id,r.route_code,r.display_name as route_display_name,r.route_color
  into v_schedule
  from public.customer_schedule_versions csv
  join public.customers c on c.customer_id=csv.customer_id and c.active=true and c.deleted_at is null
  join public.customer_schedule_days sd
    on sd.schedule_version_id=csv.schedule_version_id
   and sd.active=true
   and sd.production_weekday=extract(isodow from p_scheduled_for_date)::smallint
  join public.customer_schedule_products sp on sp.schedule_day_id=sd.schedule_day_id and sp.active=true
  join public.product_types pt
    on pt.product_type_id=sp.product_type_id
   and pt.active=true and pt.deleted_at is null and pt.product_code=v_product_code
  left join public.distribution_routes r on r.route_id=sd.default_route_id and r.deleted_at is null
  where csv.customer_id=p_customer_id
    and csv.status='PUBLISHED'
    and csv.effective_from<=p_scheduled_for_date
    and (csv.effective_until is null or csv.effective_until>=p_scheduled_for_date)
  order by csv.version_number desc
  limit 1;

  if v_schedule.schedule_product_id is null then
    raise exception using errcode='P0002', message='No matching published Customer Schedule product was found.';
  end if;

  if public.sorting_schedule_product_has_trolley(v_schedule.schedule_product_id) then
    raise exception using
      errcode='22023',
      message='This scheduled product has a trolley mapped to it. Use normal trolley Reception instead of Receive without trolley.';
  end if;

  v_flow_id := public.ensure_production_flow_item(
    p_customer_id,
    v_product_code,
    p_scheduled_for_date,
    v_business_date,
    v_schedule.schedule_version_id,
    v_schedule.schedule_day_id,
    v_schedule.schedule_product_id,
    v_schedule.production_order,
    v_schedule.route_id,
    v_schedule.route_code,
    v_schedule.route_display_name,
    v_schedule.route_color
  );

  insert into public.sorting_non_trolley_arrivals(
    customer_id,customer_code_snapshot,customer_name_snapshot,product_code,
    business_date,physical_received_on,shift_id,shift_code_snapshot,arrived_at,
    scheduled_for_date,source_schedule_version_id,source_schedule_day_id,
    source_schedule_product_id,production_flow_item_id,operator_staff_id,
    recorded_by_staff_id,recorded_by_auth_user_id,notes
  ) values (
    p_customer_id,v_schedule.customer_code,v_schedule.customer_name,v_product_code,
    v_business_date,v_physical_received_on,v_shift.shift_id,v_shift.shift_code,now(),
    p_scheduled_for_date,v_schedule.schedule_version_id,v_schedule.schedule_day_id,
    v_schedule.schedule_product_id,v_flow_id,p_operator_staff_id,
    v_actor_staff_id,auth.uid(),nullif(trim(coalesce(p_notes,'')),'')
  )
  on conflict (customer_id,source_schedule_product_id,scheduled_for_date)
    where status='RECORDED'
  do nothing
  returning * into v_arrival;

  -- Idempotency is evidence-preserving: a repeated click returns the original
  -- Reception fact without mutating its notes/timestamp or appending duplicate events.
  if v_arrival.sorting_non_trolley_arrival_id is null then
    select * into v_arrival
    from public.sorting_non_trolley_arrivals a
    where a.customer_id=p_customer_id
      and a.source_schedule_product_id=v_schedule.schedule_product_id
      and a.scheduled_for_date=p_scheduled_for_date
      and a.status='RECORDED'
    order by a.arrived_at desc
    limit 1;

    return jsonb_build_object(
      'sorting_non_trolley_arrival_id',v_arrival.sorting_non_trolley_arrival_id,
      'production_flow_item_id',v_arrival.production_flow_item_id,
      'customer_id',p_customer_id,
      'customer_name',v_schedule.customer_name,
      'product_code',v_product_code,
      'scheduled_for_date',p_scheduled_for_date,
      'business_date',v_arrival.business_date,
      'wash_unlocked',true,
      'already_recorded',true,
      'message',format('%s contents without trolley were already received. Washing remains unlocked.',v_schedule.customer_name)
    );
  end if;

  perform public.append_production_flow_event(
    v_flow_id,
    'CONTENTS_RECEIVED_WITHOUT_TROLLEY','INTAKE',20,'SORTING',v_business_date,now(),
    p_operator_staff_id,v_actor_staff_id,auth.uid(),
    'SORTING_RECEPTION_NO_TROLLEY','sorting_non_trolley_arrivals',
    v_arrival.sorting_non_trolley_arrival_id::text,
    jsonb_build_object(
      'arrival_mode','NO_TROLLEY',
      'scheduled_for_date',p_scheduled_for_date,
      'product_code',v_product_code,
      'trolley_expected',false,
      'physical_received_on',v_physical_received_on
    )
  );

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application
  ) values (
    auth.uid(),v_actor_staff_id,'RECORD_SORTING_CONTENTS_WITHOUT_TROLLEY',
    'sorting_non_trolley_arrivals',v_arrival.sorting_non_trolley_arrival_id::text,
    to_jsonb(v_arrival),p_notes,'SORTING_RECEPTION_NO_TROLLEY'
  );

  return jsonb_build_object(
    'sorting_non_trolley_arrival_id',v_arrival.sorting_non_trolley_arrival_id,
    'production_flow_item_id',v_flow_id,
    'customer_id',p_customer_id,
    'customer_name',v_schedule.customer_name,
    'product_code',v_product_code,
    'scheduled_for_date',p_scheduled_for_date,
    'business_date',v_business_date,
    'wash_unlocked',true,
    'message',format('%s contents received without trolley. Washing is now unlocked.',v_schedule.customer_name)
  );
end;
$$;

revoke all on function public.record_sorting_non_trolley_arrival(text,uuid,date,text,uuid,text)
  from public,anon,authenticated;
grant execute on function public.record_sorting_non_trolley_arrival(text,uuid,date,text,uuid,text)
  to authenticated;

-- ---------------------------------------------------------------------
-- 3. Reception and Washing read models include no-trolley evidence.
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_trolley_intake_context_v3(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb := public.get_sorting_trolley_intake_context_v2(p_shift_code);
  v_board jsonb := '[]'::jsonb;
  v_queue jsonb := '[]'::jsonb;
  v_no_trolley_recent jsonb := '[]'::jsonb;
  v_business_date date := (v_base->>'business_date')::date;
begin
  perform public.require_sorting_operational_access();

  select coalesce(jsonb_agg(
    b.value || jsonb_build_object(
      'trolley_reception_expected',req.has_trolley,
      'no_trolley_eligible',not req.has_trolley,
      'no_trolley_arrival_count',coalesce(nta.arrival_count,0),
      'no_trolley_arrival_at',nta.last_arrived_at,
      'receipt_evidence_count',coalesce((b.value->>'received_count')::integer,0)+coalesce(nta.arrival_count,0),
      'receipt_status',case
        when not req.has_trolley and coalesce(nta.arrival_count,0)>0 then 'NO_TROLLEY_RECEIVED'
        when not req.has_trolley then 'WAITING_NO_TROLLEY_CONFIRMATION'
        else b.value->>'receipt_status'
      end,
      'operational_state',case
        when coalesce((b.value->>'wash_count')::integer,0)>0 then 'WASHING_RECORDED'
        when not req.has_trolley and coalesce(nta.arrival_count,0)>0 then 'WAITING_WASH'
        when not req.has_trolley then 'WAITING_RECEIPT'
        else b.value->>'operational_state'
      end,
      'waiting_wash',case
        when coalesce((b.value->>'wash_count')::integer,0)>0 then false
        when not req.has_trolley and coalesce(nta.arrival_count,0)>0 then true
        else coalesce((b.value->>'waiting_wash')::boolean,false)
      end,
      'reception_evidence_source',case
        when coalesce(nta.arrival_count,0)>0 then 'NO_TROLLEY_CONTENTS'
        when coalesce((b.value->>'received_count')::integer,0)>0 then 'PHYSICAL_TROLLEY'
        else 'NONE'
      end
    )
    order by (b.value->>'day_offset')::integer,
             case b.value->>'product_code' when 'CLOTHES' then 1 else 2 end,
             nullif(b.value->>'production_order','')::integer nulls last,
             lower(b.value->>'customer_name')
  ),'[]'::jsonb)
  into v_board
  from jsonb_array_elements(coalesce(v_base->'board','[]'::jsonb)) b
  left join lateral (
    select public.sorting_schedule_product_has_trolley(
      nullif(b.value->>'schedule_product_id','')::uuid
    ) as has_trolley
  ) req on true
  left join lateral (
    select count(*)::integer as arrival_count,max(a.arrived_at) as last_arrived_at
    from public.sorting_non_trolley_arrivals a
    where a.status='RECORDED'
      and a.customer_id=nullif(b.value->>'customer_id','')::uuid
      and a.source_schedule_product_id=nullif(b.value->>'schedule_product_id','')::uuid
      and a.scheduled_for_date=nullif(b.value->>'scheduled_for_date','')::date
  ) nta on true;

  select coalesce(jsonb_agg(q.value order by
    case q.value->>'day_relation' when 'TODAY' then 0 when 'TOMORROW' then 1 else 2 end,
    nullif(q.value->>'production_order','')::integer nulls last,
    lower(q.value->>'customer_name')
  ),'[]'::jsonb)
  into v_queue
  from jsonb_array_elements(v_board) q
  where q.value->>'operational_state'='WAITING_WASH'
    and q.value->>'day_relation' in ('TODAY','TOMORROW');

  select coalesce(jsonb_agg(jsonb_build_object(
    'sorting_non_trolley_arrival_id',a.sorting_non_trolley_arrival_id,
    'arrival_mode','NO_TROLLEY',
    'trolley_code','NO TROLLEY',
    'customer_id',a.customer_id,
    'customer_name',a.customer_name_snapshot,
    'business_date',a.business_date,
    'physical_received_on',a.physical_received_on,
    'shift_code',a.shift_code_snapshot,
    'arrived_at',a.arrived_at,
    'contents_status','CONTENTS',
    'product_scope',a.product_code,
    'scheduled_for_date',a.scheduled_for_date,
    'schedule_relation',case
      when a.scheduled_for_date=v_business_date then 'TODAY'
      when a.scheduled_for_date=v_business_date+1 then 'TOMORROW'
      when a.scheduled_for_date=v_business_date-1 then 'YESTERDAY'
      else 'OFF_SCHEDULE' end,
    'review_status','NOT_REQUIRED',
    'operator_staff_id',a.operator_staff_id,
    'operator_name',sm.display_name,
    'notes',a.notes,
    'products',jsonb_build_array(jsonb_build_object(
      'product_code',a.product_code,
      'production_flow_item_id',a.production_flow_item_id
    ))
  ) order by a.arrived_at desc),'[]'::jsonb)
  into v_no_trolley_recent
  from public.sorting_non_trolley_arrivals a
  left join public.staff_members sm on sm.staff_id=a.operator_staff_id
  where a.business_date=v_business_date
    and a.shift_code_snapshot=upper(trim(p_shift_code))
    and a.status='RECORDED';

  return v_base || jsonb_build_object(
    'board',v_board,
    'waiting_queue',v_queue,
    'recent_intakes',v_no_trolley_recent || coalesce(v_base->'recent_intakes','[]'::jsonb),
    'summary',coalesce(v_base->'summary','{}'::jsonb) || jsonb_build_object(
      'no_trolley_received_today',(
        select count(*) from public.sorting_non_trolley_arrivals a
        where a.business_date=v_business_date
          and a.shift_code_snapshot=upper(trim(p_shift_code))
          and a.status='RECORDED'
      ),
      'received_today',coalesce((v_base->'summary'->>'received_today')::integer,0)+(
        select count(*) from public.sorting_non_trolley_arrivals a
        where a.business_date=v_business_date
          and a.shift_code_snapshot=upper(trim(p_shift_code))
          and a.status='RECORDED'
      ),
      'contents_today',coalesce((v_base->'summary'->>'contents_today')::integer,0)+(
        select count(*) from public.sorting_non_trolley_arrivals a
        where a.business_date=v_business_date
          and a.shift_code_snapshot=upper(trim(p_shift_code))
          and a.status='RECORDED'
      ),
      'waiting_wash',jsonb_array_length(v_queue)
    ),
    'source','PUBLISHED_SCHEDULE_PLUS_TROLLEY_OR_CONTROLLED_NO_TROLLEY_CONTENTS'
  );
end;
$$;

revoke all on function public.get_sorting_trolley_intake_context_v3(text)
  from public,anon,authenticated;
grant execute on function public.get_sorting_trolley_intake_context_v3(text)
  to authenticated;

create or replace function public.get_sorting_customer_board_v4(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb := public.get_sorting_customer_board_v3(p_shift_code);
  v_customers jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  select coalesce(jsonb_agg(
    b.value || jsonb_build_object(
      'trolley_reception_expected',req.has_trolley,
      'no_trolley_eligible',not req.has_trolley,
      'no_trolley_arrival_count',coalesce(nta.arrival_count,0),
      'no_trolley_arrival_at',nta.last_arrived_at,
      'wash_enabled',coalesce((b.value->>'scan_contents_count')::integer,0)>0 or coalesce(nta.arrival_count,0)>0,
      'wash_gate_status',case
        when coalesce((b.value->>'scan_contents_count')::integer,0)>0 then 'READY_TO_WASH'
        when coalesce(nta.arrival_count,0)>0 then 'READY_TO_WASH_NO_TROLLEY'
        when not req.has_trolley then 'WAITING_NO_TROLLEY_ARRIVAL'
        when coalesce((b.value->>'scan_empty_count')::integer,0)>0 then 'EMPTY_ONLY'
        else 'WAITING_SCAN'
      end,
      'reception_evidence_source',case
        when coalesce((b.value->>'scan_contents_count')::integer,0)>0 then 'PHYSICAL_TROLLEY'
        when coalesce(nta.arrival_count,0)>0 then 'NO_TROLLEY_CONTENTS'
        else 'NONE'
      end
    )
    order by (b.value->>'day_offset')::integer,
             case b.value->>'product_code' when 'CLOTHES' then 1 else 2 end,
             nullif(b.value->>'production_order','')::integer nulls last,
             lower(b.value->>'customer_name')
  ),'[]'::jsonb)
  into v_customers
  from jsonb_array_elements(coalesce(v_base->'customers','[]'::jsonb)) b
  left join lateral (
    select public.sorting_schedule_product_has_trolley(
      nullif(b.value->>'schedule_product_id','')::uuid
    ) as has_trolley
  ) req on true
  left join lateral (
    select count(*)::integer as arrival_count,max(a.arrived_at) as last_arrived_at
    from public.sorting_non_trolley_arrivals a
    where a.status='RECORDED'
      and a.customer_id=nullif(b.value->>'customer_id','')::uuid
      and a.source_schedule_product_id=nullif(b.value->>'schedule_product_id','')::uuid
      and a.scheduled_for_date=nullif(b.value->>'scheduled_for_date','')::date
  ) nta on true;

  return v_base || jsonb_build_object(
    'customers',v_customers,
    'wash_scan_gate_required',true,
    'source','PUBLISHED_SCHEDULE_PLUS_TROLLEY_OR_NO_TROLLEY_RECEPTION_GATE'
  );
end;
$$;

revoke all on function public.get_sorting_customer_board_v4(text)
  from public,anon,authenticated;
grant execute on function public.get_sorting_customer_board_v4(text)
  to authenticated;

-- Replace the private Washing gate. Off-schedule selections still require a
-- physical trolley CONTENTS scan because no published no-trolley rule exists.
create or replace function public.sorting_assert_wash_scan_gate(
  p_business_date date,
  p_wash_type text,
  p_customer_selections jsonb
)
returns void
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_type text := upper(trim(coalesce(p_wash_type,'')));
  v_product_code text;
  v_selection record;
  v_customer_id uuid;
  v_schedule_product_id uuid;
  v_scheduled_for_date date;
  v_customer_name text;
  v_contents_count integer;
  v_empty_count integer;
  v_no_trolley_count integer;
  v_trolley_expected boolean;
begin
  if p_customer_selections is null
     or jsonb_typeof(p_customer_selections)<>'array'
     or jsonb_array_length(p_customer_selections)=0 then
    raise exception using errcode='22023', message='At least one customer selection is required.';
  end if;

  v_product_code := case
    when v_type='MOP' then 'MOP'
    when v_type in ('CLOTHES','OTHERS') then 'CLOTHES'
    else null end;
  if v_product_code is null then
    raise exception using errcode='22023', message='Wash type is not supported by the Reception gate.';
  end if;

  for v_selection in select value from jsonb_array_elements(p_customer_selections)
  loop
    v_customer_id := nullif(v_selection.value->>'customer_id','')::uuid;
    v_schedule_product_id := nullif(v_selection.value->>'schedule_product_id','')::uuid;
    v_scheduled_for_date := nullif(v_selection.value->>'scheduled_for_date','')::date;
    if v_customer_id is null then
      raise exception using errcode='22023', message='Every Washing customer selection requires a valid customer.';
    end if;
    if (v_schedule_product_id is null) <> (v_scheduled_for_date is null) then
      raise exception using errcode='22023', message='Scheduled Washing selection requires both Scheduled Date and schedule product.';
    end if;

    select c.customer_name into v_customer_name
    from public.customers c where c.customer_id=v_customer_id limit 1;

    v_contents_count:=0;v_empty_count:=0;v_no_trolley_count:=0;v_trolley_expected:=true;
    if v_schedule_product_id is not null then
      select
        count(*) filter(where sti.contents_status='CONTENTS')::integer,
        count(*) filter(where sti.contents_status='EMPTY')::integer
      into v_contents_count,v_empty_count
      from public.sorting_trolley_intake_products stip
      join public.sorting_trolley_intakes sti on sti.sorting_trolley_intake_id=stip.sorting_trolley_intake_id
      where sti.customer_id=v_customer_id
        and stip.product_code=v_product_code
        and stip.source_schedule_product_id=v_schedule_product_id
        and stip.scheduled_for_date=v_scheduled_for_date;

      select count(*)::integer into v_no_trolley_count
      from public.sorting_non_trolley_arrivals a
      where a.status='RECORDED'
        and a.customer_id=v_customer_id
        and a.product_code=v_product_code
        and a.source_schedule_product_id=v_schedule_product_id
        and a.scheduled_for_date=v_scheduled_for_date;

      v_trolley_expected:=public.sorting_schedule_product_has_trolley(v_schedule_product_id);
    else
      select
        count(*) filter(where sti.contents_status='CONTENTS')::integer,
        count(*) filter(where sti.contents_status='EMPTY')::integer
      into v_contents_count,v_empty_count
      from public.sorting_trolley_intake_products stip
      join public.sorting_trolley_intakes sti on sti.sorting_trolley_intake_id=stip.sorting_trolley_intake_id
      where sti.customer_id=v_customer_id
        and stip.product_code=v_product_code
        and sti.business_date=p_business_date;
    end if;

    if coalesce(v_contents_count,0)+coalesce(v_no_trolley_count,0)=0 then
      if not v_trolley_expected and v_schedule_product_id is not null then
        raise exception using errcode='22023', message=format(
          'Confirm %s contents in Reception using Receive without trolley before recording Washing.',
          coalesce(v_customer_name,'the selected customer')
        );
      end if;
      if coalesce(v_empty_count,0)>0 then
        raise exception using errcode='22023', message=format(
          '%s has only EMPTY trolley receipt evidence. Washing remains locked until laundry contents are identified.',
          coalesce(v_customer_name,'Selected customer')
        );
      end if;
      raise exception using errcode='22023', message=format(
        'Receive and identify %s before recording Washing. CONTENTS Reception evidence is required for the selected Customer + Date + Product.',
        coalesce(v_customer_name,'the selected customer')
      );
    end if;
  end loop;
end;
$$;

revoke all on function public.sorting_assert_wash_scan_gate(date,text,jsonb)
  from public,anon,authenticated;

-- ---------------------------------------------------------------------
-- 4. MOP Production evidence.
-- ---------------------------------------------------------------------

create table if not exists public.sorting_mop_production_batches (
  mop_production_batch_id uuid primary key default gen_random_uuid(),
  production_flow_item_id uuid not null references public.production_flow_items(production_flow_item_id) on delete restrict,
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  customer_code_snapshot text,
  customer_name_snapshot text not null,
  business_date date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  shift_code_snapshot text not null,
  scheduled_for_date date,
  delivery_due_date date not null,
  operator_staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  entry_mode text not null,
  physical_processed_on date not null,
  physical_processed_time time,
  physical_time_precision text not null,
  total_weight_kg numeric(14,3) not null default 0,
  total_units integer not null default 0,
  trolley_capture_status text not null,
  planned_output_trolley_quantity integer not null default 0,
  recorded_at timestamptz not null default now(),
  recorded_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid references auth.users(id) on delete set null,
  notes text,
  status text not null default 'RECORDED',
  created_at timestamptz not null default now(),
  constraint sorting_mop_production_entry_mode_check check (entry_mode in ('LIVE','LATE_RECONCILIATION')),
  constraint sorting_mop_production_time_precision_check check (physical_time_precision in ('EXACT','DATE_ONLY')),
  constraint sorting_mop_production_trolley_status_check check (trolley_capture_status in ('NOT_REQUIRED','RECORDED','RECORDED_MISMATCH','UNPLANNED_RECORDED','UNKNOWN_LATE_ENTRY','LATE_RECORDED_CODE')),
  constraint sorting_mop_production_status_check check (status in ('RECORDED','CANCELLED')),
  constraint sorting_mop_production_totals_check check (total_weight_kg>=0 and total_units>=0 and (total_weight_kg>0 or total_units>0))
);

create unique index if not exists sorting_mop_production_active_flow_uidx
  on public.sorting_mop_production_batches(production_flow_item_id)
  where status='RECORDED';
create index if not exists sorting_mop_production_daily_idx
  on public.sorting_mop_production_batches(business_date,shift_id,recorded_at desc);

create table if not exists public.sorting_mop_production_lines (
  mop_production_line_id uuid primary key default gen_random_uuid(),
  mop_production_batch_id uuid not null references public.sorting_mop_production_batches(mop_production_batch_id) on delete restrict,
  product_variant_id uuid references public.product_variants(product_variant_id) on delete restrict,
  variant_code_snapshot text not null,
  variant_name_snapshot text not null,
  weight_kg numeric(14,3),
  units integer,
  unit_weight_grams_snapshot numeric(14,3),
  created_at timestamptz not null default now(),
  constraint sorting_mop_production_line_quantity_check check (
    (weight_kg is not null and weight_kg>0) or (units is not null and units>0)
  ),
  constraint sorting_mop_production_line_weight_check check (unit_weight_grams_snapshot is null or unit_weight_grams_snapshot>0)
);
create index if not exists sorting_mop_production_lines_batch_idx
  on public.sorting_mop_production_lines(mop_production_batch_id);

create table if not exists public.sorting_mop_production_trolleys (
  mop_production_trolley_id uuid primary key default gen_random_uuid(),
  mop_production_batch_id uuid not null references public.sorting_mop_production_batches(mop_production_batch_id) on delete restrict,
  trolley_id uuid references public.trolleys(trolley_id) on delete restrict,
  trolley_code_snapshot text not null,
  stay_id uuid references public.trolley_customer_stays(stay_id) on delete restrict,
  lifecycle_action text not null,
  created_at timestamptz not null default now(),
  constraint sorting_mop_production_trolley_action_check check (lifecycle_action in ('LIVE_ASSIGNMENT','LATE_REFERENCE_ONLY')),
  constraint sorting_mop_production_trolley_unique unique(mop_production_batch_id,trolley_code_snapshot)
);

create table if not exists public.sorting_mop_reconciliations (
  mop_reconciliation_id uuid primary key default gen_random_uuid(),
  production_flow_item_id uuid not null references public.production_flow_items(production_flow_item_id) on delete restrict,
  delivery_due_date date not null,
  decision text not null,
  reason text,
  operator_staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  linked_mop_production_batch_id uuid references public.sorting_mop_production_batches(mop_production_batch_id) on delete restrict,
  recorded_at timestamptz not null default now(),
  recorded_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid references auth.users(id) on delete set null,
  constraint sorting_mop_reconciliation_decision_check check (decision in ('NOT_PROCESSED','PROCESSED_MISSED_ENTRY'))
);
create unique index if not exists sorting_mop_reconciliation_not_processed_uidx
  on public.sorting_mop_reconciliations(production_flow_item_id)
  where decision='NOT_PROCESSED';

alter table public.sorting_mop_production_batches enable row level security;
alter table public.sorting_mop_production_lines enable row level security;
alter table public.sorting_mop_production_trolleys enable row level security;
alter table public.sorting_mop_reconciliations enable row level security;
revoke all on table public.sorting_mop_production_batches,public.sorting_mop_production_lines,
  public.sorting_mop_production_trolleys,public.sorting_mop_reconciliations
  from public,anon,authenticated;

create or replace function public.sorting_mop_reconciliation_config()
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v jsonb;
begin
  select value_json into v from public.app_config where config_key='sorting_mop_reconciliation';
  return coalesce(v,jsonb_build_object('timezone','Europe/Dublin','cutoff_local_time','12:00:00','enforcement_from',(now() at time zone 'Europe/Dublin')::date::text));
end;
$$;
revoke all on function public.sorting_mop_reconciliation_config() from public,anon,authenticated;

create or replace function public.sorting_assert_current_mop_staff(
  p_shift_code text,
  p_staff_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare v_ctx jsonb;
begin
  if p_staff_id is null then
    raise exception using errcode='22023', message='MOP staff is required.';
  end if;
  v_ctx:=public.get_sorting_staff_dashboard_context_v2(p_shift_code);
  if not exists(
    select 1 from jsonb_array_elements(coalesce(v_ctx->'staff','[]'::jsonb)) s
    where s.value->>'staff_id'=p_staff_id::text
      and coalesce(s.value->>'attendance_status','') not in ('ABSENT','AUTO_ABSENT','MOVED')
      and coalesce((s.value->>'actual_in_sorting')::boolean,true)=true
      and s.value->>'work_mode'='MOP'
  ) then
    raise exception using errcode='22023', message='Selected staff member is not the current Actual MOP operator in Sorting.';
  end if;
end;
$$;
revoke all on function public.sorting_assert_current_mop_staff(text,uuid) from public,anon,authenticated;

-- ---------------------------------------------------------------------
-- 5. Sorting workstation is allowed to assign a MOP-owned clean trolley.
--    The central lifecycle function and all its original guards are retained;
--    only the MOP role gate adds SORTING_OPERATOR because MOP Production now
--    lives inside the Sorting workstation application.
-- ---------------------------------------------------------------------

create or replace function public.assign_trolley_to_customer_from_production(
  p_trolley_code text,
  p_customer_id uuid,
  p_production_business_date date,
  p_area_code text,
  p_notes text default null,
  p_source_application text default 'TROLLEY_PRODUCTION_ASSIGNMENT'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff_id uuid;
  v_area_code text := upper(nullif(trim(p_area_code), ''));
  v_product_code text;
  v_production_date date := coalesce(p_production_business_date, current_date);
  v_delivery_date date;
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_schedule record;
begin
  if nullif(trim(p_trolley_code), '') is null then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  if p_customer_id is null then
    raise exception using errcode = '22023', message = 'Customer is required.';
  end if;

  if v_area_code not in ('FINISH', 'MOP') then
    raise exception using errcode = '22023', message = 'Production area must be FINISH or MOP.';
  end if;

  if extract(isodow from v_production_date)::integer = 7 then
    raise exception using errcode = '22023', message = 'Sunday is not a production day.';
  end if;

  if v_area_code = 'FINISH' then
    perform public.require_any_trolley_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'FINISH_OPERATOR']
    );
    v_product_code := 'CLOTHES';
  else
    perform public.require_any_trolley_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'MOP_OPERATOR', 'SORTING_OPERATOR']
    );
    v_product_code := 'MOP';
  end if;

  select
    v.schedule_version_id,
    d.schedule_day_id,
    sp.schedule_product_id,
    c.customer_code,
    c.customer_name
  into v_schedule
  from public.customer_schedule_versions v
  join public.customers c
    on c.customer_id = v.customer_id
  join public.customer_schedule_days d
    on d.schedule_version_id = v.schedule_version_id
  join public.customer_schedule_products sp
    on sp.schedule_day_id = d.schedule_day_id
  join public.product_types pt
    on pt.product_type_id = sp.product_type_id
  where v.customer_id = p_customer_id
    and v.status = 'PUBLISHED'
    and v_production_date >= v.effective_from
    and (v.effective_until is null or v_production_date <= v.effective_until)
    and d.active = true
    and d.production_weekday = extract(isodow from v_production_date)::smallint
    and sp.active = true
    and pt.active = true
    and pt.deleted_at is null
    and pt.product_code = v_product_code
    and c.active = true
    and c.deleted_at is null
  order by v.version_number desc
  limit 1;

  if v_schedule.schedule_product_id is null then
    raise exception using
      errcode = '22023',
      message = format(
        'The selected customer is not scheduled for %s production on %s.',
        v_area_code,
        to_char(v_production_date, 'DD Mon YYYY')
      );
  end if;

  v_delivery_date := public.next_distribution_business_date(v_production_date);
  v_staff_id := public.current_staff_id();

  select *
  into v_trolley
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(p_trolley_code))
    and t.deleted_at is null
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = format('Trolley not found: %s', trim(p_trolley_code));
  end if;

  if not v_trolley.active
     or v_trolley.status not in ('AVAILABLE', 'LOCATION_UNCONFIRMED') then
    raise exception using
      errcode = '23514',
      message = format(
        'Trolley %s cannot be assigned from production. Current status: %s',
        v_trolley.trolley_code,
        v_trolley.status
      );
  end if;

  if exists (
    select 1
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.received_on is null
  ) then
    raise exception using
      errcode = '23505',
      message = format('Trolley %s already has an open customer stay.', v_trolley.trolley_code);
  end if;

  insert into public.trolley_customer_stays (
    trolley_id,
    outbound_customer_id,
    sent_on,
    status,
    review_status,
    sent_recorded_by,
    notes,
    production_business_date,
    planned_delivery_on,
    production_area_code,
    custody_start_source,
    source_schedule_version_id,
    source_schedule_day_id,
    source_schedule_product_id,
    production_recorded_by,
    production_recorded_at
  )
  values (
    v_trolley.trolley_id,
    p_customer_id,
    v_delivery_date,
    'OPEN',
    'NOT_REQUIRED',
    v_staff_id,
    nullif(trim(p_notes), ''),
    v_production_date,
    v_delivery_date,
    v_area_code,
    'PRODUCTION_NEXT_DAY_INFERENCE',
    v_schedule.schedule_version_id,
    v_schedule.schedule_day_id,
    v_schedule.schedule_product_id,
    v_staff_id,
    now()
  )
  returning * into v_stay;

  update public.trolleys
  set
    status = 'IN_PRODUCTION',
    updated_by = auth.uid()
  where trolley_id = v_trolley.trolley_id;

  insert into public.trolley_events (
    trolley_id,
    stay_id,
    event_type,
    customer_id,
    business_date,
    performed_by,
    source_application,
    reason,
    metadata
  )
  values (
    v_trolley.trolley_id,
    v_stay.stay_id,
    'ASSIGNED_IN_PRODUCTION',
    p_customer_id,
    v_production_date,
    v_staff_id,
    p_source_application,
    p_notes,
    jsonb_build_object(
      'production_area_code', v_area_code,
      'product_code', v_product_code,
      'planned_delivery_on', v_delivery_date,
      'custody_start_source', 'PRODUCTION_NEXT_DAY_INFERENCE',
      'schedule_version_id', v_schedule.schedule_version_id,
      'schedule_day_id', v_schedule.schedule_day_id,
      'schedule_product_id', v_schedule.schedule_product_id
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
    'ASSIGN_TROLLEY_FROM_PRODUCTION',
    'trolley_customer_stays',
    v_stay.stay_id::text,
    to_jsonb(v_stay),
    p_notes,
    p_source_application
  );

  return jsonb_build_object(
    'trolley_id', v_trolley.trolley_id,
    'trolley_code', v_trolley.trolley_code,
    'stay_id', v_stay.stay_id,
    'customer_id', p_customer_id,
    'customer_code', v_schedule.customer_code,
    'customer_name', v_schedule.customer_name,
    'production_business_date', v_production_date,
    'planned_delivery_on', v_delivery_date,
    'production_area_code', v_area_code,
    'custody_start_source', v_stay.custody_start_source,
    'status', 'IN_PRODUCTION'
  );
end;
$$;


comment on function public.assign_trolley_to_customer_from_production(text,uuid,date,text,text,text)
  is 'Assigns a physical trolley to a scheduled Finish/Mop customer and records an explicitly inferred next-day delivery date. MOP assignment may also be performed from the controlled Sorting workstation.';

-- ---------------------------------------------------------------------
-- 6. MOP Production read model.
-- ---------------------------------------------------------------------

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
  perform public.require_sorting_operational_access();
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

revoke all on function public.get_sorting_mop_production_context(text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.get_sorting_mop_production_context(text,timestamptz)
  to authenticated;

-- ---------------------------------------------------------------------
-- 7. Mandatory delivery-day decision: not processed.
-- ---------------------------------------------------------------------

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
  perform public.require_sorting_operational_access();
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

revoke all on function public.record_sorting_mop_reconciliation(text,uuid,uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.record_sorting_mop_reconciliation(text,uuid,uuid,text,text)
  to authenticated;

-- ---------------------------------------------------------------------
-- 8. MOP Production write.
-- ---------------------------------------------------------------------

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
  if v_other_overdue>0 then
    raise exception using errcode='22023', message=format('Resolve %s overdue MOP delivery-day confirmation(s) before recording another MOP customer.',v_other_overdue);
  end if;

  if v_base_date>=v_enforcement and v_local >= (v_due+v_cutoff)
     and not v_prior_not_processed and v_entry_mode='LIVE' then
    raise exception using errcode='22023', message='This delivery-day MOP item requires reconciliation. Choose Already processed — missed entry or Not processed.';
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

-- ---------------------------------------------------------------------
-- 9. Whole-shift No Work / Move guard includes the new operational evidence.
--    Existing No Work RPCs need no rewrite: these table-level guards stop a
--    contradictory whole-shift absence/transfer after Reception or MOP activity.
-- ---------------------------------------------------------------------

create or replace function public.guard_sorting_new_activity_against_no_work()
returns trigger
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
begin
  if exists(
    select 1 from public.sorting_daily_staff_attendance a
    where a.business_date=new.business_date and a.shift_id=new.shift_id
      and a.staff_id=new.operator_staff_id and a.attendance_status='ABSENT'
  ) then
    raise exception using errcode='23514', message='This staff member is recorded as not working in Sorting for the whole shift.';
  end if;
  if exists(
    select 1 from public.work_sessions ws
    join public.areas ar on ar.area_id=ws.area_id
    where ws.work_date=new.business_date and ws.shift_id=new.shift_id
      and ws.staff_id=new.operator_staff_id and ws.source='SORTING_AREA_TRANSFER'
      and ws.status<>'CANCELLED' and ar.area_code<>'SORTING'
  ) then
    raise exception using errcode='23514', message='This staff member is currently moved to another Actual area.';
  end if;
  return new;
end;
$$;

revoke all on function public.guard_sorting_new_activity_against_no_work() from public,anon,authenticated;

drop trigger if exists sorting_non_trolley_arrival_no_work_guard on public.sorting_non_trolley_arrivals;
create trigger sorting_non_trolley_arrival_no_work_guard
before insert on public.sorting_non_trolley_arrivals
for each row execute function public.guard_sorting_new_activity_against_no_work();

drop trigger if exists sorting_mop_production_no_work_guard on public.sorting_mop_production_batches;
create trigger sorting_mop_production_no_work_guard
before insert on public.sorting_mop_production_batches
for each row execute function public.guard_sorting_new_activity_against_no_work();

create or replace function public.guard_sorting_whole_shift_no_work_after_new_activity()
returns trigger
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare v_area_code text;
begin
  if tg_table_name='sorting_daily_staff_attendance' then
    if new.attendance_status='ABSENT' and (
      exists(select 1 from public.sorting_non_trolley_arrivals a where a.business_date=new.business_date and a.shift_id=new.shift_id and a.operator_staff_id=new.staff_id and a.status='RECORDED')
      or exists(select 1 from public.sorting_mop_production_batches mb where mb.business_date=new.business_date and mb.shift_id=new.shift_id and mb.operator_staff_id=new.staff_id and mb.status='RECORDED')
    ) then
      raise exception using errcode='23514', message='Whole-shift No Work conflicts with recorded Reception/MOP Production activity.';
    end if;
  elsif tg_table_name='work_sessions' and new.source='SORTING_AREA_TRANSFER' and new.status<>'CANCELLED' then
    select area_code into v_area_code from public.areas where area_id=new.area_id;
    if v_area_code<>'SORTING' and (
      exists(select 1 from public.sorting_non_trolley_arrivals a where a.business_date=new.work_date and a.shift_id=new.shift_id and a.operator_staff_id=new.staff_id and a.status='RECORDED')
      or exists(select 1 from public.sorting_mop_production_batches mb where mb.business_date=new.work_date and mb.shift_id=new.shift_id and mb.operator_staff_id=new.staff_id and mb.status='RECORDED')
    ) then
      raise exception using errcode='23514', message='Whole-shift area transfer conflicts with recorded Reception/MOP Production activity.';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.guard_sorting_whole_shift_no_work_after_new_activity() from public,anon,authenticated;

drop trigger if exists sorting_attendance_new_activity_guard on public.sorting_daily_staff_attendance;
create trigger sorting_attendance_new_activity_guard
before insert or update on public.sorting_daily_staff_attendance
for each row execute function public.guard_sorting_whole_shift_no_work_after_new_activity();

drop trigger if exists sorting_area_transfer_new_activity_guard on public.work_sessions;
create trigger sorting_area_transfer_new_activity_guard
before insert or update on public.work_sessions
for each row execute function public.guard_sorting_whole_shift_no_work_after_new_activity();

-- ---------------------------------------------------------------------
-- 10. Comments / contract.
-- ---------------------------------------------------------------------

comment on table public.sorting_non_trolley_arrivals is
  'Controlled Reception evidence for scheduled laundry contents that legitimately arrive without a physical trolley. It never fabricates trolley custody.';
comment on table public.sorting_mop_production_batches is
  'MOP Production batch linked to one exact washed Production Flow item. Late entries preserve physical date/time precision separately from registration time.';
comment on table public.sorting_mop_reconciliations is
  'Delivery-day MOP reconciliation decisions. NOT_PROCESSED acknowledges outstanding work; PROCESSED_MISSED_ENTRY links a traceable late production record.';
comment on function public.get_sorting_mop_production_context(text,timestamptz) is
  'Controlled MOP queue. Only exact washed MOP Flow items are eligible. From local noon on the Distribution due date, unresolved items require reconciliation.';
comment on function public.save_sorting_mop_production(text,uuid,uuid,jsonb,text[],boolean,date,time,text,text) is
  'Records MOP Production from a washed Flow item. LIVE trolley codes update the physical lifecycle; late reconciliation never fabricates or retroactively mutates unknown trolley custody.';

commit;
