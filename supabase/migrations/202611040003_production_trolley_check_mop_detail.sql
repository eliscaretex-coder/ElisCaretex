-- =====================================================================
-- ElisCaretex V2
-- End-of-shift trolley check: MOP detail (type, units, kg) and ABS status
--
-- Owner request 2026-11-04: for MOP customers the customer sheet must show
-- each MOP type with its units and kg, and whether the batch was recorded in
-- ABS. Replaces production_trolley_check_expected (built on
-- 202611040002_production_trolley_check_scanned_sizes.sql) to add mop_kg,
-- mop_lines [{type, units, weight_kg, unit_weight_grams}], mop_abs_recorded
-- and mop_abs [{batch_reference, quantity, unit_code, recorded_by,
-- recorded_at}]. Values come from get_production_tracker_v4 (MOP Production
-- lines and ABS batches). No table, data or permission change.
-- =====================================================================

create or replace function public.production_trolley_check_expected(p_business_date date)
returns table (
  customer_id uuid,
  customer_name text,
  route_code text,
  route_display_name text,
  route_color text,
  production_order integer,
  scheduled boolean,
  expected jsonb
)
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_tracker jsonb;
begin
  v_tracker := public.get_production_tracker_v4(p_business_date);

  return query
  with items as (
    select i
    from jsonb_array_elements(coalesce(v_tracker->'items','[]'::jsonb)) i
    where nullif(i->>'customer_id','') is not null
  ), req as (
    select (x.i->>'customer_id')::uuid cid,
      case when upper(x.i->>'product_code') = 'MOP' then 'MOP' else 'FINISH' end source,
      upper(coalesce(r->>'display_code', r->>'trolley_type_code', '?')) type_code,
      coalesce((r->>'empty_trolley')::boolean, false) is_empty,
      coalesce((r->>'quantity')::integer, 0) qty
    from items x, jsonb_array_elements(coalesce(x.i->'planned_trolley_requirements','[]'::jsonb)) r
  ), req_types as (
    select cid, is_empty, type_code, sum(qty)::integer qty from req group by cid, is_empty, type_code
  ), recorded as (
    -- One row per scanned trolley, with its size and the area that recorded it:
    -- trolleys on the Clothes row come from Finish, trolleys on the MOP row from MOP Production.
    select (x.i->>'customer_id')::uuid cid,
      btrim(t->>'trolley_code') code,
      case when upper(x.i->>'product_code') = 'MOP' then 'MOP' else 'FINISH' end source,
      max(upper(coalesce(nullif(t->>'display_code',''), nullif(t->>'trolley_type_code',''), '?'))) size_code,
      max(t->>'trolley_type_name') size_name
    from items x,
      jsonb_array_elements(coalesce(x.i->'lifecycle_trolleys','[]'::jsonb) || coalesce(x.i->'mop_trolleys','[]'::jsonb)) t
    where nullif(btrim(t->>'trolley_code'),'') is not null
    group by 1, 2, 3
  ), per_customer as (
    select (x.i->>'customer_id')::uuid cid,
      max(x.i->>'customer_name') cname,
      max(x.i->>'route_code') rcode,
      max(x.i->>'route_display_name') rname,
      max(x.i->>'route_color') rcolor,
      min(nullif(x.i->>'production_order','')::integer) porder,
      bool_or(coalesce((x.i->>'scheduled')::boolean, false)) sched,
      bool_or(upper(x.i->>'product_code') = 'CLOTHES') has_clothes,
      bool_or(upper(x.i->>'product_code') = 'MOP') has_mop,
      bool_or(upper(x.i->>'product_code') = 'CLOTHES' and coalesce((x.i->>'finish_contribution_count')::integer,0) > 0) clothes_recorded,
      bool_or(upper(x.i->>'product_code') = 'MOP' and nullif(x.i->>'mop_production_batch_id','') is not null) mop_recorded,
      sum(case when upper(x.i->>'product_code') = 'CLOTHES' then coalesce((x.i->>'processed_quantity_kg')::numeric,0) else 0 end) clothes_kg,
      sum(case when upper(x.i->>'product_code') = 'MOP' then coalesce((x.i->>'processed_weight_kg')::numeric,0) else 0 end) mop_kg
    from items x
    group by 1
  ), mop_lines as (
    -- MOP Production lines (type, units, kg) of the MOP row, one entry per line.
    select (x.i->>'customer_id')::uuid cid,
      jsonb_agg(jsonb_build_object(
        'type', coalesce(nullif(pl->>'variant_name',''), nullif(pl->>'variant_code',''), 'MOP'),
        'units', nullif(pl->>'units','')::numeric,
        'weight_kg', nullif(pl->>'weight_kg','')::numeric,
        'unit_weight_grams', nullif(pl->>'unit_weight_grams','')::numeric)
        order by coalesce(nullif(pl->>'variant_name',''), nullif(pl->>'variant_code',''))) lines
    from items x, jsonb_array_elements(coalesce(x.i->'production_lines','[]'::jsonb)) pl
    where upper(x.i->>'product_code') = 'MOP'
    group by 1
  ), mop_abs as (
    -- ABS batches recorded for the MOP row.
    select (x.i->>'customer_id')::uuid cid,
      jsonb_agg(jsonb_build_object(
        'batch_reference', a->>'batch_reference',
        'quantity', nullif(a->>'quantity','')::numeric,
        'unit_code', a->>'unit_code',
        'recorded_by', a->>'recorded_by',
        'recorded_at', a->>'recorded_at') order by a->>'recorded_at') batches
    from items x, jsonb_array_elements(coalesce(x.i->'abs_details','[]'::jsonb)) a
    where upper(x.i->>'product_code') = 'MOP'
    group by 1
  )
  select pc.cid, pc.cname, pc.rcode, pc.rname, pc.rcolor, pc.porder, pc.sched,
    jsonb_build_object(
      'has_clothes', pc.has_clothes,
      'has_mop', pc.has_mop,
      'clothes_recorded', pc.clothes_recorded,
      'mop_recorded', pc.mop_recorded,
      'clothes_kg', round(pc.clothes_kg, 2),
      'mop_kg', round(pc.mop_kg, 2),
      'mop_lines', coalesce(ml.lines, '[]'::jsonb),
      'mop_abs_recorded', ma.batches is not null,
      'mop_abs', coalesce(ma.batches, '[]'::jsonb),
      'planned_trolleys', coalesce((select sum(rt.qty) from req_types rt where rt.cid = pc.cid and not rt.is_empty), 0),
      'planned_empty_trolleys', coalesce((select sum(rt.qty) from req_types rt where rt.cid = pc.cid and rt.is_empty), 0),
      'planned_types', coalesce((select jsonb_agg(jsonb_build_object('type', rt.type_code, 'quantity', rt.qty) order by rt.type_code)
                                 from req_types rt where rt.cid = pc.cid and not rt.is_empty and rt.qty > 0), '[]'::jsonb),
      'planned_empty_types', coalesce((select jsonb_agg(jsonb_build_object('type', rt.type_code, 'quantity', rt.qty) order by rt.type_code)
                                 from req_types rt where rt.cid = pc.cid and rt.is_empty and rt.qty > 0), '[]'::jsonb),
      -- Planned (non-empty) trolleys per area, to compare with what each area scanned.
      'planned_by_source', coalesce((select jsonb_object_agg(ps.source, ps.types) from (
          select rq.source, jsonb_agg(jsonb_build_object('type', rq.type_code, 'quantity', rq.qty) order by rq.type_code) types
          from (select r2.source, r2.type_code, sum(r2.qty)::integer qty from req r2
                where r2.cid = pc.cid and not r2.is_empty group by 1, 2) rq
          where rq.qty > 0 group by rq.source) ps), '{}'::jsonb),
      'recorded_trolleys', coalesce((select jsonb_agg(jsonb_build_object('code', rc.code, 'size', rc.size_code, 'size_name', rc.size_name, 'source', rc.source)
                                     order by rc.source, rc.size_code, rc.code)
                                     from recorded rc where rc.cid = pc.cid), '[]'::jsonb)
    )
  from per_customer pc
  left join mop_lines ml on ml.cid = pc.cid
  left join mop_abs ma on ma.cid = pc.cid;
end;
$$;
revoke all on function public.production_trolley_check_expected(date) from public, anon, authenticated;
