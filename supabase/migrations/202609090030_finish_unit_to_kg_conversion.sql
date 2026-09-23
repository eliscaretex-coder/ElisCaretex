begin;

insert into public.production_targets (
  target_code,target_name,area_code,metric_code,unit_code,target_value,description,active,sort_order
)
values (
  'FINISH_UNITS_PER_KG','Finish units conversion','FINISH','UNIT_TO_KG_CONVERSION','UNITS_PER_KG',6,
  'How many Finish Units are equivalent to 1 kg. Exact recorded KG and Units remain unchanged; this value is used only for KG-equivalent operational totals and productivity.',true,11
)
on conflict (target_code) do nothing;

create or replace function public.get_finish_production_context_v4(
  p_shift_code text default 'MORNING',
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb; v_business_date date; v_rewash_entries jsonb; v_options jsonb; v_tables jsonb;
  v_units_per_kg numeric:=6;
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_production_context_v3(p_shift_code,p_at);
  v_business_date:=nullif(v_base->>'business_date','')::date;
  select coalesce((select target_value from public.production_targets where target_code='FINISH_UNITS_PER_KG' and active=true limit 1),6) into v_units_per_kg;
  v_units_per_kg:=greatest(v_units_per_kg,0.001);
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
    'recorded_kg',coalesce((item->>'produced_kg')::numeric,0),
    'units_kg_equivalent',round(coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg,2),
    'normal_produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg,
    'rewash_kg',coalesce(rw.rewash_kg,0),
    'produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg+coalesce(rw.rewash_kg,0),
    'difference_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg+coalesce(rw.rewash_kg,0)-coalesce((item->>'target_now_kg')::numeric,0),
    'kg_per_staff_hour',case when coalesce((item->>'staff_hours')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg+coalesce(rw.rewash_kg,0))/((item->>'staff_hours')::numeric),2) else null end,
    'efficiency_percent',case when coalesce((item->>'staff_hours')::numeric,0)>0 and coalesce((item->>'target_kg_per_staff_hour')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg+coalesce(rw.rewash_kg,0))/((item->>'staff_hours')::numeric*(item->>'target_kg_per_staff_hour')::numeric)*100,1) else null end
  ) order by item->>'table_code'),'[]'::jsonb) into v_tables
  from base_tables left join rw on rw.table_code_snapshot=item->>'table_code';

  return (v_base-'schema_version'-'source_contract'-'tables')||jsonb_build_object(
    'schema_version','FINISH_PRODUCTION_V4','source_contract','FINISH_V4_NORMAL_PLUS_REWASH_LEDGER',
    'units_per_kg',v_units_per_kg,'tables',v_tables,'rewash_entries',v_rewash_entries,'rewash_customer_options',v_options,'rewash_supported',true
  );
end;
$$;

create or replace function public.get_finish_results_dashboard(
  p_business_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb; v_date date; v_total jsonb; v_tables jsonb; v_shifts jsonb; v_entries jsonb; v_rewash_kg numeric:=0;
  v_units_per_kg numeric:=6;
begin
  v_base:=public.get_finish_results_dashboard_normal_v1(p_business_date);
  v_date:=nullif(v_base->>'business_date','')::date;
  select coalesce((select target_value from public.production_targets where target_code='FINISH_UNITS_PER_KG' and active=true limit 1),6) into v_units_per_kg;
  v_units_per_kg:=greatest(v_units_per_kg,0.001);
  select coalesce(sum(l.quantity_kg),0) into v_rewash_kg
  from public.finish_rewash_entries e join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
  where e.status='ACTIVE' and e.production_business_date=v_date;

  with rw as (
    select e.table_code_snapshot,e.shift_code_snapshot,sum(l.quantity_kg) rewash_kg,count(distinct e.entry_group_id) contribution_count
    from public.finish_rewash_entries e join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
    where e.status='ACTIVE' and e.production_business_date=v_date group by e.table_code_snapshot,e.shift_code_snapshot
  ), base_rows as (select value item from jsonb_array_elements(coalesce(v_base->'tables','[]'::jsonb)))
  select coalesce(jsonb_agg(item||jsonb_build_object(
    'recorded_kg',coalesce((item->>'produced_kg')::numeric,0),'units_kg_equivalent',round(coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg,2),
    'normal_produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg,'rewash_kg',coalesce(rw.rewash_kg,0),
    'produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg+coalesce(rw.rewash_kg,0),
    'missing_kg',greatest(coalesce((item->>'planned_kg')::numeric,0)-coalesce((item->>'produced_kg')::numeric,0)-coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg-coalesce(rw.rewash_kg,0),0),
    'efficiency_percent',case when coalesce((item->>'planned_kg')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg+coalesce(rw.rewash_kg,0))/(item->>'planned_kg')::numeric*100,2) else 0 end,
    'kg_per_staff_hour',case when coalesce((item->>'staff_hours')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg+coalesce(rw.rewash_kg,0))/(item->>'staff_hours')::numeric,2) else 0 end,
    'contribution_count',coalesce((item->>'contribution_count')::integer,0)+coalesce(rw.contribution_count,0)
  ) order by item->>'shift_code',item->>'table_code'),'[]'::jsonb) into v_tables
  from base_rows left join rw on rw.table_code_snapshot=item->>'table_code' and rw.shift_code_snapshot=item->>'shift_code';

  with rw as (
    select e.shift_code_snapshot,sum(l.quantity_kg) rewash_kg,count(distinct e.entry_group_id) contribution_count
    from public.finish_rewash_entries e join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
    where e.status='ACTIVE' and e.production_business_date=v_date group by e.shift_code_snapshot
  ), base_rows as (select value item from jsonb_array_elements(coalesce(v_base->'shifts','[]'::jsonb)))
  select coalesce(jsonb_agg(item||jsonb_build_object(
    'recorded_kg',coalesce((item->>'produced_kg')::numeric,0),'units_kg_equivalent',round(coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg,2),
    'normal_produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg,'rewash_kg',coalesce(rw.rewash_kg,0),
    'produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg+coalesce(rw.rewash_kg,0),
    'missing_kg',greatest(coalesce((item->>'planned_kg')::numeric,0)-coalesce((item->>'produced_kg')::numeric,0)-coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg-coalesce(rw.rewash_kg,0),0),
    'efficiency_percent',case when coalesce((item->>'planned_kg')::numeric,0)>0 then round((coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg+coalesce(rw.rewash_kg,0))/(item->>'planned_kg')::numeric*100,2) else 0 end,
    'contribution_count',coalesce((item->>'contribution_count')::integer,0)+coalesce(rw.contribution_count,0)
  ) order by item->>'shift_code'),'[]'::jsonb) into v_shifts
  from base_rows left join rw on rw.shift_code_snapshot=item->>'shift_code';

  v_total:=(v_base->'total')||jsonb_build_object(
    'recorded_kg',coalesce((v_base->'total'->>'produced_kg')::numeric,0),'units_kg_equivalent',round(coalesce((v_base->'total'->>'produced_units')::numeric,0)/v_units_per_kg,2),
    'normal_produced_kg',coalesce((v_base->'total'->>'produced_kg')::numeric,0)+coalesce((v_base->'total'->>'produced_units')::numeric,0)/v_units_per_kg,'rewash_kg',v_rewash_kg,
    'produced_kg',coalesce((v_base->'total'->>'produced_kg')::numeric,0)+coalesce((v_base->'total'->>'produced_units')::numeric,0)/v_units_per_kg+v_rewash_kg,
    'missing_kg',greatest(coalesce((v_base->'total'->>'planned_kg')::numeric,0)-coalesce((v_base->'total'->>'produced_kg')::numeric,0)-coalesce((v_base->'total'->>'produced_units')::numeric,0)/v_units_per_kg-v_rewash_kg,0),
    'efficiency_percent',case when coalesce((v_base->'total'->>'planned_kg')::numeric,0)>0 then round((coalesce((v_base->'total'->>'produced_kg')::numeric,0)+coalesce((v_base->'total'->>'produced_units')::numeric,0)/v_units_per_kg+v_rewash_kg)/(v_base->'total'->>'planned_kg')::numeric*100,2) else 0 end
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
    'schema_version','FINISH_RESULTS_V2','source_contract','FINISH_NORMAL_PLUS_REAL_REWASH_LEDGER','units_per_kg',v_units_per_kg,
    'total',v_total,'tables',v_tables,'shifts',v_shifts,'entries',v_entries,'rewash_separate_metric_supported',true
  );
end;
$$;

revoke all on function public.get_finish_production_context_v4(text,timestamptz) from public,anon;
grant execute on function public.get_finish_production_context_v4(text,timestamptz) to authenticated;
revoke all on function public.get_finish_results_dashboard(date) from public,anon;
grant execute on function public.get_finish_results_dashboard(date) to authenticated;

commit;
