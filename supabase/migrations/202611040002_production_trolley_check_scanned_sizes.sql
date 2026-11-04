-- =====================================================================
-- ElisCaretex V2
-- End-of-shift trolley check: size and origin of the scanned trolleys
--
-- Owner request 2026-11-04 (after 202611040001): the customer sheet must show
-- the size of each scanned trolley and, for customers with Clothes and MOP,
-- whether the trolley was recorded by Finish or by MOP Production.
--
-- Only production_trolley_check_expected changes: recorded_trolleys is now a
-- list of {code, size, size_name, source} instead of a list of codes
-- (source FINISH = trolley on the Clothes row, MOP = trolley on the MOP row),
-- and planned_by_source gives the planned trolleys per area by size, so the page
-- can summarise planned vs scanned and say where the difference is.
-- Results saved before this migration keep the old snapshot format; the page
-- reads both. No table, data or permission change.
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
      sum(case when upper(x.i->>'product_code') = 'CLOTHES' then coalesce((x.i->>'processed_quantity_kg')::numeric,0) else 0 end) clothes_kg
    from items x
    group by 1
  )
  select pc.cid, pc.cname, pc.rcode, pc.rname, pc.rcolor, pc.porder, pc.sched,
    jsonb_build_object(
      'has_clothes', pc.has_clothes,
      'has_mop', pc.has_mop,
      'clothes_recorded', pc.clothes_recorded,
      'mop_recorded', pc.mop_recorded,
      'clothes_kg', round(pc.clothes_kg, 2),
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
  from per_customer pc;
end;
$$;
revoke all on function public.production_trolley_check_expected(date) from public, anon, authenticated;
