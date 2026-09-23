-- ElisCaretex V2
-- Migration 041: Trolley physical dimensions + Production Tracker vehicle-load summary.
-- Stores user-confirmed master dimensions/tare weights for standard trolley types and
-- exposes them through a backward-safe Production Tracker V3 read model.

alter table public.trolley_types
  add column if not exists footprint_length_cm numeric(8,2),
  add column if not exists footprint_width_cm numeric(8,2),
  add column if not exists tare_weight_kg numeric(8,2);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='trolley_types_footprint_length_positive_ck'
      and conrelid='public.trolley_types'::regclass
  ) then
    alter table public.trolley_types
      add constraint trolley_types_footprint_length_positive_ck
      check (footprint_length_cm is null or footprint_length_cm > 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='trolley_types_footprint_width_positive_ck'
      and conrelid='public.trolley_types'::regclass
  ) then
    alter table public.trolley_types
      add constraint trolley_types_footprint_width_positive_ck
      check (footprint_width_cm is null or footprint_width_cm > 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='trolley_types_tare_weight_positive_ck'
      and conrelid='public.trolley_types'::regclass
  ) then
    alter table public.trolley_types
      add constraint trolley_types_tare_weight_positive_ck
      check (tare_weight_kg is null or tare_weight_kg > 0);
  end if;
end;
$$;

-- User-confirmed physical master data supplied 2026-08-12.
update public.trolley_types
set footprint_length_cm=68.00,
    footprint_width_cm=52.00,
    tare_weight_kg=29.20,
    updated_at=now()
where trolley_type_code='SMALL'
  and deleted_at is null;

update public.trolley_types
set footprint_length_cm=90.00,
    footprint_width_cm=70.00,
    tare_weight_kg=42.00,
    updated_at=now()
where trolley_type_code='MEDIUM'
  and deleted_at is null;

update public.trolley_types
set footprint_length_cm=91.00,
    footprint_width_cm=70.00,
    tare_weight_kg=48.60,
    updated_at=now()
where trolley_type_code='LARGE'
  and deleted_at is null;

comment on column public.trolley_types.footprint_length_cm is
'Confirmed external trolley footprint length in centimetres. Null means not yet confirmed.';
comment on column public.trolley_types.footprint_width_cm is
'Confirmed external trolley footprint width in centimetres. Null means not yet confirmed.';
comment on column public.trolley_types.tare_weight_kg is
'Confirmed trolley empty/tare weight in kilograms. Null means not yet confirmed.';

create or replace function public.get_production_tracker_v3(
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

  -- V2 remains authoritative for schedule, Washing quantity provenance,
  -- processed production quantities and typed trolley evidence. V3 only enriches
  -- trolley entries with confirmed physical dimensions/tare master data.
  v_base := public.get_production_tracker_v2(p_business_date);

  with base_items as (
    select item, ordinality
    from jsonb_array_elements(coalesce(v_base -> 'items','[]'::jsonb))
         with ordinality as x(item, ordinality)
  ),
  enriched as (
    select
      b.ordinality,
      b.item || jsonb_build_object(
        'planned_trolley_requirements', coalesce(pr.requirements,'[]'::jsonb),
        'mop_trolleys', coalesce(mt.trolleys,'[]'::jsonb),
        'lifecycle_trolleys', coalesce(lt.trolleys,'[]'::jsonb)
      ) as item
    from base_items b
    left join lateral (
      select coalesce(jsonb_agg(
        r.value || jsonb_build_object(
          'footprint_length_cm',tt.footprint_length_cm,
          'footprint_width_cm',tt.footprint_width_cm,
          'footprint_area_m2',case
            when tt.footprint_length_cm is not null and tt.footprint_width_cm is not null
              then round((tt.footprint_length_cm*tt.footprint_width_cm/10000.0)::numeric,4)
            else null
          end,
          'tare_weight_kg',tt.tare_weight_kg,
          'physical_master_complete',
            tt.footprint_length_cm is not null
            and tt.footprint_width_cm is not null
            and tt.tare_weight_kg is not null
        ) order by r.ordinality),'[]'::jsonb) as requirements
      from jsonb_array_elements(coalesce(b.item -> 'planned_trolley_requirements','[]'::jsonb))
           with ordinality as r(value, ordinality)
      left join public.trolley_types tt
        on tt.trolley_type_id=nullif(r.value ->> 'trolley_type_id','')::uuid
       and tt.deleted_at is null
    ) pr on true
    left join lateral (
      select coalesce(jsonb_agg(
        t.value || jsonb_build_object(
          'footprint_length_cm',tt.footprint_length_cm,
          'footprint_width_cm',tt.footprint_width_cm,
          'footprint_area_m2',case
            when tt.footprint_length_cm is not null and tt.footprint_width_cm is not null
              then round((tt.footprint_length_cm*tt.footprint_width_cm/10000.0)::numeric,4)
            else null
          end,
          'tare_weight_kg',tt.tare_weight_kg,
          'physical_master_complete',
            tt.footprint_length_cm is not null
            and tt.footprint_width_cm is not null
            and tt.tare_weight_kg is not null
        ) order by t.ordinality),'[]'::jsonb) as trolleys
      from jsonb_array_elements(coalesce(b.item -> 'mop_trolleys','[]'::jsonb))
           with ordinality as t(value, ordinality)
      left join public.trolley_types tt
        on tt.trolley_type_id=nullif(t.value ->> 'trolley_type_id','')::uuid
       and tt.deleted_at is null
    ) mt on true
    left join lateral (
      select coalesce(jsonb_agg(
        t.value || jsonb_build_object(
          'footprint_length_cm',tt.footprint_length_cm,
          'footprint_width_cm',tt.footprint_width_cm,
          'footprint_area_m2',case
            when tt.footprint_length_cm is not null and tt.footprint_width_cm is not null
              then round((tt.footprint_length_cm*tt.footprint_width_cm/10000.0)::numeric,4)
            else null
          end,
          'tare_weight_kg',tt.tare_weight_kg,
          'physical_master_complete',
            tt.footprint_length_cm is not null
            and tt.footprint_width_cm is not null
            and tt.tare_weight_kg is not null
        ) order by t.ordinality),'[]'::jsonb) as trolleys
      from jsonb_array_elements(coalesce(b.item -> 'lifecycle_trolleys','[]'::jsonb))
           with ordinality as t(value, ordinality)
      left join public.trolley_types tt
        on tt.trolley_type_id=nullif(t.value ->> 'trolley_type_id','')::uuid
       and tt.deleted_at is null
    ) lt on true
  )
  select coalesce(jsonb_agg(e.item order by e.ordinality),'[]'::jsonb)
  into v_items
  from enriched e;

  return (v_base - 'schema_version' - 'source_contract' - 'trolley_capacity_area_contract' - 'items') || jsonb_build_object(
    'schema_version','PRODUCTION_TRACKER_V3',
    'source_contract','PRODUCTION_FLOW_SHARED_TRACKER_V3',
    'trolley_physical_master_contract','CONFIRMED_FOOTPRINT_AND_TARE_WEIGHT',
    'route_vehicle_load_contract','ACTUAL_FOOTPRINT_AND_TARE_PLUS_RECORDED_PROCESSED_KG',
    'truck_capacity_contract','PENDING_TRUCK_MASTER_CAPACITY',
    'items',v_items
  );
end;
$function$;

revoke all on function public.get_production_tracker_v3(date) from public;
revoke all on function public.get_production_tracker_v3(date) from anon;
grant execute on function public.get_production_tracker_v3(date) to authenticated;

comment on function public.get_production_tracker_v3(date) is
'Governed shared Production Tracker V3. Enriches V2 trolley evidence with confirmed footprint dimensions and tare weights. Route vehicle-load UI may sum actual trolley footprint/tare plus recorded processed KG, but must label weight partial until all production streams have recorded processed KG. Truck capacity remains pending confirmed vehicle master data.';
