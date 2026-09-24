-- Lightweight permission-aware inbox built from authoritative workflow data.

insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage) values
 ('PRODUCTION_SUPERVISOR','NOTIFICATIONS','PRODUCTION',true,false,false,false,false),
 ('PRODUCTION_MANAGER','NOTIFICATIONS','PRODUCTION',true,false,false,false,false),
 ('GENERAL_MANAGER','NOTIFICATIONS','ALL',true,false,false,false,false)
on conflict(job_title_code,module_code) do update set access_scope=excluded.access_scope,can_view=true;

insert into public.account_permission_grants(auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage)
select ap.auth_user_id,t.module_code,t.access_scope,t.can_view,t.can_create,t.can_edit,t.can_approve,t.can_manage
from public.account_access_profiles ap join public.job_title_permission_templates t on t.job_title_code=ap.job_title_code and t.module_code='NOTIFICATIONS'
where ap.job_title_code in('PRODUCTION_SUPERVISOR','PRODUCTION_MANAGER','GENERAL_MANAGER')
on conflict(auth_user_id,module_code) do nothing;

create or replace function public.get_my_notification_inbox()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_staff_id uuid; v_can_review boolean; v_items jsonb:='[]'::jsonb; v_pending integer:=0;
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
   if v_pending>0 then v_items:=jsonb_build_array(jsonb_build_object('id','leave-review','kind','APPROVAL','title',v_pending||case when v_pending=1 then ' leave request needs review' else ' leave requests need review' end,'message','Open Production Roster to review the pending requests.','status','ACTION_REQUIRED','occurred_at',now(),'href','./roster.html'))||v_items; end if;
 end if;
 return jsonb_build_object('items',v_items,'pending_review_count',v_pending,'generated_at',now());
end; $$;

revoke all on function public.get_my_notification_inbox() from public,anon;
grant execute on function public.get_my_notification_inbox() to authenticated;
