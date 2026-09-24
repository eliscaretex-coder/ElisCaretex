-- Authenticated employee self-service for My Roster and own leave requests.

create or replace function public.get_my_account_roster_portal()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_staff public.staff_members%rowtype; v_current_week date:=public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date);
begin
 if not public.has_account_permission('MY_ROSTER','VIEW','OWN') then raise exception using errcode='42501',message='Your account cannot view My Roster.'; end if;
 select * into v_staff from public.staff_members where auth_user_id=auth.uid() and active and production_staff and deleted_at is null;
 if not found then raise exception using errcode='P0002',message='This account is not linked to an active Production Staff record.'; end if;
 return jsonb_build_object('generated_at',now(),'fixed_link',false,'staff',jsonb_build_object('staff_id',v_staff.staff_id,'display_name',v_staff.display_name),
 'shifts',coalesce((select jsonb_agg(jsonb_build_object('shift_code',s.shift_code,'shift_name',s.shift_name,
 'weeks',coalesce((select jsonb_agg(week_json order by (week_json->>'week_start')::date) from (
   select jsonb_build_object('week_start',rp.week_start,'week_end',rp.week_start+6,'version_number',prv.version_number,'published_at',prv.published_at,'week_note',prv.week_note,'include_sunday',prv.include_sunday,
   'entries',coalesce((select jsonb_agg(jsonb_build_object(
    'staff_id',pre.staff_id,'display_name',pre.staff_display_name_snapshot,'work_date',pre.work_date,'day_status',pre.day_status,'assignment_type',pre.assignment_type,
    'operational_role_code',pre.operational_role_code_snapshot,'operational_role_name',pre.operational_role_name_snapshot,'area_code',pre.area_code_snapshot,'area_name',pre.area_name_snapshot,
    'station_code',pre.station_code_snapshot,'station_name',pre.station_name_snapshot,'sorting_work_mode',pre.sorting_work_mode,
    'display_section_code',coalesce(pre.display_section_code,public.production_roster_default_display_section(pre.staff_primary_role_code_snapshot,pre.staff_default_station_code_snapshot)),
    'staff_primary_role_code',pre.staff_primary_role_code_snapshot,'staff_primary_role_name',pre.staff_primary_role_name_snapshot,
    'staff_default_area_code',pre.staff_default_area_code_snapshot,'staff_default_area_name',pre.staff_default_area_name_snapshot,
    'staff_default_station_code',pre.staff_default_station_code_snapshot,'staff_default_station_name',pre.staff_default_station_name_snapshot,
    'staff_default_shift_code',coalesce(pre.staff_default_shift_code_snapshot,pre.shift_code_snapshot),'staff_default_shift_name',coalesce(pre.staff_default_shift_name_snapshot,pre.shift_name_snapshot),
    'roster_shift_code',pre.shift_code_snapshot,'roster_shift_name',pre.shift_name_snapshot,'fire_training',pre.fire_training_snapshot,'first_aid_training',pre.first_aid_training_snapshot,'eod_capable',pre.eod_capable_snapshot,'notes',pre.notes
   ) order by pre.work_date) from public.production_roster_entries pre where pre.roster_version_id=prv.roster_version_id and pre.staff_id=v_staff.staff_id),'[]'::jsonb)) week_json
   from public.production_roster_versions prv join public.roster_periods rp on rp.roster_period_id=prv.roster_period_id
   where prv.shift_id=s.shift_id and prv.status='PUBLISHED' and rp.week_start in(v_current_week,v_current_week+7)
     and exists(select 1 from public.production_roster_entries pre where pre.roster_version_id=prv.roster_version_id and pre.staff_id=v_staff.staff_id)
 ) published_weeks),'[]'::jsonb)) order by case upper(s.shift_code) when 'MORNING' then 1 when 'EVENING' then 2 else 99 end)
 from public.shifts s where s.active and s.deleted_at is null and upper(s.shift_code) in('MORNING','EVENING')),'[]'::jsonb));
end; $$;

create or replace function public.get_my_account_leave_requests()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_staff_id uuid;
begin
 if not public.has_account_permission('LEAVE','VIEW','OWN') then raise exception using errcode='42501',message='Your account cannot view leave requests.'; end if;
 select staff_id into v_staff_id from public.staff_members where auth_user_id=auth.uid() and active and deleted_at is null;
 if v_staff_id is null then raise exception using errcode='P0002',message='This account is not linked to Staff Master.'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('leave_request_id',r.leave_request_id,'request_type',r.request_type,'start_date',r.start_date,'end_date',r.end_date,
 'status',r.status,'workflow_status',case when r.status='PENDING' and gm.state='AWAITING_GM' then 'AWAITING_GENERAL_MANAGER' when r.status='PENDING' and gm.state='SEND_FAILED' then 'GENERAL_MANAGER_EMAIL_FAILED' else r.status end,
 'requires_general_manager',r.requires_general_manager,'submitted_at',r.submitted_at,'reviewed_at',r.reviewed_at,'decision_source',r.decision_source) order by r.submitted_at desc)
 from (select * from public.production_roster_leave_requests where staff_id=v_staff_id and submitted_at>=now()-interval '1 month' order by submitted_at desc limit 3) r
 left join public.production_roster_leave_gm_reviews gm on gm.leave_request_id=r.leave_request_id),'[]'::jsonb);
end; $$;

create or replace function public.submit_my_account_leave_request(p_request_type text,p_start_date date,p_end_date date default null,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_staff public.staff_members%rowtype; v_type text:=upper(trim(coalesce(p_request_type,''))); v_start date:=p_start_date; v_end date;
 v_today date:=(now() at time zone 'Europe/Dublin')::date; v_next_monday date; v_request public.production_roster_leave_requests%rowtype;
 v_settings jsonb:=public.production_roster_leave_governance_settings_value(); v_threshold integer; v_duration integer; v_requires_gm boolean;
begin
 if not public.has_account_permission('LEAVE','CREATE','OWN') then raise exception using errcode='42501',message='Your account cannot submit leave requests.'; end if;
 select * into v_staff from public.staff_members where auth_user_id=auth.uid() and active and production_staff and deleted_at is null;
 if not found then raise exception using errcode='P0002',message='This account is not linked to an active Production Staff record.'; end if;
 if v_type not in('DAY_OFF','HOLIDAY') then raise exception using errcode='22023',message='Request type must be Day Off or Holiday.'; end if;
 if v_start is null then raise exception using errcode='22023',message='A request date is required.'; end if;
 v_end:=case when v_type='DAY_OFF' then v_start else coalesce(p_end_date,v_start) end;
 if v_end<v_start then raise exception using errcode='22023',message='The end date cannot be before the start date.'; end if;
 v_next_monday:=public.production_roster_week_start(v_today)+7;
 if v_start<v_next_monday then raise exception using errcode='22023',message='Holiday and Day Off requests can only be submitted for next week or later.'; end if;
 if extract(isodow from v_today)>4 and v_start<v_next_monday+7 then raise exception using errcode='22023',message='Requests for next week close after Thursday. Please choose a later date.'; end if;
 if exists(select 1 from public.production_roster_leave_requests r where r.staff_id=v_staff.staff_id and r.status in('PENDING','APPROVED') and daterange(r.start_date,r.end_date,'[]')&&daterange(v_start,v_end,'[]')) then raise exception using errcode='23505',message='There is already a pending or approved request overlapping these dates.'; end if;
 v_threshold:=greatest(1,coalesce((v_settings->>'general_manager_threshold_days')::integer,20)); v_duration:=(v_end-v_start)+1; v_requires_gm:=v_type='HOLIDAY' and v_duration>v_threshold;
 insert into public.production_roster_leave_requests(staff_id,staff_display_name_snapshot,request_type,start_date,end_date,reason,status,source_application,requires_general_manager,gm_threshold_days_snapshot)
 values(v_staff.staff_id,v_staff.display_name,v_type,v_start,v_end,nullif(trim(p_reason),''),'PENDING','MY_ROSTER',v_requires_gm,v_threshold) returning * into v_request;
 perform public.record_production_roster_leave_event(v_request.leave_request_id,'SUBMITTED',v_staff.display_name,'STAFF',null,'PENDING',v_request.reason,
 jsonb_build_object('request_type',v_type,'start_date',v_start,'end_date',v_end,'duration_days',v_duration,'requires_general_manager',v_requires_gm,'general_manager_threshold_days',v_threshold),auth.uid());
 insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application)
 values(auth.uid(),v_staff.staff_id,'PRODUCTION_ROSTER_LEAVE_REQUEST_SUBMITTED','production_roster_leave_requests',v_request.leave_request_id::text,
 jsonb_build_object('staff_id',v_staff.staff_id,'request_type',v_type,'start_date',v_start,'end_date',v_end,'status','PENDING','requires_general_manager',v_requires_gm),v_request.reason,'MY_ROSTER');
 return jsonb_build_object('leave_request_id',v_request.leave_request_id,'status','PENDING','request_type',v_type,'start_date',v_start,'end_date',v_end,'duration_days',v_duration,
 'requires_general_manager',v_requires_gm,'general_manager_threshold_days',v_threshold,'submitted_at',v_request.submitted_at);
end; $$;

revoke all on function public.get_my_account_roster_portal(),public.get_my_account_leave_requests(),public.submit_my_account_leave_request(text,date,date,text) from public,anon;
grant execute on function public.get_my_account_roster_portal(),public.get_my_account_leave_requests(),public.submit_my_account_leave_request(text,date,date,text) to authenticated;
