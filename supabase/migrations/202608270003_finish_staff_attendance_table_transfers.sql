-- ElisCaretex V2 - Finish Staff attendance and timed table transfers.
-- Published Roster remains the planned record. This migration adds the
-- reversible Actual attendance overlay and the actual time segments used by
-- Finish table productivity metrics.

begin;

create table if not exists public.finish_daily_staff_attendance (
  finish_daily_staff_attendance_id uuid primary key default gen_random_uuid(),
  business_date date not null,
  shift_id uuid not null references public.shifts(shift_id) on delete restrict,
  staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  attendance_status text not null,
  absence_reason text,
  notes text,
  source text not null default 'FINISH_WORKSTATION',
  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by_auth_user_id uuid references auth.users(id) on delete set null,
  constraint finish_daily_staff_attendance_unique unique (business_date, shift_id, staff_id),
  constraint finish_daily_staff_attendance_status_check check (attendance_status in ('PRESENT','ABSENT')),
  constraint finish_daily_staff_attendance_reason_check check (
    absence_reason is null or absence_reason in ('SICK','NO_SHOW','TRAINING','OTHER')
  ),
  constraint finish_daily_staff_attendance_reason_required_check check (
    (attendance_status = 'PRESENT' and absence_reason is null)
    or (attendance_status = 'ABSENT' and absence_reason is not null)
  )
);

alter table public.finish_daily_staff_attendance enable row level security;
revoke all on table public.finish_daily_staff_attendance from public, anon, authenticated;

create index if not exists finish_daily_staff_attendance_date_shift_idx
  on public.finish_daily_staff_attendance (business_date, shift_id, attendance_status, staff_id);

create table if not exists public.finish_staff_table_segments (
  finish_staff_table_segment_id uuid primary key default gen_random_uuid(),
  work_session_id uuid not null references public.work_sessions(work_session_id) on delete cascade,
  station_id uuid not null references public.stations(station_id) on delete restrict,
  started_at timestamptz not null,
  ended_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by_auth_user_id uuid references auth.users(id) on delete set null,
  constraint finish_staff_table_segments_time_check check (ended_at is null or ended_at > started_at)
);

alter table public.finish_staff_table_segments enable row level security;
revoke all on table public.finish_staff_table_segments from public, anon, authenticated;

create index if not exists finish_staff_table_segments_session_started_idx
  on public.finish_staff_table_segments (work_session_id, started_at);
create unique index if not exists finish_staff_table_segments_one_open_per_session_idx
  on public.finish_staff_table_segments (work_session_id)
  where ended_at is null;

-- Existing Finish Actual rows retain their metrics through the legacy fallback
-- below. New and edited rows receive explicit table segments.

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

  if exists (
    select 1
    from public.finish_daily_staff_attendance a
    where a.business_date=p_business_date
      and a.shift_id=p_shift_id
      and a.staff_id=p_staff_id
      and a.attendance_status='ABSENT'
  ) then
    return false;
  end if;

  if not exists(
    select 1 from public.staff_members sm
    where sm.staff_id=p_staff_id and sm.production_staff=true and sm.active=true
      and sm.roster_eligible=true and sm.deleted_at is null
  ) then
    return false;
  end if;

  select ws.* into v_ws
  from public.work_sessions ws
  where ws.staff_id=p_staff_id and ws.work_date=p_business_date and ws.shift_id=p_shift_id
    and upper(coalesce(ws.status,''))<>'CANCELLED'
  order by ws.updated_at desc,ws.created_at desc
  limit 1;

  if found then
    select a.area_code into v_ws_area from public.areas a where a.area_id=v_ws.area_id;
    if v_ws_area<>'FINISH' then
      return false;
    end if;

    if exists (select 1 from public.finish_staff_table_segments s where s.work_session_id=v_ws.work_session_id) then
      return exists (
        select 1
        from public.finish_staff_table_segments s
        where s.work_session_id=v_ws.work_session_id
          and s.station_id=p_station_id
          and s.started_at<=v_at
          and (s.ended_at is null or v_at<s.ended_at)
      );
    end if;

    if v_ws.station_id is distinct from p_station_id then return false; end if;
    if upper(coalesce(v_ws.status,''))='OPEN' then return true; end if;
    if v_ws.actual_start_at is null or v_at<v_ws.actual_start_at then return false; end if;
    if v_ws.actual_end_at is not null and v_at>v_ws.actual_end_at+interval '15 minutes' then return false; end if;
    return true;
  end if;

  return exists(
    select 1
    from public.production_roster_entries pre
    join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
    where pre.staff_id=p_staff_id and pre.work_date=p_business_date and prv.status='PUBLISHED'
      and prv.shift_id=p_shift_id and upper(coalesce(pre.area_code_snapshot,''))='FINISH'
      and pre.station_id=p_station_id and upper(coalesce(pre.day_status,'')) in ('WORKING','COVER')
  );
end;
$$;

revoke all on function public.finish_processing_staff_available(uuid,date,uuid,uuid,timestamptz)
  from public,anon,authenticated;

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
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null;
  if not found or v_shift.shift_code not in ('MORNING','EVENING') then raise exception using errcode='22023', message='Shift must be Morning or Evening.'; end if;
  select st.* into v_station from public.stations st join public.areas a on a.area_id=st.area_id where st.station_code=upper(trim(coalesce(p_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  if not found or v_station.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then raise exception using errcode='22023', message='Choose Finish Table 1, Table 2 or Table 3.'; end if;
  select area_id into v_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null;
  select * into v_staff from public.staff_members where staff_id=p_staff_id and production_staff=true and active=true and roster_eligible=true and deleted_at is null;
  if not found then raise exception using errcode='22023', message='Selected staff member is not active production staff.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  if p_start_time is not null then v_start:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_start_time); end if;
  if p_end_time is not null then v_end:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_end_time); end if;
  if v_start is not null and v_end is not null and v_end<v_start then raise exception using errcode='22023', message='Leaving time cannot be before Started at.'; end if;
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
    update public.work_sessions set station_id=v_station.station_id,actual_start_at=coalesce(v_start,actual_start_at),actual_end_at=v_end,status=case when v_end is null then 'OPEN' else 'CONFIRMED' end,source='FINISH_V2',confirmed_by=v_actor,notes=coalesce(nullif(trim(p_reason),''),notes),updated_at=now() where work_session_id=v_existing.work_session_id returning * into v_saved;
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
    set started_at=coalesce(v_start,started_at),ended_at=v_end,updated_at=now(),updated_by_auth_user_id=auth.uid()
    where work_session_id=v_saved.work_session_id;
  end if;

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,case when v_old is null then 'CREATE_FINISH_STAFF_ACTUAL' else 'UPDATE_FINISH_STAFF_ACTUAL' end,'work_sessions',v_saved.work_session_id::text,v_old,to_jsonb(v_saved),p_reason,'FINISH_V2');
  return jsonb_build_object('status','saved','work_session_id',v_saved.work_session_id,'staff_id',p_staff_id,'table_code',v_station.station_code,'business_date',v_business_date,'shift_code',v_shift.shift_code,'actual_start_at',v_saved.actual_start_at,'actual_end_at',v_saved.actual_end_at);
end;
$$;

create or replace function public.set_finish_staff_attendance_v1(
  p_shift_code text,
  p_staff_id uuid,
  p_attendance_status text,
  p_absence_reason text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_shift_code text:=upper(trim(coalesce(p_shift_code,'')));
  v_status text:=upper(trim(coalesce(p_attendance_status,'')));
  v_reason text:=nullif(upper(trim(coalesce(p_absence_reason,''))), '');
  v_notes text:=nullif(trim(coalesce(p_notes,'')), '');
  v_business_date date; v_shift public.shifts%rowtype; v_staff_name text; v_old jsonb; v_new public.finish_daily_staff_attendance%rowtype;
  v_actor uuid:=public.current_staff_id();
begin
  perform public.require_finish_production_access();
  if p_staff_id is null then raise exception using errcode='22023',message='Staff is required.'; end if;
  if v_status not in ('PRESENT','ABSENT') then raise exception using errcode='22023',message='Attendance must be PRESENT or ABSENT.'; end if;
  if v_status='ABSENT' and v_reason not in ('SICK','NO_SHOW','TRAINING','OTHER') then raise exception using errcode='22023',message='Choose Sick, No show, Training or Other.'; end if;
  if v_status='PRESENT' then v_reason:=null; end if;
  if v_notes is not null and length(v_notes)>1000 then raise exception using errcode='22023',message='Attendance notes must be 1000 characters or fewer.'; end if;
  select * into v_shift from public.shifts where shift_code=v_shift_code and active=true and deleted_at is null limit 1;
  if not found then raise exception using errcode='P0002',message='Selected shift is not available.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift_code);
  select sm.display_name into v_staff_name from public.staff_members sm where sm.staff_id=p_staff_id and sm.production_staff=true and sm.active=true and sm.roster_eligible=true and sm.deleted_at is null;
  if not found then raise exception using errcode='22023',message='Selected staff member is not active production staff.'; end if;
  if not exists(
    select 1 from public.production_roster_entries pre join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
    where pre.staff_id=p_staff_id and pre.work_date=v_business_date and prv.status='PUBLISHED' and prv.shift_id=v_shift.shift_id
      and pre.area_code_snapshot='FINISH' and upper(coalesce(pre.day_status,'')) in ('WORKING','QUALITY_ANALYSIS','COVER')
  ) and not exists(
    select 1 from public.work_sessions ws join public.areas a on a.area_id=ws.area_id
    where ws.staff_id=p_staff_id and ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id and a.area_code='FINISH' and ws.status<>'CANCELLED'
  ) then raise exception using errcode='22023',message='This staff member is not active in Finish for this shift.'; end if;
  if v_status='ABSENT' and exists(
    select 1 from public.finish_production_entries e
    where e.production_business_date=v_business_date and e.shift_code_snapshot=v_shift_code and e.status='ACTIVE' and e.processed_by_staff_id=p_staff_id
  ) then raise exception using errcode='22023',message=format('%s already has recorded Finish production. Correct that activity before marking the whole shift absent.',v_staff_name); end if;
  select to_jsonb(a) into v_old from public.finish_daily_staff_attendance a where a.business_date=v_business_date and a.shift_id=v_shift.shift_id and a.staff_id=p_staff_id;
  insert into public.finish_daily_staff_attendance(business_date,shift_id,staff_id,attendance_status,absence_reason,notes,source,created_by_auth_user_id,updated_by_auth_user_id)
  values(v_business_date,v_shift.shift_id,p_staff_id,v_status,v_reason,v_notes,'FINISH_WORKSTATION',auth.uid(),auth.uid())
  on conflict(business_date,shift_id,staff_id) do update set attendance_status=excluded.attendance_status,absence_reason=excluded.absence_reason,notes=excluded.notes,source='FINISH_WORKSTATION',updated_at=now(),updated_by_auth_user_id=auth.uid()
  returning * into v_new;
  if v_status='ABSENT' then
    update public.work_sessions ws set status='CANCELLED',notes=coalesce(ws.notes,'') || case when v_notes is null then '' else ' | Absent: '||v_notes end,updated_at=now()
    where ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id and ws.staff_id=p_staff_id and ws.status<>'CANCELLED'
      and exists(select 1 from public.areas a where a.area_id=ws.area_id and a.area_code='FINISH');
  end if;
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,'FINISH_ATTENDANCE_CHANGED','finish_daily_staff_attendance',v_new.finish_daily_staff_attendance_id::text,v_old,to_jsonb(v_new),coalesce(v_notes,case when v_status='PRESENT' then 'Attendance corrected to Present' else replace(initcap(lower(v_reason)),'_',' ') end),'FINISH_V3');
  return jsonb_build_object('status','saved','business_date',v_business_date,'shift_code',v_shift_code,'staff_id',p_staff_id,'staff_name',v_staff_name,'attendance_status',v_status,'absence_reason',v_reason);
end;
$$;

create or replace function public.move_finish_staff_table_v1(
  p_staff_id uuid,
  p_shift_code text,
  p_from_table_code text,
  p_to_table_code text,
  p_move_time time,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  v_business_date date; v_shift public.shifts%rowtype; v_area_id uuid; v_from public.stations%rowtype; v_to public.stations%rowtype;
  v_ws public.work_sessions%rowtype; v_open public.finish_staff_table_segments%rowtype; v_move_at timestamptz; v_actor uuid:=public.current_staff_id();
  v_planned_start time; v_start_at timestamptz; v_old jsonb; v_new jsonb; v_staff_name text;
begin
  perform public.require_finish_production_access();
  if p_staff_id is null or p_move_time is null then raise exception using errcode='22023',message='Staff and move time are required.'; end if;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,''))) and active=true and deleted_at is null limit 1;
  if not found then raise exception using errcode='22023',message='Shift must be Morning or Evening.'; end if;
  v_business_date:=public.operational_business_date_for_shift(v_shift.shift_code);
  select st.* into v_from from public.stations st join public.areas a on a.area_id=st.area_id where st.station_code=upper(trim(coalesce(p_from_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  select st.* into v_to from public.stations st join public.areas a on a.area_id=st.area_id where st.station_code=upper(trim(coalesce(p_to_table_code,''))) and a.area_code='FINISH' and st.active=true and st.deleted_at is null;
  if not found or v_to.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then raise exception using errcode='22023',message='Choose a valid destination Finish Table.'; end if;
  if v_from.station_id is null or v_from.station_code not in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') then raise exception using errcode='22023',message='Choose the current Finish Table.'; end if;
  if v_from.station_id=v_to.station_id then raise exception using errcode='22023',message='Choose a different Finish Table.'; end if;
  if exists(select 1 from public.finish_daily_staff_attendance a where a.business_date=v_business_date and a.shift_id=v_shift.shift_id and a.staff_id=p_staff_id and a.attendance_status='ABSENT') then raise exception using errcode='22023',message='Mark the staff member present before moving them.'; end if;
  select area_id into v_area_id from public.areas where area_code='FINISH' and active=true and deleted_at is null;
  select * into v_ws from public.work_sessions ws where ws.work_date=v_business_date and ws.shift_id=v_shift.shift_id and ws.staff_id=p_staff_id and ws.area_id=v_area_id and ws.status<>'CANCELLED' order by ws.updated_at desc limit 1 for update;
  if not found then raise exception using errcode='22023',message='Confirm this staff member on the current Table before moving them.'; end if;
  select sm.display_name into v_staff_name from public.staff_members sm where sm.staff_id=p_staff_id;
  v_move_at:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,p_move_time);
  select * into v_open from public.finish_staff_table_segments s where s.work_session_id=v_ws.work_session_id and s.ended_at is null order by s.started_at desc limit 1 for update;
  if not found then
    if v_ws.station_id is distinct from v_from.station_id then raise exception using errcode='22023',message='This staff member is not currently assigned to the selected Table.'; end if;
    v_start_at:=v_ws.actual_start_at;
    if v_start_at is null then
      select pre.planned_start_time into v_planned_start from public.production_roster_entries pre join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
      where pre.staff_id=p_staff_id and pre.work_date=v_business_date and prv.status='PUBLISHED' and prv.shift_id=v_shift.shift_id and pre.area_code_snapshot='FINISH'
      order by prv.version_number desc,prv.published_at desc nulls last limit 1;
      if v_planned_start is null then raise exception using errcode='22023',message='Set the staff start time before moving between Tables.'; end if;
      v_start_at:=public.operational_timestamp_for_shift(v_business_date,v_shift.shift_code,v_planned_start);
      update public.work_sessions set actual_start_at=v_start_at,updated_at=now() where work_session_id=v_ws.work_session_id returning * into v_ws;
    end if;
    if v_move_at<=v_start_at then raise exception using errcode='22023',message='Move time must be after the staff start time.'; end if;
    insert into public.finish_staff_table_segments(work_session_id,station_id,started_at,ended_at,notes,created_by_auth_user_id,updated_by_auth_user_id)
    values(v_ws.work_session_id,v_from.station_id,v_start_at,v_move_at,nullif(trim(p_notes),''),auth.uid(),auth.uid());
  else
    if v_open.station_id is distinct from v_from.station_id then raise exception using errcode='22023',message='This staff member is not currently working on the selected Table.'; end if;
    if v_move_at<=v_open.started_at then raise exception using errcode='22023',message='Move time must be after the current Table start time.'; end if;
    update public.finish_staff_table_segments set ended_at=v_move_at,notes=coalesce(nullif(trim(p_notes),''),notes),updated_at=now(),updated_by_auth_user_id=auth.uid() where finish_staff_table_segment_id=v_open.finish_staff_table_segment_id;
  end if;
  v_old:=to_jsonb(v_ws);
  insert into public.finish_staff_table_segments(work_session_id,station_id,started_at,notes,created_by_auth_user_id,updated_by_auth_user_id)
  values(v_ws.work_session_id,v_to.station_id,v_move_at,nullif(trim(p_notes),''),auth.uid(),auth.uid());
  update public.work_sessions set station_id=v_to.station_id,actual_end_at=null,status='OPEN',source='FINISH_TABLE_TRANSFER',notes=coalesce(nullif(trim(p_notes),''),notes),updated_at=now() where work_session_id=v_ws.work_session_id returning * into v_ws;
  v_new:=to_jsonb(v_ws);
  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),v_actor,'FINISH_TABLE_TRANSFERRED','work_sessions',v_ws.work_session_id::text,v_old,v_new,format('%s moved from %s to %s at %s%s',coalesce(v_staff_name,'Staff'),v_from.station_name,v_to.station_name,to_char(v_move_at at time zone 'Europe/Dublin','HH24:MI'),case when nullif(trim(p_notes),'') is null then '' else ': '||trim(p_notes) end),'FINISH_V3');
  return jsonb_build_object('status','moved','business_date',v_business_date,'shift_code',v_shift.shift_code,'staff_id',p_staff_id,'from_table_code',v_from.station_code,'to_table_code',v_to.station_code,'moved_at',v_move_at);
end;
$$;

create or replace function public.get_finish_staff_context_v3(
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
  v_base jsonb; v_staff jsonb; v_shift public.shifts%rowtype; v_business_date date;
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_staff_context_v2(p_shift_code,p_at);
  v_business_date:=nullif(v_base->>'business_date','')::date;
  select * into v_shift from public.shifts where shift_code=upper(trim(coalesce(p_shift_code,'MORNING'))) and active=true and deleted_at is null limit 1;
  with base_rows as (
    select value item from jsonb_array_elements(coalesce(v_base->'staff','[]'::jsonb))
  ), segments as (
    select s.work_session_id,
      coalesce(jsonb_agg(jsonb_build_object('table_code',st.station_code,'started_at',s.started_at,'ended_at',s.ended_at) order by s.started_at),'[]'::jsonb) as items
    from public.finish_staff_table_segments s join public.stations st on st.station_id=s.station_id group by s.work_session_id
  )
  select coalesce(jsonb_agg(
    case when a.attendance_status='ABSENT' then br.item || jsonb_build_object(
      'attendance_status','ABSENT','absence_reason',a.absence_reason,'attendance_notes',a.notes,
      'actual_in_finish',false,'actual_status','ABSENT','staff_state','ABSENT',
      'effective_table_code',br.item->>'planned_table_code','actual_start_at',null,'actual_end_at',null,
      'table_segments',coalesce(s.items,'[]'::jsonb)
    ) else br.item || jsonb_build_object(
      'attendance_status',coalesce(a.attendance_status,'PRESENT'),'absence_reason',null,'attendance_notes',a.notes,
      'table_segments',coalesce(s.items,'[]'::jsonb)
    ) end
    order by coalesce(case when a.attendance_status='ABSENT' then br.item->>'planned_table_code' else br.item->>'effective_table_code' end,br.item->>'planned_table_code','ZZZ'),lower(coalesce(br.item->>'display_name',''))
  ),'[]'::jsonb) into v_staff
  from base_rows br
  left join public.finish_daily_staff_attendance a on a.business_date=v_business_date and a.shift_id=v_shift.shift_id and a.staff_id=nullif(br.item->>'staff_id','')::uuid
  left join segments s on s.work_session_id=nullif(br.item->>'work_session_id','')::uuid;
  return (v_base-'schema_version'-'source_contract'-'staff')||jsonb_build_object(
    'schema_version','FINISH_STAFF_V3','source_contract','PUBLISHED_ROSTER_PLUS_REVERSIBLE_ATTENDANCE_AND_TABLE_SEGMENTS','staff',v_staff
  );
end;
$$;

create or replace function public.get_finish_production_context_v3(
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
  v_base jsonb; v_entries jsonb; v_tables jsonb; v_shift text:=upper(trim(coalesce(p_shift_code,'MORNING'))); v_now timestamptz:=coalesce(p_at,now()); v_business_date date; v_shift_id uuid; v_target numeric:=23.5;
begin
  perform public.require_finish_production_access();
  v_base:=public.get_finish_production_context_v2(v_shift,v_now);
  v_business_date:=nullif(v_base->>'business_date','')::date;
  select shift_id into v_shift_id from public.shifts where shift_code=v_shift and active=true and deleted_at is null limit 1;
  select coalesce((select target_value from public.production_targets where target_code='FINISH_TABLE_KG_PER_STAFF_HOUR' and active=true limit 1),23.5) into v_target;
  with table_master as (
    select st.station_id,st.station_code,st.station_name from public.stations st join public.areas a on a.area_id=st.area_id
    where a.area_code='FINISH' and st.station_code in ('FINISH_TABLE_1','FINISH_TABLE_2','FINISH_TABLE_3') and st.active=true and st.deleted_at is null
  ), segmented as (
    select s.station_id,ws.staff_id,
      greatest(0,extract(epoch from (least(coalesce(s.ended_at,v_now),v_now)-s.started_at))/3600.0) gross_hours,
      sum(greatest(0,extract(epoch from (least(coalesce(s.ended_at,v_now),v_now)-s.started_at))/3600.0)) over(partition by ws.work_session_id) total_hours,
      coalesce(ws.break_minutes,0)+coalesce(ws.extra_non_work_minutes,0) as non_work_minutes
    from public.finish_staff_table_segments s join public.work_sessions ws on ws.work_session_id=s.work_session_id join public.areas a on a.area_id=ws.area_id
    where ws.work_date=v_business_date and ws.shift_id=v_shift_id and ws.status<>'CANCELLED' and a.area_code='FINISH' and s.started_at<=v_now
  ), segment_metrics as (
    select station_id,staff_id,greatest(0,gross_hours-(non_work_minutes/60.0)*(gross_hours/nullif(total_hours,0))) net_hours from segmented where gross_hours>0
  ), legacy_metrics as (
    select ws.station_id,ws.staff_id,greatest(0,extract(epoch from (least(coalesce(ws.actual_end_at,v_now),v_now)-ws.actual_start_at))/3600.0-(coalesce(ws.break_minutes,0)+coalesce(ws.extra_non_work_minutes,0))/60.0) net_hours
    from public.work_sessions ws join public.areas a on a.area_id=ws.area_id
    where ws.work_date=v_business_date and ws.shift_id=v_shift_id and ws.status<>'CANCELLED' and a.area_code='FINISH' and ws.actual_start_at is not null
      and not exists(select 1 from public.finish_staff_table_segments s where s.work_session_id=ws.work_session_id)
  ), all_metrics as (select * from segment_metrics union all select * from legacy_metrics), hours as (
    select station_id,sum(net_hours) staff_hours,count(distinct staff_id) filter(where net_hours>0) staff_count from all_metrics group by station_id
  ), prod as (
    select e.table_code_snapshot station_code,coalesce(sum(l.quantity) filter(where l.unit_code='KG'),0) produced_kg,coalesce(sum(l.quantity) filter(where l.unit_code='UNIT'),0) produced_units
    from public.finish_production_entries e join public.finish_production_lines l on l.finish_production_entry_id=e.finish_production_entry_id
    where e.status='ACTIVE' and e.production_business_date=v_business_date and e.shift_code_snapshot=v_shift group by e.table_code_snapshot
  )
  select coalesce(jsonb_agg(jsonb_build_object('table_code',tm.station_code,'table_name',tm.station_name,'produced_kg',coalesce(p.produced_kg,0),'produced_units',coalesce(p.produced_units,0),'staff_hours',round(coalesce(h.staff_hours,0)::numeric,2),'staff_count',coalesce(h.staff_count,0),'target_kg_per_staff_hour',v_target,'target_now_kg',round((coalesce(h.staff_hours,0)*v_target)::numeric,2),'difference_kg',round((coalesce(p.produced_kg,0)-coalesce(h.staff_hours,0)*v_target)::numeric,2),'kg_per_staff_hour',case when coalesce(h.staff_hours,0)>0 then round((coalesce(p.produced_kg,0)/h.staff_hours)::numeric,2) else null end,'efficiency_percent',case when coalesce(h.staff_hours,0)>0 then round((coalesce(p.produced_kg,0)/(h.staff_hours*v_target)*100)::numeric,1) else null end) order by tm.station_code),'[]'::jsonb) into v_tables
  from table_master tm left join hours h on h.station_id=tm.station_id left join prod p on p.station_code=tm.station_code;
  with base_entries as (select item,ordinality from jsonb_array_elements(coalesce(v_base->'entries','[]'::jsonb)) with ordinality x(item,ordinality))
  select coalesce(jsonb_agg(b.item||jsonb_build_object('trolley_scan_status',coalesce(e.trolley_scan_status,'UNSPECIFIED')) order by b.ordinality),'[]'::jsonb) into v_entries
  from base_entries b left join public.finish_production_entries e on e.finish_production_entry_id=nullif(b.item->>'finish_production_entry_id','')::uuid;
  return (v_base-'schema_version'-'source_contract'-'entries'-'tables')||jsonb_build_object('schema_version','FINISH_PRODUCTION_V3','source_contract','FINISH_V3_PRACTICAL_EDIT_TROLLEY_STATUS_WITH_TABLE_SEGMENT_METRICS','entries',v_entries,'tables',v_tables,'typed_correction_reason_required',false,'trolley_pending_supported',true);
end;
$$;

create or replace function public.terminal_set_finish_staff_attendance_v1(
  p_shift_code text,p_staff_id uuid,p_attendance_status text,p_absence_reason text default null,p_notes text default null
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_table_code text;
begin
  select coalesce(pre.station_code_snapshot,st.station_code) into v_table_code
  from public.production_roster_entries pre join public.production_roster_versions prv on prv.roster_version_id=pre.roster_version_id
  left join public.stations st on st.station_id=pre.station_id
  where pre.staff_id=p_staff_id and pre.work_date=public.operational_business_date_for_shift(p_shift_code) and prv.status='PUBLISHED'
    and upper(coalesce(pre.area_code_snapshot,''))='FINISH'
  order by prv.version_number desc,prv.published_at desc nulls last limit 1;
  if v_table_code is null then raise exception using errcode='22023',message='This staff member is not planned for a Finish Table in this shift.'; end if;
  perform public.require_production_terminal('FINISH',v_table_code);
  return public.set_finish_staff_attendance_v1(p_shift_code,p_staff_id,p_attendance_status,p_absence_reason,p_notes);
end;
$$;

create or replace function public.terminal_move_finish_staff_table_v1(
  p_staff_id uuid,p_shift_code text,p_from_table_code text,p_to_table_code text,p_move_time time,p_notes text default null
)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_production_terminal('FINISH',p_from_table_code);
  return public.move_finish_staff_table_v1(p_staff_id,p_shift_code,p_from_table_code,p_to_table_code,p_move_time,p_notes);
end;
$$;

revoke all on function public.upsert_finish_staff_actual(uuid,text,text,time,time,text) from public,anon;
revoke all on function public.set_finish_staff_attendance_v1(text,uuid,text,text,text) from public,anon;
revoke all on function public.move_finish_staff_table_v1(uuid,text,text,text,time,text) from public,anon;
revoke all on function public.get_finish_staff_context_v3(text,timestamptz) from public,anon;
revoke all on function public.get_finish_production_context_v3(text,timestamptz) from public,anon;
revoke all on function public.terminal_set_finish_staff_attendance_v1(text,uuid,text,text,text) from public,anon;
revoke all on function public.terminal_move_finish_staff_table_v1(uuid,text,text,text,time,text) from public,anon;
grant execute on function public.upsert_finish_staff_actual(uuid,text,text,time,time,text) to authenticated;
grant execute on function public.set_finish_staff_attendance_v1(text,uuid,text,text,text) to authenticated;
grant execute on function public.move_finish_staff_table_v1(uuid,text,text,text,time,text) to authenticated;
grant execute on function public.get_finish_staff_context_v3(text,timestamptz) to authenticated;
grant execute on function public.get_finish_production_context_v3(text,timestamptz) to authenticated;
grant execute on function public.terminal_set_finish_staff_attendance_v1(text,uuid,text,text,text) to authenticated;
grant execute on function public.terminal_move_finish_staff_table_v1(uuid,text,text,text,time,text) to authenticated;

comment on function public.get_finish_staff_context_v3(text,timestamptz) is 'Finish Staff V3: published roster plus reversible Actual attendance and time-segmented Finish table history.';
comment on function public.move_finish_staff_table_v1(uuid,text,text,text,time,text) is 'Moves a confirmed Finish staff member between tables at an explicit time and keeps each table metrics proportional to the time worked there.';

commit;
