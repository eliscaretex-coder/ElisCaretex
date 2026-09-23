-- Finish Staff: close the current table segment when a person leaves early.

begin;

create or replace function public.finish_end_staff_shift_v1(
  p_staff_id uuid,
  p_shift_code text,
  p_table_code text,
  p_end_time time,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_business_date date; v_shift public.shifts%rowtype; v_station public.stations%rowtype; v_area_id uuid;
  v_ws public.work_sessions%rowtype; v_open public.finish_staff_table_segments%rowtype; v_end_at timestamptz; v_start_at timestamptz;
  v_actor uuid:=public.current_staff_id(); v_old jsonb; v_saved public.work_sessions%rowtype; v_name text;
begin
  perform public.require_finish_production_access();
  if p_staff_id is null or p_end_time is null then raise exception using errcode='22023',message='Staff and leaving time are required.'; end if;
  if nullif(trim(coalesce(p_notes,'')),'') is not null and length(trim(p_notes))>1000 then raise exception using errcode='22023',message='Notes must be 1000 characters or fewer.'; end if;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null limit 1;
  if not found then raise exception using errcode='22023',message='Shift must be Morning or Evening.'; end if;
  select st.* into v_station from public.stations st join public.areas a on a.area_id=st.area_id where st.station_code=upper(trim(coalesce(p_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  if not found then raise exception using errcode='22023',message='Choose the current Finish Table.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  v_end_at:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_end_time);
  select area_id into v_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null;
  select * into v_ws from public.work_sessions ws where ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id and ws.staff_id=p_staff_id and ws.area_id=v_area_id and ws.status<>'CANCELLED' order by ws.updated_at desc limit 1 for update;
  if not found then raise exception using errcode='22023',message='Confirm this staff member before recording an early departure.'; end if;
  if v_ws.actual_end_at is not null then raise exception using errcode='22023',message='This staff shift is already closed.'; end if;
  select * into v_open from public.finish_staff_table_segments s where s.work_session_id=v_ws.work_session_id and s.ended_at is null order by s.started_at desc limit 1 for update;
  if found then
    if v_open.station_id is distinct from v_station.station_id then raise exception using errcode='22023',message='This staff member is not currently working on the selected Table.'; end if;
    if v_end_at<=v_open.started_at then raise exception using errcode='22023',message='Leaving time must be after the current Table start time.'; end if;
    update public.finish_staff_table_segments set ended_at=v_end_at,notes=coalesce(nullif(trim(p_notes),''),notes),updated_at=now(),updated_by_auth_user_id=auth.uid() where finish_staff_table_segment_id=v_open.finish_staff_table_segment_id;
  else
    if v_ws.station_id is distinct from v_station.station_id then raise exception using errcode='22023',message='This staff member is not currently working on the selected Table.'; end if;
    v_start_at:=v_ws.actual_start_at;
    if v_start_at is null then raise exception using errcode='22023',message='Set the staff start time before recording an early departure.'; end if;
    if v_end_at<=v_start_at then raise exception using errcode='22023',message='Leaving time must be after the staff start time.'; end if;
    insert into public.finish_staff_table_segments(work_session_id,station_id,started_at,ended_at,notes,created_by_auth_user_id,updated_by_auth_user_id)
    values(v_ws.work_session_id,v_station.station_id,v_start_at,v_end_at,nullif(trim(p_notes),''),auth.uid(),auth.uid());
  end if;
  v_old:=to_jsonb(v_ws);
  update public.work_sessions set actual_end_at=v_end_at,status='CONFIRMED',notes=coalesce(nullif(trim(p_notes),''),notes),updated_at=now() where work_session_id=v_ws.work_session_id returning * into v_saved;
  select display_name into v_name from public.staff_members where staff_id=p_staff_id;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,'FINISH_STAFF_EARLY_DEPARTURE','work_sessions',v_saved.work_session_id::text,v_old,to_jsonb(v_saved),format('%s left %s at %s%s',coalesce(v_name,'Staff'),v_station.station_name,to_char(v_end_at at time zone 'Europe/Dublin','HH24:MI'),case when nullif(trim(p_notes),'') is null then '' else ': '||trim(p_notes) end),'FINISH_V3');
  return jsonb_build_object('status','closed','business_date',v_business_date,'shift_code',v_shift.shift_code,'staff_id',p_staff_id,'table_code',v_station.station_code,'actual_end_at',v_end_at);
end;
$$;

create or replace function public.terminal_finish_end_staff_shift_v1(
  p_staff_id uuid,p_shift_code text,p_table_code text,p_end_time time,p_notes text default null
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('FINISH',p_table_code);
  return public.finish_end_staff_shift_v1(p_staff_id,p_shift_code,p_table_code,p_end_time,p_notes);
end;
$$;

revoke all on function public.finish_end_staff_shift_v1(uuid,text,text,time,text) from public,anon;
revoke all on function public.terminal_finish_end_staff_shift_v1(uuid,text,text,time,text) from public,anon;
grant execute on function public.finish_end_staff_shift_v1(uuid,text,text,time,text) to authenticated;
grant execute on function public.terminal_finish_end_staff_shift_v1(uuid,text,text,time,text) to authenticated;

commit;
