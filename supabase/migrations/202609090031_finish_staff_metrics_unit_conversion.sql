begin;

create or replace function public.get_finish_staff_context_v4(
  p_shift_code text default 'MORNING',
  p_at timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_base jsonb; v_staff jsonb; v_tables jsonb; v_business_date date; v_units_per_kg numeric:=6;
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_staff_context_v3(p_shift_code,p_at);
  v_business_date:=nullif(v_base->>'business_date','')::date;
  select coalesce((select target_value from public.production_targets where target_code='FINISH_UNITS_PER_KG' and active=true limit 1),6) into v_units_per_kg;
  v_units_per_kg:=greatest(v_units_per_kg,0.001);

  select coalesce(jsonb_agg(br.item||jsonb_build_object('is_sorting_cover',exists(
    select 1 from public.staff_cover_capabilities scc join public.operational_roles role on role.operational_role_id=scc.operational_role_id
    where scc.staff_id=nullif(br.item->>'staff_id','')::uuid and role.role_code='SORTING_AREA' and scc.active=true and scc.deleted_at is null
      and scc.effective_from<=v_business_date and(scc.effective_until is null or scc.effective_until>=v_business_date)
  )) order by br.ordinality),'[]'::jsonb) into v_staff
  from jsonb_array_elements(coalesce(v_base->'staff','[]'::jsonb)) with ordinality br(item,ordinality);

  with base_tables as (select value item from jsonb_array_elements(coalesce(v_base->'tables','[]'::jsonb)))
  select coalesce(jsonb_agg(item||jsonb_build_object(
    'recorded_kg',coalesce((item->>'produced_kg')::numeric,0),
    'units_kg_equivalent',round(coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg,2),
    'produced_kg',coalesce((item->>'produced_kg')::numeric,0)+coalesce((item->>'produced_units')::numeric,0)/v_units_per_kg
  ) order by item->>'table_code'),'[]'::jsonb) into v_tables
  from base_tables;

  return(v_base-'schema_version'-'source_contract'-'staff'-'tables')||jsonb_build_object(
    'schema_version','FINISH_STAFF_V4','source_contract','PUBLISHED_ROSTER_PLUS_ATTENDANCE_TABLE_SEGMENTS_AND_SORTING_COVER_CAPABILITY',
    'units_per_kg',v_units_per_kg,'staff',v_staff,'tables',v_tables
  );
end;
$$;

revoke all on function public.get_finish_staff_context_v4(text,timestamptz) from public,anon;
grant execute on function public.get_finish_staff_context_v4(text,timestamptz) to authenticated;

commit;
