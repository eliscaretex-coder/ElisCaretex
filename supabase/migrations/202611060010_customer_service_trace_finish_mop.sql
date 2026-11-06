-- Customer Service: the production trace starts from what was finished.
--
-- Owner request (2026-11-06): to find when a customer's goods were done, the useful
-- records are Finish (clothes) and, for customers that also have MOP, MOP Production.
-- The wash comes with them through the shared production flow, so the full cycle shows
-- on one row; other washes of the period stay available but are secondary.
--
-- * get_customer_service_production_trace_v1 (same signature) adds has_mop, a "mop" list
--   (recorded MOP batches, latest revision only, with products, operator and trolleys)
--   and, on every Finish and MOP row, the wash(es) of the same production flow.
-- * Complaints can be linked to a MOP batch: new columns linked_mop_batch_id,
--   mop_business_date, mop_shift_code, mop_operator_name.
-- * link_customer_service_complaint_production_v2(complaint, finish, mop, wash): when no
--   wash is chosen, the wash of the chosen record's production flow is linked with it.
-- * Moving a complaint to another customer also removes its MOP link (trigger).
-- * The complaint JSON shows the MOP link; Results count MOP links and add by_mop_shift.

alter table public.customer_service_complaints
  add column if not exists linked_mop_batch_id uuid references public.sorting_mop_production_batches(mop_production_batch_id) on delete set null,
  add column if not exists mop_business_date date,
  add column if not exists mop_shift_code text,
  add column if not exists mop_operator_name text;

-- A complaint moved to another customer cannot keep the old customer's MOP batch.
create or replace function public.customer_service_complaints_clear_mop_link()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.customer_id is distinct from old.customer_id then
    new.linked_mop_batch_id:=null; new.mop_business_date:=null; new.mop_shift_code:=null; new.mop_operator_name:=null;
  end if;
  return new;
end;$$;
revoke all on function public.customer_service_complaints_clear_mop_link() from public,anon,authenticated;
drop trigger if exists customer_service_complaints_clear_mop_link on public.customer_service_complaints;
create trigger customer_service_complaints_clear_mop_link before update of customer_id on public.customer_service_complaints
  for each row execute function public.customer_service_complaints_clear_mop_link();

-- Washes of one production flow (the same goods), newest first, cancelled or replaced ones left out.
create or replace function public.customer_service_flow_washes(p_flow uuid,p_customer_id uuid)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('wash_run_id',r.wash_run_id,'wash_code',r.wash_code,'business_date',r.business_date,
      'shift_code',r.shift_code_snapshot,'washer_name',r.washer_name_snapshot,'operator_name',r.operator_name_snapshot,'wash_type',r.wash_type,
      'registered_at',r.registered_at,'customer_kg',wc.allocated_weight_kg) order by r.registered_at desc),'[]'::jsonb)
  from public.sorting_wash_run_customers wc join public.sorting_wash_runs r on r.wash_run_id=wc.wash_run_id
  where p_flow is not null and wc.production_flow_item_id=p_flow and wc.customer_id=p_customer_id
    and r.cancelled_at is null and coalesce(r.status,'')<>'CANCELLED'
    and not exists(select 1 from public.sorting_wash_runs r2 where r2.replaces_wash_run_id=r.wash_run_id and r2.cancelled_at is null);
$$;
revoke all on function public.customer_service_flow_washes(uuid,uuid) from public,anon,authenticated;

-- A customer "has MOP" when the current MOP schedule plans it or MOP was produced for it lately.
create or replace function public.customer_service_customer_has_mop(p_customer_id uuid)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select exists(select 1 from public.v_mop_current_schedule s where s.customer_id=p_customer_id)
    or exists(select 1 from public.sorting_mop_production_batches b where b.customer_id=p_customer_id and b.status='RECORDED'
      and b.business_date>=public.customer_service_today()-120);
$$;
revoke all on function public.customer_service_customer_has_mop(uuid) from public,anon,authenticated;

-- JSON shape: the link shows MOP too ------------------------------------------------

create or replace function public.customer_service_complaint_json(p_complaint_id uuid)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  with x as (
    select c.*,cu.customer_code,cu.customer_name,t.type_name,public.customer_service_today() as today,
      coalesce((select max(e.created_at) from public.customer_service_events e where e.complaint_id=c.complaint_id),c.updated_at) as last_activity_at
    from public.customer_service_complaints c
    join public.customers cu on cu.customer_id=c.customer_id
    join public.customer_service_complaint_types t on t.type_code=c.type_code
    where c.complaint_id=p_complaint_id
  )
  select jsonb_build_object(
    'complaint_id',x.complaint_id,'complaint_code',x.complaint_code,
    'customer_id',x.customer_id,'customer_code',x.customer_code,'customer_name',x.customer_name,
    'received_on',x.received_on,'delivery_date',x.delivery_date,'channel',x.channel,
    'type_code',x.type_code,'type_name',x.type_name,'severity',x.severity,
    'description',x.description,'customer_reference',x.customer_reference,
    'status',x.status,'outcome',x.outcome,'resolution_notes',x.resolution_notes,'resolved_at',x.resolved_at,
    'resolved_by_name',public.customer_service_user_name(x.resolved_by_auth_user_id),
    'owner_auth_user_id',x.owner_auth_user_id,'owner_name',public.customer_service_user_name(x.owner_auth_user_id),
    'created_at',x.created_at,'created_by_name',public.customer_service_user_name(x.created_by_auth_user_id),
    'days_open',case when x.status in ('OPEN','INVESTIGATING') then x.today-x.received_on else coalesce(x.resolved_at::date,x.updated_at::date)-x.received_on end,
    'resolve_by',x.resolve_by,
    'due_state',case when x.status not in ('OPEN','INVESTIGATING') or x.resolve_by is null then null
      when x.resolve_by<x.today then 'OVERDUE' when x.resolve_by=x.today then 'DUE_TODAY' else 'ON_TRACK' end,
    'overdue_days',case when x.status in ('OPEN','INVESTIGATING') and x.resolve_by<x.today then x.today-x.resolve_by else 0 end,
    'resolved_on_time',case when x.status='RESOLVED' and x.resolve_by is not null and x.resolved_at is not null
      then (x.resolved_at at time zone 'Europe/Dublin')::date<=x.resolve_by end,
    'last_activity_at',x.last_activity_at,
    'idle_days',x.today-(x.last_activity_at at time zone 'Europe/Dublin')::date,
    'link',case when x.linked_finish_entry_id is null and x.linked_wash_run_id is null and x.linked_mop_batch_id is null then null else jsonb_build_object(
      'finish_entry_id',x.linked_finish_entry_id,'wash_run_id',x.linked_wash_run_id,'production_flow_item_id',x.linked_production_flow_item_id,
      'finish_business_date',x.finish_business_date,'finish_shift_code',x.finish_shift_code,'finish_table_code',x.finish_table_code,'finish_processed_by',x.finish_processed_by,
      'sorting_business_date',x.sorting_business_date,'sorting_shift_code',x.sorting_shift_code,'sorting_washer_name',x.sorting_washer_name,'sorting_operator_name',x.sorting_operator_name,
      'mop_batch_id',x.linked_mop_batch_id,'mop_business_date',x.mop_business_date,'mop_shift_code',x.mop_shift_code,'mop_operator_name',x.mop_operator_name,
      'linked_at',x.linked_at,'linked_by_name',public.customer_service_user_name(x.linked_by_auth_user_id)) end,
    'open_task_count',(select count(*) from public.customer_service_tasks k where k.complaint_id=x.complaint_id and k.status in ('OPEN','IN_PROGRESS')),
    'task_count',(select count(*) from public.customer_service_tasks k where k.complaint_id=x.complaint_id and k.status<>'CANCELLED'),
    'active_alert',exists(select 1 from public.customer_service_alerts a where a.customer_id=x.customer_id and a.ended_at is null
      and a.starts_on<=x.today and (a.ends_on is null or a.ends_on>=x.today)),
    'own_active_alerts',(select count(*) from public.customer_service_alerts a where a.complaint_id=x.complaint_id and a.ended_at is null
      and (a.ends_on is null or a.ends_on>=x.today))
  )
  from x;
$$;
create or replace function public.get_customer_service_production_trace_v1(p_customer_id uuid,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_has_mop boolean;
begin
  perform public.require_customer_service_access('VIEW');
  if p_customer_id is null or p_from is null or p_to is null then raise exception using errcode='22023',message='Choose a customer and a period.'; end if;
  if p_from>p_to then raise exception using errcode='22023',message='The start date must be on or before the end date.'; end if;
  if p_to-p_from>62 then raise exception using errcode='22023',message='Choose a period of 62 days or less.'; end if;
  v_has_mop:=public.customer_service_customer_has_mop(p_customer_id);

  return jsonb_build_object('customer_id',p_customer_id,'from',p_from,'to',p_to,'has_mop',v_has_mop,
    -- Finish: every active record whose production or delivery date is in the period, with the
    -- staff on that table in that shift and the wash of the same production flow.
    'finish',coalesce((select jsonb_agg(jsonb_build_object(
        'finish_production_entry_id',f.finish_production_entry_id,'production_flow_item_id',f.production_flow_item_id,
        'business_date',f.production_business_date,'delivery_date',f.delivery_date,
        'shift_code',f.shift_code_snapshot,'table_code',f.table_code_snapshot,'table_name',coalesce(f.table_name_snapshot,f.table_code_snapshot),
        'processed_by',coalesce(f.processed_by_name_snapshot,(select sm.display_name from public.staff_members sm where sm.staff_id=f.processed_by_staff_id)),
        'recorded_at',f.recorded_at,'notes',f.notes,
        'kg',(select coalesce(sum(l.quantity) filter (where l.unit_code='KG'),0) from public.finish_production_lines l where l.finish_production_entry_id=f.finish_production_entry_id),
        'units',(select coalesce(sum(l.quantity) filter (where l.unit_code='UNIT'),0) from public.finish_production_lines l where l.finish_production_entry_id=f.finish_production_entry_id),
        'batches',(select coalesce(jsonb_agg(distinct l.batch_reference) filter (where l.batch_reference is not null),'[]'::jsonb) from public.finish_production_lines l where l.finish_production_entry_id=f.finish_production_entry_id),
        'table_staff',(select coalesce(jsonb_agg(distinct sm.display_name),'[]'::jsonb)
          from public.work_sessions ws join public.staff_members sm on sm.staff_id=ws.staff_id
          where ws.work_date=f.production_business_date and ws.shift_id=f.shift_id and coalesce(ws.status,'')<>'CANCELLED'
            and (ws.station_id=f.table_station_id or exists(select 1 from public.finish_staff_table_segments s where s.work_session_id=ws.work_session_id and s.station_id=f.table_station_id))),
        'washes',public.customer_service_flow_washes(f.production_flow_item_id,p_customer_id)
      ) order by f.production_business_date desc,f.recorded_at desc)
      from (select e.*,coalesce(e.station_id,st.station_id) as table_station_id
        from public.finish_production_entries e
        left join public.stations st on st.station_code=e.table_code_snapshot and st.deleted_at is null
        where e.customer_id=p_customer_id and e.status='ACTIVE'
          and (e.delivery_date between p_from and p_to or e.production_business_date between p_from and p_to)) f),'[]'::jsonb),
    -- MOP Production: recorded batches (latest revision) delivered or produced in the period.
    'mop',case when not v_has_mop then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object(
        'mop_production_batch_id',b.mop_production_batch_id,'production_flow_item_id',b.production_flow_item_id,
        'business_date',b.business_date,'delivery_date',coalesce(b.delivery_due_date,b.scheduled_for_date),'shift_code',b.shift_code_snapshot,
        'operator_name',(select sm.display_name from public.staff_members sm where sm.staff_id=b.operator_staff_id),
        'recorded_at',b.recorded_at,'entry_mode',b.entry_mode,'notes',b.notes,
        'kg',b.total_weight_kg,'units',b.total_units,
        'products',(select coalesce(jsonb_agg(jsonb_build_object('name',coalesce(l.variant_name_snapshot,l.variant_code_snapshot),'units',l.units,'kg',l.weight_kg) order by l.variant_name_snapshot),'[]'::jsonb)
          from public.sorting_mop_production_lines l where l.mop_production_batch_id=b.mop_production_batch_id),
        'trolleys',(select coalesce(jsonb_agg(distinct t.trolley_code_snapshot) filter (where t.trolley_code_snapshot is not null),'[]'::jsonb)
          from public.sorting_mop_production_trolleys t where t.mop_production_batch_id=b.mop_production_batch_id),
        'washes',public.customer_service_flow_washes(b.production_flow_item_id,p_customer_id)
      ) order by b.business_date desc,b.recorded_at desc)
      from public.sorting_mop_production_batches b
      where b.customer_id=p_customer_id and b.status='RECORDED'
        and not exists(select 1 from public.sorting_mop_production_batches b2 where b2.supersedes_mop_production_batch_id=b.mop_production_batch_id and b2.status='RECORDED')
        and (coalesce(b.delivery_due_date,b.scheduled_for_date) between p_from and p_to or b.business_date between p_from and p_to)),'[]'::jsonb) end,
    -- Every wash of the customer in the period (three days earlier included), for records
    -- without a production flow, such as legacy imports.
    'washes',coalesce((select jsonb_agg(jsonb_build_object(
        'wash_run_id',w.wash_run_id,'production_flow_item_id',w.flow_id,'wash_code',w.wash_code,'business_date',w.business_date,
        'scheduled_for_date',w.scheduled_for_date,'shift_code',w.shift_code_snapshot,
        'washer_name',w.washer_name_snapshot,'operator_name',w.operator_name_snapshot,'wash_type',w.wash_type,
        'registered_at',w.registered_at,'customer_kg',w.allocated_weight_kg,'total_kg',w.total_weight_kg,
        'sorting_staff',(select coalesce(jsonb_agg(distinct sm.display_name),'[]'::jsonb)
          from public.work_sessions ws join public.staff_members sm on sm.staff_id=ws.staff_id join public.areas a on a.area_id=ws.area_id
          where a.area_code='SORTING' and ws.work_date=w.business_date and ws.shift_id=w.shift_id and coalesce(ws.status,'')<>'CANCELLED')
      ) order by w.business_date desc,w.registered_at desc)
      from (select r.*,wc.production_flow_item_id as flow_id,wc.allocated_weight_kg,wc.scheduled_for_date
        from public.sorting_wash_run_customers wc
        join public.sorting_wash_runs r on r.wash_run_id=wc.wash_run_id
        where wc.customer_id=p_customer_id and r.cancelled_at is null and coalesce(r.status,'')<>'CANCELLED'
          and not exists(select 1 from public.sorting_wash_runs r2 where r2.replaces_wash_run_id=r.wash_run_id and r2.cancelled_at is null)
          and r.business_date between p_from-3 and p_to) w),'[]'::jsonb));
end;$$;

-- Link (v2): Finish, MOP and/or wash. Without a chosen wash, the wash of the chosen record's flow is used.
create or replace function public.link_customer_service_complaint_production_v2(p_complaint_id uuid,p_finish_entry_id uuid default null,p_mop_batch_id uuid default null,p_wash_run_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints; v_fin public.finish_production_entries; v_mop public.sorting_mop_production_batches;
  v_wash public.sorting_wash_runs; v_flow uuid; v_wash_id uuid:=p_wash_run_id; v_any boolean;
begin
  perform public.require_customer_service_access('EDIT');
  select * into v_row from public.customer_service_complaints where complaint_id=p_complaint_id for update;
  if v_row.complaint_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Complaint not found.';
  end if;
  if p_finish_entry_id is not null then
    select * into v_fin from public.finish_production_entries where finish_production_entry_id=p_finish_entry_id and customer_id=v_row.customer_id;
    if v_fin.finish_production_entry_id is null then raise exception using errcode='22023',message='That Finish record is not for this customer.'; end if;
    v_flow:=v_fin.production_flow_item_id;
  end if;
  if p_mop_batch_id is not null then
    select * into v_mop from public.sorting_mop_production_batches where mop_production_batch_id=p_mop_batch_id and customer_id=v_row.customer_id;
    if v_mop.mop_production_batch_id is null then raise exception using errcode='22023',message='That MOP batch is not for this customer.'; end if;
    v_flow:=coalesce(v_flow,v_mop.production_flow_item_id);
  end if;
  if v_wash_id is null and v_flow is not null then
    v_wash_id:=nullif(public.customer_service_flow_washes(v_flow,v_row.customer_id)->0->>'wash_run_id','')::uuid;
  end if;
  if v_wash_id is not null then
    select r.* into v_wash from public.sorting_wash_runs r
    where r.wash_run_id=v_wash_id and exists(select 1 from public.sorting_wash_run_customers wc where wc.wash_run_id=r.wash_run_id and wc.customer_id=v_row.customer_id);
    if v_wash.wash_run_id is null then raise exception using errcode='22023',message='That wash is not for this customer.'; end if;
    if v_flow is null then
      select wc.production_flow_item_id into v_flow from public.sorting_wash_run_customers wc where wc.wash_run_id=v_wash_id and wc.customer_id=v_row.customer_id limit 1;
    end if;
  end if;
  v_any:=p_finish_entry_id is not null or p_mop_batch_id is not null or v_wash_id is not null;
  update public.customer_service_complaints set
    linked_finish_entry_id=v_fin.finish_production_entry_id,linked_wash_run_id=v_wash.wash_run_id,linked_production_flow_item_id=v_flow,
    finish_business_date=v_fin.production_business_date,finish_shift_code=v_fin.shift_code_snapshot,finish_table_code=v_fin.table_code_snapshot,
    finish_processed_by=coalesce(v_fin.processed_by_name_snapshot,(select sm.display_name from public.staff_members sm where sm.staff_id=v_fin.processed_by_staff_id)),
    linked_mop_batch_id=v_mop.mop_production_batch_id,mop_business_date=v_mop.business_date,mop_shift_code=v_mop.shift_code_snapshot,
    mop_operator_name=(select sm.display_name from public.staff_members sm where sm.staff_id=v_mop.operator_staff_id),
    sorting_business_date=v_wash.business_date,sorting_shift_code=v_wash.shift_code_snapshot,sorting_washer_name=v_wash.washer_name_snapshot,sorting_operator_name=v_wash.operator_name_snapshot,
    linked_at=case when v_any then now() end,
    linked_by_auth_user_id=case when v_any then auth.uid() end,
    status=case when status='OPEN' and v_any then 'INVESTIGATING' else status end,
    updated_at=now()
  where complaint_id=p_complaint_id;
  perform public.customer_service_log(p_complaint_id,case when v_any then 'LINKED' else 'UNLINKED' end,null,
    jsonb_strip_nulls(jsonb_build_object('finish_date',v_fin.production_business_date,'finish_shift',v_fin.shift_code_snapshot,'finish_table',v_fin.table_code_snapshot,
      'mop_date',v_mop.business_date,'mop_shift',v_mop.shift_code_snapshot,
      'sorting_date',v_wash.business_date,'sorting_shift',v_wash.shift_code_snapshot,'washer',v_wash.washer_name_snapshot)));
  return public.customer_service_complaint_json(p_complaint_id);
end;$$;

-- Results: MOP links count as linked; complaints per MOP shift ---------------------

create or replace function public.get_customer_service_results_v1(p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_from date:=p_from; v_to date:=p_to; v_period text; v_result jsonb; v_today date:=public.customer_service_today();
begin
  perform public.require_customer_service_access('VIEW');
  if v_from is null or v_to is null or v_from>v_to then raise exception using errcode='22023',message='Choose a valid period.'; end if;
  if v_to-v_from>731 then raise exception using errcode='22023',message='Choose a period of two years or less.'; end if;
  v_period:=case when v_to-v_from<=45 then 'day' when v_to-v_from<=190 then 'week' else 'month' end;

  with c as (
    select c.*,t.type_name,
      c.status in ('OPEN','INVESTIGATING') and c.resolve_by<v_today as is_overdue,
      case when c.status='RESOLVED' and c.resolve_by is not null and c.resolved_at is not null
        then (c.resolved_at at time zone 'Europe/Dublin')::date<=c.resolve_by end as on_time
    from public.customer_service_complaints c join public.customer_service_complaint_types t on t.type_code=c.type_code
    where c.status<>'CANCELLED' and c.received_on between v_from and v_to
      and public.customer_service_customer_visible(c.customer_id,c.created_by_auth_user_id)
  ), k as (
    select k.* from public.customer_service_tasks k
    join c on c.complaint_id=k.complaint_id where k.status<>'CANCELLED'
  )
  select jsonb_build_object(
    'from',v_from,'to',v_to,'period',v_period,
    'totals',jsonb_build_object(
      'complaints',(select count(*) from c),
      'open',(select count(*) from c where status in ('OPEN','INVESTIGATING')),
      'overdue',(select count(*) from c where is_overdue),
      'resolved',(select count(*) from c where status='RESOLVED'),
      'resolved_on_time',(select count(*) from c where on_time),
      'resolved_with_date',(select count(*) from c where on_time is not null),
      'justified',(select count(*) from c where outcome='JUSTIFIED'),
      'not_justified',(select count(*) from c where outcome='NOT_JUSTIFIED'),
      'high',(select count(*) from c where severity='HIGH'),
      'customers',(select count(distinct customer_id) from c),
      'linked',(select count(*) from c where linked_finish_entry_id is not null or linked_wash_run_id is not null or linked_mop_batch_id is not null),
      'avg_days_to_resolve',(select round(avg(extract(epoch from (resolved_at-received_on::timestamptz))/86400.0)::numeric,1) from c where status='RESOLVED' and resolved_at is not null),
      'tasks',(select count(*) from k),'tasks_open',(select count(*) from k where status in ('OPEN','IN_PROGRESS')),
      'tasks_overdue',(select count(*) from k where status in ('OPEN','IN_PROGRESS') and due_on<v_today)),
    'by_period',coalesce((select jsonb_agg(jsonb_build_object('period_start',p,'complaints',n,'justified',j) order by p) from (
      select date_trunc(v_period,received_on)::date p,count(*) n,count(*) filter (where outcome='JUSTIFIED') j from c group by 1) x),'[]'::jsonb),
    'by_type',coalesce((select jsonb_agg(jsonb_build_object('type_code',type_code,'type_name',type_name,'complaints',n,'justified',j) order by n desc,type_name) from (
      select type_code,type_name,count(*) n,count(*) filter (where outcome='JUSTIFIED') j from c group by 1,2) x),'[]'::jsonb),
    'by_customer',coalesce((select jsonb_agg(jsonb_build_object('customer_id',customer_id,'customer_name',customer_name,'complaints',n,'open',o,'last_received_on',l) order by n desc,customer_name) from (
      select c.customer_id,cu.customer_name,count(*) n,count(*) filter (where c.status in ('OPEN','INVESTIGATING')) o,max(c.received_on) l
      from c join public.customers cu on cu.customer_id=c.customer_id group by 1,2 order by 3 desc,2 limit 20) x),'[]'::jsonb),
    'by_finish_shift',coalesce((select jsonb_agg(jsonb_build_object('shift_code',finish_shift_code,'complaints',n) order by finish_shift_code) from (
      select finish_shift_code,count(*) n from c where finish_shift_code is not null group by 1) x),'[]'::jsonb),
    'by_finish_table',coalesce((select jsonb_agg(jsonb_build_object('table_code',finish_table_code,'shift_code',finish_shift_code,'complaints',n) order by finish_table_code,finish_shift_code) from (
      select finish_table_code,finish_shift_code,count(*) n from c where finish_table_code is not null group by 1,2) x),'[]'::jsonb),
    'by_mop_shift',coalesce((select jsonb_agg(jsonb_build_object('shift_code',mop_shift_code,'complaints',n) order by mop_shift_code) from (
      select mop_shift_code,count(*) n from c where mop_shift_code is not null group by 1) x),'[]'::jsonb),
    'by_sorting_shift',coalesce((select jsonb_agg(jsonb_build_object('shift_code',sorting_shift_code,'complaints',n) order by sorting_shift_code) from (
      select sorting_shift_code,count(*) n from c where sorting_shift_code is not null group by 1) x),'[]'::jsonb),
    'by_owner',coalesce((select jsonb_agg(jsonb_build_object('owner_name',coalesce(public.customer_service_user_name(owner_auth_user_id),'Not assigned'),'complaints',n,'open',o,'overdue',d,'resolved',r,'on_time',ot) order by n desc) from (
      select owner_auth_user_id,count(*) n,count(*) filter (where status in ('OPEN','INVESTIGATING')) o,count(*) filter (where is_overdue) d,
        count(*) filter (where status='RESOLVED') r,count(*) filter (where on_time) ot from c group by 1) x),'[]'::jsonb),
    'by_department',coalesce((select jsonb_agg(jsonb_build_object('department_code',department_code,'tasks',n,'open',o,'overdue',d) order by n desc) from (
      select department_code,count(*) n,count(*) filter (where status in ('OPEN','IN_PROGRESS')) o,
        count(*) filter (where status in ('OPEN','IN_PROGRESS') and due_on<v_today) d from k group by 1) x),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;$$;

-- Grants ----------------------------------------------------------------------------

revoke all on function public.customer_service_complaint_json(uuid) from public,anon,authenticated;
revoke all on function public.get_customer_service_production_trace_v1(uuid,date,date),
  public.link_customer_service_complaint_production_v2(uuid,uuid,uuid,uuid),
  public.get_customer_service_results_v1(date,date)
from public,anon;
grant execute on function public.get_customer_service_production_trace_v1(uuid,date,date),
  public.link_customer_service_complaint_production_v2(uuid,uuid,uuid,uuid),
  public.get_customer_service_results_v1(date,date)
to authenticated;
