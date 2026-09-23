-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608110006_sorting_trolley_contract_sizes_and_reception_status
--
-- Reception lateral board must show the published trolley contract by type,
-- not only an aggregated trolley count.
--
-- This migration changes only the controlled Reception read model.
-- Protected schedule / intake source tables remain private.
-- =====================================================================

begin;

create or replace function public.get_sorting_trolley_intake_context_v2(
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := public.operational_business_date_for_shift(p_shift_code);
  v_shift_id uuid;
  v_board jsonb := '[]'::jsonb;
  v_queue jsonb := '[]'::jsonb;
  v_recent jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  select sh.shift_id
  into v_shift_id
  from public.shifts sh
  where sh.shift_code=upper(trim(coalesce(p_shift_code,'')))
    and sh.active=true
    and sh.deleted_at is null
  limit 1;

  if v_shift_id is null then
    raise exception using errcode='P0002', message='Selected shift is not available.';
  end if;

  with board_days as (
    select v_business_date-1 as scheduled_for_date, 'YESTERDAY'::text as day_relation, -1 as day_offset
    union all
    select v_business_date, 'TODAY'::text, 0
    union all
    select v_business_date+1, 'TOMORROW'::text, 1
  ),
  scheduled as (
    select
      bd.scheduled_for_date,
      bd.day_relation,
      bd.day_offset,
      c.customer_id,
      c.customer_code,
      c.customer_name,
      pt.product_code,
      sp.production_order,
      sp.production_instructions,
      csv.schedule_version_id,
      sd.schedule_day_id,
      sp.schedule_product_id,
      r.route_id,
      r.route_code,
      r.display_name as route_display_name,
      r.route_color,
      coalesce((
        select sum(req.quantity)::integer
        from public.customer_schedule_trolley_requirements req
        where req.schedule_day_id=sd.schedule_day_id
          and req.owner_schedule_product_id=sp.schedule_product_id
          and req.active=true
      ),0) as planned_trolley_quantity,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'trolley_type_id',req.trolley_type_id,
            'trolley_type_code',tt.trolley_type_code,
            'display_code',tt.display_code,
            'trolley_type_name',tt.trolley_type_name,
            'quantity',req.quantity,
            'empty_trolley',req.empty_trolley
          )
          order by tt.sort_order,tt.display_code,tt.trolley_type_code
        )
        from public.customer_schedule_trolley_requirements req
        join public.trolley_types tt
          on tt.trolley_type_id=req.trolley_type_id
         and tt.active=true
         and tt.deleted_at is null
        where req.schedule_day_id=sd.schedule_day_id
          and req.owner_schedule_product_id=sp.schedule_product_id
          and req.active=true
      ),'[]'::jsonb) as trolley_requirements
    from board_days bd
    join public.customer_schedule_versions csv
      on csv.status='PUBLISHED'
     and csv.effective_from<=bd.scheduled_for_date
     and (csv.effective_until is null or csv.effective_until>=bd.scheduled_for_date)
    join public.customers c
      on c.customer_id=csv.customer_id
     and c.active=true
     and c.deleted_at is null
    join public.customer_schedule_days sd
      on sd.schedule_version_id=csv.schedule_version_id
     and sd.active=true
     and sd.production_weekday=extract(isodow from bd.scheduled_for_date)::smallint
    join public.customer_schedule_products sp
      on sp.schedule_day_id=sd.schedule_day_id
     and sp.active=true
    join public.product_types pt
      on pt.product_type_id=sp.product_type_id
     and pt.active=true
     and pt.deleted_at is null
     and pt.product_code in ('CLOTHES','MOP')
    left join public.distribution_routes r
      on r.route_id=sd.default_route_id
     and r.deleted_at is null
  ),
  enriched as (
    select
      s.*,
      coalesce(i.received_count,0) as received_count,
      coalesce(i.contents_count,0) as contents_count,
      coalesce(i.empty_count,0) as empty_count,
      coalesce(i.review_count,0) as review_count,
      i.first_received_at,
      i.last_received_at,
      coalesce(i.trolley_codes,'[]'::jsonb) as trolley_codes,
      coalesce(w.wash_count,0) as wash_count,
      w.last_wash_code,
      pfi.production_flow_item_id,
      coalesce(pfi.washed_kg_total,0) as flow_washed_kg,
      public.sorting_trolley_receipt_status(
        s.planned_trolley_quantity,
        coalesce(i.received_count,0)
      ) as receipt_status,
      public.sorting_trolley_intake_state(
        s.planned_trolley_quantity,
        coalesce(i.received_count,0),
        coalesce(i.contents_count,0),
        coalesce(i.empty_count,0),
        coalesce(w.wash_count,0),
        coalesce(i.review_count,0)
      ) as operational_state
    from scheduled s
    left join lateral (
      select
        count(*)::integer as received_count,
        count(*) filter (where sti.contents_status='CONTENTS')::integer as contents_count,
        count(*) filter (where sti.contents_status='EMPTY')::integer as empty_count,
        count(*) filter (where sti.review_status in ('PENDING','UNDER_REVIEW'))::integer as review_count,
        min(sti.arrived_at) as first_received_at,
        max(sti.arrived_at) as last_received_at,
        jsonb_agg(
          jsonb_build_object(
            'trolley_code',sti.trolley_code_snapshot,
            'trolley_type_code',tt.trolley_type_code,
            'trolley_display_code',tt.display_code,
            'trolley_type_name',tt.trolley_type_name,
            'contents_status',sti.contents_status,
            'arrived_at',sti.arrived_at,
            'review_status',sti.review_status
          )
          order by sti.arrived_at
        ) as trolley_codes
      from public.sorting_trolley_intake_products stip
      join public.sorting_trolley_intakes sti
        on sti.sorting_trolley_intake_id=stip.sorting_trolley_intake_id
      join public.trolleys t
        on t.trolley_id=sti.trolley_id
      join public.trolley_types tt
        on tt.trolley_type_id=t.trolley_type_id
      where stip.source_schedule_product_id=s.schedule_product_id
        and stip.scheduled_for_date=s.scheduled_for_date
        and sti.customer_id=s.customer_id
    ) i on true
    left join lateral (
      select
        count(*)::integer as wash_count,
        (
          select wr2.wash_code
          from public.sorting_wash_run_customers wrc2
          join public.sorting_wash_runs wr2 on wr2.wash_run_id=wrc2.wash_run_id
          where wr2.status='RECORDED'
            and wrc2.customer_id=s.customer_id
            and wrc2.source_schedule_product_id=s.schedule_product_id
            and wrc2.scheduled_for_date=s.scheduled_for_date
          order by wr2.started_at desc,wr2.created_at desc
          limit 1
        ) as last_wash_code
      from public.sorting_wash_run_customers wrc
      join public.sorting_wash_runs wr on wr.wash_run_id=wrc.wash_run_id
      where wr.status='RECORDED'
        and wrc.customer_id=s.customer_id
        and wrc.source_schedule_product_id=s.schedule_product_id
        and wrc.scheduled_for_date=s.scheduled_for_date
    ) w on true
    left join public.production_flow_items pfi
      on pfi.customer_id=s.customer_id
     and pfi.product_code=s.product_code
     and pfi.scheduled_for_date=s.scheduled_for_date
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id',e.customer_id,
      'customer_code',e.customer_code,
      'customer_name',e.customer_name,
      'product_code',e.product_code,
      'scheduled_for_date',e.scheduled_for_date,
      'day_relation',e.day_relation,
      'day_offset',e.day_offset,
      'production_order',e.production_order,
      'production_instructions',e.production_instructions,
      'schedule_version_id',e.schedule_version_id,
      'schedule_day_id',e.schedule_day_id,
      'schedule_product_id',e.schedule_product_id,
      'route_id',e.route_id,
      'route_code',e.route_code,
      'route_display_name',e.route_display_name,
      'route_color',e.route_color,
      'planned_trolley_quantity',e.planned_trolley_quantity,
      'trolley_requirements',e.trolley_requirements,
      'received_count',e.received_count,
      'contents_count',e.contents_count,
      'empty_count',e.empty_count,
      'review_count',e.review_count,
      'receipt_status',e.receipt_status,
      'operational_state',e.operational_state,
      'nothing_to_wash',e.operational_state='NOTHING_TO_WASH',
      'waiting_wash',e.operational_state='WAITING_WASH',
      'wash_count',e.wash_count,
      'last_wash_code',e.last_wash_code,
      'first_received_at',e.first_received_at,
      'last_received_at',e.last_received_at,
      'trolleys',e.trolley_codes,
      'production_flow_item_id',e.production_flow_item_id,
      'flow_washed_kg',e.flow_washed_kg
    )
    order by
      e.day_offset,
      case e.product_code when 'CLOTHES' then 1 else 2 end,
      e.production_order nulls last,
      lower(e.customer_name)
  ),'[]'::jsonb)
  into v_board
  from enriched e;

  with board as (
    select value as row
    from jsonb_array_elements(v_board)
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id',row->>'customer_id',
      'customer_name',row->>'customer_name',
      'product_code',row->>'product_code',
      'scheduled_for_date',row->>'scheduled_for_date',
      'day_relation',row->>'day_relation',
      'route_code',row->>'route_code',
      'route_display_name',row->>'route_display_name',
      'route_color',row->>'route_color',
      'received_count',(row->>'received_count')::integer,
      'planned_trolley_quantity',(row->>'planned_trolley_quantity')::integer,
      'first_received_at',row->>'first_received_at',
      'production_flow_item_id',row->>'production_flow_item_id'
    )
    order by (row->>'first_received_at')::timestamptz,
             (row->>'production_order')::integer nulls last,
             lower(row->>'customer_name')
  ),'[]'::jsonb)
  into v_queue
  from board
  where row->>'operational_state'='WAITING_WASH'
    and row->>'day_relation' in ('TODAY','TOMORROW');

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'sorting_trolley_intake_id',q.sorting_trolley_intake_id,
      'trolley_code',q.trolley_code_snapshot,
      'customer_id',q.customer_id,
      'customer_name',q.customer_name_snapshot,
      'business_date',q.business_date,
      'physical_received_on',q.physical_received_on,
      'shift_code',q.shift_code_snapshot,
      'arrived_at',q.arrived_at,
      'contents_status',q.contents_status,
      'product_scope',q.product_scope,
      'scheduled_for_date',q.scheduled_for_date,
      'schedule_relation',q.schedule_relation,
      'review_status',q.review_status,
      'exception_type',q.exception_type,
      'operator_staff_id',q.operator_staff_id,
      'operator_name',operator.display_name,
      'notes',q.notes,
      'products',coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'product_code',p.product_code,
            'production_flow_item_id',p.production_flow_item_id,
            'route_code',p.route_code_snapshot,
            'route_display_name',p.route_display_name_snapshot
          )
          order by p.product_code
        )
        from public.sorting_trolley_intake_products p
        where p.sorting_trolley_intake_id=q.sorting_trolley_intake_id
      ),'[]'::jsonb)
    )
    order by q.arrived_at desc
  ),'[]'::jsonb)
  into v_recent
  from (
    select *
    from public.sorting_trolley_intakes sti
    where sti.business_date=v_business_date
      and sti.shift_id=v_shift_id
    order by sti.arrived_at desc
    limit 30
  ) q
  left join public.staff_members operator
    on operator.staff_id=q.operator_staff_id;

  return jsonb_build_object(
    'business_date',v_business_date,
    'physical_date',current_date,
    'shift_code',upper(trim(p_shift_code)),
    'board',v_board,
    'waiting_queue',v_queue,
    'recent_intakes',v_recent,
    'summary',jsonb_build_object(
      'received_today',(
        select count(*)
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
      ),
      'contents_today',(
        select count(*)
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and sti.contents_status='CONTENTS'
      ),
      'empty_today',(
        select count(*)
        from public.sorting_trolley_intakes sti
        where sti.business_date=v_business_date
          and sti.shift_id=v_shift_id
          and sti.contents_status='EMPTY'
      ),
      'waiting_wash',jsonb_array_length(v_queue)
    ),
    'source','PUBLISHED_SCHEDULE_PLUS_PHYSICAL_TROLLEY_INTAKE'
  );
end;
$$;


revoke all on function public.get_sorting_trolley_intake_context_v2(text)
  from public, anon, authenticated;
grant execute on function public.get_sorting_trolley_intake_context_v2(text)
  to authenticated;

comment on function public.get_sorting_trolley_intake_context_v2(text) is
  'Controlled Sorting Reception context. Board rows expose published trolley requirements by physical type/size plus received physical trolley type evidence and Washing state.';

commit;
