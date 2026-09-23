-- =====================================================================
-- ElisCaretex V2
-- Migration 048: Finish processed-by availability follows Roster Planned
--                with Actual work_sessions override
--
-- PREPARED: owner executes in Development.
--
-- Why:
-- Migration 047 required an explicit Finish work_session before a staff member
-- appeared in Processed by. In normal operation the published Production Roster
-- is the planned baseline, exactly as in Sorting. Actual work_sessions override
-- that baseline when the person is moved/adjusted.
-- =====================================================================

begin;

create or replace function public.finish_processing_staff_available(
  p_staff_id uuid,
  p_business_date date,
  p_shift_id uuid,
  p_station_id uuid,
  p_at timestamptz default now()
)
returns boolean
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_ws public.work_sessions%rowtype;
  v_ws_area text;
  v_at timestamptz:=coalesce(p_at,now());
begin
  if p_staff_id is null or p_business_date is null or p_shift_id is null or p_station_id is null then
    return false;
  end if;

  if not exists(
    select 1
    from public.staff_members sm
    where sm.staff_id=p_staff_id
      and sm.production_staff=true
      and sm.active=true
      and sm.roster_eligible=true
      and sm.deleted_at is null
  ) then
    return false;
  end if;

  -- Actual overrides Planned. Use the latest non-cancelled Actual evidence for
  -- this Business Date + Shift, regardless of area/station.
  select ws.*
  into v_ws
  from public.work_sessions ws
  where ws.staff_id=p_staff_id
    and ws.work_date=p_business_date
    and ws.shift_id=p_shift_id
    and upper(coalesce(ws.status,''))<>'CANCELLED'
  order by ws.updated_at desc,ws.created_at desc
  limit 1;

  if found then
    select a.area_code into v_ws_area from public.areas a where a.area_id=v_ws.area_id;
    if v_ws_area<>'FINISH' or v_ws.station_id is distinct from p_station_id then
      return false;
    end if;

    if upper(coalesce(v_ws.status,''))='OPEN' then
      return true;
    end if;

    if v_ws.actual_start_at is null then
      return false;
    end if;
    if v_at < v_ws.actual_start_at then
      return false;
    end if;
    if v_ws.actual_end_at is not null and v_at > v_ws.actual_end_at + interval '15 minutes' then
      return false;
    end if;
    return true;
  end if;

  -- No Actual evidence: Published Roster is the operational baseline.
  return exists(
    select 1
    from public.production_roster_entries pre
    join public.production_roster_versions prv
      on prv.roster_version_id=pre.roster_version_id
    where pre.staff_id=p_staff_id
      and pre.work_date=p_business_date
      and prv.status='PUBLISHED'
      and prv.shift_id=p_shift_id
      and upper(coalesce(pre.area_code_snapshot,''))='FINISH'
      and pre.station_id=p_station_id
      and upper(coalesce(pre.day_status,'')) in ('WORKING','COVER')
  );
end;
$$;

revoke all on function public.finish_processing_staff_available(uuid,date,uuid,uuid,timestamptz)
  from public,anon,authenticated;

create or replace function public.get_finish_production_context_v2(
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
  v_base jsonb;
  v_entries jsonb;
  v_staff_now jsonb;
  v_staff_history jsonb;
  v_business_date date;
  v_shift text:=upper(trim(coalesce(p_shift_code,'MORNING')));
  v_now timestamptz:=coalesce(p_at,now());
  v_shift_id uuid;
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_production_context(v_shift,v_now);
  v_business_date:=nullif(v_base->>'business_date','')::date;

  select sh.shift_id into v_shift_id
  from public.shifts sh
  where sh.shift_code=v_shift and sh.active=true and sh.deleted_at is null
  limit 1;

  with base_entries as (
    select item,ordinality
    from jsonb_array_elements(coalesce(v_base->'entries','[]'::jsonb)) with ordinality x(item,ordinality)
  )
  select coalesce(jsonb_agg(
    b.item||jsonb_build_object(
      'processed_by_staff_id',e.processed_by_staff_id,
      'processed_by',coalesce(nullif(e.processed_by_name_snapshot,''),ps.display_name),
      'recorded_by_staff_id',e.recorded_by_staff_id,
      'recorded_by_scanner',rs.display_name,
      'recorded_by_auth_user_id',e.recorded_by_auth_user_id,
      'route_code',pfi.route_code_snapshot,
      'route_name',pfi.route_display_name_snapshot,
      'route_color',pfi.route_color_snapshot,
      'production_order',pfi.production_order_snapshot,
      'customer_code',pfi.customer_code_snapshot
    ) order by b.ordinality
  ),'[]'::jsonb)
  into v_entries
  from base_entries b
  join public.finish_production_entries e
    on e.finish_production_entry_id=nullif(b.item->>'finish_production_entry_id','')::uuid
  join public.production_flow_items pfi on pfi.production_flow_item_id=e.production_flow_item_id
  left join public.staff_members ps on ps.staff_id=e.processed_by_staff_id
  left join public.staff_members rs on rs.staff_id=e.recorded_by_staff_id;

  -- Candidate staff = published Finish Roster plus any Finish Actual session.
  -- The availability helper applies Actual-over-Planned and exact Table rules.
  with candidates as (
    select distinct
      pre.staff_id,
      pre.staff_display_name_snapshot as display_name,
      pre.station_id,
      pre.station_code_snapshot as table_code,
      null::uuid as work_session_id,
      'ROSTER_PLANNED'::text as source,
      null::text as actual_status,
      null::timestamptz as actual_start_at,
      null::timestamptz as actual_end_at
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
    where pre.work_date=v_business_date
      and prv.status='PUBLISHED'
      and prv.shift_id=v_shift_id
      and upper(coalesce(pre.area_code_snapshot,''))='FINISH'
      and pre.station_code_snapshot in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
      and upper(coalesce(pre.day_status,'')) in ('WORKING','COVER')

    union all

    select
      ws.staff_id,
      sm.display_name,
      ws.station_id,
      st.station_code,
      ws.work_session_id,
      'ACTUAL'::text,
      ws.status,
      ws.actual_start_at,
      ws.actual_end_at
    from public.work_sessions ws
    join public.staff_members sm on sm.staff_id=ws.staff_id
    join public.areas a on a.area_id=ws.area_id
    join public.stations st on st.station_id=ws.station_id
    where ws.work_date=v_business_date
      and ws.shift_id=v_shift_id
      and a.area_code='FINISH'
      and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
      and upper(coalesce(ws.status,''))<>'CANCELLED'
  ), ranked as (
    select c.*,
      row_number() over(partition by c.staff_id,c.station_id order by case when c.source='ACTUAL' then 0 else 1 end) rn
    from candidates c
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id',sm.staff_id,
    'display_name',coalesce(nullif(r.display_name,''),sm.display_name),
    'work_session_id',r.work_session_id,
    'business_date',v_business_date,
    'shift_code',v_shift,
    'table_code',r.table_code,
    'status',coalesce(r.actual_status,r.source),
    'source',r.source,
    'actual_start_at',r.actual_start_at,
    'actual_end_at',r.actual_end_at,
    'available_now',public.finish_processing_staff_available(sm.staff_id,v_business_date,v_shift_id,r.station_id,v_now)
  ) order by r.table_code,sm.display_name),'[]'::jsonb)
  into v_staff_now
  from ranked r
  join public.staff_members sm on sm.staff_id=r.staff_id
  where r.rn=1
    and sm.production_staff=true
    and sm.active=true
    and sm.roster_eligible=true
    and sm.deleted_at is null;

  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id',sm.staff_id,
    'display_name',sm.display_name,
    'business_date',ws.work_date,
    'shift_code',sh.shift_code,
    'table_code',st.station_code,
    'status',ws.status
  ) order by ws.work_date desc,sh.shift_code,st.station_code,sm.display_name),'[]'::jsonb)
  into v_staff_history
  from public.work_sessions ws
  join public.staff_members sm on sm.staff_id=ws.staff_id
  join public.areas a on a.area_id=ws.area_id
  join public.stations st on st.station_id=ws.station_id
  join public.shifts sh on sh.shift_id=ws.shift_id
  where ws.work_date between v_business_date-7 and v_business_date
    and a.area_code='FINISH'
    and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
    and upper(coalesce(ws.status,''))<>'CANCELLED'
    and sm.production_staff=true and sm.active=true and sm.roster_eligible=true and sm.deleted_at is null;

  return (v_base-'schema_version'-'source_contract'-'entries')||jsonb_build_object(
    'schema_version','FINISH_PRODUCTION_V2',
    'source_contract','FINISH_V2_PRODUCTION_LEDGER_WITH_PROCESSOR',
    'entries',v_entries,
    'production_staff_now',v_staff_now,
    'processing_staff_history',v_staff_history,
    'processor_rule','ROSTER_PLANNED_WITH_ACTUAL_OVERRIDE_EXACT_TABLE_SHIFT',
    'scanner_identity_separate',true
  );
end;
$$;

revoke all on function public.get_finish_production_context_v2(text,timestamptz) from public,anon;
grant execute on function public.get_finish_production_context_v2(text,timestamptz) to authenticated;

comment on function public.finish_processing_staff_available(uuid,date,uuid,uuid,timestamptz) is
'Finish Processed by availability: published Roster is Planned baseline; latest work_sessions Actual overrides Planned. Staff must resolve to the exact Finish Table and Shift.';

commit;
