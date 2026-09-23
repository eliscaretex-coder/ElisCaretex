begin;

create or replace function public.upsert_finish_staff_actual(
  p_staff_id uuid,
  p_shift_code text,
  p_table_code text,
  p_start_time time default null,
  p_end_time time default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_business_date date; v_shift public.shifts%rowtype; v_station public.stations%rowtype; v_area_id uuid;
  v_staff public.staff_members%rowtype; v_existing public.work_sessions%rowtype; v_saved public.work_sessions%rowtype;
  v_start timestamptz; v_end timestamptz; v_actor uuid; v_old jsonb; v_segment_count integer:=0;
begin
  perform public.require_finish_production_access();
  if p_staff_id is null then raise exception using errcode='22023', message='Staff member is required.'; end if;
  if p_start_time is null then raise exception using errcode='22023', message='Enter the actual start time before saving.'; end if;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null;
  if not found or v_shift.shift_code not in ('MORNING','EVENING') then raise exception using errcode='22023', message='Shift must be Morning or Evening.'; end if;
  select st.* into v_station from public.stations st join public.areas a on a.area_id=st.area_id where st.station_code=upper(trim(coalesce(p_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  if not found or v_station.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then raise exception using errcode='22023', message='Choose Finish Table 1, Table 2 or Table 3.'; end if;
  select area_id into v_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null;
  select * into v_staff from public.staff_members where staff_id=p_staff_id and production_staff=true and active=true and roster_eligible=true and deleted_at is null;
  if not found then raise exception using errcode='22023', message='Selected staff member is not active production staff.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  v_start:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_start_time);
  if p_end_time is not null then v_end:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_end_time); end if;
  if v_end is not null and (v_end<=v_start or v_end-v_start>interval '13 hours') then raise exception using errcode='22023', message='Actual worked span must be more than zero and no longer than 13 hours.'; end if;
  v_actor:=public.current_staff_id();

  insert into public.finish_daily_staff_attendance (business_date,shift_id,staff_id,attendance_status,source,created_by_auth_user_id,updated_by_auth_user_id)
  values (v_business_date,v_shift.shift_id,p_staff_id,'PRESENT','FINISH_WORKSTATION',auth.uid(),auth.uid())
  on conflict (business_date,shift_id,staff_id) do update
    set attendance_status='PRESENT',absence_reason=null,source='FINISH_WORKSTATION',updated_at=now(),updated_by_auth_user_id=auth.uid();

  select * into v_existing from public.work_sessions ws where ws.work_date=v_business_date and ws.staff_id=p_staff_id and ws.shift_id=v_shift.shift_id and ws.area_id=v_area_id and ws.status<>'CANCELLED' order by ws.updated_at desc limit 1 for update;
  if found then
    select count(*) into v_segment_count from public.finish_staff_table_segments s where s.work_session_id=v_existing.work_session_id;
    if v_existing.station_id is distinct from v_station.station_id and v_segment_count>0 then
      raise exception using errcode='22023', message='Use Move table so the hours already worked stay with the original Table.';
    end if;
    if v_segment_count>1 and (p_start_time is not null or p_end_time is not null) then
      raise exception using errcode='22023', message='This staff member has table transfers. Use Move table for the next timed change.';
    end if;
    v_old:=to_jsonb(v_existing);
    update public.work_sessions set station_id=v_station.station_id,actual_start_at=v_start,actual_end_at=v_end,status=case when v_end is null then 'OPEN' else 'CONFIRMED' end,source='FINISH_V2',confirmed_by=v_actor,notes=coalesce(nullif(trim(p_reason),''),notes),updated_at=now() where work_session_id=v_existing.work_session_id returning * into v_saved;
  else
    v_old:=null;
    insert into public.work_sessions(work_date,staff_id,area_id,station_id,shift_id,actual_start_at,actual_end_at,status,source,confirmed_by,notes)
    values(v_business_date,p_staff_id,v_area_id,v_station.station_id,v_shift.shift_id,v_start,v_end,case when v_end is null then 'OPEN' else 'CONFIRMED' end,'FINISH_V2',v_actor,nullif(trim(p_reason),'')) returning * into v_saved;
  end if;

  if v_saved.actual_start_at is not null and not exists(select 1 from public.finish_staff_table_segments s where s.work_session_id=v_saved.work_session_id) then
    insert into public.finish_staff_table_segments(work_session_id,station_id,started_at,ended_at,notes,created_by_auth_user_id,updated_by_auth_user_id)
    values(v_saved.work_session_id,v_station.station_id,v_saved.actual_start_at,v_saved.actual_end_at,nullif(trim(p_reason),''),auth.uid(),auth.uid());
  elsif v_segment_count=1 then
    update public.finish_staff_table_segments
    set started_at=v_start,ended_at=v_end,updated_at=now(),updated_by_auth_user_id=auth.uid()
    where work_session_id=v_saved.work_session_id;
  end if;

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,case when v_old is null then 'CREATE_FINISH_STAFF_ACTUAL' else 'UPDATE_FINISH_STAFF_ACTUAL' end,'work_sessions',v_saved.work_session_id::text,v_old,to_jsonb(v_saved),p_reason,'FINISH_V2');
  return jsonb_build_object('status','saved','work_session_id',v_saved.work_session_id,'staff_id',p_staff_id,'table_code',v_station.station_code,'business_date',v_business_date,'shift_code',v_shift.shift_code,'actual_start_at',v_saved.actual_start_at,'actual_end_at',v_saved.actual_end_at);
end;
$$;

revoke all on function public.upsert_finish_staff_actual(uuid,text,text,time,time,text) from public,anon;
grant execute on function public.upsert_finish_staff_actual(uuid,text,text,time,time,text) to authenticated;

comment on function public.upsert_finish_staff_actual(uuid,text,text,time,time,text) is
  'Saves Finish Actual staff time with an explicit start time and a maximum 13-hour recorded span.';

commit;
