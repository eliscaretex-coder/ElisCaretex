-- Actual break duration is an editable operational fact and must feed worked time.

begin;

create or replace function public.set_finish_staff_break_v1(
  p_staff_id uuid,p_shift_code text,p_break_minutes integer
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_shift public.shifts%rowtype; v_business_date date; v_area_id uuid; v_session public.work_sessions%rowtype; v_old jsonb;
begin
  perform public.require_finish_production_access();
  if p_staff_id is null or p_break_minutes is null or p_break_minutes<0 or p_break_minutes>240 then
    raise exception using errcode='22023',message='Break must be between 0 and 240 minutes.';
  end if;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null limit 1;
  if not found then raise exception using errcode='22023',message='Shift must be Morning or Evening.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  select area_id into v_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null;
  select * into v_session from public.work_sessions ws where ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id and ws.staff_id=p_staff_id and ws.area_id=v_area_id and ws.status<>'CANCELLED' order by ws.updated_at desc limit 1 for update;
  if not found then raise exception using errcode='22023',message='Confirm the Finish staff member before changing their break.'; end if;
  v_old:=to_jsonb(v_session);
  update public.work_sessions set break_minutes=p_break_minutes,updated_at=now(),confirmed_by=public.current_staff_id() where work_session_id=v_session.work_session_id returning * into v_session;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),public.current_staff_id(),'UPDATE_FINISH_STAFF_BREAK','work_sessions',v_session.work_session_id::text,v_old,to_jsonb(v_session),format('Actual break set to %s minutes',p_break_minutes),'FINISH_V4');
  return jsonb_build_object('status','saved','staff_id',p_staff_id,'break_minutes',p_break_minutes,'work_session_id',v_session.work_session_id);
end;
$$;

create or replace function public.terminal_set_finish_staff_break_v1(
  p_staff_id uuid,p_shift_code text,p_table_code text,p_break_minutes integer
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_shift public.shifts%rowtype; v_business_date date;
begin
  perform public.require_production_terminal('FINISH',p_table_code);
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null limit 1;
  if not found then raise exception using errcode='22023',message='Shift must be Morning or Evening.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  if not exists(
    select 1 from public.work_sessions ws join public.areas a on a.area_id=ws.area_id join public.stations st on st.station_id=ws.station_id
    where ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id and ws.staff_id=p_staff_id and a.area_code='FINISH'
      and st.station_code=upper(trim(coalesce(p_table_code,''))) and ws.status<>'CANCELLED'
  ) then raise exception using errcode='42501',message='This staff member is not active on this Finish terminal table.'; end if;
  return public.set_finish_staff_break_v1(p_staff_id,p_shift_code,p_break_minutes);
end;
$$;

create or replace function public.set_sorting_staff_break_v1(
  p_staff_id uuid,p_shift_code text,p_break_minutes integer
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_shift public.shifts%rowtype; v_business_date date; v_area_id uuid; v_session public.work_sessions%rowtype; v_old jsonb;
begin
  perform public.require_sorting_operational_access();
  if p_staff_id is null or p_break_minutes is null or p_break_minutes<0 or p_break_minutes>240 then
    raise exception using errcode='22023',message='Break must be between 0 and 240 minutes.';
  end if;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null limit 1;
  if not found then raise exception using errcode='22023',message='Shift must be Morning or Evening.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  select area_id into v_area_id from public.areas where area_code='SORTING' and active=true and deleted_at is null;
  select * into v_session from public.work_sessions ws where ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id and ws.staff_id=p_staff_id and ws.area_id=v_area_id and ws.status<>'CANCELLED' order by case when ws.source='SORTING_MANUAL_POSITION' then 0 else 1 end,ws.updated_at desc limit 1 for update;
  if not found then raise exception using errcode='22023',message='This staff member is not active in Sorting.'; end if;
  v_old:=to_jsonb(v_session);
  update public.work_sessions set break_minutes=p_break_minutes,updated_at=now(),confirmed_by=public.current_staff_id() where work_session_id=v_session.work_session_id returning * into v_session;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),public.current_staff_id(),'UPDATE_SORTING_STAFF_BREAK','work_sessions',v_session.work_session_id::text,v_old,to_jsonb(v_session),format('Actual break set to %s minutes',p_break_minutes),'SORTING_V2');
  return jsonb_build_object('status','saved','staff_id',p_staff_id,'break_minutes',p_break_minutes,'work_session_id',v_session.work_session_id);
end;
$$;

revoke all on function public.set_finish_staff_break_v1(uuid,text,integer) from public,anon;
revoke all on function public.terminal_set_finish_staff_break_v1(uuid,text,text,integer) from public,anon;
revoke all on function public.set_sorting_staff_break_v1(uuid,text,integer) from public,anon;
grant execute on function public.set_finish_staff_break_v1(uuid,text,integer) to authenticated;
grant execute on function public.terminal_set_finish_staff_break_v1(uuid,text,text,integer) to authenticated;
grant execute on function public.set_sorting_staff_break_v1(uuid,text,integer) to authenticated;

comment on function public.set_finish_staff_break_v1(uuid,text,integer) is 'Updates the actual Finish break so worked hours and table metrics deduct the real break.';
comment on function public.set_sorting_staff_break_v1(uuid,text,integer) is 'Updates the actual Sorting break so worked hours and staff performance use the real break.';

commit;
