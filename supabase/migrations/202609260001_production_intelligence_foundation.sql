-- Production Intelligence foundation.
-- Official actual weight comes only from Finish Production and MOP Production.
-- Sorting/Washing estimates are deliberately excluded.

insert into public.application_modules(module_code,module_name,module_group,display_order,active)
values ('PRODUCTION_INSIGHTS','Production Intelligence','PRODUCTION',170,true)
on conflict(module_code) do update
set module_name=excluded.module_name,module_group=excluded.module_group,display_order=excluded.display_order,active=true;

insert into public.job_title_permission_templates
  (job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage)
values
  ('ADMINISTRATOR','PRODUCTION_INSIGHTS','ALL',true,true,true,true,true),
  ('GENERAL_MANAGER','PRODUCTION_INSIGHTS','ALL',true,false,false,false,false),
  ('PRODUCTION_MANAGER','PRODUCTION_INSIGHTS','PRODUCTION',true,false,false,false,false),
  ('LOGISTICS_MANAGER','PRODUCTION_INSIGHTS','DISTRIBUTION',true,false,false,false,false)
on conflict(job_title_code,module_code) do update
set access_scope=excluded.access_scope,can_view=excluded.can_view,can_create=excluded.can_create,
    can_edit=excluded.can_edit,can_approve=excluded.can_approve,can_manage=excluded.can_manage;

insert into public.account_permission_grants
  (auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage,granted_by_auth_user_id)
select ap.auth_user_id,t.module_code,t.access_scope,t.can_view,t.can_create,t.can_edit,t.can_approve,t.can_manage,null
from public.account_access_profiles ap
join public.job_title_permission_templates t on t.job_title_code=ap.job_title_code
where t.module_code='PRODUCTION_INSIGHTS'
on conflict(auth_user_id,module_code) do update
set access_scope=excluded.access_scope,can_view=excluded.can_view,can_create=excluded.can_create,
    can_edit=excluded.can_edit,can_approve=excluded.can_approve,can_manage=excluded.can_manage,
    active=true,effective_from=current_date,effective_until=null,updated_at=now();

create or replace view public.production_official_actuals
with (security_invoker=false)
as
select
  e.finish_production_entry_id as source_record_id,
  'FINISH'::text as production_source,
  e.production_business_date as actual_date,
  e.customer_id,
  coalesce(c.customer_code,'') as customer_code,
  coalesce(c.customer_name,'Unknown customer') as customer_name,
  'CLOTHES'::text as product_code,
  e.shift_code_snapshot as shift_code,
  e.table_code_snapshot as workstation_code,
  sum(l.quantity)::numeric as actual_kg
from public.finish_production_entries e
join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id and l.unit_code='KG'
left join public.customers c on c.customer_id=e.customer_id
where e.status='ACTIVE'
group by e.finish_production_entry_id,e.production_business_date,e.customer_id,c.customer_code,c.customer_name,
         e.shift_code_snapshot,e.table_code_snapshot
having sum(l.quantity)>0
union all
select
  b.mop_production_batch_id,
  'MOP'::text,
  coalesce(b.physical_processed_on,b.business_date),
  b.customer_id,
  coalesce(c.customer_code,b.customer_code_snapshot,''),
  coalesce(c.customer_name,b.customer_name_snapshot,'Unknown customer'),
  'MOP'::text,
  b.shift_code_snapshot,
  'MOP'::text,
  b.total_weight_kg
from public.sorting_mop_production_batches b
left join public.customers c on c.customer_id=b.customer_id
where b.status='RECORDED' and b.total_weight_kg>0;

revoke all on public.production_official_actuals from public,anon,authenticated;

create index if not exists finish_production_entries_intelligence_idx
  on public.finish_production_entries(production_business_date,status,customer_id);
create index if not exists sorting_mop_production_intelligence_idx
  on public.sorting_mop_production_batches(business_date,status,customer_id);

create or replace function public.get_production_intelligence_dashboard(
  p_from_date date default null,
  p_to_date date default null,
  p_customer_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_from date:=coalesce(p_from_date,date_trunc('year',current_date)::date);
  v_to date:=coalesce(p_to_date,current_date);
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null) then
    raise exception using errcode='42501',message='This account cannot view Production Intelligence.';
  end if;
  if v_from>v_to or v_to-v_from>1827 then
    raise exception using errcode='22023',message='Choose a valid date range of no more than five years.';
  end if;

  with range_actuals as (
    select * from public.production_official_actuals a
    where a.actual_date between v_from and v_to
      and (p_customer_id is null or a.customer_id=p_customer_id)
  ), daily as (
    select actual_date,customer_id,max(customer_code) customer_code,max(customer_name) customer_name,
           product_code,sum(actual_kg) actual_kg
    from public.production_official_actuals a
    where a.actual_date between (v_to-interval '84 days')::date and v_to
      and (p_customer_id is null or a.customer_id=p_customer_id)
    group by actual_date,customer_id,product_code
  ), ranked as (
    select d.*,row_number() over(partition by customer_id,product_code order by actual_date desc) recency_rank
    from daily d
  ), forecast as (
    select customer_id,max(customer_code) customer_code,max(customer_name) customer_name,product_code,
           count(*) filter(where recency_rank<=8) history_points,
           max(actual_date) last_actual_date,
           (array_agg(actual_kg order by actual_date desc))[1] last_actual_kg,
           round(avg(actual_kg) filter(where recency_rank<=4),2) four_week_average_kg,
           case when count(*) filter(where recency_rank<=8)>=3 then
             round(sum(actual_kg*(9-recency_rank)) filter(where recency_rank<=8)
               /nullif(sum(9-recency_rank) filter(where recency_rank<=8),0),2)
           end forecast_kg
    from ranked where recency_rank<=8
    group by customer_id,product_code
  )
  select jsonb_build_object(
    'period',jsonb_build_object('from',v_from,'to',v_to),
    'source_policy',jsonb_build_object(
      'official_sources',jsonb_build_array('FINISH','MOP'),
      'excluded_sources',jsonb_build_array('SORTING_ESTIMATE'),
      'message','Official KG uses Finish and MOP Production only. Sorting estimates are excluded.'
    ),
    'summary',jsonb_build_object(
      'total_kg',coalesce((select round(sum(actual_kg),2) from range_actuals),0),
      'finish_kg',coalesce((select round(sum(actual_kg),2) from range_actuals where production_source='FINISH'),0),
      'mop_kg',coalesce((select round(sum(actual_kg),2) from range_actuals where production_source='MOP'),0),
      'production_days',coalesce((select count(distinct actual_date) from range_actuals),0),
      'customers',coalesce((select count(distinct customer_id) from range_actuals),0)
    ),
    'weekly',coalesce((select jsonb_agg(to_jsonb(w) order by w.week_start) from (
      select date_trunc('week',actual_date)::date week_start,
             round(sum(actual_kg) filter(where production_source='FINISH'),2) finish_kg,
             round(sum(actual_kg) filter(where production_source='MOP'),2) mop_kg,
             round(sum(actual_kg),2) total_kg,
             count(distinct customer_id) customers
      from range_actuals group by date_trunc('week',actual_date)::date
    ) w),'[]'::jsonb),
    'forecasts',coalesce((select jsonb_agg(jsonb_build_object(
      'customer_id',f.customer_id,'customer_code',f.customer_code,'customer_name',f.customer_name,
      'product_code',f.product_code,'last_actual_date',f.last_actual_date,'last_actual_kg',f.last_actual_kg,
      'four_week_average_kg',f.four_week_average_kg,'forecast_kg',f.forecast_kg,
      'history_points',f.history_points,
      'status',case when f.history_points<3 then 'LEARNING' else 'READY' end,
      'confidence',case when f.history_points<3 then 'LEARNING' when f.history_points<6 then 'LOW' when f.history_points<8 then 'MEDIUM' else 'HIGH' end
    ) order by f.customer_name,f.product_code) from forecast f),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_production_intelligence_dashboard(date,date,uuid) from public,anon;
grant execute on function public.get_production_intelligence_dashboard(date,date,uuid) to authenticated;

comment on view public.production_official_actuals is
  'Canonical actual KG for analytics. Finish and MOP Production only; excludes Sorting estimates.';
comment on function public.get_production_intelligence_dashboard(date,date,uuid) is
  'Permission-guarded Production Intelligence foundation with official weekly actuals and learning forecasts.';
