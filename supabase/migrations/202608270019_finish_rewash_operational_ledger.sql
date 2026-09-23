-- One real ReWash production record per Finish Table / Shift / operational day.
-- Delivery reconciliation remains intentionally outside this ledger and metrics.
create table if not exists public.finish_rewash_entries (
  finish_rewash_entry_id uuid primary key default gen_random_uuid(),
  entry_group_id uuid not null,
  revision_no integer not null,
  status text not null default 'ACTIVE',
  supersedes_finish_rewash_entry_id uuid references public.finish_rewash_entries(finish_rewash_entry_id) on delete restrict,
  production_business_date date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  shift_code_snapshot text not null,
  station_id uuid not null references public.stations(station_id) on delete restrict,
  table_code_snapshot text not null,
  table_name_snapshot text not null,
  processed_by_staff_id uuid references public.staff_members(staff_id) on delete restrict,
  processed_by_name_snapshot text not null,
  notes text,
  recorded_at timestamptz not null default now(),
  recorded_by_staff_id uuid references public.staff_members(staff_id) on delete set null,
  recorded_by_auth_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint finish_rewash_entries_revision_ck check (revision_no > 0),
  constraint finish_rewash_entries_status_ck check (status in ('ACTIVE','SUPERSEDED','CANCELLED')),
  constraint finish_rewash_entries_shift_ck check (shift_code_snapshot in ('MORNING','EVENING')),
  constraint finish_rewash_entries_table_ck check (table_code_snapshot in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')),
  unique (entry_group_id,revision_no)
);

create unique index if not exists finish_rewash_one_active_cell_uq
  on public.finish_rewash_entries(production_business_date,shift_code_snapshot,table_code_snapshot)
  where status='ACTIVE';
create index if not exists finish_rewash_entries_metrics_idx
  on public.finish_rewash_entries(production_business_date,shift_code_snapshot,table_code_snapshot,status);

create table if not exists public.finish_rewash_lines (
  finish_rewash_line_id uuid primary key default gen_random_uuid(),
  finish_rewash_entry_id uuid not null references public.finish_rewash_entries(finish_rewash_entry_id) on delete restrict,
  line_no integer not null,
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  customer_code_snapshot text not null,
  customer_name_snapshot text not null,
  service_codes_snapshot text[] not null default array[]::text[],
  scheduled_days_snapshot text[] not null default array[]::text[],
  batch_reference text,
  quantity_kg numeric(14,2) not null,
  created_at timestamptz not null default now(),
  constraint finish_rewash_lines_line_no_ck check (line_no > 0),
  constraint finish_rewash_lines_batch_ck check (batch_reference is null or length(trim(batch_reference)) between 1 and 120),
  constraint finish_rewash_lines_kg_ck check (quantity_kg > 0),
  unique (finish_rewash_entry_id,line_no)
);
create index if not exists finish_rewash_lines_customer_idx on public.finish_rewash_lines(customer_id);
create index if not exists finish_rewash_lines_batch_idx on public.finish_rewash_lines(lower(batch_reference)) where batch_reference is not null;

alter table public.finish_rewash_entries enable row level security;
alter table public.finish_rewash_lines enable row level security;
revoke all on table public.finish_rewash_entries from public,anon,authenticated;
revoke all on table public.finish_rewash_lines from public,anon,authenticated;

create or replace function public.finish_rewash_customer_options_v1(p_business_date date)
returns jsonb
language sql
stable
security definer
set search_path=public,auth,pg_temp
as $$
  with eligible as (
    select
      c.customer_id,c.customer_code,c.customer_name,
      array_agg(distinct pt.product_code order by pt.product_code) as service_codes,
      array_agg(distinct public.weekday_name(d.production_weekday) order by public.weekday_name(d.production_weekday)) as scheduled_days
    from public.customers c
    join public.customer_schedule_versions v on v.customer_id=c.customer_id
      and v.status='PUBLISHED'
      and p_business_date between v.effective_from and coalesce(v.effective_until,'infinity'::date)
    join public.customer_schedule_days d on d.schedule_version_id=v.schedule_version_id and d.active=true
    join public.customer_schedule_products sp on sp.schedule_day_id=d.schedule_day_id and sp.active=true
    join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.active=true
    where c.active=true and c.deleted_at is null and pt.product_code in ('CLOTHES','OTHERS')
    group by c.customer_id,c.customer_code,c.customer_name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'customer_id',customer_id,
    'customer_code',customer_code,
    'customer_name',customer_name,
    'label',customer_name||' ('||customer_code||')',
    'service_codes',to_jsonb(service_codes),
    'scheduled_days',to_jsonb(scheduled_days)
  ) order by customer_name,customer_code),'[]'::jsonb)
  from eligible;
$$;

create or replace function public.record_finish_rewash_v1(
  p_shift_code text,
  p_table_code text,
  p_processed_by_staff_id uuid,
  p_lines jsonb,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_shift public.shifts%rowtype;
  v_station public.stations%rowtype;
  v_processor public.staff_members%rowtype;
  v_existing public.finish_rewash_entries%rowtype;
  v_saved public.finish_rewash_entries%rowtype;
  v_business_date date;
  v_actor uuid;
  v_entry_id uuid:=gen_random_uuid();
  v_group_id uuid;
  v_line jsonb;
  v_line_no integer:=0;
  v_customer_id uuid;
  v_customer_code text;
  v_customer_name text;
  v_service_codes text[];
  v_scheduled_days text[];
  v_batch text;
  v_kg numeric;
  v_clean jsonb:='[]'::jsonb;
  v_total_kg numeric:=0;
  v_before jsonb;
begin
  perform public.require_finish_production_access();
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null;
  if not found or v_shift.shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023',message='Choose the Morning or Evening Finish shift.';
  end if;
  select st.* into v_station
  from public.stations st join public.areas a on a.area_id=st.area_id
  where st.station_code=upper(trim(coalesce(p_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  if not found or v_station.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then
    raise exception using errcode='22023',message='Choose Finish Table 1, Table 2 or Table 3.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then
    raise exception using errcode='22023',message='Add at least one ReWash customer line.';
  end if;

  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  select * into v_processor from public.finish_assert_processing_staff(
    p_processed_by_staff_id,v_business_date,v_shift.shift_id,v_station.station_id,now()
  );
  if not found then
    raise exception using errcode='22023',message='Select a staff member working on this Finish Table and Shift.';
  end if;

  select * into v_existing from public.finish_rewash_entries
  where production_business_date=v_business_date and shift_code_snapshot=v_shift.shift_code and table_code_snapshot=v_station.station_code and status='ACTIVE'
  for update;
  v_group_id:=coalesce(v_existing.entry_group_id,v_entry_id);

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_line_no:=v_line_no+1;
    begin v_customer_id:=nullif(v_line->>'customer_id','')::uuid; exception when others then v_customer_id:=null; end;
    begin v_kg:=(v_line->>'quantity_kg')::numeric; exception when others then v_kg:=null; end;
    v_batch:=upper(nullif(trim(v_line->>'batch_reference'),''));
    if v_customer_id is null then raise exception using errcode='22023',message='Choose a valid customer for every ReWash line.'; end if;
    if v_kg is null or v_kg<=0 or v_kg>10000 then raise exception using errcode='22023',message='Each ReWash customer needs a KG value greater than zero.'; end if;
    if v_batch is not null and length(v_batch)>120 then raise exception using errcode='22023',message='A ReWash batch reference is too long.'; end if;

    select c.customer_code,c.customer_name,
      array_agg(distinct pt.product_code order by pt.product_code),
      array_agg(distinct public.weekday_name(d.production_weekday) order by public.weekday_name(d.production_weekday))
    into v_customer_code,v_customer_name,v_service_codes,v_scheduled_days
    from public.customers c
    join public.customer_schedule_versions v on v.customer_id=c.customer_id and v.status='PUBLISHED'
      and v_business_date between v.effective_from and coalesce(v.effective_until,'infinity'::date)
    join public.customer_schedule_days d on d.schedule_version_id=v.schedule_version_id and d.active=true
    join public.customer_schedule_products sp on sp.schedule_day_id=d.schedule_day_id and sp.active=true
    join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.active=true
    where c.customer_id=v_customer_id and c.active=true and c.deleted_at is null and pt.product_code in ('CLOTHES','OTHERS')
    group by c.customer_code,c.customer_name;
    if not found then raise exception using errcode='22023',message='ReWash customers must be active Clothes or Others customers from the current schedule.'; end if;

    if v_batch is not null and exists (
      select 1
      from public.finish_production_entries e
      join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
      where e.status='ACTIVE' and e.production_business_date=v_business_date and lower(l.batch_reference)=lower(v_batch)
      union all
      select 1
      from public.finish_rewash_entries e
      join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
      where e.status='ACTIVE' and e.production_business_date=v_business_date and lower(coalesce(l.batch_reference,''))=lower(v_batch)
        and e.entry_group_id<>v_group_id
    ) then
      raise exception using errcode='23505',message=format('Batch %s is already used by another active Finish record today.',v_batch);
    end if;

    v_clean:=v_clean||jsonb_build_array(jsonb_build_object(
      'line_no',v_line_no,'customer_id',v_customer_id,'customer_code',v_customer_code,'customer_name',v_customer_name,
      'service_codes',to_jsonb(v_service_codes),'scheduled_days',to_jsonb(v_scheduled_days),'batch_reference',v_batch,'quantity_kg',v_kg
    ));
    v_total_kg:=v_total_kg+v_kg;
  end loop;

  v_actor:=public.current_staff_id();
  v_before:=case when v_existing.finish_rewash_entry_id is null then null else to_jsonb(v_existing) end;
  if v_existing.finish_rewash_entry_id is not null then
    update public.finish_rewash_entries set status='SUPERSEDED' where finish_rewash_entry_id=v_existing.finish_rewash_entry_id;
  end if;
  insert into public.finish_rewash_entries(
    finish_rewash_entry_id,entry_group_id,revision_no,status,supersedes_finish_rewash_entry_id,production_business_date,
    shift_id,shift_code_snapshot,station_id,table_code_snapshot,table_name_snapshot,processed_by_staff_id,processed_by_name_snapshot,
    notes,recorded_by_staff_id,recorded_by_auth_user_id
  ) values (
    v_entry_id,v_group_id,case when v_existing.finish_rewash_entry_id is null then 1 else v_existing.revision_no+1 end,'ACTIVE',v_existing.finish_rewash_entry_id,v_business_date,
    v_shift.shift_id,v_shift.shift_code,v_station.station_id,v_station.station_code,v_station.station_name,v_processor.staff_id,v_processor.display_name,
    nullif(trim(p_notes),''),v_actor,auth.uid()
  ) returning * into v_saved;
  insert into public.finish_rewash_lines(
    finish_rewash_entry_id,line_no,customer_id,customer_code_snapshot,customer_name_snapshot,service_codes_snapshot,scheduled_days_snapshot,batch_reference,quantity_kg
  ) select
    v_saved.finish_rewash_entry_id,(item->>'line_no')::integer,(item->>'customer_id')::uuid,item->>'customer_code',item->>'customer_name',
    array(select jsonb_array_elements_text(item->'service_codes')),array(select jsonb_array_elements_text(item->'scheduled_days')),
    nullif(item->>'batch_reference',''),(item->>'quantity_kg')::numeric
  from jsonb_array_elements(v_clean) item;

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,case when v_existing.finish_rewash_entry_id is null then 'RECORD_FINISH_REWASH' else 'CORRECT_FINISH_REWASH' end,
    'finish_rewash_entries',v_saved.finish_rewash_entry_id::text,v_before,jsonb_build_object('entry',to_jsonb(v_saved),'lines',v_clean),nullif(trim(p_notes),''),'FINISH_REWASH');

  return jsonb_build_object('status',case when v_existing.finish_rewash_entry_id is null then 'saved' else 'corrected' end,
    'finish_rewash_entry_id',v_saved.finish_rewash_entry_id,'entry_group_id',v_group_id,'revision_no',v_saved.revision_no,'processed_kg',v_total_kg);
end;
$$;

create or replace function public.terminal_record_finish_rewash_v1(
  p_shift_code text,p_table_code text,p_processed_by_staff_id uuid,p_lines jsonb,p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
begin
  perform public.require_production_terminal('FINISH',p_table_code);
  return public.record_finish_rewash_v1(p_shift_code,p_table_code,p_processed_by_staff_id,p_lines,p_notes);
end;
$$;

create or replace function public.get_finish_production_context_v4(
  p_shift_code text default 'MORNING',p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb;
  v_business_date date;
  v_rewash_entries jsonb;
  v_options jsonb;
  v_tables jsonb;
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_production_context_v3(p_shift_code,p_at);
  v_business_date:=nullif(v_base->>'business_date','')::date;
  v_options:=public.finish_rewash_customer_options_v1(v_business_date);

  with active_entries as (
    select e.* from public.finish_rewash_entries e where e.status='ACTIVE' and e.production_business_date=v_business_date
  ), detailed as (
    select e.*,coalesce((select sum(l.quantity_kg) from public.finish_rewash_lines l where l.finish_rewash_entry_id=e.finish_rewash_entry_id),0) as processed_kg,
      coalesce((select jsonb_agg(jsonb_build_object('line_no',l.line_no,'customer_id',l.customer_id,'customer_code',l.customer_code_snapshot,'customer_name',l.customer_name_snapshot,'service_codes',to_jsonb(l.service_codes_snapshot),'scheduled_days',to_jsonb(l.scheduled_days_snapshot),'batch_reference',l.batch_reference,'quantity_kg',l.quantity_kg) order by l.line_no) from public.finish_rewash_lines l where l.finish_rewash_entry_id=e.finish_rewash_entry_id),'[]'::jsonb) as lines
    from active_entries e
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'finish_rewash_entry_id',finish_rewash_entry_id,'entry_group_id',entry_group_id,'revision_no',revision_no,'business_date',production_business_date,
    'shift_code',shift_code_snapshot,'table_code',table_code_snapshot,'table_name',table_name_snapshot,'processed_by_staff_id',processed_by_staff_id,
    'processed_by',processed_by_name_snapshot,'recorded_by_staff_id',recorded_by_staff_id,'recorded_at',recorded_at,'notes',notes,'processed_kg',processed_kg,'lines',lines
  ) order by shift_code_snapshot,table_code_snapshot,recorded_at),'[]'::jsonb) into v_rewash_entries from detailed;

  with rw as (
    select e.table_code_snapshot,sum(l.quantity_kg) rewash_kg
    from public.finish_rewash_entries e join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
    where e.status='ACTIVE' and e.production_business_date=v_business_date and e.shift_code_snapshot=upper(trim(p_shift_code))
    group by e.table_code_snapshot
  ), base_tables as (select value item from jsonb_array_elements(coalesce(v_base->'tables','[]'::jsonb)))
  select coalesce(jsonb_agg(item||jsonb_build_object(
    'normal_produced_kg',coalesce((item->>'produced_kg')::numeric,0),
    'rewash_kg',coalesce(rw.rewash_kg,0),
    'produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce(rw.rewash_kg,0),
    'difference_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce(rw.rewash_kg,0)-coalesce((item->>'target_now_kg')::numeric,0),
    'kg_per_staff_hour',case when coalesce((item->>'staff_hours')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce(rw.rewash_kg,0))/((item->>'staff_hours')::numeric),2) else null end,
    'efficiency_percent',case when coalesce((item->>'staff_hours')::numeric,0)>0 and coalesce((item->>'target_kg_per_staff_hour')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce(rw.rewash_kg,0))/((item->>'staff_hours')::numeric*(item->>'target_kg_per_staff_hour')::numeric)*100,1) else null end
  ) order by item->>'table_code'),'[]'::jsonb) into v_tables
  from base_tables left join rw on rw.table_code_snapshot=item->>'table_code';

  return (v_base-'schema_version'-'source_contract'-'tables')||jsonb_build_object(
    'schema_version','FINISH_PRODUCTION_V4','source_contract','FINISH_V4_NORMAL_PLUS_REWASH_LEDGER',
    'tables',v_tables,'rewash_entries',v_rewash_entries,'rewash_customer_options',v_options,'rewash_supported',true
  );
end;
$$;

alter function public.get_finish_results_dashboard(date) rename to get_finish_results_dashboard_normal_v1;

create or replace function public.get_finish_results_dashboard(p_business_date date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb;
  v_date date;
  v_total jsonb;
  v_tables jsonb;
  v_shifts jsonb;
  v_entries jsonb;
  v_rewash_kg numeric:=0;
begin
  v_base:=public.get_finish_results_dashboard_normal_v1(p_business_date);
  v_date:=nullif(v_base->>'business_date','')::date;
  select coalesce(sum(l.quantity_kg),0) into v_rewash_kg
  from public.finish_rewash_entries e join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
  where e.status='ACTIVE' and e.production_business_date=v_date;

  with rw as (
    select e.table_code_snapshot,e.shift_code_snapshot,sum(l.quantity_kg) rewash_kg,count(distinct e.entry_group_id) contribution_count
    from public.finish_rewash_entries e join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
    where e.status='ACTIVE' and e.production_business_date=v_date group by e.table_code_snapshot,e.shift_code_snapshot
  ), base_rows as (select value item from jsonb_array_elements(coalesce(v_base->'tables','[]'::jsonb)))
  select coalesce(jsonb_agg(item||jsonb_build_object(
    'normal_produced_kg',coalesce((item->>'produced_kg')::numeric,0),'rewash_kg',coalesce(rw.rewash_kg,0),
    'produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce(rw.rewash_kg,0),
    'missing_kg',greatest(coalesce((item->>'planned_kg')::numeric,0)-coalesce((item->>'produced_kg')::numeric,0)-coalesce(rw.rewash_kg,0),0),
    'efficiency_percent',case when coalesce((item->>'planned_kg')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce(rw.rewash_kg,0))/(item->>'planned_kg')::numeric*100,2) else 0 end,
    'kg_per_staff_hour',case when coalesce((item->>'staff_hours')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce(rw.rewash_kg,0))/(item->>'staff_hours')::numeric,2) else 0 end,
    'contribution_count',coalesce((item->>'contribution_count')::integer,0)+coalesce(rw.contribution_count,0)
  ) order by item->>'shift_code',item->>'table_code'),'[]'::jsonb) into v_tables
  from base_rows left join rw on rw.table_code_snapshot=item->>'table_code' and rw.shift_code_snapshot=item->>'shift_code';

  with rw as (
    select e.shift_code_snapshot,sum(l.quantity_kg) rewash_kg,count(distinct e.entry_group_id) contribution_count
    from public.finish_rewash_entries e join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
    where e.status='ACTIVE' and e.production_business_date=v_date group by e.shift_code_snapshot
  ), base_rows as (select value item from jsonb_array_elements(coalesce(v_base->'shifts','[]'::jsonb)))
  select coalesce(jsonb_agg(item||jsonb_build_object(
    'normal_produced_kg',coalesce((item->>'produced_kg')::numeric,0),'rewash_kg',coalesce(rw.rewash_kg,0),
    'produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce(rw.rewash_kg,0),
    'missing_kg',greatest(coalesce((item->>'planned_kg')::numeric,0)-coalesce((item->>'produced_kg')::numeric,0)-coalesce(rw.rewash_kg,0),0),
    'efficiency_percent',case when coalesce((item->>'planned_kg')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce(rw.rewash_kg,0))/(item->>'planned_kg')::numeric*100,2) else 0 end,
    'contribution_count',coalesce((item->>'contribution_count')::integer,0)+coalesce(rw.contribution_count,0)
  ) order by item->>'shift_code'),'[]'::jsonb) into v_shifts
  from base_rows left join rw on rw.shift_code_snapshot=item->>'shift_code';

  v_total:=(v_base->'total')||jsonb_build_object(
    'normal_produced_kg',coalesce((v_base->'total'->>'produced_kg')::numeric,0),'rewash_kg',v_rewash_kg,
    'produced_kg',coalesce((v_base->'total'->>'produced_kg')::numeric,0)+v_rewash_kg,
    'missing_kg',greatest(coalesce((v_base->'total'->>'planned_kg')::numeric,0)-coalesce((v_base->'total'->>'produced_kg')::numeric,0)-v_rewash_kg,0),
    'efficiency_percent',case when coalesce((v_base->'total'->>'planned_kg')::numeric,0)>0 then round((coalesce((v_base->'total'->>'produced_kg')::numeric,0)+v_rewash_kg)/(v_base->'total'->>'planned_kg')::numeric*100,2) else 0 end
  );

  with rewash_entries as (
    select e.*,coalesce((select sum(l.quantity_kg) from public.finish_rewash_lines l where l.finish_rewash_entry_id=e.finish_rewash_entry_id),0) processed_kg,
      coalesce((select jsonb_agg(jsonb_build_object('customer_name',l.customer_name_snapshot,'customer_code',l.customer_code_snapshot,'batch_reference',coalesce(l.batch_reference,'ReWash'),'unit_code','KG','quantity',l.quantity_kg,'scheduled_days',to_jsonb(l.scheduled_days_snapshot)) order by l.line_no) from public.finish_rewash_lines l where l.finish_rewash_entry_id=e.finish_rewash_entry_id),'[]'::jsonb) lines
    from public.finish_rewash_entries e where e.status='ACTIVE' and e.production_business_date=v_date
  )
  select coalesce(v_base->'entries','[]'::jsonb)||coalesce(jsonb_agg(jsonb_build_object(
    'entry_type','REWASH','finish_rewash_entry_id',finish_rewash_entry_id,'entry_group_id',entry_group_id,'revision_no',revision_no,
    'customer_name','ReWash','customer_code',null,'route_code',null,'route_name',null,'route_color','#d97706','production_order',null,
    'business_date',production_business_date,'shift_code',shift_code_snapshot,'table_code',table_code_snapshot,'table_name',table_name_snapshot,
    'recorded_at',recorded_at,'processed_by_staff_id',processed_by_staff_id,'processed_by',processed_by_name_snapshot,'recorded_by_staff_id',recorded_by_staff_id,
    'recorded_by',coalesce((select display_name from public.staff_members sm where sm.staff_id=recorded_by_staff_id),'—'),
    'trolley_scan_status','NOT_REQUIRED','trolley_codes','[]'::jsonb,'lines',lines,'processed_kg',processed_kg,'processed_units',0
  ) order by recorded_at),'[]'::jsonb) into v_entries from rewash_entries;

  return (v_base-'total'-'tables'-'shifts'-'entries'-'rewash_separate_metric_supported')||jsonb_build_object(
    'schema_version','FINISH_RESULTS_V2','source_contract','FINISH_NORMAL_PLUS_REAL_REWASH_LEDGER',
    'total',v_total,'tables',v_tables,'shifts',v_shifts,'entries',v_entries,'rewash_separate_metric_supported',true
  );
end;
$$;

revoke all on function public.finish_rewash_customer_options_v1(date) from public,anon,authenticated;
revoke all on function public.record_finish_rewash_v1(text,text,uuid,jsonb,text) from public,anon,authenticated;
revoke all on function public.terminal_record_finish_rewash_v1(text,text,uuid,jsonb,text) from public,anon;
revoke all on function public.get_finish_production_context_v4(text,timestamptz) from public,anon;
revoke all on function public.get_finish_results_dashboard_normal_v1(date) from public,anon,authenticated;
revoke all on function public.get_finish_results_dashboard(date) from public,anon;
grant execute on function public.terminal_record_finish_rewash_v1(text,text,uuid,jsonb,text) to authenticated;
grant execute on function public.get_finish_production_context_v4(text,timestamptz) to authenticated;
grant execute on function public.get_finish_results_dashboard(date) to authenticated;
