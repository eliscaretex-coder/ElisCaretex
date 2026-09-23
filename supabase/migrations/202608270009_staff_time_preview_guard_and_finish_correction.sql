-- Staff time is safety critical: enforce a daily maximum and provide an
-- explicit correction path for Finish sessions that have table segments.

begin;

create or replace function public.enforce_staff_work_session_duration_v1()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare v_other_minutes numeric:=0; v_this_minutes numeric;
begin
  if upper(coalesce(new.status,''))='CANCELLED' or new.actual_start_at is null or new.actual_end_at is null then return new; end if;
  v_this_minutes:=extract(epoch from(new.actual_end_at-new.actual_start_at))/60.0;
  if v_this_minutes<=0 then raise exception using errcode='22023',message='Actual leaving time must be later than the staff start time.'; end if;
  if v_this_minutes>780 then raise exception using errcode='22023',message='A staff shift cannot be longer than 13 hours.'; end if;
  select coalesce(sum(extract(epoch from(ws.actual_end_at-ws.actual_start_at))/60.0),0) into v_other_minutes
  from public.work_sessions ws
  where ws.staff_id=new.staff_id and ws.work_date=new.work_date and ws.work_session_id is distinct from new.work_session_id
    and ws.status<>'CANCELLED' and ws.actual_start_at is not null and ws.actual_end_at is not null;
  if v_other_minutes+v_this_minutes>780 then
    raise exception using errcode='22023',message='This staff member cannot exceed 13 hours of recorded work in one day.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_staff_work_session_duration_v1 on public.work_sessions;
create trigger enforce_staff_work_session_duration_v1
before insert or update of actual_start_at,actual_end_at,status,staff_id,work_date on public.work_sessions
for each row execute function public.enforce_staff_work_session_duration_v1();

create or replace function public.correct_finish_staff_time_v1(
  p_staff_id uuid,p_shift_code text,p_table_code text,p_start_time time,p_end_time time default null,p_reason text default null
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare
  v_shift public.shifts%rowtype; v_business_date date; v_area_id uuid; v_station public.stations%rowtype;
  v_session public.work_sessions%rowtype; v_first public.finish_staff_table_segments%rowtype; v_last public.finish_staff_table_segments%rowtype;
  v_start timestamptz; v_end timestamptz; v_old jsonb; v_name text;
begin
  perform public.require_finish_production_access();
  if p_staff_id is null or p_start_time is null then raise exception using errcode='22023',message='Staff and actual start time are required.'; end if;
  if length(coalesce(p_reason,''))>500 then raise exception using errcode='22023',message='Reason must be 500 characters or fewer.'; end if;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null limit 1;
  if not found then raise exception using errcode='22023',message='Shift must be Morning or Evening.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  select st.* into v_station from public.stations st join public.areas a on a.area_id=st.area_id where st.station_code=upper(trim(coalesce(p_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  if v_station.station_id is null then raise exception using errcode='22023',message='Choose a valid Finish Table.'; end if;
  select area_id into v_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null;
  select * into v_session from public.work_sessions ws where ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id and ws.staff_id=p_staff_id and ws.area_id=v_area_id and ws.status<>'CANCELLED' order by ws.updated_at desc limit 1 for update;
  if not found then raise exception using errcode='22023',message='Confirm the Finish staff member before correcting their time.'; end if;
  if v_session.station_id is distinct from v_station.station_id then raise exception using errcode='22023',message='This staff member is not currently assigned to the selected Finish Table.'; end if;
  v_start:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_start_time);
  v_end:=case when p_end_time is null then null else public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_end_time) end;
  if v_end is not null and(v_end<=v_start or v_end-v_start>interval '13 hours') then raise exception using errcode='22023',message='Actual worked span must be more than zero and no longer than 13 hours.'; end if;
  select * into v_first from public.finish_staff_table_segments where work_session_id=v_session.work_session_id order by started_at limit 1 for update;
  select * into v_last from public.finish_staff_table_segments where work_session_id=v_session.work_session_id order by started_at desc limit 1 for update;
  if found then
    if v_first.ended_at is not null and v_start>=v_first.ended_at then raise exception using errcode='22023',message='The corrected start must be before the first Table move.'; end if;
    if v_end is not null and v_end<=v_last.started_at then raise exception using errcode='22023',message='The corrected leaving time must be after the last Table move.'; end if;
    update public.finish_staff_table_segments set started_at=v_start,updated_at=now(),updated_by_auth_user_id=auth.uid() where finish_staff_table_segment_id=v_first.finish_staff_table_segment_id;
    update public.finish_staff_table_segments set ended_at=v_end,notes=coalesce(nullif(trim(p_reason),''),notes),updated_at=now(),updated_by_auth_user_id=auth.uid() where finish_staff_table_segment_id=v_last.finish_staff_table_segment_id;
  else
    insert into public.finish_staff_table_segments(work_session_id,station_id,started_at,ended_at,notes,created_by_auth_user_id,updated_by_auth_user_id) values(v_session.work_session_id,v_station.station_id,v_start,v_end,nullif(trim(p_reason),''),auth.uid(),auth.uid());
  end if;
  v_old:=to_jsonb(v_session);
  update public.work_sessions set actual_start_at=v_start,actual_end_at=v_end,status=case when v_end is null then 'OPEN' else 'CORRECTED' end,notes=coalesce(nullif(trim(p_reason),''),notes),confirmed_by=public.current_staff_id(),updated_at=now() where work_session_id=v_session.work_session_id returning * into v_session;
  select display_name into v_name from public.staff_members where staff_id=p_staff_id;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),public.current_staff_id(),'CORRECT_FINISH_STAFF_TIME','work_sessions',v_session.work_session_id::text,v_old,to_jsonb(v_session),format('%s corrected Finish time to %s-%s%s',coalesce(v_name,'Staff'),to_char(v_start at time zone 'Europe/Dublin','HH24:MI'),coalesce(to_char(v_end at time zone 'Europe/Dublin','HH24:MI'),'open'),case when nullif(trim(p_reason),'') is null then '' else ': '||trim(p_reason) end),'FINISH_V4');
  return jsonb_build_object('status','corrected','staff_id',p_staff_id,'actual_start_at',v_session.actual_start_at,'actual_end_at',v_session.actual_end_at,'work_session_id',v_session.work_session_id);
end;
$$;

create or replace function public.terminal_correct_finish_staff_time_v1(
  p_staff_id uuid,p_shift_code text,p_table_code text,p_start_time time,p_end_time time default null,p_reason text default null
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('FINISH',p_table_code);
  return public.correct_finish_staff_time_v1(p_staff_id,p_shift_code,p_table_code,p_start_time,p_end_time,p_reason);
end;
$$;

revoke all on function public.correct_finish_staff_time_v1(uuid,text,text,time,time,text) from public,anon;
revoke all on function public.terminal_correct_finish_staff_time_v1(uuid,text,text,time,time,text) from public,anon;
grant execute on function public.correct_finish_staff_time_v1(uuid,text,text,time,time,text) to authenticated;
grant execute on function public.terminal_correct_finish_staff_time_v1(uuid,text,text,time,time,text) to authenticated;

comment on function public.correct_finish_staff_time_v1(uuid,text,text,time,time,text) is 'Corrects Finish start/end after table transfers while preserving the internal Table move history and enforcing a 13-hour maximum.';

commit;
