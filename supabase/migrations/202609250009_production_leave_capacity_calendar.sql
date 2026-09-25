-- Month view for balancing leave requests against production staffing and scheduled customer KG.

create or replace function public.get_production_roster_capacity_calendar(
  p_month date,
  p_shift_code text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_month date:=date_trunc('month',coalesce(p_month,(now() at time zone 'Europe/Dublin')::date))::date;
  v_shift text:=upper(nullif(trim(coalesce(p_shift_code,'')),''));
  v_grid_start date;
  v_grid_end date;
  v_days jsonb;
  v_summary jsonb;
begin
  perform public.require_production_roster_manage_role();
  if v_shift is not null and v_shift not in ('MORNING','EVENING') then
    raise exception using errcode='22023',message='Invalid shift.';
  end if;
  if v_month < date '2020-01-01' or v_month > (now() at time zone 'Europe/Dublin')::date + interval '5 years' then
    raise exception using errcode='22023',message='Calendar month is outside the supported planning range.';
  end if;

  v_grid_start:=v_month-(extract(isodow from v_month)::integer-1);
  v_grid_end:=(v_month+interval '1 month'-interval '1 day')::date+(7-extract(isodow from (v_month+interval '1 month'-interval '1 day')::date)::integer);

  with calendar as (
    select gs::date work_date from generate_series(v_grid_start,v_grid_end,interval '1 day') gs
  ), daily as (
    select c.work_date,
      (select count(*) from public.staff_members sm left join public.shifts sh on sh.shift_id=sm.default_shift_id
       where sm.active and sm.deleted_at is null and sm.roster_eligible and sm.production_staff
         and coalesce(sm.joined_on,c.work_date)<=c.work_date and (sm.deactivated_on is null or sm.deactivated_on>=c.work_date)
         and (v_shift is null or upper(sh.shift_code)=v_shift))::integer eligible_staff,
      coalesce((select jsonb_agg(jsonb_build_object('leave_request_id',lr.leave_request_id,'staff_id',lr.staff_id,'display_name',lr.staff_display_name_snapshot,'request_type',lr.request_type,'status',lr.status,'requires_general_manager',lr.requires_general_manager) order by lr.status,lower(lr.staff_display_name_snapshot))
        from public.production_roster_leave_requests lr left join public.staff_members sm on sm.staff_id=lr.staff_id left join public.shifts sh on sh.shift_id=sm.default_shift_id
        where lr.status in ('PENDING','APPROVED') and c.work_date between lr.start_date and lr.end_date and (v_shift is null or upper(sh.shift_code)=v_shift)),'[]'::jsonb) leave,
      coalesce(demand.customer_count,0)::integer customer_count,
      coalesce(demand.exact_customer_count,0)::integer exact_customer_count,
      coalesce(demand.estimated_kg,0)::numeric estimated_kg
    from calendar c
    left join lateral (
      select count(*) customer_count,count(*) filter(where q.has_exact_kg) exact_customer_count,sum(q.estimated_kg) estimated_kg
      from (
        select cv.customer_id,
          bool_and(cp.expected_kg is not null) and count(cp.*)>0 has_exact_kg,
          case when bool_and(cp.expected_kg is not null) and count(cp.*)>0 then sum(cp.expected_kg) else coalesce(max(cu.distribution_estimated_kg),sum(cp.expected_kg),0) end estimated_kg
        from public.customer_schedule_versions cv
        join public.customers cu on cu.customer_id=cv.customer_id and cu.active and cu.deleted_at is null
        join public.customer_schedule_days cd on cd.schedule_version_id=cv.schedule_version_id and cd.active and cd.production_weekday=extract(isodow from c.work_date)::integer
        left join public.customer_schedule_products cp on cp.schedule_day_id=cd.schedule_day_id and cp.active
        where cv.status='PUBLISHED' and c.work_date between cv.effective_from and coalesce(cv.effective_until,'infinity'::date)
        group by cv.customer_id
      ) q
    ) demand on true
  ), shaped as (
    select d.*,
      jsonb_array_length(d.leave) filter_dummy,
      (select count(*) from jsonb_array_elements(d.leave) x where x->>'status'='APPROVED')::integer approved_count,
      (select count(*) from jsonb_array_elements(d.leave) x where x->>'status'='PENDING')::integer pending_count,
      case when d.customer_count>0 then round(d.exact_customer_count::numeric/d.customer_count*100,1) else 0 end exact_kg_coverage_percent
    from daily d
  )
  select coalesce(jsonb_agg(to_jsonb(s)-'filter_dummy' order by s.work_date),'[]'::jsonb) into v_days from shaped s;

  with x as (
    select (item->>'work_date')::date work_date,(item->>'approved_count')::integer approved_count,(item->>'pending_count')::integer pending_count,
      (item->>'estimated_kg')::numeric estimated_kg,(item->>'customer_count')::integer customer_count,(item->>'exact_customer_count')::integer exact_customer_count
    from jsonb_array_elements(v_days) item where (item->>'work_date')::date>=v_month and (item->>'work_date')::date<(v_month+interval '1 month')::date
  ) select jsonb_build_object(
    'approved_staff_days',coalesce(sum(approved_count),0),'pending_staff_days',coalesce(sum(pending_count),0),
    'estimated_kg',round(coalesce(sum(estimated_kg),0),2),'scheduled_customer_days',coalesce(sum(customer_count),0),
    'exact_kg_coverage_percent',case when coalesce(sum(customer_count),0)>0 then round(sum(exact_customer_count)::numeric/sum(customer_count)*100,1) else 0 end
  ) into v_summary from x;

  return jsonb_build_object('month',v_month,'shift_code',v_shift,'grid_start',v_grid_start,'grid_end',v_grid_end,'summary',v_summary,'days',v_days,'kg_is_estimate',true);
end;
$$;

revoke all on function public.get_production_roster_capacity_calendar(date,text) from public,anon;
grant execute on function public.get_production_roster_capacity_calendar(date,text) to authenticated;

comment on function public.get_production_roster_capacity_calendar(date,text) is
'Permission-aware monthly planning calendar combining roster-eligible production staff, pending/approved leave and scheduled customer KG estimates.';
