-- Customer Service tasks can also go to a person (supervisor, manager or a General
-- Operative given extra work), not only to a department.
--
-- Owner request (2026-11-06): "daria para tambem destinar a pessoas, que seriam
-- supervisores, gerentes, ou ate uns ou outros GOs que irao receber atividades extras".
--
-- A task still names the department that answers for it (it decides which production
-- screen shows it and how Results count it). The person is optional:
--   * Staff Master people (most General Operatives have no sign-in): the task shows
--     "For <name>" on their area's production screen.
--   * People with a sign-in (supervisors, managers, office): the task also appears in
--     their Notifications under "Needs action", where they mark it done.
-- The person is stored as Staff Master id and/or sign-in id, with the name as a snapshot.

alter table public.customer_service_tasks
  add column if not exists assigned_staff_id uuid references public.staff_members(staff_id) on delete set null,
  add column if not exists assigned_auth_user_id uuid references auth.users(id) on delete set null,
  add column if not exists assigned_name text;

create index if not exists customer_service_tasks_assigned_user_idx
  on public.customer_service_tasks(assigned_auth_user_id) where status in ('OPEN','IN_PROGRESS');
create index if not exists customer_service_tasks_assigned_staff_idx
  on public.customer_service_tasks(assigned_staff_id) where status in ('OPEN','IN_PROGRESS');

-- People a task can go to: active Staff Master people, and sign-in accounts (not
-- production terminals) that are not linked to a Staff Master record.
-- key is 'S:<staff_id>' or 'U:<auth_user_id>'. No email is returned.
create or replace function public.get_customer_service_task_people_v1()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_customer_service_access('VIEW');
  return coalesce((select jsonb_agg(jsonb_build_object('key',x.key,'name',x.name,'detail',x.detail,'has_login',x.has_login)
      order by x.rank,lower(x.name))
    from (
      select 'S:'||s.staff_id as key, s.display_name as name,
        coalesce(jt.job_title_name,r.role_name,'Staff') as detail,
        (s.auth_user_id is not null) as has_login,
        case when r.role_code='GENERAL_OPERATIVE' and jt.job_title_code is null then 2 else 1 end as rank
      from public.staff_members s
      left join public.operational_roles r on r.operational_role_id=s.primary_operational_role_id
      left join public.account_access_profiles ap on ap.auth_user_id=s.auth_user_id
      left join public.account_job_titles jt on jt.job_title_code=ap.job_title_code
      where s.active and s.deleted_at is null and nullif(trim(s.display_name),'') is not null
      union all
      select 'U:'||ap.auth_user_id, ap.display_name, coalesce(jt.job_title_name,'Account'), true, 1
      from public.account_access_profiles ap
      left join public.account_job_titles jt on jt.job_title_code=ap.job_title_code
      where ap.account_type<>'TERMINAL' and nullif(trim(ap.display_name),'') is not null
        and not exists(select 1 from public.staff_members s where s.auth_user_id=ap.auth_user_id and s.active and s.deleted_at is null)
    ) x),'[]'::jsonb);
end;$$;

revoke all on function public.get_customer_service_task_people_v1() from public,anon;
grant execute on function public.get_customer_service_task_people_v1() to authenticated;

-- Task JSON: adds the person.
create or replace function public.customer_service_task_json(p_task_id uuid)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object(
    'task_id',k.task_id,'complaint_id',k.complaint_id,'complaint_code',c.complaint_code,
    'customer_id',k.customer_id,'customer_code',cu.customer_code,'customer_name',cu.customer_name,
    'department_code',k.department_code,'title',k.title,'details',k.details,'due_on',k.due_on,'status',k.status,
    'assigned_key',case when k.assigned_staff_id is not null then 'S:'||k.assigned_staff_id when k.assigned_auth_user_id is not null then 'U:'||k.assigned_auth_user_id end,
    'assigned_name',k.assigned_name,
    'assigned_has_login',k.assigned_auth_user_id is not null,
    'overdue',k.status in ('OPEN','IN_PROGRESS') and k.due_on is not null and k.due_on<public.customer_service_today(),
    'completion_notes',k.completion_notes,'completed_at',k.completed_at,'completed_by_name',k.completed_by_name,
    'created_at',k.created_at,'created_by_name',public.customer_service_user_name(k.created_by_auth_user_id))
  from public.customer_service_tasks k
  left join public.customers cu on cu.customer_id=k.customer_id
  left join public.customer_service_complaints c on c.complaint_id=k.complaint_id
  where k.task_id=p_task_id;
$$;
revoke all on function public.customer_service_task_json(uuid) from public,anon,authenticated;

-- Save a task with an optional person. v1 stays for older screens and keeps the person.
create or replace function public.save_customer_service_task_v2(p_task_id uuid,p_department_code text,p_title text,
  p_details text default null,p_due_on date default null,p_complaint_id uuid default null,p_customer_id uuid default null,
  p_assignee_key text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_id uuid; v_row public.customer_service_tasks; v_customer uuid:=p_customer_id; v_dept text:=upper(trim(coalesce(p_department_code,'')));
  v_key text:=nullif(trim(coalesce(p_assignee_key,'')),''); v_staff uuid; v_user uuid; v_name text; v_ref uuid;
begin
  perform public.require_customer_service_access(case when p_task_id is null then 'CREATE' else 'EDIT' end);
  if v_dept not in ('SORTING','FINISH','MOP','DISTRIBUTION','CUSTOMER_SERVICE','MAINTENANCE','MANAGEMENT') then
    raise exception using errcode='22023',message='Choose the department that must do the task.';
  end if;
  if length(trim(coalesce(p_title,'')))<3 then raise exception using errcode='22023',message='Write what must be done.'; end if;
  if p_complaint_id is not null then
    select c.customer_id into v_customer from public.customer_service_complaints c
    where c.complaint_id=p_complaint_id and public.customer_service_customer_visible(c.customer_id,c.created_by_auth_user_id);
    if v_customer is null then raise exception using errcode='P0002',message='Complaint not found.'; end if;
  end if;

  if v_key is not null then
    begin v_ref:=substr(v_key,3)::uuid; exception when others then v_ref:=null; end;
    if left(v_key,2)='S:' and v_ref is not null then
      select s.staff_id,s.auth_user_id,s.display_name into v_staff,v_user,v_name from public.staff_members s
      where s.staff_id=v_ref and s.active and s.deleted_at is null;
    elsif left(v_key,2)='U:' and v_ref is not null then
      select ap.auth_user_id,ap.display_name into v_user,v_name from public.account_access_profiles ap
      where ap.auth_user_id=v_ref and ap.account_type<>'TERMINAL';
    end if;
    if v_name is null then raise exception using errcode='22023',message='Choose a person from the list.'; end if;
  end if;

  if p_task_id is null then
    insert into public.customer_service_tasks(complaint_id,customer_id,department_code,title,details,due_on,created_by_auth_user_id,
      assigned_staff_id,assigned_auth_user_id,assigned_name)
    values(p_complaint_id,v_customer,v_dept,trim(p_title),nullif(trim(p_details),''),p_due_on,auth.uid(),v_staff,v_user,v_name)
    returning task_id into v_id;
    perform public.customer_service_log(p_complaint_id,'TASK_CREATED',p_title,
      jsonb_strip_nulls(jsonb_build_object('department',v_dept,'due_on',p_due_on,'person',v_name)),null,v_id);
    return public.customer_service_task_json(v_id);
  end if;

  select * into v_row from public.customer_service_tasks where task_id=p_task_id for update;
  if v_row.task_id is null or (v_row.customer_id is not null and not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id)) then
    raise exception using errcode='P0002',message='Task not found.';
  end if;
  update public.customer_service_tasks set department_code=v_dept,title=trim(p_title),details=nullif(trim(p_details),''),due_on=p_due_on,
    assigned_staff_id=v_staff,assigned_auth_user_id=v_user,assigned_name=v_name,updated_at=now()
  where task_id=p_task_id;
  perform public.customer_service_log(v_row.complaint_id,'TASK_EDITED',p_title,
    jsonb_strip_nulls(jsonb_build_object('department',v_dept,'due_on',p_due_on,'person',v_name)),null,p_task_id);
  return public.customer_service_task_json(p_task_id);
end;$$;

revoke all on function public.save_customer_service_task_v2(uuid,text,text,text,date,uuid,uuid,text) from public,anon;
grant execute on function public.save_customer_service_task_v2(uuid,text,text,text,date,uuid,uuid,text) to authenticated;

-- Tasks list: optional filter by person key ('S:..' / 'U:..').
create or replace function public.get_customer_service_tasks_v2(p_status text default 'ACTIVE',p_department_code text default null,p_assignee_key text default null)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_status text:=upper(coalesce(nullif(trim(p_status),''),'ACTIVE')); v_key text:=nullif(trim(coalesce(p_assignee_key,'')),'');
begin
  perform public.require_customer_service_access('VIEW');
  return coalesce((select jsonb_agg(public.customer_service_task_json(k.task_id)
      order by (k.status in ('OPEN','IN_PROGRESS')) desc,k.due_on nulls last,k.created_at desc)
    from public.customer_service_tasks k
    where (k.customer_id is null or public.customer_service_customer_visible(k.customer_id,k.created_by_auth_user_id))
      and (p_department_code is null or k.department_code=upper(trim(p_department_code)))
      and (v_key is null
        or (v_key='NONE' and k.assigned_staff_id is null and k.assigned_auth_user_id is null)
        or (left(v_key,2)='S:' and k.assigned_staff_id::text=substr(v_key,3))
        or (left(v_key,2)='U:' and k.assigned_staff_id is null and k.assigned_auth_user_id::text=substr(v_key,3)))
      and case when v_status='ACTIVE' then k.status in ('OPEN','IN_PROGRESS')
        when v_status='ALL' then k.status in ('OPEN','IN_PROGRESS') or k.updated_at>=now()-interval '180 days'
        else k.status=v_status and k.updated_at>=now()-interval '180 days' end),'[]'::jsonb);
end;$$;

revoke all on function public.get_customer_service_tasks_v2(text,text,text) from public,anon;
grant execute on function public.get_customer_service_tasks_v2(text,text,text) to authenticated;

-- Production screens: each task says who it is for.
create or replace function public.get_production_customer_alerts_v1(p_area_code text)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_area text:=upper(trim(coalesce(p_area_code,''))); v_today date:=public.customer_service_today();
begin
  if public.customer_service_access_scope() is null then
    perform public.require_production_flow_read_role();
  end if;
  if v_area not in ('SORTING','FINISH','MOP','DISTRIBUTION') then raise exception using errcode='22023',message='Unknown production area.'; end if;
  return jsonb_build_object(
    'area_code',v_area,
    'alerts',coalesce((select jsonb_agg(jsonb_build_object('alert_id',a.alert_id,'customer_id',a.customer_id,'customer_code',cu.customer_code,'customer_name',cu.customer_name,
        'message',a.message,'starts_on',a.starts_on,'ends_on',a.ends_on) order by lower(cu.customer_name))
      from public.customer_service_alerts a join public.customers cu on cu.customer_id=a.customer_id
      where a.ended_at is null and v_area=any(a.areas) and a.starts_on<=v_today and (a.ends_on is null or a.ends_on>=v_today)),'[]'::jsonb),
    'tasks',coalesce((select jsonb_agg(jsonb_build_object('task_id',k.task_id,'title',k.title,'details',k.details,'due_on',k.due_on,'status',k.status,
        'overdue',k.due_on is not null and k.due_on<v_today,'customer_name',cu.customer_name,'assigned_name',k.assigned_name) order by k.due_on nulls last,k.created_at)
      from public.customer_service_tasks k left join public.customers cu on cu.customer_id=k.customer_id
      where k.department_code=v_area and k.status in ('OPEN','IN_PROGRESS')),'[]'::jsonb)
  );
end;$$;

revoke all on function public.get_production_customer_alerts_v1(text) from public,anon;
grant execute on function public.get_production_customer_alerts_v1(text) to authenticated;

-- Open tasks for the signed-in person (by sign-in, or through their Staff Master record).
create or replace function public.customer_service_my_open_tasks()
returns setof public.customer_service_tasks language sql stable security definer set search_path=public,auth,pg_temp as $$
  select k.* from public.customer_service_tasks k
  where k.status in ('OPEN','IN_PROGRESS') and auth.uid() is not null
    and (k.assigned_auth_user_id=auth.uid()
      or k.assigned_staff_id in (select s.staff_id from public.staff_members s where s.auth_user_id=auth.uid() and s.deleted_at is null));
$$;
revoke all on function public.customer_service_my_open_tasks() from public,anon,authenticated;

-- The person marks their own task done (from Notifications), without Customer Service access.
create or replace function public.complete_my_customer_service_task_v1(p_task_id uuid,p_notes text)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_tasks;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='Authentication is required.'; end if;
  select * into v_row from public.customer_service_my_open_tasks() t where t.task_id=p_task_id;
  if v_row.task_id is null then raise exception using errcode='P0002',message='This task is not open for you.'; end if;
  if length(trim(coalesce(p_notes,'')))<2 then raise exception using errcode='22023',message='Write what was done.'; end if;
  update public.customer_service_tasks set status='DONE',completion_notes=trim(p_notes),completed_at=now(),completed_by_auth_user_id=auth.uid(),
    completed_by_name=public.customer_service_user_name(auth.uid()),updated_at=now()
  where task_id=p_task_id and status in ('OPEN','IN_PROGRESS');
  perform public.customer_service_log(v_row.complaint_id,'TASK_DONE',p_notes,
    jsonb_strip_nulls(jsonb_build_object('title',v_row.title,'department',v_row.department_code,'person',v_row.assigned_name,'by_assignee',true)),null,p_task_id);
  return jsonb_build_object('task_id',p_task_id,'status','DONE');
end;$$;

revoke all on function public.complete_my_customer_service_task_v1(uuid,text) from public,anon;
grant execute on function public.complete_my_customer_service_task_v1(uuid,text) to authenticated;

-- Notification counter (sidebar and Home) also counts my open tasks.
create or replace function public.get_my_notification_summary() returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare u integer; a integer; z integer; t text; c integer:=0; k integer:=0; kt text;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','VIEW',null) then raise exception using errcode='42501',message='Your account cannot view notifications.'; end if;
 select count(*) filter(where r.read_at is null),count(*) filter(where n.acknowledgement_required and r.acknowledged_at is null),count(*) filter(where r.read_at is null or (n.acknowledgement_required and r.acknowledged_at is null)),max(n.title) filter(where n.created_at=(select max(n2.created_at) from public.staff_notice_recipients r2 join public.staff_notices n2 using(notice_id) where r2.auth_user_id=auth.uid() and r2.archived_at is null and n2.expires_at>now()))
 into u,a,z,t from public.staff_notice_recipients r join public.staff_notices n using(notice_id) where r.auth_user_id=auth.uid() and r.archived_at is null and n.expires_at>now();
 if public.can_handle_trolley_plan_checks() then select count(*) into c from public.operational_data_reports where status='PENDING'; end if;
 select count(*) into k from public.customer_service_my_open_tasks();
 kt:=case when k>0 then k||case when k=1 then ' task for you' else ' tasks for you' end end;
 return jsonb_build_object('unread_count',coalesce(u,0),'action_count',coalesce(a,0)+c+k,'attention_count',coalesce(z,0)+c+k,'trolley_check_count',c,'task_count',k,
   'latest_title',case when c>0 then c||case when c=1 then ' trolley check is open' else ' trolley checks are open' end when k>0 then kt else t end); end; $$;

revoke all on function public.get_my_notification_summary() from public,anon;
grant execute on function public.get_my_notification_summary() to authenticated;

-- The inbox lists my open tasks under "Needs action" (kind TASK, done from the inbox).
create or replace function public.get_my_notification_inbox()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_staff_id uuid; v_can_review boolean; v_items jsonb:='[]'::jsonb; v_pending integer:=0; v_checks integer:=0; v_oldest timestamptz;
  v_tasks jsonb; v_today date:=public.customer_service_today();
begin
 if auth.uid() is null then raise exception using errcode='42501',message='Authentication is required.'; end if;
 if not public.has_account_permission('NOTIFICATIONS','VIEW',null) then raise exception using errcode='42501',message='Your account cannot view notifications.'; end if;
 select staff_id into v_staff_id from public.staff_members where auth_user_id=auth.uid() and active and deleted_at is null limit 1;
 if v_staff_id is not null then
   select coalesce(jsonb_agg(jsonb_build_object(
     'id','leave-'||r.leave_request_id,'kind','LEAVE_STATUS','title',case r.status when 'APPROVED' then 'Leave request approved' when 'REJECTED' then 'Leave request declined' else 'Leave request awaiting review' end,
     'message',initcap(replace(r.request_type,'_',' '))||' · '||to_char(r.start_date,'DD Mon YYYY')||case when r.end_date<>r.start_date then ' to '||to_char(r.end_date,'DD Mon YYYY') else '' end,
     'status',r.status,'occurred_at',coalesce(r.reviewed_at,r.submitted_at),'href','./roster-view.html'
   ) order by coalesce(r.reviewed_at,r.submitted_at) desc),'[]'::jsonb) into v_items
   from (select * from public.production_roster_leave_requests where staff_id=v_staff_id and submitted_at>=now()-interval '90 days' order by submitted_at desc limit 12) r;
 end if;
 v_can_review:=public.has_account_permission('LEAVE','APPROVE','PRODUCTION');
 if v_can_review then
   select count(*) into v_pending from public.production_roster_leave_requests where status='PENDING';
   if v_pending>0 then v_items:=jsonb_build_array(jsonb_build_object('id','leave-review','kind','APPROVAL','title',v_pending||case when v_pending=1 then ' leave request needs review' else ' leave requests need review' end,'message','Open the Leave Request Control Centre to review pending requests.','status','ACTION_REQUIRED','occurred_at',now(),'href','./roster.html?panel=leave&scope=ACTION'))||v_items; end if;
 end if;
 if public.can_handle_trolley_plan_checks() then
   select count(*),min(reported_at) into v_checks,v_oldest from public.operational_data_reports where status='PENDING';
   if v_checks>0 then v_items:=jsonb_build_array(jsonb_build_object('id','trolley-checks','kind','APPROVAL','title',v_checks||case when v_checks=1 then ' trolley check is open' else ' trolley checks are open' end,'message','Urgent: Production reported a trolley quantity to check. Oldest open since '||to_char(v_oldest at time zone 'Europe/Dublin','DD Mon HH24:MI')||'.','status','URGENT','occurred_at',v_oldest,'href','./notifications.html?trolleyChecks=open'))||v_items; end if;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id','cs-task-'||k.task_id,'kind','TASK','task_id',k.task_id,'title',k.title,
     'message',concat_ws(' · ',nullif(k.details,''),cu.customer_name,
       case when k.due_on is null then 'No due date' when k.due_on<v_today then 'Overdue since '||to_char(k.due_on,'Dy DD Mon') else 'Due '||to_char(k.due_on,'Dy DD Mon') end,
       'from '||coalesce(public.customer_service_user_name(k.created_by_auth_user_id),'Customer Service')),
     'status',case when k.due_on<v_today then 'OVERDUE' else 'TASK' end,'occurred_at',k.created_at)
   order by k.due_on nulls last,k.created_at),'[]'::jsonb) into v_tasks
 from public.customer_service_my_open_tasks() k left join public.customers cu on cu.customer_id=k.customer_id;
 v_items:=v_tasks||v_items;
 return jsonb_build_object('items',v_items,'pending_review_count',v_pending,'trolley_check_count',v_checks,'task_count',jsonb_array_length(v_tasks),'generated_at',now());
end; $$;

revoke all on function public.get_my_notification_inbox() from public,anon;
grant execute on function public.get_my_notification_inbox() to authenticated;
