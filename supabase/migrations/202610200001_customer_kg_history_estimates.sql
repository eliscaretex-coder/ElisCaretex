-- Customer KG estimates calculated from official production history.
--
-- Before: Expected KG per customer, product and weekday was typed by hand (1 of 505 current
-- schedule slots had a value) and Distribution used one manual KG per customer for every day.
-- Now every consumer uses one shared model:
--   * Source: official KG only (Finish KG lines and MOP batches); Sorting estimates are excluded.
--   * Service attribution: a production day is credited to the customer's scheduled production
--     weekday on or up to two days before it, so work finished the next day (about 13% of
--     customer days, Jun-Sep 2026) is added to the service it belongs to instead of being lost.
--   * Window: the latest 8 services for the same customer, product and weekday within 26 weeks.
--   * Outliers: each service is capped between 0.4x and 2x the window median before averaging.
--   * Ready after 3 services; older than 6 weeks is flagged STALE but still used.
--   * Manual Expected KG (schedule) and Distribution estimated KG (customer) remain as fallback
--     while a slot is still learning.
-- Backtest on Jul-Sep 2026 services (3,643 predictions): slot error (WAPE) 28.0% -> 25.2%,
-- total bias -7.4% -> -1.5%; daily total error 7.4%.

create or replace function public.customer_kg_service_history(
  p_reference_date date,
  p_customer_id uuid default null
)
returns table(
  customer_id uuid,
  product_code text,
  production_weekday smallint,
  service_date date,
  service_kg numeric,
  production_days integer,
  carried_over boolean,
  recency_rank integer
)
language sql
stable
set search_path=public,pg_temp
as $$
  with slots as materialized (
    select distinct v.customer_id,pt.product_code,d.production_weekday::smallint production_weekday
    from public.customer_schedule_versions v
    join public.customers c on c.customer_id=v.customer_id and c.active and c.deleted_at is null
    join public.customer_schedule_days d on d.schedule_version_id=v.schedule_version_id and d.active
    join public.customer_schedule_products sp on sp.schedule_day_id=d.schedule_day_id and sp.active
    join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.product_code in ('CLOTHES','MOP')
    where v.status='PUBLISHED' and v.effective_from<=p_reference_date
      and (v.effective_until is null or v.effective_until>=p_reference_date)
      and (p_customer_id is null or v.customer_id=p_customer_id)
  ), daily as (
    select a.customer_id,a.product_code,a.actual_date,sum(a.actual_kg)::numeric kg
    from public.production_official_actuals a
    where a.actual_date>=p_reference_date-182 and a.actual_date<p_reference_date
      and (p_customer_id is null or a.customer_id=p_customer_id)
    group by a.customer_id,a.product_code,a.actual_date
  ), attributed as (
    select distinct on (dl.customer_id,dl.product_code,dl.actual_date)
      dl.customer_id,dl.product_code,sl.production_weekday,dl.actual_date,dl.kg,
      (extract(isodow from dl.actual_date)::integer-sl.production_weekday+7)%7 days_after
    from daily dl
    join slots sl on sl.customer_id=dl.customer_id and sl.product_code=dl.product_code
    order by dl.customer_id,dl.product_code,dl.actual_date,(extract(isodow from dl.actual_date)::integer-sl.production_weekday+7)%7
  ), services as (
    select a.customer_id,a.product_code,a.production_weekday,a.actual_date-a.days_after service_date,
      sum(a.kg) service_kg,count(*)::integer production_days,bool_or(a.days_after>0) carried_over
    from attributed a
    where a.days_after<=2
    group by a.customer_id,a.product_code,a.production_weekday,a.actual_date-a.days_after
  )
  select s.customer_id,s.product_code,s.production_weekday,s.service_date,round(s.service_kg,2),
    s.production_days,s.carried_over,
    row_number() over(partition by s.customer_id,s.product_code,s.production_weekday order by s.service_date desc)::integer
  from services s;
$$;

revoke all on function public.customer_kg_service_history(date,uuid) from public,anon,authenticated;

comment on function public.customer_kg_service_history(date,uuid) is
  'Internal. Official KG per customer service (Finish KG lines and MOP batches), credited to the scheduled production weekday on or up to two days before the production date. 26 weeks before the reference date.';

create or replace function public.customer_kg_estimates(
  p_reference_date date,
  p_customer_id uuid default null
)
returns table(
  customer_id uuid,
  product_code text,
  production_weekday smallint,
  estimated_kg numeric,
  history_points integer,
  median_kg numeric,
  minimum_kg numeric,
  maximum_kg numeric,
  last_service_date date,
  last_service_kg numeric,
  carried_over_points integer,
  estimate_status text
)
language sql
stable
set search_path=public,pg_temp
as $$
  with slots as (
    select distinct v.customer_id,pt.product_code,d.production_weekday::smallint production_weekday
    from public.customer_schedule_versions v
    join public.customers c on c.customer_id=v.customer_id and c.active and c.deleted_at is null
    join public.customer_schedule_days d on d.schedule_version_id=v.schedule_version_id and d.active
    join public.customer_schedule_products sp on sp.schedule_day_id=d.schedule_day_id and sp.active
    join public.product_types pt on pt.product_type_id=sp.product_type_id and pt.product_code in ('CLOTHES','MOP')
    where v.status='PUBLISHED' and v.effective_from<=p_reference_date
      and (v.effective_until is null or v.effective_until>=p_reference_date)
      and (p_customer_id is null or v.customer_id=p_customer_id)
  ), recent as materialized (
    select h.* from public.customer_kg_service_history(p_reference_date,p_customer_id) h where h.recency_rank<=8
  ), medians as (
    select r.customer_id,r.product_code,r.production_weekday,
      percentile_cont(0.5) within group(order by r.service_kg)::numeric median_kg
    from recent r group by r.customer_id,r.product_code,r.production_weekday
  ), model as (
    select r.customer_id,r.product_code,r.production_weekday,count(*)::integer history_points,
      avg(least(greatest(r.service_kg,m.median_kg*0.4),m.median_kg*2)) capped_average_kg,
      m.median_kg,min(r.service_kg) minimum_kg,max(r.service_kg) maximum_kg,max(r.service_date) last_service_date,
      (array_agg(r.service_kg order by r.service_date desc))[1] last_service_kg,
      count(*) filter(where r.carried_over)::integer carried_over_points
    from recent r
    join medians m on m.customer_id=r.customer_id and m.product_code=r.product_code and m.production_weekday=r.production_weekday
    group by r.customer_id,r.product_code,r.production_weekday,m.median_kg
  )
  select s.customer_id,s.product_code,s.production_weekday,
    case when coalesce(m.history_points,0)>=3 then round(m.capped_average_kg,1) end,
    coalesce(m.history_points,0),round(m.median_kg,1),round(m.minimum_kg,1),round(m.maximum_kg,1),
    m.last_service_date,round(m.last_service_kg,1),coalesce(m.carried_over_points,0),
    case when coalesce(m.history_points,0)<3 then 'LEARNING'
         when m.last_service_date<p_reference_date-42 then 'STALE'
         else 'READY' end
  from slots s
  left join model m on m.customer_id=s.customer_id and m.product_code=s.product_code and m.production_weekday=s.production_weekday;
$$;

revoke all on function public.customer_kg_estimates(date,uuid) from public,anon,authenticated;

comment on function public.customer_kg_estimates(date,uuid) is
  'Internal. Expected KG per current schedule slot (customer, product, production weekday): average of the latest 8 official services within 26 weeks, each capped at 0.4x-2x the median. Null until 3 services exist.';

create or replace function public.get_customer_kg_estimates(
  p_effective_date date default null,
  p_customer_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_date date:=coalesce(p_effective_date,public.current_business_date());
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(array[
    'ADMIN','MANAGER','PLANNER','SUPERVISOR','AUDITOR',
    'SORTING_OPERATOR','FINISH_OPERATOR','MOP_OPERATOR','DISTRIBUTION_OPERATOR'
  ]);
  if v_date<date '2020-01-01' or v_date>public.current_business_date()+366 then
    raise exception using errcode='22023',message='Choose a date within the planning range.';
  end if;

  select jsonb_build_object(
    'reference_date',v_date,
    'policy',jsonb_build_object(
      'method','RECENT_SERVICES_CAPPED_AVERAGE','recent_services',8,'lookback_weeks',26,
      'minimum_services',3,'stale_after_days',42,'carry_over_days',2,'cap_low',0.4,'cap_high',2,
      'official_sources',jsonb_build_array('FINISH','MOP'),
      'message','Average of the latest 8 official services for the same customer, product and weekday. Production finished up to two days later counts towards the same service. Each service is capped at 0.4x-2x the median.'
    ),
    'items',coalesce(jsonb_agg(jsonb_build_object(
      'customer_id',e.customer_id,'product_code',e.product_code,'production_weekday',e.production_weekday,
      'estimated_kg',e.estimated_kg,'history_points',e.history_points,'median_kg',e.median_kg,
      'minimum_kg',e.minimum_kg,'maximum_kg',e.maximum_kg,'last_service_date',e.last_service_date,
      'last_service_kg',e.last_service_kg,'carried_over_points',e.carried_over_points,'status',e.estimate_status
    ) order by e.customer_id,e.product_code,e.production_weekday),'[]'::jsonb)
  ) into v_result
  from public.customer_kg_estimates(v_date,p_customer_id) e;

  return v_result;
end;
$$;

revoke all on function public.get_customer_kg_estimates(date,uuid) from public,anon;
grant execute on function public.get_customer_kg_estimates(date,uuid) to authenticated;

comment on function public.get_customer_kg_estimates(date,uuid) is
  'Automatic Expected KG per schedule slot from official production history. Customer schedule readers only.';

-- Customer schedule editor: same model, with the services used as evidence.
create or replace function public.get_customer_kg_history(
  p_customer_id uuid,
  p_from_date date default null,
  p_to_date date default null,
  p_recent_limit integer default 3
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_from date:=coalesce(p_from_date,current_date-interval '18 months');
  v_to date:=coalesce(p_to_date,current_date);
  v_limit integer:=least(greatest(coalesce(p_recent_limit,8),1),12);
  v_result jsonb;
begin
  if auth.uid() is null or not (
    public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null)
    or public.has_any_role(array['ADMIN','MANAGER','PLANNER'])
  ) then
    raise exception using errcode='42501',message='This account cannot view customer KG history.';
  end if;
  if p_customer_id is null then
    raise exception using errcode='22023',message='Choose a customer.';
  end if;
  if v_from>v_to or v_to-v_from>1827 then
    raise exception using errcode='22023',message='Choose a valid date range of no more than five years.';
  end if;
  if not exists(select 1 from public.customers c where c.customer_id=p_customer_id and c.deleted_at is null) then
    raise exception using errcode='P0002',message='Customer not found.';
  end if;

  with daily as (
    select a.actual_date,a.customer_id,max(a.customer_code) customer_code,max(a.customer_name) customer_name,
      a.product_code,extract(isodow from a.actual_date)::integer production_weekday,
      round(sum(a.actual_kg),2) actual_kg,
      string_agg(distinct a.production_source,', ' order by a.production_source) production_source
    from public.production_official_actuals a
    where a.customer_id=p_customer_id and a.actual_date between v_from and v_to
    group by a.actual_date,a.customer_id,a.product_code
  ), services as (
    select h.* from public.customer_kg_service_history(v_to+1,p_customer_id) h where h.recency_rank<=greatest(v_limit,8)
  ), estimates as (
    select e.* from public.customer_kg_estimates(v_to+1,p_customer_id) e
  )
  select jsonb_build_object(
    'customer',coalesce((select jsonb_build_object(
      'customer_id',customer_id,'customer_code',customer_code,'customer_name',customer_name
    ) from daily limit 1),(select jsonb_build_object(
      'customer_id',c.customer_id,'customer_code',c.customer_code,'customer_name',c.customer_name
    ) from public.customers c where c.customer_id=p_customer_id)),
    'period',jsonb_build_object('from',v_from,'to',v_to),
    'policy',jsonb_build_object(
      'recent_records',8,'minimum_records',3,'method','RECENT_SERVICES_CAPPED_AVERAGE',
      'official_sources',jsonb_build_array('FINISH','MOP'),
      'message','Expected KG is calculated automatically: average of the latest 8 official services for the same customer, product and weekday (production finished up to two days later counts towards the same service; each service capped at 0.4x-2x the median).'
    ),
    'suggestions',coalesce((select jsonb_agg(jsonb_build_object(
      'product_code',e.product_code,'production_weekday',e.production_weekday,
      'history_points',e.history_points,
      'suggested_kg',e.estimated_kg,
      'observed_average_kg',e.estimated_kg,'median_kg',e.median_kg,'minimum_kg',e.minimum_kg,'maximum_kg',e.maximum_kg,
      'last_actual_date',e.last_service_date,'last_actual_kg',e.last_service_kg,
      'carried_over_points',e.carried_over_points,
      'recent_records',coalesce((select jsonb_agg(jsonb_build_object(
        'actual_date',s.service_date,'actual_kg',s.service_kg,'production_days',s.production_days,'carried_over',s.carried_over
      ) order by s.service_date desc) from services s
        where s.product_code=e.product_code and s.production_weekday=e.production_weekday and s.recency_rank<=8),'[]'::jsonb),
      'status',case when e.estimate_status='STALE' then 'READY' else e.estimate_status end,
      'estimate_status',e.estimate_status
    ) order by e.production_weekday,e.product_code) from estimates e),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(jsonb_build_object(
      'actual_date',d.actual_date,'production_weekday',d.production_weekday,'product_code',d.product_code,
      'actual_kg',d.actual_kg,'production_source',d.production_source
    ) order by d.actual_date desc,d.product_code) from daily d),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_customer_kg_history(uuid,date,date,integer) from public,anon;
grant execute on function public.get_customer_kg_history(uuid,date,date,integer) to authenticated;

comment on function public.get_customer_kg_history(uuid,date,date,integer) is
  'Official customer KG history plus the automatic Expected KG per weekday (latest 8 services, capped average). Finish/MOP only; never Sorting estimates.';

-- Distribution stops and route loads: automatic KG for the products of the service day.
create or replace function public.distribution_source_stops(
  p_business_date date,
  p_route_id uuid default null
)
returns table (
  source_schedule_day_id uuid, customer_id uuid, route_id uuid, route_code text,
  route_display_name text, route_color text, source_delivery_order integer,
  customer_code text, customer_name text, eircode text, delivery_window_start time,
  delivery_window_end time, planned_product_codes text[], planned_trolley_total integer,
  planned_trolley_summary text, estimated_kg numeric, stop_units integer,
  distribution_instructions text, day_alert text
)
language sql stable security definer set search_path = public, auth, pg_temp as $$
  with estimates as materialized (
    select e.customer_id, e.product_code, e.production_weekday, e.estimated_kg
    from public.customer_kg_estimates(p_business_date, null) e
  )
  select d.schedule_day_id, c.customer_id, r.route_id, r.route_code, r.display_name, r.route_color,
    d.delivery_order, c.customer_code, c.customer_name, c.eircode, d.delivery_window_start,
    d.delivery_window_end, coalesce(products.product_codes, array[]::text[]),
    coalesce(trolleys.total_quantity, 0)::integer, trolleys.trolley_summary,
    coalesce(kg.expected_kg, c.distribution_estimated_kg), c.distribution_stop_count, d.distribution_instructions, d.day_alert
  from public.customer_schedule_versions v
  join public.customer_schedule_days d on d.schedule_version_id = v.schedule_version_id and d.active
  join public.customers c on c.customer_id = v.customer_id and c.active and c.deleted_at is null
  join public.distribution_routes r on r.route_id = d.default_route_id and r.active and r.deleted_at is null
  left join lateral (
    select array_agg(pt.product_code order by pt.sort_order, pt.product_code) as product_codes
    from public.customer_schedule_products sp
    join public.product_types pt on pt.product_type_id = sp.product_type_id
    where sp.schedule_day_id = d.schedule_day_id and sp.active and pt.active and pt.deleted_at is null
  ) products on true
  left join lateral (
    -- Automatic history estimate per product, then the manual schedule KG, then the customer's manual KG.
    select sum(coalesce(e.estimated_kg, sp.expected_kg)) as expected_kg
    from public.customer_schedule_products sp
    join public.product_types pt on pt.product_type_id = sp.product_type_id
    left join estimates e on e.customer_id = c.customer_id and e.product_code = pt.product_code
      and e.production_weekday = d.production_weekday
    where sp.schedule_day_id = d.schedule_day_id and sp.active and pt.active and pt.deleted_at is null
  ) kg on true
  left join lateral (
    select sum(req.quantity)::integer as total_quantity,
      string_agg(concat(req.quantity, coalesce(tt.display_code, tt.trolley_type_code)), ' + ' order by tt.sort_order, tt.trolley_type_code) as trolley_summary
    from public.customer_schedule_trolley_requirements req
    join public.trolley_types tt on tt.trolley_type_id = req.trolley_type_id
    where req.schedule_day_id = d.schedule_day_id and req.active
  ) trolleys on true
  where v.status = 'PUBLISHED'
    and v.effective_from <= p_business_date
    and (v.effective_until is null or v.effective_until >= p_business_date)
    and d.delivery_weekday = extract(isodow from p_business_date)::smallint
    and (p_route_id is null or d.default_route_id = p_route_id);
$$;

revoke all on function public.distribution_source_stops(date,uuid) from public,anon,authenticated;

-- Route customers (Distribution and Customer Master): automatic KG per delivery.
create or replace function public.get_distribution_weekly_planner(
  p_effective_date date default public.current_business_date(),
  p_delivery_weekday smallint default null,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_search text := nullif(trim(p_search), '');
  v_result jsonb;
begin
  perform public.require_any_customer_read_role(
    array[
      'ADMIN', 'MANAGER', 'PLANNER',
      'DISTRIBUTION_OPERATOR', 'AUDITOR'
    ]
  );

  if p_delivery_weekday is not null
     and p_delivery_weekday not between 1 and 7 then
    raise exception using errcode = '22023', message = 'Delivery weekday must be between 1 and 7.';
  end if;

  with estimates as materialized (
    select e.customer_id, e.product_code, e.production_weekday, e.estimated_kg, e.history_points, e.estimate_status
    from public.customer_kg_estimates(p_effective_date, null) e
  ), planner_rows as (
    select
      v.schedule_version_id,
      v.version_number,
      d.schedule_day_id,
      d.production_weekday,
      public.weekday_name(d.production_weekday) as production_day,
      public.next_distribution_weekday(d.production_weekday) as delivery_weekday,
      public.weekday_name(public.next_distribution_weekday(d.production_weekday)) as delivery_day,
      d.delivery_window_start,
      d.delivery_window_end,
      d.delivery_order,
      d.day_alert,
      d.distribution_instructions,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      c.eircode,
      c.distribution_estimated_kg,
      c.distribution_stop_count,
      c.operational_alert,
      r.route_id as default_route_id,
      r.route_code as default_route_code,
      r.display_name as default_route_display_name,
      r.route_color as default_route_color,
      coalesce(products.product_codes, array[]::text[]) as scheduled_products,
      kg.history_kg,
      kg.product_kg,
      kg.kg_breakdown,
      coalesce(trolley.total_quantity, 0) as planned_trolley_total,
      trolley.trolley_summary,
      coalesce(trolley.trolley_breakdown, '[]'::jsonb) as trolley_breakdown
    from public.customer_schedule_versions v
    join public.customers c
      on c.customer_id = v.customer_id
    join public.customer_schedule_days d
      on d.schedule_version_id = v.schedule_version_id
    left join public.distribution_routes r
      on r.route_id = d.default_route_id
    left join lateral (
      select array_agg(pt.product_code order by pt.sort_order, pt.product_code)
        as product_codes
      from public.customer_schedule_products p
      join public.product_types pt
        on pt.product_type_id = p.product_type_id
      where p.schedule_day_id = d.schedule_day_id
        and p.active = true
        and pt.active = true
        and pt.deleted_at is null
    ) products on true
    left join lateral (
      select
        sum(e.estimated_kg) as history_kg,
        sum(coalesce(e.estimated_kg, p.expected_kg)) as product_kg,
        jsonb_agg(
          jsonb_build_object(
            'product_code', pt.product_code,
            'estimated_kg', e.estimated_kg,
            'history_points', coalesce(e.history_points, 0),
            'status', coalesce(e.estimate_status, 'LEARNING'),
            'manual_kg', p.expected_kg
          ) order by pt.sort_order, pt.product_code
        ) as kg_breakdown
      from public.customer_schedule_products p
      join public.product_types pt
        on pt.product_type_id = p.product_type_id
      left join estimates e
        on e.customer_id = c.customer_id
       and e.product_code = pt.product_code
       and e.production_weekday = d.production_weekday
      where p.schedule_day_id = d.schedule_day_id
        and p.active = true
        and pt.active = true
        and pt.deleted_at is null
    ) kg on true
    left join lateral (
      select
        sum(req.quantity)::integer as total_quantity,
        string_agg(
          concat(
            req.quantity,
            coalesce(tt.display_code, tt.trolley_type_code),
            ' (', owner_pt.product_code,
            case when served.product_count > 1 then ', Shared' else '' end,
            case when req.empty_trolley then ', Empty' else '' end,
            ')'
          ),
          ' + ' order by tt.sort_order, req.created_at
        ) as trolley_summary,
        jsonb_agg(
          jsonb_build_object(
            'quantity', req.quantity,
            'trolley_type_code', tt.trolley_type_code,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code),
            'owner_product_code', owner_pt.product_code,
            'serves_product_codes', served.product_codes,
            'shared', served.product_count > 1,
            'empty_trolley', req.empty_trolley,
            'notes', req.notes
          ) order by tt.sort_order, req.created_at
        ) as trolley_breakdown
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id = req.trolley_type_id
      join public.customer_schedule_products owner_product
        on owner_product.schedule_product_id = req.owner_schedule_product_id
      join public.product_types owner_pt
        on owner_pt.product_type_id = owner_product.product_type_id
      left join lateral (
        select
          count(*)::integer as product_count,
          coalesce(
            jsonb_agg(pt2.product_code order by pt2.sort_order, pt2.product_code),
            '[]'::jsonb
          ) as product_codes
        from public.customer_schedule_trolley_requirement_products map
        join public.customer_schedule_products mapped_product
          on mapped_product.schedule_product_id = map.schedule_product_id
        join public.product_types pt2
          on pt2.product_type_id = mapped_product.product_type_id
        where map.schedule_trolley_requirement_id = req.schedule_trolley_requirement_id
      ) served on true
      where req.schedule_day_id = d.schedule_day_id
        and req.active = true
        and tt.active = true
        and tt.deleted_at is null
    ) trolley on true
    where v.status = 'PUBLISHED'
      and p_effective_date >= v.effective_from
      and (v.effective_until is null or p_effective_date <= v.effective_until)
      and c.active = true
      and c.deleted_at is null
      and d.active = true
      and (
        p_delivery_weekday is null
        or public.next_distribution_weekday(d.production_weekday) = p_delivery_weekday
      )
      and (
        v_search is null
        or c.customer_name ilike '%' || v_search || '%'
        or c.customer_code ilike '%' || v_search || '%'
        or coalesce(r.route_code, '') ilike '%' || v_search || '%'
        or coalesce(r.display_name, '') ilike '%' || v_search || '%'
      )
  )
  select jsonb_build_object(
    'effective_date', p_effective_date,
    'delivery_weekday', p_delivery_weekday,
    'search', v_search,
    'route_semantics', jsonb_build_object(
      'source', 'CUSTOMER_DEFAULT_SCHEDULE',
      'delivery_rule', 'NEXT_DAY_SKIP_SUNDAY',
      'manual_daily_plan_enabled', false,
      'future_driver_assignment', 'DISTRIBUTION_ROSTER_BY_ROUTE'
    ),
    'total_count', count(*),
    'items', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'schedule_version_id', pr.schedule_version_id,
          'version_number', pr.version_number,
          'schedule_day_id', pr.schedule_day_id,
          'production_weekday', pr.production_weekday,
          'production_day', pr.production_day,
          'delivery_weekday', pr.delivery_weekday,
          'delivery_day', pr.delivery_day,
          'delivery_window_start', pr.delivery_window_start,
          'delivery_window_end', pr.delivery_window_end,
          'delivery_order', pr.delivery_order,
          'day_alert', pr.day_alert,
          'distribution_instructions', pr.distribution_instructions,
          'customer_id', pr.customer_id,
          'customer_code', pr.customer_code,
          'customer_name', pr.customer_name,
          'eircode', pr.eircode,
          'distribution_estimated_kg', pr.distribution_estimated_kg,
          'expected_kg', coalesce(pr.product_kg, pr.distribution_estimated_kg),
          'expected_kg_source', case
            when pr.history_kg is not null then 'HISTORY'
            when pr.product_kg is not null or pr.distribution_estimated_kg is not null then 'MANUAL'
            else 'NONE'
          end,
          'expected_kg_breakdown', coalesce(pr.kg_breakdown, '[]'::jsonb),
          'distribution_stop_count', pr.distribution_stop_count,
          'operational_alert', pr.operational_alert,
          'default_route_id', pr.default_route_id,
          'default_route_code', pr.default_route_code,
          'default_route_display_name', pr.default_route_display_name,
          'default_route_color', pr.default_route_color,
          'scheduled_products', pr.scheduled_products,
          'planned_trolley_total', pr.planned_trolley_total,
          'trolley_summary', pr.trolley_summary,
          'trolley_breakdown', pr.trolley_breakdown
        )
        order by
          pr.delivery_weekday nulls last,
          pr.default_route_code nulls last,
          pr.delivery_order nulls last,
          lower(pr.customer_name)
      ),
      '[]'::jsonb
    )
  ) into v_result
  from planner_rows pr;

  return v_result;
end;
$$;

revoke all on function public.get_distribution_weekly_planner(date,smallint,text) from public,anon;
grant execute on function public.get_distribution_weekly_planner(date,smallint,text) to authenticated;

-- Forward capacity: same model as Customer Master and Distribution.
create or replace function public.get_production_intelligence_forward_capacity(
  p_week_start date default null,
  p_weeks integer default 6
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_start date:=coalesce(p_week_start,(date_trunc('week',current_date)+interval '7 days')::date);
  v_weeks integer:=least(greatest(coalesce(p_weeks,6),1),12);
  v_end date;
  v_target numeric;
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_account_permission('PRODUCTION_INSIGHTS','VIEW',null) then
    raise exception using errcode='42501',message='This account cannot view Production Intelligence.';
  end if;
  if extract(isodow from v_start)<>1 then
    raise exception using errcode='22023',message='Forward capacity must start on a Monday.';
  end if;
  v_end:=v_start+(v_weeks*7-1);
  select coalesce((select target_value from public.production_targets where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR' and active limit 1),23.5) into v_target;

  with dates as (
    select d::date work_date from generate_series(v_start,v_end,interval '1 day') d where extract(isodow from d)<7
  ), schedule as (
    select d.work_date,csv.customer_id,c.customer_code,c.customer_name,pt.product_code,csp.expected_kg manual_kg,
      extract(isodow from d.work_date)::integer production_weekday
    from dates d
    join public.customer_schedule_versions csv on csv.status='PUBLISHED' and csv.effective_from<=d.work_date
      and (csv.effective_until is null or csv.effective_until>=d.work_date)
    join public.customers c on c.customer_id=csv.customer_id and c.active and c.deleted_at is null
    join public.customer_schedule_days csd on csd.schedule_version_id=csv.schedule_version_id and csd.active
      and csd.production_weekday=extract(isodow from d.work_date)::integer
    join public.customer_schedule_products csp on csp.schedule_day_id=csd.schedule_day_id and csp.active
    join public.product_types pt on pt.product_type_id=csp.product_type_id and pt.active and pt.product_code in ('CLOTHES','MOP')
  ), model as (
    select e.customer_id,e.product_code,e.production_weekday,e.history_points,e.estimated_kg forecast_kg
    from public.customer_kg_estimates(v_start,null) e
  ), demand_detail as (
    select s.*,m.history_points,coalesce(m.forecast_kg,s.manual_kg) forecast_kg
    from schedule s left join model m on m.customer_id=s.customer_id and m.product_code=s.product_code
      and m.production_weekday=s.production_weekday
  ), demand_by_day as (
    select work_date,count(*)::integer scheduled_services,
      count(*) filter(where forecast_kg is not null)::integer learned_services,
      coalesce(sum(forecast_kg),0)::numeric forecast_kg,
      coalesce(sum(forecast_kg) filter(where product_code='CLOTHES'),0)::numeric finish_forecast_kg,
      coalesce(sum(forecast_kg) filter(where product_code='MOP'),0)::numeric mop_forecast_kg,
      count(*) filter(where forecast_kg is null)::integer learning_services,
      count(*) filter(where forecast_kg is null and product_code='CLOTHES')::integer finish_learning_services
    from demand_detail group by work_date
  ), capacity_by_day as (
    select pre.work_date,count(distinct pre.staff_id)::integer finish_staff,
      sum(pwp.net_minutes/60.0)::numeric finish_staff_hours,
      sum(pwp.net_minutes/60.0*v_target)::numeric finish_capacity_kg
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id and prv.status='PUBLISHED'
    join public.production_roster_work_profiles pwp on pwp.active and pwp.shift_code=pre.shift_code_snapshot
      and extract(isodow from pre.work_date)::integer=any(pwp.iso_days)
    where pre.work_date between v_start and v_end and pre.day_status='WORKING' and pre.area_code_snapshot='FINISH'
    group by pre.work_date
  ), day_rows as (
    select d.work_date,date_trunc('week',d.work_date)::date week_start,
      coalesce(db.scheduled_services,0)::integer scheduled_services,coalesce(db.learned_services,0)::integer learned_services,
      coalesce(db.learning_services,0)::integer learning_services,round(coalesce(db.forecast_kg,0),2) forecast_kg,
      coalesce(db.finish_learning_services,0)::integer finish_learning_services,
      round(coalesce(db.finish_forecast_kg,0),2) finish_forecast_kg,round(coalesce(db.mop_forecast_kg,0),2) mop_forecast_kg,
      coalesce(cb.finish_staff,0)::integer finish_staff,round(coalesce(cb.finish_staff_hours,0),2) finish_staff_hours,
      case when cb.finish_capacity_kg is not null then round(cb.finish_capacity_kg,2) end finish_capacity_kg,
      case when coalesce(db.finish_learning_services,0)>0 then 'LEARNING'
           when cb.finish_capacity_kg is null then 'ROSTER_NOT_PUBLISHED'
           when coalesce(db.finish_forecast_kg,0)>cb.finish_capacity_kg then 'AT_RISK'
           when coalesce(db.finish_forecast_kg,0)>=cb.finish_capacity_kg*.85 then 'WATCH'
           else 'COVERED' end capacity_status
    from dates d left join demand_by_day db using(work_date) left join capacity_by_day cb using(work_date)
  ), week_rows as (
    select week_start,sum(forecast_kg)::numeric forecast_kg,sum(finish_forecast_kg)::numeric finish_forecast_kg,
      sum(mop_forecast_kg)::numeric mop_forecast_kg,
      case when count(finish_capacity_kg)>0 then sum(coalesce(finish_capacity_kg,0))::numeric end finish_capacity_kg,
      sum(scheduled_services)::integer scheduled_services,sum(learning_services)::integer learning_services,
      sum(finish_learning_services)::integer finish_learning_services,
      count(*) filter(where capacity_status='AT_RISK')::integer risk_days,
      count(*) filter(where capacity_status='ROSTER_NOT_PUBLISHED')::integer unpublished_days
    from day_rows group by week_start
  )
  select jsonb_build_object(
    'period',jsonb_build_object('from',v_start,'to',v_end,'weeks',v_weeks),
    'target_kg_per_staff_hour',v_target,
    'policy',jsonb_build_object('minimum_history_records',3,'method','RECENT_SERVICES_CAPPED_AVERAGE',
      'message','Demand uses the automatic Expected KG: average of the latest 8 official services for the same customer, product and weekday. Manual Expected KG is used while history is incomplete; without either the service remains Learning.'),
    'days',coalesce((select jsonb_agg(to_jsonb(r) order by work_date) from day_rows r),'[]'::jsonb),
    'weeks',coalesce((select jsonb_agg(to_jsonb(w) order by week_start) from week_rows w),'[]'::jsonb),
    'learning_customers',coalesce((select jsonb_agg(to_jsonb(l) order by customer_name,product_code,production_weekday) from (
      select customer_id,customer_code,customer_name,product_code,production_weekday,
        coalesce(max(history_points),0)::integer history_points,min(work_date) next_scheduled_date,
        count(distinct work_date)::integer scheduled_days
      from demand_detail where forecast_kg is null
      group by customer_id,customer_code,customer_name,product_code,production_weekday
    ) l),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_production_intelligence_forward_capacity(date,integer) from public,anon;
grant execute on function public.get_production_intelligence_forward_capacity(date,integer) to authenticated;

comment on function public.get_production_intelligence_forward_capacity(date,integer) is
  'Forward demand uses the automatic Expected KG (latest 8 official services, capped average), then manual Expected KG.';

-- Leave capacity calendar: automatic Expected KG first, then manual values.
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

  with estimates as materialized (
    select e.customer_id,e.product_code,e.production_weekday,e.estimated_kg
    from public.customer_kg_estimates(public.current_business_date(),null) e
  ), calendar as (
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
          bool_and(coalesce(est.estimated_kg,cp.expected_kg) is not null) and count(cp.*)>0 has_exact_kg,
          case when bool_and(coalesce(est.estimated_kg,cp.expected_kg) is not null) and count(cp.*)>0 then sum(coalesce(est.estimated_kg,cp.expected_kg))
            else coalesce(max(cu.distribution_estimated_kg),sum(coalesce(est.estimated_kg,cp.expected_kg)),0) end estimated_kg
        from public.customer_schedule_versions cv
        join public.customers cu on cu.customer_id=cv.customer_id and cu.active and cu.deleted_at is null
        join public.customer_schedule_days cd on cd.schedule_version_id=cv.schedule_version_id and cd.active and cd.production_weekday=extract(isodow from c.work_date)::integer
        left join public.customer_schedule_products cp on cp.schedule_day_id=cd.schedule_day_id and cp.active
        left join public.product_types cpt on cpt.product_type_id=cp.product_type_id
        left join estimates est on est.customer_id=cv.customer_id and est.product_code=cpt.product_code and est.production_weekday=cd.production_weekday
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
