-- Customer Service Results closer to the Elis group complaint dashboards.
--
-- Owner request (2026-11-06): compare the charts with the Elis eForce / Power BI complaint
-- dashboards (all plants). Those show complaints per 100 accounts, % of accounts that
-- complained, complaints by service line, by type, by responsible department and by status.
-- get_customer_service_results_v1 (same signature) now also returns:
--   totals.active_customers  active customers this account can see (per 100 / % of customers)
--   totals.investigating     complaints being investigated (status split with open/resolved)
--   by_product               CLOTHES / MOP / NOT_KNOWN, our equivalent of the service line:
--                            the linked production record decides; a customer without MOP is
--                            clothes; a clothes+MOP customer not linked yet is NOT_KNOWN
--   by_responsible           the complaint type's responsible department (NOT_SET if none)

create or replace function public.get_customer_service_results_v1(p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_from date:=p_from; v_to date:=p_to; v_period text; v_result jsonb; v_today date:=public.customer_service_today();
begin
  perform public.require_customer_service_access('VIEW');
  if v_from is null or v_to is null or v_from>v_to then raise exception using errcode='22023',message='Choose a valid period.'; end if;
  if v_to-v_from>731 then raise exception using errcode='22023',message='Choose a period of two years or less.'; end if;
  v_period:=case when v_to-v_from<=45 then 'day' when v_to-v_from<=190 then 'week' else 'month' end;

  with c as (
    select c.*,t.type_name,coalesce(t.default_department_code,'NOT_SET') as responsible_code,
      case when c.linked_mop_batch_id is not null then 'MOP'
        when c.linked_finish_entry_id is not null then 'CLOTHES'
        when not public.customer_service_customer_has_mop(c.customer_id) then 'CLOTHES'
        else 'NOT_KNOWN' end as product_code,
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
      'active_customers',(select count(*) from public.customers cu where cu.active and cu.deleted_at is null
        and public.customer_service_customer_visible(cu.customer_id,null)),
      'investigating',(select count(*) from c where status='INVESTIGATING'),
      'linked',(select count(*) from c where linked_finish_entry_id is not null or linked_wash_run_id is not null or linked_mop_batch_id is not null),
      'avg_days_to_resolve',(select round(avg(extract(epoch from (resolved_at-received_on::timestamptz))/86400.0)::numeric,1) from c where status='RESOLVED' and resolved_at is not null),
      'tasks',(select count(*) from k),'tasks_open',(select count(*) from k where status in ('OPEN','IN_PROGRESS')),
      'tasks_overdue',(select count(*) from k where status in ('OPEN','IN_PROGRESS') and due_on<v_today)),
    'by_period',coalesce((select jsonb_agg(jsonb_build_object('period_start',p,'complaints',n,'justified',j) order by p) from (
      select date_trunc(v_period,received_on)::date p,count(*) n,count(*) filter (where outcome='JUSTIFIED') j from c group by 1) x),'[]'::jsonb),
    'by_type',coalesce((select jsonb_agg(jsonb_build_object('type_code',type_code,'type_name',type_name,'complaints',n,'justified',j) order by n desc,type_name) from (
      select type_code,type_name,count(*) n,count(*) filter (where outcome='JUSTIFIED') j from c group by 1,2) x),'[]'::jsonb),
    'by_product',coalesce((select jsonb_agg(jsonb_build_object('product_code',product_code,'complaints',n,'open',o) order by n desc) from (
      select product_code,count(*) n,count(*) filter (where status in ('OPEN','INVESTIGATING')) o from c group by 1) x),'[]'::jsonb),
    'by_responsible',coalesce((select jsonb_agg(jsonb_build_object('department_code',responsible_code,'complaints',n,'justified',j) order by n desc) from (
      select responsible_code,count(*) n,count(*) filter (where outcome='JUSTIFIED') j from c group by 1) x),'[]'::jsonb),
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

revoke all on function public.get_customer_service_results_v1(date,date) from public,anon;
grant execute on function public.get_customer_service_results_v1(date,date) to authenticated;
