-- Customer Service: cancelling a complaint also ends its customer alerts and cancels its
-- open department tasks, so production screens stop showing an alert for a complaint that
-- no longer exists. Resolving a complaint keeps its alerts (Customer Service may still want
-- production to watch the customer) and its tasks.
--
-- Also closes what was left open by complaints cancelled before this change.

create or replace function public.set_customer_service_complaint_status_v1(p_complaint_id uuid,p_status text,p_outcome text default null,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints; v_alert uuid; v_task uuid; v_status text:=upper(trim(coalesce(p_status,''))); v_outcome text:=nullif(upper(trim(coalesce(p_outcome,''))),'');
begin
  perform public.require_customer_service_access('EDIT');
  select * into v_row from public.customer_service_complaints where complaint_id=p_complaint_id for update;
  if v_row.complaint_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Complaint not found.';
  end if;
  if v_status not in ('OPEN','INVESTIGATING','RESOLVED','CANCELLED') then raise exception using errcode='22023',message='Unknown complaint status.'; end if;
  if v_status in ('RESOLVED','CANCELLED') and length(trim(coalesce(p_notes,'')))<3 then
    raise exception using errcode='22023',message='Write what was done (or why it is cancelled).';
  end if;
  if v_status='RESOLVED' and v_outcome is null then raise exception using errcode='22023',message='Say whether the complaint was justified.'; end if;
  update public.customer_service_complaints set
    status=v_status,
    outcome=case when v_status='RESOLVED' then v_outcome when v_status='CANCELLED' then null else outcome end,
    resolution_notes=case when v_status in ('RESOLVED','CANCELLED') then trim(p_notes) else resolution_notes end,
    resolved_at=case when v_status='RESOLVED' then now() when v_status in ('OPEN','INVESTIGATING') then null else resolved_at end,
    resolved_by_auth_user_id=case when v_status='RESOLVED' then auth.uid() when v_status in ('OPEN','INVESTIGATING') then null else resolved_by_auth_user_id end,
    updated_at=now()
  where complaint_id=p_complaint_id;
  perform public.customer_service_log(p_complaint_id,'STATUS_'||v_status,p_notes,jsonb_build_object('from',v_row.status,'outcome',v_outcome));
  -- A cancelled complaint was logged by mistake: its alerts and open tasks go with it.
  if v_status='CANCELLED' then
    for v_alert in update public.customer_service_alerts set ended_at=now(),ended_by_auth_user_id=auth.uid(),end_reason='Complaint cancelled'
      where complaint_id=p_complaint_id and ended_at is null returning alert_id loop
      perform public.customer_service_log(p_complaint_id,'ALERT_ENDED','Complaint cancelled','{}'::jsonb,v_alert,null);
    end loop;
    for v_task in update public.customer_service_tasks set status='CANCELLED',completion_notes='Complaint cancelled: '||trim(p_notes),completed_at=now(),
        completed_by_auth_user_id=auth.uid(),completed_by_name=public.customer_service_user_name(auth.uid()),updated_at=now()
      where complaint_id=p_complaint_id and status in ('OPEN','IN_PROGRESS') returning task_id loop
      perform public.customer_service_log(p_complaint_id,'TASK_CANCELLED','Complaint cancelled','{}'::jsonb,null,v_task);
    end loop;
  end if;
  return public.customer_service_complaint_json(p_complaint_id);
end;$$;

-- Alerts and tasks left open by complaints cancelled before this change.
insert into public.customer_service_events(complaint_id,alert_id,event_type,notes,created_by_name)
select a.complaint_id,a.alert_id,'ALERT_ENDED','Complaint cancelled','System'
from public.customer_service_alerts a join public.customer_service_complaints c on c.complaint_id=a.complaint_id
where c.status='CANCELLED' and a.ended_at is null;
update public.customer_service_alerts a set ended_at=now(),end_reason='Complaint cancelled'
from public.customer_service_complaints c
where c.complaint_id=a.complaint_id and c.status='CANCELLED' and a.ended_at is null;

insert into public.customer_service_events(complaint_id,task_id,event_type,notes,created_by_name)
select k.complaint_id,k.task_id,'TASK_CANCELLED','Complaint cancelled','System'
from public.customer_service_tasks k join public.customer_service_complaints c on c.complaint_id=k.complaint_id
where c.status='CANCELLED' and k.status in ('OPEN','IN_PROGRESS');
update public.customer_service_tasks k set status='CANCELLED',completion_notes='Complaint cancelled',completed_at=now(),completed_by_name='System',updated_at=now()
from public.customer_service_complaints c
where c.complaint_id=k.complaint_id and c.status='CANCELLED' and k.status in ('OPEN','IN_PROGRESS');

revoke all on function public.set_customer_service_complaint_status_v1(uuid,text,text,text) from public,anon;
grant execute on function public.set_customer_service_complaint_status_v1(uuid,text,text,text) to authenticated;
