-- ElisCaretex V2
-- Migration 040: Production Tracker quantity clarity + Route trolley load.
-- Adds a backward-safe V2 read model. No source-table write behavior changes.

create or replace function public.get_production_tracker_v2(
  p_business_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $function$
declare
  v_base jsonb;
  v_items jsonb;
begin
  perform public.require_production_flow_read_role();

  -- Keep the established V1 Production Flow read model authoritative for schedule,
  -- Washing, MOP Production and ABS. V2 enriches it with quantity provenance and
  -- typed physical/planned trolley evidence for Route readiness.
  v_base := public.get_production_tracker_v1(p_business_date);

  with base_items as (
    select item, ordinality
    from jsonb_array_elements(coalesce(v_base -> 'items', '[]'::jsonb))
         with ordinality as x(item, ordinality)
  ),
  enriched as (
    select
      b.ordinality,
      b.item || jsonb_build_object(
        'washed_quantity_kg', nullif(b.item ->> 'washed_kg_total', '')::numeric,
        'washed_quantity_units', null,
        'washed_quantity_basis', wb.quantity_basis,
        'washed_units_source', 'NOT_MEASURED_IN_WASHING',
        'processed_quantity_kg', nullif(b.item ->> 'processed_weight_kg', '')::numeric,
        'processed_quantity_units', nullif(b.item ->> 'processed_units', '')::integer,
        'processed_quantity_source', case
          when upper(coalesce(b.item ->> 'product_code',''))='MOP'
               and nullif(b.item ->> 'mop_production_batch_id','') is not null
            then 'MOP_PRODUCTION'
          when upper(coalesce(b.item ->> 'product_code',''))='CLOTHES'
            then 'FINISH_PENDING'
          else 'NOT_RECORDED'
        end,
        'planned_trolley_quantity', coalesce(pt.planned_quantity,0),
        'planned_trolley_requirements', coalesce(pt.requirements,'[]'::jsonb),
        'mop_trolleys', coalesce(mt.trolleys,'[]'::jsonb),
        'lifecycle_trolleys', coalesce(lt.trolleys,'[]'::jsonb)
      ) as item
    from base_items b
    left join lateral (
      select case
        when count(*)=0 then null
        when bool_and(wrc.weight_allocation_method='FULL_LOAD') then 'FULL_LOAD'
        when bool_and(wrc.weight_allocation_method='EQUAL_SPLIT_ESTIMATE') then 'EQUAL_SPLIT_ESTIMATE'
        else 'MIXED_WASH_ALLOCATION'
      end as quantity_basis
      from public.sorting_wash_run_customers wrc
      join public.sorting_wash_runs wr
        on wr.wash_run_id=wrc.wash_run_id
       and wr.status='RECORDED'
      where wrc.production_flow_item_id=nullif(b.item ->> 'production_flow_item_id','')::uuid
    ) wb on true
    left join lateral (
      select
        coalesce(sum(req.quantity),0)::integer as planned_quantity,
        coalesce(
          jsonb_agg(
            jsonb_build_object(
              'trolley_type_id',tt.trolley_type_id,
              'trolley_type_code',tt.trolley_type_code,
              'display_code',tt.display_code,
              'trolley_type_name',tt.trolley_type_name,
              'trolley_category',tt.trolley_category,
              'quantity',req.quantity,
              'empty_trolley',req.empty_trolley
            )
            order by tt.sort_order,tt.display_code,tt.trolley_type_code
          ),
          '[]'::jsonb
        ) as requirements
      from public.customer_schedule_trolley_requirements req
      join public.trolley_types tt
        on tt.trolley_type_id=req.trolley_type_id
       and tt.active=true
       and tt.deleted_at is null
      where req.owner_schedule_product_id=nullif(b.item ->> 'schedule_product_id','')::uuid
        and req.active=true
    ) pt on true
    left join lateral (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'trolley_code',mtx.trolley_code_snapshot,
            'trolley_id',coalesce(mtx.trolley_id,t.trolley_id),
            'trolley_type_id',tt.trolley_type_id,
            'trolley_type_code',tt.trolley_type_code,
            'display_code',tt.display_code,
            'trolley_type_name',tt.trolley_type_name,
            'trolley_category',tt.trolley_category,
            'lifecycle_action',mtx.lifecycle_action,
            'stay_id',mtx.stay_id
          )
          order by mtx.created_at,mtx.trolley_code_snapshot
        ),
        '[]'::jsonb
      ) as trolleys
      from public.sorting_mop_production_trolleys mtx
      left join public.trolleys t
        on t.deleted_at is null
       and (
         t.trolley_id=mtx.trolley_id
         or (
           mtx.trolley_id is null
           and upper(t.trolley_code)=upper(mtx.trolley_code_snapshot)
         )
       )
      left join public.trolley_types tt
        on tt.trolley_type_id=t.trolley_type_id
       and tt.deleted_at is null
      where mtx.mop_production_batch_id=nullif(b.item ->> 'mop_production_batch_id','')::uuid
    ) mt on true
    left join lateral (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'trolley_code',t.trolley_code,
            'trolley_id',t.trolley_id,
            'trolley_type_id',tt.trolley_type_id,
            'trolley_type_code',tt.trolley_type_code,
            'display_code',tt.display_code,
            'trolley_type_name',tt.trolley_type_name,
            'trolley_category',tt.trolley_category,
            'lifecycle_action','PRODUCTION_ASSIGNMENT',
            'stay_id',s.stay_id
          )
          order by t.trolley_code
        ),
        '[]'::jsonb
      ) as trolleys
      from public.trolley_customer_stays s
      join public.trolleys t
        on t.trolley_id=s.trolley_id
       and t.deleted_at is null
      left join public.trolley_types tt
        on tt.trolley_type_id=t.trolley_type_id
       and tt.deleted_at is null
      where s.source_schedule_product_id=nullif(b.item ->> 'schedule_product_id','')::uuid
        and s.production_business_date=(v_base ->> 'business_date')::date
    ) lt on true
  )
  select coalesce(jsonb_agg(e.item order by e.ordinality),'[]'::jsonb)
  into v_items
  from enriched e;

  return (v_base - 'schema_version' - 'source_contract' - 'items') || jsonb_build_object(
    'schema_version','PRODUCTION_TRACKER_V2',
    'source_contract','PRODUCTION_FLOW_SHARED_TRACKER_V2',
    'quantity_contract','WASHED_ESTIMATE_VS_PROCESSED_ACTUAL',
    'route_trolley_contract','PHYSICAL_TYPED_TROLLEYS_PLUS_SCHEDULE_REQUIREMENTS',
    'trolley_capacity_area_contract','PENDING_MASTER_DIMENSIONS',
    'items',v_items
  );
end;
$function$;

revoke all on function public.get_production_tracker_v2(date) from public;
revoke all on function public.get_production_tracker_v2(date) from anon;
grant execute on function public.get_production_tracker_v2(date) to authenticated;

comment on function public.get_production_tracker_v2(date) is
'Governed shared Production Tracker V2. Adds explicit washed quantity provenance, processed actual quantities, schedule-owned trolley requirements, and physical trolley type evidence for Route readiness. Trolley footprint/capacity dimensions are intentionally not invented and remain pending master data.';
