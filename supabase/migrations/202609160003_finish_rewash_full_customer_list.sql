create or replace function public.finish_rewash_customer_options_v1(p_business_date date)
returns jsonb
language sql
stable
security definer
set search_path=public,auth,pg_temp
as $$
  with chosen as (
    select c.customer_id,c.customer_code,c.customer_name,v.schedule_version_id
    from public.customers c
    left join lateral (
      select v.schedule_version_id
      from public.customer_schedule_versions v
      where v.customer_id=c.customer_id
        and v.status='PUBLISHED'
        and v.cancelled_at is null
      order by
        case
          when p_business_date between v.effective_from and coalesce(v.effective_until,'infinity'::date) then 0
          when v.effective_from<=p_business_date then 1
          else 2
        end,
        case when v.effective_from<=p_business_date then v.effective_from end desc nulls last,
        v.effective_from asc
      limit 1
    ) v on true
    where c.active=true and c.deleted_at is null
  ), raw as (
    select chosen.customer_id,pt.product_code,d.production_weekday
    from chosen
    left join public.customer_schedule_days d on d.schedule_version_id=chosen.schedule_version_id and d.active=true
    left join public.customer_schedule_products sp on sp.schedule_day_id=d.schedule_day_id and sp.active=true
    left join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.active=true
  ), eligible as (
    select
      c.customer_id,c.customer_code,c.customer_name,
      coalesce((select array_agg(product_code order by product_code) from (select distinct product_code from raw r where r.customer_id=c.customer_id and product_code is not null) s),array[]::text[]) as service_codes,
      coalesce((select array_agg(public.weekday_name(production_weekday) order by production_weekday) from (select distinct production_weekday from raw r where r.customer_id=c.customer_id and production_weekday is not null) s),array[]::text[]) as scheduled_days,
      coalesce((select array_agg(production_weekday order by production_weekday) from (select distinct production_weekday from raw r where r.customer_id=c.customer_id and production_weekday is not null) s),array[]::integer[]) as scheduled_weekdays
    from chosen c
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'customer_id',customer_id,
    'customer_code',customer_code,
    'customer_name',customer_name,
    'label',customer_name||case when array_length(scheduled_days,1)>0 then ' ('||array_to_string(array(select left(day_name,3) from unnest(scheduled_days) day_name),', ')||')' else '' end,
    'service_codes',to_jsonb(service_codes),
    'scheduled_days',to_jsonb(scheduled_days),
    'scheduled_weekdays',to_jsonb(scheduled_weekdays)
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
  v_station public.finish_workstations%rowtype;
  v_staff public.staff_members%rowtype;
  v_business_date date;
  v_existing public.finish_rewash_entries%rowtype;
  v_entry_id uuid:=gen_random_uuid();
  v_group_id uuid;
  v_saved public.finish_rewash_entries%rowtype;
  v_line jsonb;
  v_line_no integer:=0;
  v_customer_id uuid;
  v_customer_code text;
  v_customer_name text;
  v_service_codes text[];
  v_scheduled_days text[];
  v_batch text;
  v_kg numeric;
  v_lines jsonb:='[]'::jsonb;
begin
  perform public.require_finish_production_access();
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,'MORNING'))) and active=true and deleted_at is null;
  if not found then raise exception using errcode='22023',message='Selected Finish shift is not available.'; end if;
  select * into v_station from public.finish_workstations where station_code=upper(trim(coalesce(p_table_code,''))) and active=true;
  if not found then raise exception using errcode='22023',message='Selected Finish table is not available.'; end if;
  select * into v_staff from public.staff_members where staff_id=p_processed_by_staff_id and active=true and deleted_at is null;
  if not found then raise exception using errcode='22023',message='Select the staff member who processed this ReWash.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception using errcode='22023',message='Add at least one ReWash customer.'; end if;

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

    select
      opt->>'customer_code',
      opt->>'customer_name',
      array(select jsonb_array_elements_text(coalesce(opt->'service_codes','[]'::jsonb))),
      coalesce(nullif(array(select jsonb_array_elements_text(coalesce(v_line->'scheduled_days','[]'::jsonb))),array[]::text[]),array(select jsonb_array_elements_text(coalesce(opt->'scheduled_days','[]'::jsonb))))
    into v_customer_code,v_customer_name,v_service_codes,v_scheduled_days
    from jsonb_array_elements(public.finish_rewash_customer_options_v1(v_business_date)) opt
    where opt->>'customer_id'=v_customer_id::text
    limit 1;
    if not found then raise exception using errcode='22023',message='ReWash customers must be active customers from the master customer schedule.'; end if;

    if v_batch is not null and exists (
      select 1
      from public.finish_production_entries e
      join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
      where e.status='ACTIVE' and e.production_business_date=v_business_date and lower(l.batch_reference)=lower(v_batch)
      union all
      select 1
      from public.finish_rewash_entries e
      join public.finish_rewash_lines l on l.finish_rewash_entry_id=e.finish_rewash_entry_id
      where e.status='ACTIVE' and e.production_business_date=v_business_date and e.finish_rewash_entry_id is distinct from coalesce(v_existing.finish_rewash_entry_id,'00000000-0000-0000-0000-000000000000'::uuid) and lower(l.batch_reference)=lower(v_batch)
    ) then
      raise exception using errcode='23505',message=format('Batch %s is already used in Finish or ReWash today.',v_batch);
    end if;

    v_lines:=v_lines||jsonb_build_array(jsonb_build_object(
      'line_no',v_line_no,'customer_id',v_customer_id,'customer_code',v_customer_code,'customer_name',v_customer_name,
      'service_codes',to_jsonb(v_service_codes),'scheduled_days',to_jsonb(v_scheduled_days),'batch_reference',v_batch,'quantity_kg',v_kg
    ));
  end loop;

  if v_existing.finish_rewash_entry_id is not null then
    update public.finish_rewash_entries
    set status='SUPERSEDED',superseded_by_finish_rewash_entry_id=v_entry_id,correction_reason='ReWash edited',
        cancelled_at=now(),cancelled_by_staff_id=public.current_staff_id(),cancelled_by_auth_user_id=auth.uid()
    where finish_rewash_entry_id=v_existing.finish_rewash_entry_id;
  end if;

  insert into public.finish_rewash_entries(
    finish_rewash_entry_id,entry_group_id,revision_no,status,supersedes_finish_rewash_entry_id,production_business_date,
    shift_id,shift_code_snapshot,station_id,table_code_snapshot,table_name_snapshot,processed_by_staff_id,processed_by_name_snapshot,
    recorded_by_staff_id,recorded_by_auth_user_id,notes
  )
  values(
    v_entry_id,v_group_id,case when v_existing.finish_rewash_entry_id is null then 1 else v_existing.revision_no+1 end,'ACTIVE',v_existing.finish_rewash_entry_id,v_business_date,
    v_shift.shift_id,v_shift.shift_code,v_station.station_id,v_station.station_code,v_station.station_name,v_staff.staff_id,v_staff.display_name,
    public.current_staff_id(),auth.uid(),nullif(trim(p_notes),'')
  )
  returning * into v_saved;

  insert into public.finish_rewash_lines(
    finish_rewash_entry_id,line_no,customer_id,customer_code_snapshot,customer_name_snapshot,service_codes_snapshot,scheduled_days_snapshot,batch_reference,quantity_kg
  )
  select v_saved.finish_rewash_entry_id,(item->>'line_no')::integer,(item->>'customer_id')::uuid,item->>'customer_code',item->>'customer_name',
    array(select jsonb_array_elements_text(item->'service_codes')),array(select jsonb_array_elements_text(item->'scheduled_days')),
    nullif(item->>'batch_reference',''),(item->>'quantity_kg')::numeric
  from jsonb_array_elements(v_lines) item;

  insert into public.production_flow_events(production_flow_item_id,event_type,event_area_code,event_step_order,event_source,business_date,event_at,operator_staff_id,recorded_by_staff_id,recorded_by_auth_user_id,source_system,source_table,source_record_id,details)
  values(null,'FINISH_REWASH_RECORDED','FINISH',45,'REWASH',v_business_date,now(),v_staff.staff_id,public.current_staff_id(),auth.uid(),'FINISH_V2','finish_rewash_entries',v_saved.finish_rewash_entry_id::text,
    jsonb_build_object('finish_rewash_entry_id',v_saved.finish_rewash_entry_id,'entry_group_id',v_group_id,'revision_no',v_saved.revision_no,'processed_kg',(select sum((item->>'quantity_kg')::numeric) from jsonb_array_elements(v_lines) item)));

  return jsonb_build_object('status',case when v_existing.finish_rewash_entry_id is null then 'saved' else 'corrected' end,
    'finish_rewash_entry_id',v_saved.finish_rewash_entry_id,'entry_group_id',v_group_id,'revision_no',v_saved.revision_no,'processed_kg',(select sum((item->>'quantity_kg')::numeric) from jsonb_array_elements(v_lines) item));
end;
$$;

revoke all on function public.finish_rewash_customer_options_v1(date) from public,anon,authenticated;
grant execute on function public.finish_rewash_customer_options_v1(date) to authenticated;
revoke all on function public.record_finish_rewash_v1(text,text,uuid,jsonb,text) from public,anon;
grant execute on function public.record_finish_rewash_v1(text,text,uuid,jsonb,text) to authenticated;

comment on function public.finish_rewash_customer_options_v1(date) is
  'Returns the full active customer master list for Finish ReWash, including published schedule weekdays for staff selection.';
