-- =====================================================================
-- ElisCaretex V2
-- Migration 047: Finish processing staff attribution and route-aware history
--
-- PREPARED: owner executes in Development.
--
-- Operational baseline preserved from the production Google Apps Script:
-- - every Finish production entry identifies the staff member who processed it;
-- - new production may select only staff currently available on the exact
--   Finish Table + Business Date + Shift;
-- - scanner/authenticated recorder is stored separately from processed-by staff;
-- - the UI may remember the last selected production staff per workstation,
--   but the backend always validates availability again;
-- - corrections are append-only and keep processed-by history by revision.
-- =====================================================================

begin;

alter table public.finish_production_entries
  add column if not exists processed_by_staff_id uuid
    references public.staff_members(staff_id) on delete set null,
  add column if not exists processed_by_name_snapshot text;

create index if not exists finish_production_processed_by_idx
  on public.finish_production_entries(processed_by_staff_id,production_business_date,shift_code_snapshot,table_code_snapshot);

-- Existing Development Finish entries were recorded before processed-by was
-- separated from scanner identity. Preserve the best available historical
-- attribution by copying the recorder staff identity into processed-by.
update public.finish_production_entries e
set processed_by_staff_id=coalesce(e.processed_by_staff_id,e.recorded_by_staff_id),
    processed_by_name_snapshot=coalesce(
      nullif(trim(e.processed_by_name_snapshot),''),
      (select sm.display_name from public.staff_members sm where sm.staff_id=coalesce(e.processed_by_staff_id,e.recorded_by_staff_id))
    )
where e.processed_by_staff_id is null
   or nullif(trim(e.processed_by_name_snapshot),'') is null;

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

  select ws.* into v_ws
  from public.work_sessions ws
  join public.areas a on a.area_id=ws.area_id
  where ws.staff_id=p_staff_id
    and ws.work_date=p_business_date
    and ws.shift_id=p_shift_id
    and ws.station_id=p_station_id
    and a.area_code='FINISH'
    and ws.status<>'CANCELLED'
  order by ws.updated_at desc,ws.created_at desc
  limit 1;

  if not found then
    return false;
  end if;

  -- Same production behavior as the current Google Script: an OPEN session is
  -- an explicit staff login and is selectable immediately, even when its
  -- planned/recorded start is later than the current clock time.
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
end;
$$;

revoke all on function public.finish_processing_staff_available(uuid,date,uuid,uuid,timestamptz) from public,anon,authenticated;

create or replace function public.finish_assert_processing_staff(
  p_staff_id uuid,
  p_business_date date,
  p_shift_id uuid,
  p_station_id uuid,
  p_at timestamptz default now()
)
returns public.staff_members
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_staff public.staff_members%rowtype;
  v_table_name text;
  v_shift_name text;
begin
  select * into v_staff
  from public.staff_members sm
  where sm.staff_id=p_staff_id
    and sm.production_staff=true
    and sm.active=true
    and sm.roster_eligible=true
    and sm.deleted_at is null;

  if not found then
    raise exception using errcode='22023', message='Select an active Finish production staff member.';
  end if;

  if not public.finish_processing_staff_available(p_staff_id,p_business_date,p_shift_id,p_station_id,p_at) then
    select st.station_name into v_table_name from public.stations st where st.station_id=p_station_id;
    select sh.shift_name into v_shift_name from public.shifts sh where sh.shift_id=p_shift_id;
    raise exception using errcode='23514', message=format(
      '%s is not currently logged in for %s / %s. Open Finish Staff and confirm the correct Table/Shift before saving production.',
      v_staff.display_name,coalesce(v_table_name,'Finish Table'),coalesce(v_shift_name,'Shift')
    );
  end if;

  return v_staff;
end;
$$;

revoke all on function public.finish_assert_processing_staff(uuid,date,uuid,uuid,timestamptz) from public,anon,authenticated;

create or replace function public.record_finish_production_v2(
  p_production_flow_item_id uuid,
  p_shift_code text,
  p_table_code text,
  p_processed_by_staff_id uuid,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_shift public.shifts%rowtype;
  v_station public.stations%rowtype;
  v_business_date date;
  v_processor public.staff_members%rowtype;
  v_result jsonb;
  v_entry_id uuid;
  v_actor_staff uuid;
begin
  perform public.require_finish_production_access();

  select * into v_shift
  from public.shifts
  where shift_code=upper(trim(coalesce(p_shift_code,'')))
    and active=true and deleted_at is null;
  if not found or v_shift.shift_code not in ('MORNING','EVENING') then
    raise exception using errcode='22023', message='Shift must be Morning or Evening.';
  end if;

  select st.* into v_station
  from public.stations st
  join public.areas a on a.area_id=st.area_id
  where st.station_code=upper(trim(coalesce(p_table_code,'')))
    and a.area_code='FINISH'
    and st.active=true and st.deleted_at is null;
  if not found or v_station.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then
    raise exception using errcode='22023', message='Choose Finish Table 1, Table 2 or Table 3.';
  end if;

  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  select * into v_processor
  from public.finish_assert_processing_staff(
    p_processed_by_staff_id,v_business_date,v_shift.shift_id,v_station.station_id,now()
  );

  -- Reuse the already validated/owner-tested 044 + 046 save path. This wrapper
  -- adds production attribution without duplicating trolley/batch/lifecycle rules.
  v_result:=public.record_finish_production(
    p_production_flow_item_id,p_shift_code,p_table_code,p_lines,p_trolley_codes,p_notes
  );

  v_entry_id:=nullif(v_result->>'finish_production_entry_id','')::uuid;
  if v_entry_id is null then
    raise exception using errcode='P0002', message='Finish production save did not return an entry id.';
  end if;

  update public.finish_production_entries e
  set processed_by_staff_id=v_processor.staff_id,
      processed_by_name_snapshot=v_processor.display_name
  where e.finish_production_entry_id=v_entry_id;

  update public.production_flow_events ev
  set performed_by_staff_id=v_processor.staff_id,
      event_data=coalesce(ev.event_data,'{}'::jsonb)||jsonb_build_object(
        'processed_by_staff_id',v_processor.staff_id,
        'processed_by_name',v_processor.display_name,
        'recorded_by_scanner_staff_id',public.current_staff_id(),
        'recorded_by_auth_user_id',auth.uid()
      )
  where ev.source_application='FINISH_V2'
    and ev.source_entity_table='finish_production_entries'
    and ev.source_entity_id=v_entry_id::text
    and ev.event_type='FINISH_PRODUCTION_RECORDED';

  update public.production_flow_items pfi
  set last_performed_by_staff_id=v_processor.staff_id
  where pfi.production_flow_item_id=p_production_flow_item_id
    and pfi.last_event_type='FINISH_PRODUCTION_RECORDED';

  v_actor_staff:=public.current_staff_id();
  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,source_application
  ) values (
    auth.uid(),v_actor_staff,'ATTRIBUTE_FINISH_PRODUCTION_STAFF','finish_production_entries',v_entry_id::text,
    jsonb_build_object(
      'processed_by_staff_id',v_processor.staff_id,
      'processed_by_name',v_processor.display_name,
      'recorded_by_scanner_staff_id',v_actor_staff,
      'table_code',v_station.station_code,
      'shift_code',v_shift.shift_code,
      'business_date',v_business_date
    ),'FINISH_V2'
  );

  return v_result||jsonb_build_object(
    'processed_by_staff_id',v_processor.staff_id,
    'processed_by_name',v_processor.display_name,
    'recorded_by_scanner_staff_id',v_actor_staff
  );
end;
$$;

create or replace function public.correct_finish_production_v2(
  p_finish_production_entry_id uuid,
  p_processed_by_staff_id uuid,
  p_lines jsonb,
  p_trolley_codes text[] default array[]::text[],
  p_notes text default null,
  p_correction_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_old public.finish_production_entries%rowtype;
  v_processor public.staff_members%rowtype;
  v_result jsonb;
  v_new_id uuid;
  v_actor_staff uuid;
begin
  perform public.require_finish_production_access();

  select * into v_old
  from public.finish_production_entries e
  where e.finish_production_entry_id=p_finish_production_entry_id
    and e.status='ACTIVE';
  if not found then
    raise exception using errcode='P0002', message='The active Finish record was not found.';
  end if;

  select * into v_processor
  from public.staff_members sm
  where sm.staff_id=p_processed_by_staff_id
    and sm.production_staff=true
    and sm.active=true
    and sm.roster_eligible=true
    and sm.deleted_at is null;
  if not found then
    raise exception using errcode='22023', message='Select an active Finish production staff member.';
  end if;

  -- If attribution is changed during correction, the selected person must have
  -- a Finish Actual session on the original Table / Business Date / Shift.
  if p_processed_by_staff_id is distinct from v_old.processed_by_staff_id then
    if not exists(
      select 1
      from public.work_sessions ws
      join public.areas a on a.area_id=ws.area_id
      where ws.staff_id=p_processed_by_staff_id
        and ws.work_date=v_old.production_business_date
        and ws.shift_id=v_old.shift_id
        and ws.station_id=v_old.station_id
        and a.area_code='FINISH'
        and ws.status<>'CANCELLED'
    ) then
      raise exception using errcode='23514', message='The selected processed-by staff member has no Finish Actual session for the original Table / Business Date / Shift.';
    end if;
  end if;

  v_result:=public.correct_finish_production(
    p_finish_production_entry_id,p_lines,p_trolley_codes,p_notes,p_correction_reason
  );

  v_new_id:=nullif(v_result->>'finish_production_entry_id','')::uuid;
  if v_new_id is null then
    raise exception using errcode='P0002', message='Finish correction did not return a new revision id.';
  end if;

  update public.finish_production_entries e
  set processed_by_staff_id=v_processor.staff_id,
      processed_by_name_snapshot=v_processor.display_name
  where e.finish_production_entry_id=v_new_id;

  update public.production_flow_events ev
  set performed_by_staff_id=v_processor.staff_id,
      event_data=coalesce(ev.event_data,'{}'::jsonb)||jsonb_build_object(
        'processed_by_staff_id',v_processor.staff_id,
        'processed_by_name',v_processor.display_name,
        'recorded_by_scanner_staff_id',public.current_staff_id(),
        'recorded_by_auth_user_id',auth.uid()
      )
  where ev.source_application='FINISH_V2'
    and ev.source_entity_table='finish_production_entries'
    and ev.source_entity_id=v_new_id::text
    and ev.event_type='FINISH_PRODUCTION_CORRECTED';

  update public.production_flow_items pfi
  set last_performed_by_staff_id=v_processor.staff_id
  where pfi.production_flow_item_id=v_old.production_flow_item_id
    and pfi.last_event_type='FINISH_PRODUCTION_CORRECTED';

  v_actor_staff:=public.current_staff_id();
  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application
  ) values (
    auth.uid(),v_actor_staff,'ATTRIBUTE_FINISH_CORRECTION_STAFF','finish_production_entries',v_new_id::text,
    jsonb_build_object('processed_by_staff_id',v_old.processed_by_staff_id,'processed_by_name',v_old.processed_by_name_snapshot),
    jsonb_build_object('processed_by_staff_id',v_processor.staff_id,'processed_by_name',v_processor.display_name,'recorded_by_scanner_staff_id',v_actor_staff),
    p_correction_reason,'FINISH_V2'
  );

  return v_result||jsonb_build_object(
    'processed_by_staff_id',v_processor.staff_id,
    'processed_by_name',v_processor.display_name,
    'recorded_by_scanner_staff_id',v_actor_staff
  );
end;
$$;

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
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_production_context(v_shift,v_now);
  v_business_date:=nullif(v_base->>'business_date','')::date;

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

  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id',sm.staff_id,
    'display_name',sm.display_name,
    'work_session_id',ws.work_session_id,
    'business_date',ws.work_date,
    'shift_code',sh.shift_code,
    'table_code',st.station_code,
    'status',ws.status,
    'actual_start_at',ws.actual_start_at,
    'actual_end_at',ws.actual_end_at,
    'available_now',public.finish_processing_staff_available(sm.staff_id,ws.work_date,ws.shift_id,ws.station_id,v_now)
  ) order by st.station_code,sm.display_name),'[]'::jsonb)
  into v_staff_now
  from public.work_sessions ws
  join public.staff_members sm on sm.staff_id=ws.staff_id
  join public.areas a on a.area_id=ws.area_id
  join public.stations st on st.station_id=ws.station_id
  join public.shifts sh on sh.shift_id=ws.shift_id
  where ws.work_date=v_business_date
    and sh.shift_code=v_shift
    and a.area_code='FINISH'
    and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3')
    and ws.status<>'CANCELLED'
    and sm.production_staff=true and sm.active=true and sm.roster_eligible=true and sm.deleted_at is null;

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
    and ws.status<>'CANCELLED'
    and sm.production_staff=true and sm.active=true and sm.roster_eligible=true and sm.deleted_at is null;

  return (v_base-'schema_version'-'source_contract'-'entries')||jsonb_build_object(
    'schema_version','FINISH_PRODUCTION_V2',
    'source_contract','FINISH_V2_PRODUCTION_LEDGER_WITH_PROCESSOR',
    'entries',v_entries,
    'production_staff_now',v_staff_now,
    'processing_staff_history',v_staff_history,
    'processor_rule','EXACT_TABLE_BUSINESS_DATE_SHIFT_ACTUAL',
    'scanner_identity_separate',true
  );
end;
$$;

revoke all on function public.record_finish_production_v2(uuid,text,text,uuid,jsonb,text[],text) from public,anon;
revoke all on function public.correct_finish_production_v2(uuid,uuid,jsonb,text[],text,text) from public,anon;
revoke all on function public.get_finish_production_context_v2(text,timestamptz) from public,anon;

grant execute on function public.record_finish_production_v2(uuid,text,text,uuid,jsonb,text[],text) to authenticated;
grant execute on function public.correct_finish_production_v2(uuid,uuid,jsonb,text[],text,text) to authenticated;
grant execute on function public.get_finish_production_context_v2(text,timestamptz) to authenticated;

comment on column public.finish_production_entries.processed_by_staff_id is 'Staff member who physically processed this Finish production contribution. Separate from the authenticated scanner/recorder.';
comment on column public.finish_production_entries.processed_by_name_snapshot is 'Display-name snapshot of the processed-by staff member preserved per revision.';
comment on function public.record_finish_production_v2(uuid,text,text,uuid,jsonb,text[],text) is 'Finish save with mandatory exact Table/Shift production staff attribution. Recorder/scanner identity remains separate.';
comment on function public.correct_finish_production_v2(uuid,uuid,jsonb,text[],text,text) is 'Append-only Finish correction preserving processed-by attribution history and scanner identity.';
comment on function public.get_finish_production_context_v2(text,timestamptz) is 'Finish V2 context with route-aware entry history and exact Table/Shift production staff options.';

commit;
