-- Allow a published Finish cover to move into Sorting with one auditable split
-- of the worked shift. A later recorded leaving time is the overtime evidence.

begin;

create or replace function public.move_finish_staff_to_sorting_v1(
  p_staff_id uuid,
  p_shift_code text,
  p_from_table_code text,
  p_move_time time,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_business_date date; v_shift public.shifts%rowtype; v_entry public.production_roster_entries%rowtype;
  v_finish_area_id uuid; v_sorting_area_id uuid; v_sorting_station_id uuid; v_from public.stations%rowtype;
  v_finish_session public.work_sessions%rowtype; v_open public.finish_staff_table_segments%rowtype;
  v_move_at timestamptz; v_start_at timestamptz; v_sorting_end_at timestamptz; v_profile jsonb;
  v_default_start time; v_default_end time; v_total_minutes numeric; v_finish_minutes numeric;
  v_finish_break integer; v_sorting_break integer; v_sorting_session_id uuid; v_actor uuid:=public.current_staff_id();
  v_staff_name text; v_old jsonb; v_saved public.work_sessions%rowtype;
begin
  perform public.require_finish_production_access();
  if p_staff_id is null or p_move_time is null then
    raise exception using errcode='22023', message='Staff and move time are required.';
  end if;
  if length(coalesce(p_notes,''))>1000 then
    raise exception using errcode='22023', message='Notes must be 1000 characters or fewer.';
  end if;

  select * into v_shift from public.shifts
  where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null limit 1;
  if not found then raise exception using errcode='22023', message='Shift must be Morning or Evening.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);

  -- A move to Sorting is only available to a person explicitly rostered as cover.
  select pre.* into v_entry
  from public.production_roster_entries pre
  join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
  where pre.staff_id=p_staff_id and pre.work_date=v_business_date and prv.shift_id=v_shift.shift_id
    and prv.status='PUBLISHED' and upper(coalesce(pre.assignment_type,''))='COVER'
  order by prv.version_number desc,prv.published_at desc nulls last limit 1;
  if not found then
    raise exception using errcode='42501', message='Only a staff member rostered as COVER can be moved from Finish to Sorting.';
  end if;

  select st.* into v_from from public.stations st join public.areas a on a.area_id=st.area_id
  where st.station_code=upper(trim(coalesce(p_from_table_code,''))) and a.area_code='FINISH'
    and st.active=true and st.deleted_at is null;
  if v_from.station_id is null or v_from.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then
    raise exception using errcode='22023', message='Choose the current Finish Table.';
  end if;
  select area_id into v_finish_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null;
  select area_id into v_sorting_area_id from public.areas where area_code='SORTING' and active=true and deleted_at is null;
  select st.station_id into v_sorting_station_id from public.stations st join public.areas a on a.area_id=st.area_id
  where st.station_code='SORTING_MAIN' and a.area_code='SORTING' and st.active=true and st.deleted_at is null;
  if v_sorting_area_id is null or v_sorting_station_id is null then
    raise exception using errcode='P0002', message='Sorting Area master data is not available.';
  end if;

  select * into v_finish_session from public.work_sessions ws
  where ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id and ws.staff_id=p_staff_id
    and ws.area_id=v_finish_area_id and ws.status<>'CANCELLED'
  order by ws.updated_at desc limit 1 for update;
  if not found or v_finish_session.actual_end_at is not null then
    raise exception using errcode='22023', message='Confirm this staff member on the current Finish Table before moving them to Sorting.';
  end if;
  if exists(select 1 from public.work_sessions ws where ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id
    and ws.staff_id=p_staff_id and ws.area_id=v_sorting_area_id and ws.status<>'CANCELLED') then
    raise exception using errcode='23505', message='This staff member is already active in Sorting for this shift.';
  end if;

  v_move_at:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_move_time);
  v_start_at:=v_finish_session.actual_start_at;
  if v_start_at is null then
    v_profile:=public.production_roster_work_profile_context(v_business_date,v_shift.shift_code);
    v_default_start:=nullif(v_profile->>'default_start_time','')::time;
    v_start_at:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,coalesce(v_entry.planned_start_time,v_default_start));
    if v_start_at is null then raise exception using errcode='22023', message='Set the staff start time before moving them to Sorting.'; end if;
    update public.work_sessions set actual_start_at=v_start_at,updated_at=now() where work_session_id=v_finish_session.work_session_id
    returning * into v_finish_session;
  end if;
  if v_move_at<=v_start_at then raise exception using errcode='22023', message='Move time must be after the staff start time.'; end if;

  select * into v_open from public.finish_staff_table_segments
  where work_session_id=v_finish_session.work_session_id and ended_at is null
  order by started_at desc limit 1 for update;
  if found then
    if v_open.station_id is distinct from v_from.station_id then raise exception using errcode='22023', message='This staff member is not currently working on the selected Table.'; end if;
    if v_move_at<=v_open.started_at then raise exception using errcode='22023', message='Move time must be after the current Table start time.'; end if;
    update public.finish_staff_table_segments set ended_at=v_move_at,notes=coalesce(nullif(trim(p_notes),''),notes),updated_at=now(),updated_by_auth_user_id=auth.uid()
    where finish_staff_table_segment_id=v_open.finish_staff_table_segment_id;
  else
    if v_finish_session.station_id is distinct from v_from.station_id then raise exception using errcode='22023', message='This staff member is not currently assigned to the selected Table.'; end if;
    insert into public.finish_staff_table_segments(work_session_id,station_id,started_at,ended_at,notes,created_by_auth_user_id,updated_by_auth_user_id)
    values(v_finish_session.work_session_id,v_from.station_id,v_start_at,v_move_at,nullif(trim(p_notes),''),auth.uid(),auth.uid());
  end if;

  v_profile:=public.production_roster_work_profile_context(v_business_date,v_shift.shift_code);
  v_default_end:=nullif(v_profile->>'default_end_time','')::time;
  v_sorting_end_at:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,coalesce(v_entry.planned_end_time,v_default_end));
  if v_sorting_end_at is null or v_sorting_end_at<=v_move_at then
    raise exception using errcode='22023', message='The roster needs an end time after the transfer before this staff member can move to Sorting.';
  end if;

  -- Allocate the recorded break once across the two area sessions by elapsed time.
  v_total_minutes:=greatest(1,extract(epoch from (v_sorting_end_at-v_start_at))/60.0);
  v_finish_minutes:=greatest(0,extract(epoch from (v_move_at-v_start_at))/60.0);
  v_finish_break:=least(coalesce(v_finish_session.break_minutes,0),round(coalesce(v_finish_session.break_minutes,0)*v_finish_minutes/v_total_minutes)::integer);
  v_sorting_break:=greatest(0,coalesce(v_finish_session.break_minutes,0)-v_finish_break);

  v_old:=to_jsonb(v_finish_session);
  update public.work_sessions set actual_end_at=v_move_at,break_minutes=v_finish_break,status='CONFIRMED',source='FINISH_TO_SORTING_TRANSFER',notes=coalesce(nullif(trim(p_notes),''),notes),updated_at=now()
  where work_session_id=v_finish_session.work_session_id returning * into v_saved;

  insert into public.work_sessions(
    production_roster_entry_id,production_roster_version_id,work_date,staff_id,area_id,station_id,shift_id,
    actual_start_at,actual_end_at,break_minutes,extra_non_work_minutes,adjustment_reason,status,source,
    confirmed_by,notes,recorded_by_auth_user_id,row_version,updated_at
  ) values (
    v_entry.roster_entry_id,v_entry.roster_version_id,v_business_date,p_staff_id,v_sorting_area_id,v_sorting_station_id,v_shift.shift_id,
    v_move_at,v_sorting_end_at,v_sorting_break,0,'NONE','CONFIRMED','SORTING_MANUAL_POSITION',
    v_actor,concat_ws(' ',format('Finish cover transfer from %s at %s.',v_from.station_name,to_char(v_move_at at time zone 'Europe/Dublin','HH24:MI')),nullif(trim(p_notes),'')),auth.uid(),1,now()
  ) returning work_session_id into v_sorting_session_id;

  select display_name into v_staff_name from public.staff_members where staff_id=p_staff_id;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,'FINISH_STAFF_MOVED_TO_SORTING','work_sessions',v_saved.work_session_id::text,v_old,to_jsonb(v_saved),
    format('%s moved from %s to Sorting at %s%s',coalesce(v_staff_name,'Staff'),v_from.station_name,to_char(v_move_at at time zone 'Europe/Dublin','HH24:MI'),case when nullif(trim(p_notes),'') is null then '' else ': '||trim(p_notes) end),'FINISH_V4');
  return jsonb_build_object('status','moved','business_date',v_business_date,'shift_code',v_shift.shift_code,'staff_id',p_staff_id,'from_table_code',v_from.station_code,'to_area_code','SORTING','moved_at',v_move_at,'sorting_work_session_id',v_sorting_session_id);
end;
$$;

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
declare v_base jsonb; v_staff jsonb; v_shift public.shifts%rowtype; v_business_date date;
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_staff_context_v3(p_shift_code,p_at);
  v_business_date:=nullif(v_base->>'business_date','')::date;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,'MORNING'))) and active=true and deleted_at is null limit 1;
  select coalesce(jsonb_agg(br.item||jsonb_build_object('is_sorting_cover',exists(
    select 1 from public.production_roster_entries pre join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
    where pre.staff_id=nullif(br.item->>'staff_id','')::uuid and pre.work_date=v_business_date and prv.shift_id=v_shift.shift_id
      and prv.status='PUBLISHED' and upper(coalesce(pre.assignment_type,''))='COVER'
  )) order by br.ordinality),'[]'::jsonb) into v_staff
  from jsonb_array_elements(coalesce(v_base->'staff','[]'::jsonb)) with ordinality br(item,ordinality);
  return (v_base-'schema_version'-'source_contract'-'staff')||jsonb_build_object(
    'schema_version','FINISH_STAFF_V4','source_contract','PUBLISHED_ROSTER_PLUS_REVERSIBLE_ATTENDANCE_TABLE_SEGMENTS_AND_COVER_TRANSFERS','staff',v_staff
  );
end;
$$;

create or replace function public.terminal_move_finish_staff_to_sorting_v1(
  p_staff_id uuid,p_shift_code text,p_from_table_code text,p_move_time time,p_notes text default null
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('FINISH',p_from_table_code);
  return public.move_finish_staff_to_sorting_v1(p_staff_id,p_shift_code,p_from_table_code,p_move_time,p_notes);
end;
$$;

revoke all on function public.move_finish_staff_to_sorting_v1(uuid,text,text,time,text) from public,anon;
revoke all on function public.terminal_move_finish_staff_to_sorting_v1(uuid,text,text,time,text) from public,anon;
revoke all on function public.get_finish_staff_context_v4(text,timestamptz) from public,anon;
grant execute on function public.move_finish_staff_to_sorting_v1(uuid,text,text,time,text) to authenticated;
grant execute on function public.terminal_move_finish_staff_to_sorting_v1(uuid,text,text,time,text) to authenticated;
grant execute on function public.get_finish_staff_context_v4(text,timestamptz) to authenticated;

comment on function public.move_finish_staff_to_sorting_v1(uuid,text,text,time,text) is
  'Moves a published COVER from a Finish table to Sorting at an explicit time, preserving one auditable allocation of staff hours and break.';
comment on function public.get_finish_staff_context_v4(text,timestamptz) is
  'Finish Staff V4 adds published COVER eligibility for an auditable Finish-to-Sorting transfer.';

commit;
