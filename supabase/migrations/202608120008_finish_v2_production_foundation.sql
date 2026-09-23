-- =====================================================================
-- ElisCaretex V2
-- Migration 044: Finish V2 production foundation
--
-- Operational baseline: current Finish Google Apps Script workflow.
-- - one shared Finish workspace for Tables 1/2/3;
-- - a future central scanner may record any table, while recorder identity
--   remains separate from the physical production table;
-- - the same customer may be processed by multiple tables/shifts;
-- - continuation requires a new batch;
-- - the same batch may have KG and UNIT lines inside one Finish entry;
-- - corrections are append-only;
-- - operational add/edit closes at 12:00 Europe/Dublin on Delivery Date;
-- - private source tables stay behind governed RPCs.
-- =====================================================================

begin;

create table if not exists public.finish_production_entries (
  finish_production_entry_id uuid primary key default gen_random_uuid(),
  entry_group_id uuid not null,
  revision_no integer not null,
  status text not null default 'ACTIVE',
  supersedes_finish_production_entry_id uuid
    references public.finish_production_entries(finish_production_entry_id) on delete restrict,
  production_flow_item_id uuid not null
    references public.production_flow_items(production_flow_item_id) on delete restrict,
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  production_business_date date not null,
  delivery_date date not null,
  edit_cutoff_at timestamptz not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  shift_code_snapshot text not null,
  station_id uuid not null references public.stations(station_id) on delete restrict,
  table_code_snapshot text not null,
  table_name_snapshot text not null,
  notes text,
  correction_reason text,
  source_application text not null default 'FINISH_V2',
  recorded_at timestamptz not null default now(),
  recorded_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint finish_production_entries_revision_positive_ck check (revision_no > 0),
  constraint finish_production_entries_status_ck check (status in ('ACTIVE','SUPERSEDED','CANCELLED')),
  constraint finish_production_entries_shift_ck check (shift_code_snapshot in ('MORNING','EVENING')),
  constraint finish_production_entries_table_ck check (table_code_snapshot in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')),
  constraint finish_production_entries_delivery_ck check (delivery_date >= production_business_date),
  unique (entry_group_id, revision_no)
);

create unique index if not exists finish_production_one_active_group_uq
  on public.finish_production_entries(entry_group_id)
  where status='ACTIVE';
create index if not exists finish_production_flow_idx
  on public.finish_production_entries(production_flow_item_id,status,recorded_at desc);
create index if not exists finish_production_table_metrics_idx
  on public.finish_production_entries(production_business_date,shift_code_snapshot,table_code_snapshot,status);

create table if not exists public.finish_production_lines (
  finish_production_line_id uuid primary key default gen_random_uuid(),
  finish_production_entry_id uuid not null
    references public.finish_production_entries(finish_production_entry_id) on delete restrict,
  line_no integer not null,
  batch_reference text not null,
  unit_code text not null,
  quantity numeric(14,2) not null,
  created_at timestamptz not null default now(),
  constraint finish_production_lines_line_positive_ck check (line_no > 0),
  constraint finish_production_lines_batch_ck check (length(trim(batch_reference)) between 1 and 120),
  constraint finish_production_lines_unit_ck check (unit_code in ('KG','UNIT')),
  constraint finish_production_lines_quantity_ck check (quantity > 0),
  constraint finish_production_lines_unit_integer_ck check (unit_code <> 'UNIT' or quantity=trunc(quantity)),
  unique (finish_production_entry_id,line_no)
);
create index if not exists finish_production_lines_batch_idx
  on public.finish_production_lines(lower(batch_reference));

create table if not exists public.finish_production_trolleys (
  finish_production_trolley_id uuid primary key default gen_random_uuid(),
  finish_production_entry_id uuid not null
    references public.finish_production_entries(finish_production_entry_id) on delete restrict,
  trolley_id uuid references public.trolleys(trolley_id) on delete restrict,
  trolley_code_snapshot text not null,
  stay_id uuid references public.trolley_customer_stays(stay_id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (finish_production_entry_id,trolley_code_snapshot)
);

alter table public.finish_production_entries enable row level security;
alter table public.finish_production_lines enable row level security;
alter table public.finish_production_trolleys enable row level security;
revoke all on table public.finish_production_entries from public,anon,authenticated;
revoke all on table public.finish_production_lines from public,anon,authenticated;
revoke all on table public.finish_production_trolleys from public,anon,authenticated;

create or replace function public.require_finish_production_access()
returns void
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
begin
  if auth.uid() is null or public.current_staff_id() is null then
    raise exception using errcode='42501', message='An active authenticated staff account is required.';
  end if;
  if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR']) then
    raise exception using errcode='42501', message='Your role cannot use Finish Production.';
  end if;
end;
$$;
revoke all on function public.require_finish_production_access() from public,anon,authenticated;

create or replace function public.finish_delivery_cutoff(p_delivery_date date)
returns timestamptz
language sql
stable
security definer
set search_path=public,auth,pg_temp
as $$
  select case when p_delivery_date is null then null
    else (p_delivery_date::text || ' 12:00:00')::timestamp at time zone 'Europe/Dublin'
  end;
$$;
revoke all on function public.finish_delivery_cutoff(date) from public,anon,authenticated;

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
declare v_flow public.production_flow_items%rowtype;
begin
  select * into v_flow from public.production_flow_items where production_flow_item_id=p_flow_id;
  if not found or v_flow.product_code<>'CLOTHES' then
    raise exception using errcode='22023', message='A valid CLOTHES Production Flow item is required.';
  end if;
  if v_flow.scheduled_for_date is null then
    raise exception using errcode='22023', message='Finish V2 currently requires a scheduled CLOTHES Production Flow item.';
  end if;
  delivery_date:=public.next_distribution_business_date(v_flow.scheduled_for_date);
  edit_cutoff_at:=public.finish_delivery_cutoff(delivery_date);
  if coalesce(p_at,now())>=edit_cutoff_at then
    raise exception using errcode='23514', message=format('Finish production is locked from 12:00 on Delivery Date %s.',to_char(delivery_date,'DD Mon YYYY'));
  end if;
  return next;
end;
$$;
revoke all on function public.finish_assert_entry_open(uuid,timestamptz) from public,anon,authenticated;

create or replace function public.finish_validate_lines(
  p_flow_id uuid,
  p_business_date date,
  p_lines jsonb,
  p_exclude_group_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_line jsonb; v_batch text; v_unit text; v_qty numeric; v_line_no integer:=0; v_clean jsonb:='[]'::jsonb;
begin
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then
    raise exception using errcode='22023', message='Add at least one Finish batch line.';
  end if;
  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_line_no:=v_line_no+1;
    v_batch:=upper(nullif(trim(v_line->>'batch_reference'),''));
    v_unit:=upper(nullif(trim(v_line->>'unit_code'),''));
    begin v_qty:=(v_line->>'quantity')::numeric; exception when others then v_qty:=null; end;
    if v_batch is null then raise exception using errcode='22023', message='Batch number is required on every line.'; end if;
    if length(v_batch)>120 then raise exception using errcode='22023', message='Batch number is too long.'; end if;
    if v_unit not in ('KG','UNIT') then raise exception using errcode='22023', message='Finish line unit must be KG or UNIT.'; end if;
    if v_qty is null or v_qty<=0 then raise exception using errcode='22023', message='Finish quantity must be greater than zero.'; end if;
    if v_unit='UNIT' and v_qty<>trunc(v_qty) then raise exception using errcode='22023', message='Units must be a whole number.'; end if;

    -- Current Finish rule: the same batch can have KG + UNIT lines in one
    -- record, but continuation must use a new batch. A batch cannot belong
    -- to another active Finish record on that business day or the same flow.
    if exists(
      select 1
      from public.finish_production_entries e
      join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
      where e.status='ACTIVE'
        and lower(l.batch_reference)=lower(v_batch)
        and (e.production_business_date=p_business_date or e.production_flow_item_id=p_flow_id)
        and (p_exclude_group_id is null or e.entry_group_id<>p_exclude_group_id)
    ) then
      raise exception using errcode='23505', message=format('Batch %s is already used by another active Finish record. Continuation requires a new batch.',v_batch);
    end if;
    v_clean:=v_clean||jsonb_build_array(jsonb_build_object('line_no',v_line_no,'batch_reference',v_batch,'unit_code',v_unit,'quantity',v_qty));
  end loop;
  return v_clean;
end;
$$;
revoke all on function public.finish_validate_lines(uuid,date,jsonb,uuid) from public,anon,authenticated;


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
  v_flow public.production_flow_items%rowtype; v_trolley public.trolleys%rowtype; v_stay public.trolley_customer_stays%rowtype;
  v_staff uuid; v_delivery date;
begin
  perform public.require_finish_production_access();
  if nullif(trim(p_trolley_code),'') is null then raise exception using errcode='22023', message='Trolley code is required.'; end if;
  select * into v_flow from public.production_flow_items where production_flow_item_id=p_production_flow_item_id;
  if not found or v_flow.product_code<>'CLOTHES' or v_flow.scheduled_for_date is null then raise exception using errcode='22023', message='A scheduled CLOTHES Production Flow item is required.'; end if;
  v_delivery:=public.next_distribution_business_date(v_flow.scheduled_for_date);
  if p_production_business_date is null or p_production_business_date<v_flow.scheduled_for_date or p_production_business_date>v_delivery then
    raise exception using errcode='22023', message='Finish trolley contribution date must be between the scheduled production date and Delivery Date.';
  end if;
  if now()>=public.finish_delivery_cutoff(v_delivery) then raise exception using errcode='23514', message='Finish trolley assignment is locked after the Delivery Date 12:00 cutoff.'; end if;
  v_staff:=public.current_staff_id();
  select * into v_trolley from public.trolleys t where lower(t.trolley_code)=lower(trim(p_trolley_code)) and t.deleted_at is null for update;
  if not found then raise exception using errcode='P0002', message=format('Trolley not found: %s',trim(p_trolley_code)); end if;
  if not v_trolley.active or v_trolley.status not in ('AVAILABLE','LOCATION_UNCONFIRMED') then raise exception using errcode='23514', message=format('Trolley %s cannot be assigned from Finish. Current status: %s',v_trolley.trolley_code,v_trolley.status); end if;
  if exists(select 1 from public.trolley_customer_stays s where s.trolley_id=v_trolley.trolley_id and s.received_on is null) then raise exception using errcode='23505', message=format('Trolley %s already has an open customer stay.',v_trolley.trolley_code); end if;
  insert into public.trolley_customer_stays(trolley_id,outbound_customer_id,sent_on,status,review_status,sent_recorded_by,notes,production_business_date,planned_delivery_on,production_area_code,custody_start_source,source_schedule_version_id,source_schedule_day_id,source_schedule_product_id,production_recorded_by,production_recorded_at)
  values(v_trolley.trolley_id,v_flow.customer_id,v_delivery,'OPEN','NOT_REQUIRED',v_staff,nullif(trim(p_notes),''),p_production_business_date,v_delivery,'FINISH','PRODUCTION_NEXT_DAY_INFERENCE',v_flow.source_schedule_version_id,v_flow.source_schedule_day_id,v_flow.source_schedule_product_id,v_staff,now()) returning * into v_stay;
  update public.trolleys set status='IN_PRODUCTION',updated_by=auth.uid() where trolley_id=v_trolley.trolley_id;
  insert into public.trolley_events(trolley_id,stay_id,event_type,customer_id,business_date,performed_by,source_application,reason,metadata)
  values(v_trolley.trolley_id,v_stay.stay_id,'ASSIGNED_IN_PRODUCTION',v_flow.customer_id,p_production_business_date,v_staff,'FINISH_V2',p_notes,jsonb_build_object('production_flow_item_id',v_flow.production_flow_item_id,'scheduled_for_date',v_flow.scheduled_for_date,'production_business_date',p_production_business_date,'planned_delivery_on',v_delivery,'production_area_code','FINISH','product_code','CLOTHES','custody_start_source','PRODUCTION_NEXT_DAY_INFERENCE'));
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application)
  values(auth.uid(),v_staff,'ASSIGN_TROLLEY_FROM_FINISH_PRODUCTION','trolley_customer_stays',v_stay.stay_id::text,to_jsonb(v_stay),p_notes,'FINISH_V2');
  return jsonb_build_object('trolley_id',v_trolley.trolley_id,'trolley_code',v_trolley.trolley_code,'stay_id',v_stay.stay_id,'customer_id',v_flow.customer_id,'production_flow_item_id',v_flow.production_flow_item_id,'production_business_date',p_production_business_date,'planned_delivery_on',v_delivery,'status','IN_PRODUCTION');
end;
$$;
revoke all on function public.assign_finish_trolley_to_flow(text,uuid,date,text) from public,anon,authenticated;

create or replace function public.record_finish_production(
  p_production_flow_item_id uuid,
  p_shift_code text,
  p_table_code text,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_flow public.production_flow_items%rowtype; v_shift public.shifts%rowtype; v_station public.stations%rowtype;
  v_business_date date; v_delivery date; v_cutoff timestamptz; v_staff uuid; v_group uuid:=gen_random_uuid();
  v_entry public.finish_production_entries%rowtype; v_clean jsonb; v_line jsonb; v_code text; v_assign jsonb;
  v_trolleys text[]:=array[]::text[]; v_total_kg numeric:=0; v_total_units numeric:=0;
begin
  perform public.require_finish_production_access();
  select * into v_flow from public.production_flow_items where production_flow_item_id=p_production_flow_item_id for update;
  if not found or v_flow.product_code<>'CLOTHES' then raise exception using errcode='22023', message='A valid CLOTHES Production Flow item is required.'; end if;
  if not exists(select 1 from public.production_flow_events ev where ev.production_flow_item_id=v_flow.production_flow_item_id and ev.stage_rank>=30 and ev.event_type like 'WASH%') then
    raise exception using errcode='23514', message='Finish Production requires Washing evidence for this customer.';
  end if;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null;
  if not found or v_shift.shift_code not in ('MORNING','EVENING') then raise exception using errcode='22023', message='Shift must be Morning or Evening.'; end if;
  select * into v_station from public.stations where station_code=upper(trim(coalesce(p_table_code,''))) and active=true and deleted_at is null;
  if not found or v_station.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then raise exception using errcode='22023', message='Choose Finish Table 1, Table 2 or Table 3.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  select x.delivery_date,x.edit_cutoff_at into v_delivery,v_cutoff from public.finish_assert_entry_open(v_flow.production_flow_item_id,now()) x;
  if exists(select 1 from public.finish_production_entries e where e.production_flow_item_id=v_flow.production_flow_item_id and e.production_business_date=v_business_date and e.shift_code_snapshot=v_shift.shift_code and e.table_code_snapshot=v_station.station_code and e.status='ACTIVE') then
    raise exception using errcode='23505', message='This customer already has an active record for this Table and Shift. Use Edit to add the next batch or correct the record.';
  end if;
  v_clean:=public.finish_validate_lines(v_flow.production_flow_item_id,v_business_date,p_lines,null);
  v_staff:=public.current_staff_id();
  insert into public.finish_production_entries(entry_group_id,revision_no,status,production_flow_item_id,customer_id,production_business_date,delivery_date,edit_cutoff_at,shift_id,shift_code_snapshot,station_id,table_code_snapshot,table_name_snapshot,notes,recorded_by_staff_id,recorded_by_auth_user_id)
  values(v_group,1,'ACTIVE',v_flow.production_flow_item_id,v_flow.customer_id,v_business_date,v_delivery,v_cutoff,v_shift.shift_id,v_shift.shift_code,v_station.station_id,v_station.station_code,v_station.station_name,nullif(trim(p_notes),''),v_staff,auth.uid()) returning * into v_entry;
  for v_line in select value from jsonb_array_elements(v_clean) loop
    insert into public.finish_production_lines(finish_production_entry_id,line_no,batch_reference,unit_code,quantity)
    values(v_entry.finish_production_entry_id,(v_line->>'line_no')::integer,v_line->>'batch_reference',v_line->>'unit_code',(v_line->>'quantity')::numeric);
    if v_line->>'unit_code'='KG' then v_total_kg:=v_total_kg+(v_line->>'quantity')::numeric; else v_total_units:=v_total_units+(v_line->>'quantity')::numeric; end if;
  end loop;
  for v_code in select distinct upper(trim(x)) from unnest(coalesce(p_trolley_codes,array[]::text[])) x where nullif(trim(x),'') is not null loop
    v_assign:=public.assign_finish_trolley_to_flow(v_code,v_flow.production_flow_item_id,v_business_date,'Finish Production '||v_entry.finish_production_entry_id::text);
    insert into public.finish_production_trolleys(finish_production_entry_id,trolley_id,trolley_code_snapshot,stay_id)
    values(v_entry.finish_production_entry_id,(v_assign->>'trolley_id')::uuid,v_assign->>'trolley_code',(v_assign->>'stay_id')::uuid);
    v_trolleys:=array_append(v_trolleys,v_assign->>'trolley_code');
  end loop;
  insert into public.production_flow_events(production_flow_item_id,event_type,stage_code,stage_rank,area_code,business_date,occurred_at,performed_by_staff_id,recorded_by_staff_id,recorded_by_auth_user_id,source_application,source_entity_table,source_entity_id,event_data)
  values(v_flow.production_flow_item_id,'FINISH_PRODUCTION_RECORDED','PRODUCTION',40,'FINISH',v_business_date,now(),v_staff,v_staff,auth.uid(),'FINISH_V2','finish_production_entries',v_entry.finish_production_entry_id::text,jsonb_build_object('entry_group_id',v_group,'revision_no',1,'table_code',v_station.station_code,'shift_code',v_shift.shift_code,'delivery_date',v_delivery,'edit_cutoff_at',v_cutoff,'processed_kg',v_total_kg,'processed_units',v_total_units,'trolley_codes',to_jsonb(v_trolleys)));
  update public.production_flow_items set current_stage_code='PRODUCTION',current_stage_rank=greatest(current_stage_rank,40),last_event_type='FINISH_PRODUCTION_RECORDED',last_event_at=now(),last_area_code='FINISH',last_performed_by_staff_id=v_staff,event_count=event_count+1,updated_at=now(),row_version=row_version+1 where production_flow_item_id=v_flow.production_flow_item_id;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,source_application) values(auth.uid(),v_staff,'RECORD_FINISH_PRODUCTION','finish_production_entries',v_entry.finish_production_entry_id::text,jsonb_build_object('entry',to_jsonb(v_entry),'lines',v_clean,'trolley_codes',to_jsonb(v_trolleys)),'FINISH_V2');
  return jsonb_build_object('status','saved','finish_production_entry_id',v_entry.finish_production_entry_id,'entry_group_id',v_group,'revision_no',1,'processed_kg',v_total_kg,'processed_units',v_total_units,'delivery_date',v_delivery,'edit_cutoff_at',v_cutoff);
end;
$$;

create or replace function public.correct_finish_production(
  p_finish_production_entry_id uuid,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_notes text default null,
  p_correction_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_old public.finish_production_entries%rowtype; v_new public.finish_production_entries%rowtype; v_clean jsonb; v_line jsonb;
  v_reason text:=nullif(trim(coalesce(p_correction_reason,'')),''); v_staff uuid; v_old_codes text[]; v_new_codes text[]; v_code text; v_assign jsonb;
  v_total_kg numeric:=0; v_total_units numeric:=0;
begin
  perform public.require_finish_production_access();
  if v_reason is null then raise exception using errcode='22023', message='Correction reason is required.'; end if;
  select * into v_old from public.finish_production_entries where finish_production_entry_id=p_finish_production_entry_id and status='ACTIVE' for update;
  if not found then raise exception using errcode='P0002', message='The active Finish record was not found.'; end if;
  perform public.finish_assert_entry_open(v_old.production_flow_item_id,now());
  v_clean:=public.finish_validate_lines(v_old.production_flow_item_id,v_old.production_business_date,p_lines,v_old.entry_group_id);
  select coalesce(array_agg(upper(trolley_code_snapshot) order by upper(trolley_code_snapshot)),array[]::text[]) into v_old_codes from public.finish_production_trolleys where finish_production_entry_id=v_old.finish_production_entry_id;
  select coalesce(array_agg(distinct upper(trim(x)) order by upper(trim(x))),array[]::text[]) into v_new_codes from unnest(coalesce(p_trolley_codes,array[]::text[])) x where nullif(trim(x),'') is not null;
  -- Lifecycle safety: existing production-assigned trolleys cannot be silently
  -- removed/replaced by a production correction because that would invent a
  -- physical return. New trolleys may be added before the cutoff.
  if exists(select 1 from unnest(v_old_codes) x where not (x=any(v_new_codes))) then
    raise exception using errcode='23514', message='A trolley already assigned by Finish cannot be removed through Edit because its physical lifecycle is already open. Keep the scanned trolley and correct the production values, or use a separately governed trolley correction workflow.';
  end if;
  v_staff:=public.current_staff_id();
  update public.finish_production_entries set status='SUPERSEDED' where finish_production_entry_id=v_old.finish_production_entry_id;
  insert into public.finish_production_entries(entry_group_id,revision_no,status,supersedes_finish_production_entry_id,production_flow_item_id,customer_id,production_business_date,delivery_date,edit_cutoff_at,shift_id,shift_code_snapshot,station_id,table_code_snapshot,table_name_snapshot,notes,correction_reason,source_application,recorded_by_staff_id,recorded_by_auth_user_id)
  values(v_old.entry_group_id,v_old.revision_no+1,'ACTIVE',v_old.finish_production_entry_id,v_old.production_flow_item_id,v_old.customer_id,v_old.production_business_date,v_old.delivery_date,v_old.edit_cutoff_at,v_old.shift_id,v_old.shift_code_snapshot,v_old.station_id,v_old.table_code_snapshot,v_old.table_name_snapshot,nullif(trim(p_notes),''),v_reason,'FINISH_V2',v_staff,auth.uid()) returning * into v_new;
  for v_line in select value from jsonb_array_elements(v_clean) loop
    insert into public.finish_production_lines(finish_production_entry_id,line_no,batch_reference,unit_code,quantity) values(v_new.finish_production_entry_id,(v_line->>'line_no')::integer,v_line->>'batch_reference',v_line->>'unit_code',(v_line->>'quantity')::numeric);
    if v_line->>'unit_code'='KG' then v_total_kg:=v_total_kg+(v_line->>'quantity')::numeric; else v_total_units:=v_total_units+(v_line->>'quantity')::numeric; end if;
  end loop;
  -- Carry existing lifecycle links into the new revision.
  insert into public.finish_production_trolleys(finish_production_entry_id,trolley_id,trolley_code_snapshot,stay_id)
  select v_new.finish_production_entry_id,trolley_id,trolley_code_snapshot,stay_id from public.finish_production_trolleys where finish_production_entry_id=v_old.finish_production_entry_id;
  for v_code in select x from unnest(v_new_codes) x where not (x=any(v_old_codes)) loop
    v_assign:=public.assign_finish_trolley_to_flow(v_code,v_old.production_flow_item_id,v_old.production_business_date,'Finish correction '||v_new.finish_production_entry_id::text);
    insert into public.finish_production_trolleys(finish_production_entry_id,trolley_id,trolley_code_snapshot,stay_id) values(v_new.finish_production_entry_id,(v_assign->>'trolley_id')::uuid,v_assign->>'trolley_code',(v_assign->>'stay_id')::uuid);
  end loop;
  insert into public.production_flow_events(production_flow_item_id,event_type,stage_code,stage_rank,area_code,business_date,occurred_at,performed_by_staff_id,recorded_by_staff_id,recorded_by_auth_user_id,source_application,source_entity_table,source_entity_id,event_data)
  values(v_old.production_flow_item_id,'FINISH_PRODUCTION_CORRECTED','PRODUCTION',40,'FINISH',v_old.production_business_date,now(),v_staff,v_staff,auth.uid(),'FINISH_V2','finish_production_entries',v_new.finish_production_entry_id::text,jsonb_build_object('entry_group_id',v_old.entry_group_id,'revision_no',v_new.revision_no,'supersedes',v_old.finish_production_entry_id,'correction_reason',v_reason,'processed_kg',v_total_kg,'processed_units',v_total_units));
  update public.production_flow_items set last_event_type='FINISH_PRODUCTION_CORRECTED',last_event_at=now(),last_area_code='FINISH',last_performed_by_staff_id=v_staff,event_count=event_count+1,updated_at=now(),row_version=row_version+1 where production_flow_item_id=v_old.production_flow_item_id;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application) values(auth.uid(),v_staff,'CORRECT_FINISH_PRODUCTION','finish_production_entries',v_new.finish_production_entry_id::text,to_jsonb(v_old),jsonb_build_object('entry',to_jsonb(v_new),'lines',v_clean,'trolley_codes',to_jsonb(v_new_codes)),v_reason,'FINISH_V2');
  return jsonb_build_object('status','corrected','finish_production_entry_id',v_new.finish_production_entry_id,'entry_group_id',v_new.entry_group_id,'revision_no',v_new.revision_no,'processed_kg',v_total_kg,'processed_units',v_total_units);
end;
$$;

create or replace function public.get_finish_production_context(
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
  v_shift text:=upper(trim(coalesce(p_shift_code,'MORNING'))); v_now timestamptz:=coalesce(p_at,now()); v_business_date date;
  v_target numeric:=23.5; v_queue jsonb; v_entries jsonb; v_tables jsonb; v_staff jsonb;
begin
  perform public.require_finish_production_access();
  if v_shift not in ('MORNING','EVENING') then raise exception using errcode='22023', message='Shift must be Morning or Evening.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift,v_now);
  select coalesce((select target_value from public.production_targets where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR' and active=true limit 1),23.5) into v_target;

  with candidate as (
    select p.*,public.next_distribution_business_date(p.scheduled_for_date) delivery_date,public.finish_delivery_cutoff(public.next_distribution_business_date(p.scheduled_for_date)) cutoff
    from public.production_flow_items p
    where p.product_code='CLOTHES' and p.flow_status='OPEN' and p.scheduled_for_date is not null
      and public.next_distribution_business_date(p.scheduled_for_date)>=v_business_date
      and exists(select 1 from public.production_flow_events ev where ev.production_flow_item_id=p.production_flow_item_id and ev.stage_rank>=30 and ev.event_type like 'WASH%')
  ), totals as (
    select e.production_flow_item_id,
      coalesce(sum(case when l.unit_code='KG' then l.quantity else 0 end),0) processed_kg,
      coalesce(sum(case when l.unit_code='UNIT' then l.quantity else 0 end),0) processed_units,
      count(distinct e.entry_group_id) contribution_count,
      max(e.recorded_at) last_finish_at
    from public.finish_production_entries e join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
    where e.status='ACTIVE' group by e.production_flow_item_id
  ), q as (
    select c.*,coalesce(t.processed_kg,0) processed_kg,coalesce(t.processed_units,0) processed_units,coalesce(t.contribution_count,0) contribution_count,t.last_finish_at,
      case when v_now>=c.cutoff then 'LOCKED' when coalesce(t.contribution_count,0)>0 then 'CONTINUE' else 'READY' end finish_state
    from candidate c left join totals t on t.production_flow_item_id=c.production_flow_item_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'production_flow_item_id',q.production_flow_item_id,'customer_id',q.customer_id,'customer_code',q.customer_code_snapshot,'customer_name',q.customer_name_snapshot,
    'scheduled_for_date',q.scheduled_for_date,'delivery_date',q.delivery_date,'edit_cutoff_at',q.cutoff,'production_order',q.production_order_snapshot,
    'route_code',q.route_code_snapshot,'route_name',q.route_display_name_snapshot,'route_color',q.route_color_snapshot,'finish_state',q.finish_state,
    'processed_kg',q.processed_kg,'processed_units',q.processed_units,'contribution_count',q.contribution_count,'last_finish_at',q.last_finish_at,
    'expected_kg',(select sp.expected_kg from public.customer_schedule_products sp where sp.schedule_product_id=q.source_schedule_product_id),
    'expected_units',(select sp.expected_units from public.customer_schedule_products sp where sp.schedule_product_id=q.source_schedule_product_id),
    'finish_instructions',(select sp.production_instructions from public.customer_schedule_products sp where sp.schedule_product_id=q.source_schedule_product_id),
    'planned_trolley_summary',(select string_agg(concat(r.quantity,coalesce(tt.display_code,tt.trolley_type_code),case when r.empty_trolley then ' Empty' else '' end),' + ' order by tt.sort_order) from public.customer_schedule_trolley_requirements r join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id where r.active=true and r.owner_schedule_product_id=q.source_schedule_product_id),
    'planned_trolley_requirements',(select coalesce(jsonb_agg(jsonb_build_object('trolley_type_id',tt.trolley_type_id,'trolley_type_code',tt.trolley_type_code,'display_code',coalesce(tt.display_code,tt.trolley_type_code),'trolley_type_name',tt.trolley_type_name,'quantity',r.quantity,'empty_trolley',r.empty_trolley) order by tt.sort_order),'[]'::jsonb) from public.customer_schedule_trolley_requirements r join public.trolley_types tt on tt.trolley_type_id=r.trolley_type_id where r.active=true and r.owner_schedule_product_id=q.source_schedule_product_id)
  ) order by q.delivery_date,q.production_order_snapshot nulls last,q.customer_name_snapshot),'[]'::jsonb) into v_queue from q;

  with active as (
    select e.*,
      coalesce((select sum(l.quantity) from public.finish_production_lines l where l.finish_production_entry_id=e.finish_production_entry_id and l.unit_code='KG'),0) kg,
      coalesce((select sum(l.quantity) from public.finish_production_lines l where l.finish_production_entry_id=e.finish_production_entry_id and l.unit_code='UNIT'),0) units
    from public.finish_production_entries e where e.status='ACTIVE' and e.production_business_date between v_business_date-7 and v_business_date
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'finish_production_entry_id',a.finish_production_entry_id,'entry_group_id',a.entry_group_id,'revision_no',a.revision_no,'production_flow_item_id',a.production_flow_item_id,
    'customer_id',a.customer_id,'customer_name',(select customer_name_snapshot from public.production_flow_items where production_flow_item_id=a.production_flow_item_id),
    'business_date',a.production_business_date,'delivery_date',a.delivery_date,'edit_cutoff_at',a.edit_cutoff_at,'shift_code',a.shift_code_snapshot,'table_code',a.table_code_snapshot,'table_name',a.table_name_snapshot,
    'processed_kg',a.kg,'processed_units',a.units,'notes',a.notes,'recorded_at',a.recorded_at,
    'recorded_by',(select display_name from public.staff_members where staff_id=a.recorded_by_staff_id),
    'lines',coalesce((select jsonb_agg(jsonb_build_object('line_no',l.line_no,'batch_reference',l.batch_reference,'unit_code',l.unit_code,'quantity',l.quantity) order by l.line_no) from public.finish_production_lines l where l.finish_production_entry_id=a.finish_production_entry_id),'[]'::jsonb),
    'trolley_codes',coalesce((select jsonb_agg(t.trolley_code_snapshot order by t.trolley_code_snapshot) from public.finish_production_trolleys t where t.finish_production_entry_id=a.finish_production_entry_id),'[]'::jsonb)
  ) order by a.recorded_at desc),'[]'::jsonb) into v_entries from active a;

  with table_master as (
    select st.station_id,st.station_code,st.station_name from public.stations st join public.areas a on a.area_id=st.area_id where a.area_code='FINISH' and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') and st.active=true and st.deleted_at is null
  ), hours as (
    select tm.station_code,
      coalesce(sum(greatest(0,extract(epoch from (least(coalesce(ws.actual_end_at,v_now),v_now)-ws.actual_start_at))/3600.0 - coalesce(ws.break_minutes,0)/60.0)),0) staff_hours,
      count(distinct ws.staff_id) filter(where ws.actual_start_at is not null and (ws.actual_end_at is null or ws.actual_end_at>ws.actual_start_at)) staff_count
    from table_master tm left join public.work_sessions ws on ws.station_id=tm.station_id and ws.work_date=v_business_date and ws.status<>'CANCELLED'
      and ws.shift_id=(select shift_id from public.shifts where shift_code=v_shift and active=true and deleted_at is null)
    group by tm.station_code
  ), prod as (
    select e.table_code_snapshot station_code,coalesce(sum(l.quantity) filter(where l.unit_code='KG'),0) produced_kg,coalesce(sum(l.quantity) filter(where l.unit_code='UNIT'),0) produced_units
    from public.finish_production_entries e join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
    where e.status='ACTIVE' and e.production_business_date=v_business_date and e.shift_code_snapshot=v_shift group by e.table_code_snapshot
  )
  select coalesce(jsonb_agg(jsonb_build_object('table_code',tm.station_code,'table_name',tm.station_name,'produced_kg',coalesce(p.produced_kg,0),'produced_units',coalesce(p.produced_units,0),'staff_hours',round(coalesce(h.staff_hours,0)::numeric,2),'staff_count',coalesce(h.staff_count,0),'target_kg_per_staff_hour',v_target,'target_now_kg',round((coalesce(h.staff_hours,0)*v_target)::numeric,2),'difference_kg',round((coalesce(p.produced_kg,0)-coalesce(h.staff_hours,0)*v_target)::numeric,2),'kg_per_staff_hour',case when coalesce(h.staff_hours,0)>0 then round((coalesce(p.produced_kg,0)/h.staff_hours)::numeric,2) else null end,'efficiency_percent',case when coalesce(h.staff_hours,0)>0 then round((coalesce(p.produced_kg,0)/(h.staff_hours*v_target)*100)::numeric,1) else null end) order by tm.station_code),'[]'::jsonb) into v_tables from table_master tm left join hours h on h.station_code=tm.station_code left join prod p on p.station_code=tm.station_code;

  with planned as (
    select distinct on (pre.staff_id) pre.staff_id,pre.staff_display_name_snapshot display_name,pre.station_code_snapshot planned_table_code,pre.planned_start_time,pre.planned_end_time
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
    join public.shifts psh on psh.shift_id=prv.shift_id
    where prv.status='PUBLISHED' and pre.work_date=v_business_date and psh.shift_code=v_shift
      and pre.area_code_snapshot='FINISH' and pre.day_status in ('WORKING','QUALITY_ANALYSIS')
    order by pre.staff_id,prv.version_number desc
  ), actual as (
    select distinct on (ws.staff_id) ws.staff_id,ws.work_session_id,st.station_code table_code,ws.actual_start_at,ws.actual_end_at,ws.status,ws.source
    from public.work_sessions ws join public.areas a on a.area_id=ws.area_id join public.shifts sh on sh.shift_id=ws.shift_id left join public.stations st on st.station_id=ws.station_id
    where ws.work_date=v_business_date and ws.status<>'CANCELLED' and a.area_code='FINISH' and sh.shift_code=v_shift
    order by ws.staff_id,ws.updated_at desc
  ), ids as (select staff_id from planned union select staff_id from actual)
  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id',sm.staff_id,'display_name',sm.display_name,'planned_table_code',p.planned_table_code,'planned_start_time',p.planned_start_time,'planned_end_time',p.planned_end_time,
    'work_session_id',a.work_session_id,'table_code',a.table_code,'actual_start_at',a.actual_start_at,'actual_end_at',a.actual_end_at,'status',a.status,'source',a.source
  ) order by coalesce(a.table_code,p.planned_table_code,'ZZZ'),sm.display_name),'[]'::jsonb) into v_staff
  from ids i join public.staff_members sm on sm.staff_id=i.staff_id left join planned p on p.staff_id=i.staff_id left join actual a on a.staff_id=i.staff_id;

  return jsonb_build_object('schema_version','FINISH_PRODUCTION_V1','source_contract','FINISH_V2_PRODUCTION_LEDGER','generated_at',v_now,'business_date',v_business_date,'shift_code',v_shift,'target_kg_per_staff_hour',v_target,'queue',v_queue,'entries',v_entries,'tables',v_tables,'staff',v_staff,'permissions',jsonb_build_object('can_record',true,'can_select_any_table',public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','FINISH_OPERATOR'])));
end;
$$;


create or replace function public.upsert_finish_staff_actual(
  p_staff_id uuid,
  p_shift_code text,
  p_table_code text,
  p_start_time time default null,
  p_end_time time default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_business_date date; v_shift public.shifts%rowtype; v_station public.stations%rowtype; v_area_id uuid;
  v_staff public.staff_members%rowtype; v_existing public.work_sessions%rowtype; v_saved public.work_sessions%rowtype;
  v_start timestamptz; v_end timestamptz; v_actor uuid; v_old jsonb;
begin
  perform public.require_finish_production_access();
  if p_staff_id is null then raise exception using errcode='22023', message='Staff member is required.'; end if;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null;
  if not found or v_shift.shift_code not in ('MORNING','EVENING') then raise exception using errcode='22023', message='Shift must be Morning or Evening.'; end if;
  select st.* into v_station from public.stations st join public.areas a on a.area_id=st.area_id where st.station_code=upper(trim(coalesce(p_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  if not found or v_station.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then raise exception using errcode='22023', message='Choose Finish Table 1, Table 2 or Table 3.'; end if;
  select area_id into v_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null;
  select * into v_staff from public.staff_members where staff_id=p_staff_id and production_staff=true and active=true and roster_eligible=true and deleted_at is null;
  if not found then raise exception using errcode='22023', message='Selected staff member is not active production staff.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  if p_start_time is not null then v_start:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_start_time); end if;
  if p_end_time is not null then v_end:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_end_time); end if;
  if v_start is not null and v_end is not null and v_end<v_start then raise exception using errcode='22023', message='Leaving time cannot be before Started at.'; end if;
  v_actor:=public.current_staff_id();
  select * into v_existing from public.work_sessions ws where ws.work_date=v_business_date and ws.staff_id=p_staff_id and ws.shift_id=v_shift.shift_id and ws.area_id=v_area_id and ws.status<>'CANCELLED' order by ws.updated_at desc limit 1 for update;
  if found then
    v_old:=to_jsonb(v_existing);
    update public.work_sessions set station_id=v_station.station_id,actual_start_at=coalesce(v_start,actual_start_at),actual_end_at=v_end,status=case when v_end is null then 'OPEN' else 'CONFIRMED' end,source='FINISH_V2',confirmed_by=v_actor,notes=coalesce(nullif(trim(p_reason),''),notes),updated_at=now() where work_session_id=v_existing.work_session_id returning * into v_saved;
  else
    v_old:=null;
    insert into public.work_sessions(work_date,staff_id,area_id,station_id,shift_id,actual_start_at,actual_end_at,status,source,confirmed_by,notes)
    values(v_business_date,p_staff_id,v_area_id,v_station.station_id,v_shift.shift_id,v_start,v_end,case when v_end is null then 'OPEN' else 'CONFIRMED' end,'FINISH_V2',v_actor,nullif(trim(p_reason),'')) returning * into v_saved;
  end if;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,case when v_old is null then 'CREATE_FINISH_STAFF_ACTUAL' else 'UPDATE_FINISH_STAFF_ACTUAL' end,'work_sessions',v_saved.work_session_id::text,v_old,to_jsonb(v_saved),p_reason,'FINISH_V2');
  return jsonb_build_object('status','saved','work_session_id',v_saved.work_session_id,'staff_id',p_staff_id,'table_code',v_station.station_code,'business_date',v_business_date,'shift_code',v_shift.shift_code,'actual_start_at',v_saved.actual_start_at,'actual_end_at',v_saved.actual_end_at);
end;
$$;

-- Shared Tracker V4: preserve V3 and enrich CLOTHES with Finish actuals.
create or replace function public.get_production_tracker_v4(p_business_date date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare v_base jsonb; v_items jsonb;
begin
  v_base:=public.get_production_tracker_v3(p_business_date);
  with base_items as (
    select item,ordinality from jsonb_array_elements(coalesce(v_base->'items','[]'::jsonb)) with ordinality x(item,ordinality)
  ), enriched as (
    select b.ordinality,
      case when upper(coalesce(b.item->>'product_code',''))='CLOTHES' then
        b.item || jsonb_build_object(
          'processed_quantity_kg',coalesce(f.kg,0),
          'processed_quantity_units',coalesce(f.units,0),
          'processed_quantity_source',case when coalesce(f.contributions,0)>0 then 'FINISH_PRODUCTION' else 'FINISH_PENDING' end,
          'product_status',case when coalesce(f.contributions,0)>0 then 'TRACKER_OK' else coalesce(b.item->>'product_status','WASHED_ONLY') end,
          'finish_contribution_count',coalesce(f.contributions,0),
          'finish_last_processed_at',f.last_at,
          'finish_tables',coalesce(f.tables,'[]'::jsonb),
          'finish_trolleys',coalesce(f.trolleys,'[]'::jsonb)
        )
      else b.item end as item
    from base_items b
    left join lateral (
      select coalesce(sum(l.quantity) filter(where l.unit_code='KG'),0) kg,
        coalesce(sum(l.quantity) filter(where l.unit_code='UNIT'),0) units,
        count(distinct e.entry_group_id) contributions,max(e.recorded_at) last_at,
        coalesce(jsonb_agg(distinct e.table_code_snapshot),'[]'::jsonb) tables,
        coalesce((select jsonb_agg(distinct jsonb_build_object('trolley_code',ft.trolley_code_snapshot,'stay_id',ft.stay_id)) from public.finish_production_entries ee join public.finish_production_trolleys ft on ft.finish_production_entry_id=ee.finish_production_entry_id where ee.status='ACTIVE' and ee.production_flow_item_id=nullif(b.item->>'production_flow_item_id','')::uuid),'[]'::jsonb) trolleys
      from public.finish_production_entries e join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
      where e.status='ACTIVE' and e.production_flow_item_id=nullif(b.item->>'production_flow_item_id','')::uuid
    ) f on true
  ) select coalesce(jsonb_agg(item order by ordinality),'[]'::jsonb) into v_items from enriched;
  return (v_base-'schema_version'-'source_contract'-'items')||jsonb_build_object('schema_version','PRODUCTION_TRACKER_V4','source_contract','PRODUCTION_FLOW_SHARED_TRACKER_V4','finish_processed_actual_contract','FINISH_PRODUCTION_LEDGER','items',v_items);
end;
$$;

revoke all on function public.record_finish_production(uuid,text,text,jsonb,text[],text) from public,anon;
revoke all on function public.correct_finish_production(uuid,jsonb,text[],text,text) from public,anon;
revoke all on function public.get_finish_production_context(text,timestamptz) from public,anon;
revoke all on function public.get_production_tracker_v4(date) from public,anon;
revoke all on function public.upsert_finish_staff_actual(uuid,text,text,time,time,text) from public,anon;
grant execute on function public.record_finish_production(uuid,text,text,jsonb,text[],text) to authenticated;
grant execute on function public.correct_finish_production(uuid,jsonb,text[],text,text) to authenticated;
grant execute on function public.get_finish_production_context(text,timestamptz) to authenticated;
grant execute on function public.get_production_tracker_v4(date) to authenticated;
grant execute on function public.upsert_finish_staff_actual(uuid,text,text,time,time,text) to authenticated;

comment on function public.record_finish_production(uuid,text,text,jsonb,text[],text) is 'Records one Finish contribution for a washed CLOTHES Production Flow item. Table is explicit so the same application supports current table workstations and a future central multi-table scanner.';
comment on function public.correct_finish_production(uuid,jsonb,text[],text,text) is 'Append-only Finish correction before the Delivery Date 12:00 Europe/Dublin cutoff. Existing trolley lifecycle assignments cannot be silently removed.';
comment on function public.get_finish_production_context(text,timestamptz) is 'Finish V2 queue, active entries, actual Table staff and current productivity metrics using the governed Finish target.';
comment on function public.upsert_finish_staff_actual(uuid,text,text,time,time,text) is 'Creates or updates Finish Actual table/time evidence for production staff. Published Roster remains unchanged and audit_log preserves changes.';
comment on function public.get_production_tracker_v4(date) is 'Shared Tracker V4: V3 plus authoritative Finish processed CLOTHES quantities/tables/trolley evidence.';

commit;
