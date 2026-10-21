-- Trolley plan checks reported by Production stay in front of the people who can
-- fix them until someone resolves them.
--
-- Finish and MOP report a wrong trolley quantity or type through
-- report_customer_trolley_requirement_issue (operational_data_reports). Until now
-- only Customer Schedule editors saw the report, inside the Customers page, so it
-- could be forgotten for days. Owner request (2026-10-21): treat it as urgent and
-- show it to Managers and Distribution until it is resolved.
--
-- Who handles a check: ADMIN, MANAGER, PLANNER and DISTRIBUTION_OPERATOR accounts,
-- accounts with a Distribution edit grant, and staff whose primary role is
-- Production Manager. They see every open check in an app-wide alert, in the
-- Notifications inbox and in the notification counter, and can resolve it with a
-- note. Who resolved it and when is kept on the report and in audit_log.
-- No table changes. Published schedules are never changed by a resolution.

create or replace function public.can_handle_trolley_plan_checks()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select auth.uid() is not null and (
    public.has_any_role(array['ADMIN','MANAGER','PLANNER','DISTRIBUTION_OPERATOR'])
    or public.has_account_permission('DISTRIBUTION','EDIT',null)
    or (public.current_account_is_enabled() and exists(
      select 1
      from public.staff_members sm
      join public.operational_roles o on o.operational_role_id = sm.primary_operational_role_id
      where sm.auth_user_id = auth.uid()
        and sm.active and sm.deleted_at is null
        and o.role_code = 'PRODUCTION_MANAGER'
    ))
  );
$$;

revoke all on function public.can_handle_trolley_plan_checks() from public, anon;
grant execute on function public.can_handle_trolley_plan_checks() to authenticated;

-- Open checks for the app-wide alert. Returns an empty list, not an error, to
-- accounts outside the audience because every page calls it.
create or replace function public.get_open_trolley_checks()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Authentication is required.';
  end if;
  if not public.can_handle_trolley_plan_checks() then
    return jsonb_build_object('can_handle', false, 'open_count', 0, 'items', '[]'::jsonb, 'generated_at', now());
  end if;

  return jsonb_build_object(
    'can_handle', true,
    'open_count', (select count(*) from public.operational_data_reports where status='PENDING'),
    'oldest_reported_at', (select min(reported_at) from public.operational_data_reports where status='PENDING'),
    'generated_at', now(),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'operational_report_id', r.operational_report_id,
        'customer_code', c.customer_code,
        'customer_name', c.customer_name,
        'route_code', r.planned_snapshot->>'route_code',
        'route_display_name', r.planned_snapshot->>'route_display_name',
        'business_date', r.business_date,
        'product_code', r.product_code,
        'source_area_code', r.source_area_code,
        'reported_by', reporter.display_name,
        'reported_at', r.reported_at,
        'open_hours', round((extract(epoch from now() - r.reported_at) / 3600)::numeric, 1),
        'reason', r.reason,
        'planned_snapshot', r.planned_snapshot,
        'reported_snapshot', r.reported_snapshot,
        'observed_snapshot', r.observed_snapshot
      ) order by r.reported_at)
      from public.operational_data_reports r
      join public.customers c on c.customer_id = r.customer_id
      left join public.staff_members reporter on reporter.staff_id = r.reported_by_staff_id
      where r.status = 'PENDING'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_open_trolley_checks() from public, anon;
grant execute on function public.get_open_trolley_checks() to authenticated;

-- Same review as before; the audience grows from Customer Schedule editors to the
-- trolley check handlers above.
create or replace function public.review_operational_schedule_report(
  p_operational_report_id uuid,
  p_action text,
  p_notes text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_action text := upper(trim(coalesce(p_action,'')));
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_report public.operational_data_reports%rowtype;
  v_staff_id uuid;
  v_resolution_version uuid;
begin
  if auth.uid() is null or public.current_staff_id() is null then
    raise exception using errcode='42501', message='An active authenticated staff account is required.';
  end if;
  if not public.can_handle_trolley_plan_checks() then
    raise exception using errcode='42501', message='Your account cannot resolve trolley plan checks.';
  end if;
  if p_operational_report_id is null then
    raise exception using errcode='22023', message='Operational report is required.';
  end if;
  if v_action not in ('RESOLVED','REJECTED') then
    raise exception using errcode='22023', message='Review action must be RESOLVED or REJECTED.';
  end if;
  if v_notes is null then
    raise exception using errcode='22023', message='Review notes are required.';
  end if;
  if length(v_notes)>1000 then
    raise exception using errcode='22023', message='Review notes must be 1000 characters or fewer.';
  end if;

  select * into v_report
  from public.operational_data_reports
  where operational_report_id=p_operational_report_id
  for update;
  if not found then
    raise exception using errcode='P0002', message='Operational report was not found.';
  end if;
  if v_report.status<>'PENDING' then
    raise exception using errcode='22023', message='This operational report has already been reviewed.';
  end if;

  if v_action='RESOLVED' then
    select v.schedule_version_id into v_resolution_version
    from public.customer_schedule_versions v
    where v.customer_id=v_report.customer_id
      and v.status='PUBLISHED'
      and v_report.business_date>=v.effective_from
      and (v.effective_until is null or v_report.business_date<=v.effective_until)
    order by v.version_number desc
    limit 1;
  end if;

  v_staff_id := public.current_staff_id();
  update public.operational_data_reports
  set status=v_action,
      reviewed_by_staff_id=v_staff_id,
      reviewed_by_auth_user_id=auth.uid(),
      reviewed_at=now(),
      review_notes=v_notes,
      resolution_schedule_version_id=v_resolution_version,
      updated_at=now(),
      row_version=row_version+1
  where operational_report_id=p_operational_report_id
  returning * into v_report;

  insert into public.audit_log(
    actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,new_data,reason,source_application
  ) values (
    auth.uid(),v_staff_id,'OPERATIONAL_TROLLEY_REQUIREMENT_'||v_action,'operational_data_reports',
    v_report.operational_report_id::text,to_jsonb(v_report),v_notes,'CUSTOMER_SCHEDULE_UI'
  );

  return jsonb_build_object(
    'status','success',
    'operational_report_id',v_report.operational_report_id,
    'report_status',v_report.status,
    'message',case when v_action='RESOLVED'
      then 'Trolley check resolved. Published schedule history remains versioned.'
      else 'Trolley check closed with no change; the reason is preserved.' end
  );
end;
$$;

revoke all on function public.review_operational_schedule_report(uuid,text,text) from public, anon;
grant execute on function public.review_operational_schedule_report(uuid,text,text) to authenticated;

-- The notification counter (sidebar and Home) also counts open trolley checks.
create or replace function public.get_my_notification_summary() returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare u integer; a integer; z integer; t text; c integer:=0;
begin
 if auth.uid() is null or not public.has_account_permission('NOTIFICATIONS','VIEW',null) then raise exception using errcode='42501',message='Your account cannot view notifications.'; end if;
 select count(*) filter(where r.read_at is null),count(*) filter(where n.acknowledgement_required and r.acknowledged_at is null),count(*) filter(where r.read_at is null or (n.acknowledgement_required and r.acknowledged_at is null)),max(n.title) filter(where n.created_at=(select max(n2.created_at) from public.staff_notice_recipients r2 join public.staff_notices n2 using(notice_id) where r2.auth_user_id=auth.uid() and r2.archived_at is null and n2.expires_at>now()))
 into u,a,z,t from public.staff_notice_recipients r join public.staff_notices n using(notice_id) where r.auth_user_id=auth.uid() and r.archived_at is null and n.expires_at>now();
 if public.can_handle_trolley_plan_checks() then select count(*) into c from public.operational_data_reports where status='PENDING'; end if;
 return jsonb_build_object('unread_count',coalesce(u,0),'action_count',coalesce(a,0)+c,'attention_count',coalesce(z,0)+c,'trolley_check_count',c,'latest_title',case when c>0 then c||case when c=1 then ' trolley check is open' else ' trolley checks are open' end else t end); end; $$;

revoke all on function public.get_my_notification_summary() from public,anon;
grant execute on function public.get_my_notification_summary() to authenticated;

-- The inbox lists open trolley checks first, under "Needs action".
create or replace function public.get_my_notification_inbox()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_staff_id uuid; v_can_review boolean; v_items jsonb:='[]'::jsonb; v_pending integer:=0; v_checks integer:=0; v_oldest timestamptz;
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
 return jsonb_build_object('items',v_items,'pending_review_count',v_pending,'trolley_check_count',v_checks,'generated_at',now());
end; $$;

revoke all on function public.get_my_notification_inbox() from public,anon;
grant execute on function public.get_my_notification_inbox() to authenticated;
