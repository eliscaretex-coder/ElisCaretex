-- Customer Service review: a "resolve by" date on every complaint so none stays open
-- forever, plus fixes found in the review.
--
-- * New column customer_service_complaints.resolve_by. New complaints get it from their
--   severity (High 2 days, Medium 5, Low 7 after the received date, never before today);
--   the targets can be changed in app_config key customer_service_target_days, for example
--   {"HIGH":1,"MEDIUM":3,"LOW":7}. Existing complaints are filled the same way.
-- * set_customer_service_complaint_due_v1: moves the date, always with a reason, recorded
--   in the history (DUE_CHANGED).
-- * The complaint JSON adds resolve_by, due_state (OVERDUE / DUE_TODAY / ON_TRACK),
--   overdue_days, last_activity_at, idle_days and resolved_on_time.
-- * Workspace counts add overdue, due today, idle (no update for 3+ days) and without a
--   person, and the target days for the form.
-- * Results add overdue now and resolved on time; "by person" adds overdue.
-- Fixes:
-- * Editing a complaint to another customer now moves it to that customer's person and
--   removes the production link (it pointed at the old customer's records).
-- * A severity raised on an open complaint brings its date forward.
-- * Reopening a resolved complaint clears its outcome and resolution (they counted as
--   "justified" in Results while it was open again) and gives it a new date if the old
--   one had passed.
-- * Giving customers to another person also moves their open complaints to that person.

alter table public.customer_service_complaints add column if not exists resolve_by date;

create or replace function public.customer_service_target_days(p_severity text)
returns integer language sql stable security definer set search_path=public,auth,pg_temp as $$
  select greatest(0,coalesce(
    (select nullif(c.value_json->>upper(coalesce(p_severity,'MEDIUM')),'')::integer from public.app_config c
      where c.config_key='customer_service_target_days' and jsonb_typeof(c.value_json)='object'),
    case upper(coalesce(p_severity,'MEDIUM')) when 'HIGH' then 2 when 'LOW' then 7 else 5 end));
$$;
revoke all on function public.customer_service_target_days(text) from public,anon,authenticated;

update public.customer_service_complaints
set resolve_by=received_on+public.customer_service_target_days(severity)
where resolve_by is null;

create index if not exists customer_service_complaints_resolve_by_idx on public.customer_service_complaints(resolve_by)
  where status in ('OPEN','INVESTIGATING');

-- JSON shape ------------------------------------------------------------------------

create or replace function public.customer_service_complaint_json(p_complaint_id uuid)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  with x as (
    select c.*,cu.customer_code,cu.customer_name,t.type_name,public.customer_service_today() as today,
      coalesce((select max(e.created_at) from public.customer_service_events e where e.complaint_id=c.complaint_id),c.updated_at) as last_activity_at
    from public.customer_service_complaints c
    join public.customers cu on cu.customer_id=c.customer_id
    join public.customer_service_complaint_types t on t.type_code=c.type_code
    where c.complaint_id=p_complaint_id
  )
  select jsonb_build_object(
    'complaint_id',x.complaint_id,'complaint_code',x.complaint_code,
    'customer_id',x.customer_id,'customer_code',x.customer_code,'customer_name',x.customer_name,
    'received_on',x.received_on,'delivery_date',x.delivery_date,'channel',x.channel,
    'type_code',x.type_code,'type_name',x.type_name,'severity',x.severity,
    'description',x.description,'customer_reference',x.customer_reference,
    'status',x.status,'outcome',x.outcome,'resolution_notes',x.resolution_notes,'resolved_at',x.resolved_at,
    'resolved_by_name',public.customer_service_user_name(x.resolved_by_auth_user_id),
    'owner_auth_user_id',x.owner_auth_user_id,'owner_name',public.customer_service_user_name(x.owner_auth_user_id),
    'created_at',x.created_at,'created_by_name',public.customer_service_user_name(x.created_by_auth_user_id),
    'days_open',case when x.status in ('OPEN','INVESTIGATING') then x.today-x.received_on else coalesce(x.resolved_at::date,x.updated_at::date)-x.received_on end,
    'resolve_by',x.resolve_by,
    'due_state',case when x.status not in ('OPEN','INVESTIGATING') or x.resolve_by is null then null
      when x.resolve_by<x.today then 'OVERDUE' when x.resolve_by=x.today then 'DUE_TODAY' else 'ON_TRACK' end,
    'overdue_days',case when x.status in ('OPEN','INVESTIGATING') and x.resolve_by<x.today then x.today-x.resolve_by else 0 end,
    'resolved_on_time',case when x.status='RESOLVED' and x.resolve_by is not null and x.resolved_at is not null
      then (x.resolved_at at time zone 'Europe/Dublin')::date<=x.resolve_by end,
    'last_activity_at',x.last_activity_at,
    'idle_days',x.today-(x.last_activity_at at time zone 'Europe/Dublin')::date,
    'link',case when x.linked_finish_entry_id is null and x.linked_wash_run_id is null then null else jsonb_build_object(
      'finish_entry_id',x.linked_finish_entry_id,'wash_run_id',x.linked_wash_run_id,'production_flow_item_id',x.linked_production_flow_item_id,
      'finish_business_date',x.finish_business_date,'finish_shift_code',x.finish_shift_code,'finish_table_code',x.finish_table_code,'finish_processed_by',x.finish_processed_by,
      'sorting_business_date',x.sorting_business_date,'sorting_shift_code',x.sorting_shift_code,'sorting_washer_name',x.sorting_washer_name,'sorting_operator_name',x.sorting_operator_name,
      'linked_at',x.linked_at,'linked_by_name',public.customer_service_user_name(x.linked_by_auth_user_id)) end,
    'open_task_count',(select count(*) from public.customer_service_tasks k where k.complaint_id=x.complaint_id and k.status in ('OPEN','IN_PROGRESS')),
    'task_count',(select count(*) from public.customer_service_tasks k where k.complaint_id=x.complaint_id and k.status<>'CANCELLED'),
    'active_alert',exists(select 1 from public.customer_service_alerts a where a.customer_id=x.customer_id and a.ended_at is null
      and a.starts_on<=x.today and (a.ends_on is null or a.ends_on>=x.today)),
    'own_active_alerts',(select count(*) from public.customer_service_alerts a where a.complaint_id=x.complaint_id and a.ended_at is null
      and (a.ends_on is null or a.ends_on>=x.today))
  )
  from x;
$$;
revoke all on function public.customer_service_complaint_json(uuid) from public,anon,authenticated;

-- Workspace -------------------------------------------------------------------------

create or replace function public.get_customer_service_workspace_v1()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_scope text; v_today date;
begin
  perform public.require_customer_service_access('VIEW');
  v_scope:=public.customer_service_access_scope();
  v_today:=public.customer_service_today();
  return jsonb_build_object(
    'schema_version','CUSTOMER_SERVICE_V1',
    'today',v_today,
    'me',jsonb_build_object('auth_user_id',auth.uid(),'display_name',public.customer_service_user_name(auth.uid()),'scope',v_scope,
      'can_create',public.customer_service_can('CREATE'),'can_edit',public.customer_service_can('EDIT'),'can_manage',public.customer_service_can('MANAGE')),
    'target_days',jsonb_build_object('HIGH',public.customer_service_target_days('HIGH'),'MEDIUM',public.customer_service_target_days('MEDIUM'),'LOW',public.customer_service_target_days('LOW')),
    'customers',coalesce((select jsonb_agg(jsonb_build_object('customer_id',cu.customer_id,'customer_code',cu.customer_code,'customer_name',cu.customer_name,
        'owner_auth_user_id',o.owner_auth_user_id,'owner_name',public.customer_service_user_name(o.owner_auth_user_id),'mine',o.owner_auth_user_id=auth.uid())
      order by lower(cu.customer_name)) from public.customers cu left join public.customer_service_customer_owners o on o.customer_id=cu.customer_id
      where cu.deleted_at is null and cu.active),'[]'::jsonb),
    'types',coalesce((select jsonb_agg(to_jsonb(t)-'created_at'-'updated_at' order by t.sort_order,t.type_name) from public.customer_service_complaint_types t),'[]'::jsonb),
    'agents',coalesce((select jsonb_agg(jsonb_build_object('auth_user_id',x.auth_user_id,'display_name',public.customer_service_user_name(x.auth_user_id),'scope',x.access_scope,'can_manage',x.can_manage)
      order by lower(public.customer_service_user_name(x.auth_user_id))) from (
        select g.auth_user_id,g.access_scope,g.can_manage from public.account_permission_grants g
        where g.module_code='CUSTOMER_SERVICE' and g.active and g.effective_from<=current_date and (g.effective_until is null or g.effective_until>=current_date)
          and (g.can_create or g.can_edit or g.can_manage)
          and not exists(select 1 from public.account_access_profiles ap where ap.auth_user_id=g.auth_user_id and ap.job_title_code='ADMINISTRATOR')) x),'[]'::jsonb),
    'counts',(select jsonb_build_object(
      'open_complaints',count(*),
      'overdue_complaints',count(*) filter (where c.resolve_by<v_today),
      'due_today_complaints',count(*) filter (where c.resolve_by=v_today),
      'idle_complaints',count(*) filter (where v_today-(coalesce((select max(e.created_at) from public.customer_service_events e where e.complaint_id=c.complaint_id),c.updated_at) at time zone 'Europe/Dublin')::date>=3),
      'no_person_complaints',count(*) filter (where c.owner_auth_user_id is null),
      'active_alerts',(select count(*) from public.customer_service_alerts a where a.ended_at is null and a.starts_on<=v_today and (a.ends_on is null or a.ends_on>=v_today) and public.customer_service_customer_visible(a.customer_id,a.created_by_auth_user_id)),
      'open_tasks',(select count(*) from public.customer_service_tasks k where k.status in ('OPEN','IN_PROGRESS') and (k.customer_id is null or public.customer_service_customer_visible(k.customer_id,k.created_by_auth_user_id))),
      'overdue_tasks',(select count(*) from public.customer_service_tasks k where k.status in ('OPEN','IN_PROGRESS') and k.due_on<v_today and (k.customer_id is null or public.customer_service_customer_visible(k.customer_id,k.created_by_auth_user_id))))
      from public.customer_service_complaints c
      where c.status in ('OPEN','INVESTIGATING') and public.customer_service_customer_visible(c.customer_id,c.created_by_auth_user_id))
  );
end;$$;

-- Save complaint (same signature) -------------------------------------------------------

create or replace function public.save_customer_service_complaint_v1(
  p_complaint_id uuid,p_customer_id uuid,p_received_on date,p_type_code text,p_description text,
  p_severity text default 'MEDIUM',p_delivery_date date default null,p_channel text default null,p_customer_reference text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints; v_id uuid; v_owner uuid; v_changes jsonb:='{}'::jsonb;
  v_severity text:=upper(coalesce(nullif(trim(p_severity),''),'MEDIUM')); v_today date:=public.customer_service_today(); v_due date;
begin
  perform public.require_customer_service_access(case when p_complaint_id is null then 'CREATE' else 'EDIT' end);
  if not exists(select 1 from public.customers where customer_id=p_customer_id and deleted_at is null) then
    raise exception using errcode='22023',message='Choose a customer.';
  end if;
  if not exists(select 1 from public.customer_service_complaint_types where type_code=upper(trim(p_type_code)) and active) then
    raise exception using errcode='22023',message='Choose a complaint type.';
  end if;
  if v_severity not in ('LOW','MEDIUM','HIGH') then raise exception using errcode='22023',message='Choose the severity.'; end if;
  if p_received_on is null or p_received_on>v_today+1 then
    raise exception using errcode='22023',message='The received date is required and cannot be in the future.';
  end if;
  if length(trim(coalesce(p_description,'')))<3 then
    raise exception using errcode='22023',message='Describe the complaint.';
  end if;
  v_due:=greatest(p_received_on+public.customer_service_target_days(v_severity),v_today);

  if p_complaint_id is null then
    select owner_auth_user_id into v_owner from public.customer_service_customer_owners where customer_id=p_customer_id;
    insert into public.customer_service_complaints(customer_id,received_on,delivery_date,channel,type_code,severity,description,customer_reference,owner_auth_user_id,created_by_auth_user_id,resolve_by)
    values(p_customer_id,p_received_on,p_delivery_date,nullif(upper(trim(p_channel)),''),upper(trim(p_type_code)),v_severity,
      trim(p_description),nullif(trim(p_customer_reference),''),coalesce(v_owner,auth.uid()),auth.uid(),v_due)
    returning complaint_id into v_id;
    perform public.customer_service_log(v_id,'CREATED',null,jsonb_build_object('type_code',upper(trim(p_type_code)),'resolve_by',v_due));
    return public.customer_service_complaint_json(v_id);
  end if;

  select * into v_row from public.customer_service_complaints where complaint_id=p_complaint_id for update;
  if v_row.complaint_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Complaint not found.';
  end if;
  if v_row.status='CANCELLED' then raise exception using errcode='22023',message='A cancelled complaint cannot be changed.'; end if;
  if v_row.customer_id<>p_customer_id then
    select owner_auth_user_id into v_owner from public.customer_service_customer_owners where customer_id=p_customer_id;
    v_changes:=v_changes||jsonb_build_object('customer',true,'link_removed',v_row.linked_finish_entry_id is not null or v_row.linked_wash_run_id is not null);
  end if;
  if v_row.type_code<>upper(trim(p_type_code)) then v_changes:=v_changes||jsonb_build_object('type_from',v_row.type_code,'type_to',upper(trim(p_type_code))); end if;
  if v_row.received_on<>p_received_on then v_changes:=v_changes||jsonb_build_object('received_from',v_row.received_on,'received_to',p_received_on); end if;
  if v_row.description<>trim(p_description) then v_changes:=v_changes||jsonb_build_object('description',true); end if;
  if v_row.severity<>v_severity then v_changes:=v_changes||jsonb_build_object('severity_to',v_severity); end if;
  -- A stricter severity on an open complaint brings its date forward; a milder one keeps it.
  v_due:=case when v_row.status in ('OPEN','INVESTIGATING') and v_row.severity<>v_severity
    then least(coalesce(v_row.resolve_by,v_due),v_due) else v_row.resolve_by end;
  if v_due is distinct from v_row.resolve_by then v_changes:=v_changes||jsonb_build_object('resolve_by_from',v_row.resolve_by,'resolve_by_to',v_due); end if;
  update public.customer_service_complaints set
    customer_id=p_customer_id,received_on=p_received_on,delivery_date=p_delivery_date,channel=nullif(upper(trim(p_channel)),''),
    type_code=upper(trim(p_type_code)),severity=v_severity,description=trim(p_description),
    customer_reference=nullif(trim(p_customer_reference),''),resolve_by=v_due,
    owner_auth_user_id=case when v_row.customer_id<>p_customer_id then coalesce(v_owner,v_row.owner_auth_user_id) else owner_auth_user_id end,
    linked_finish_entry_id=case when v_row.customer_id<>p_customer_id then null else linked_finish_entry_id end,
    linked_wash_run_id=case when v_row.customer_id<>p_customer_id then null else linked_wash_run_id end,
    linked_production_flow_item_id=case when v_row.customer_id<>p_customer_id then null else linked_production_flow_item_id end,
    finish_business_date=case when v_row.customer_id<>p_customer_id then null else finish_business_date end,
    finish_shift_code=case when v_row.customer_id<>p_customer_id then null else finish_shift_code end,
    finish_table_code=case when v_row.customer_id<>p_customer_id then null else finish_table_code end,
    finish_processed_by=case when v_row.customer_id<>p_customer_id then null else finish_processed_by end,
    sorting_business_date=case when v_row.customer_id<>p_customer_id then null else sorting_business_date end,
    sorting_shift_code=case when v_row.customer_id<>p_customer_id then null else sorting_shift_code end,
    sorting_washer_name=case when v_row.customer_id<>p_customer_id then null else sorting_washer_name end,
    sorting_operator_name=case when v_row.customer_id<>p_customer_id then null else sorting_operator_name end,
    linked_at=case when v_row.customer_id<>p_customer_id then null else linked_at end,
    linked_by_auth_user_id=case when v_row.customer_id<>p_customer_id then null else linked_by_auth_user_id end,
    updated_at=now()
  where complaint_id=p_complaint_id;
  perform public.customer_service_log(p_complaint_id,'EDITED',null,v_changes);
  return public.customer_service_complaint_json(p_complaint_id);
end;$$;

-- Move the resolve-by date (always with a reason) ------------------------------------------

create or replace function public.set_customer_service_complaint_due_v1(p_complaint_id uuid,p_resolve_by date,p_reason text)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints;
begin
  perform public.require_customer_service_access('EDIT');
  select * into v_row from public.customer_service_complaints where complaint_id=p_complaint_id for update;
  if v_row.complaint_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Complaint not found.';
  end if;
  if v_row.status not in ('OPEN','INVESTIGATING') then raise exception using errcode='22023',message='Only an open complaint has a resolve-by date.'; end if;
  if p_resolve_by is null or p_resolve_by<public.customer_service_today() then
    raise exception using errcode='22023',message='Choose today or a later date.';
  end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception using errcode='22023',message='Write why the date changes.'; end if;
  update public.customer_service_complaints set resolve_by=p_resolve_by,updated_at=now() where complaint_id=p_complaint_id;
  perform public.customer_service_log(p_complaint_id,'DUE_CHANGED',p_reason,jsonb_build_object('from',v_row.resolve_by,'to',p_resolve_by));
  return public.customer_service_complaint_json(p_complaint_id);
end;$$;

-- Status (same signature): reopen clears the old outcome ----------------------------------

create or replace function public.set_customer_service_complaint_status_v1(p_complaint_id uuid,p_status text,p_outcome text default null,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints; v_alert uuid; v_task uuid; v_status text:=upper(trim(coalesce(p_status,''))); v_outcome text:=nullif(upper(trim(coalesce(p_outcome,''))),'');
  v_today date:=public.customer_service_today(); v_reopen boolean;
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
  if v_status='RESOLVED' and v_outcome not in ('JUSTIFIED','NOT_JUSTIFIED','UNDETERMINED') then raise exception using errcode='22023',message='Unknown outcome.'; end if;
  v_reopen:=v_status in ('OPEN','INVESTIGATING') and v_row.status in ('RESOLVED','CANCELLED');
  update public.customer_service_complaints set
    status=v_status,
    outcome=case when v_status='RESOLVED' then v_outcome when v_status='CANCELLED' or v_reopen then null else outcome end,
    resolution_notes=case when v_status in ('RESOLVED','CANCELLED') then trim(p_notes) when v_reopen then null else resolution_notes end,
    resolved_at=case when v_status='RESOLVED' then now() when v_status in ('OPEN','INVESTIGATING') then null else resolved_at end,
    resolved_by_auth_user_id=case when v_status='RESOLVED' then auth.uid() when v_status in ('OPEN','INVESTIGATING') then null else resolved_by_auth_user_id end,
    resolve_by=case when v_reopen and coalesce(resolve_by,v_today-1)<v_today then v_today+public.customer_service_target_days(severity) else resolve_by end,
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

-- Customer blocks (same signature): open complaints follow the customer ----------------------

create or replace function public.set_customer_service_customer_owner_v1(p_customer_ids uuid[],p_owner_auth_user_id uuid default null)
returns integer language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_count integer; v_ids uuid[]:=coalesce(p_customer_ids,array[]::uuid[]); v_complaint uuid;
begin
  perform public.require_customer_service_access('MANAGE');
  if p_owner_auth_user_id is not null and not exists(select 1 from public.account_permission_grants g where g.auth_user_id=p_owner_auth_user_id and g.module_code='CUSTOMER_SERVICE' and g.active) then
    raise exception using errcode='22023',message='The selected person has no Customer Service access.';
  end if;
  if p_owner_auth_user_id is null then
    delete from public.customer_service_customer_owners where customer_id=any(v_ids);
  else
    insert into public.customer_service_customer_owners(customer_id,owner_auth_user_id,assigned_by_auth_user_id)
    select cu.customer_id,p_owner_auth_user_id,auth.uid() from public.customers cu where cu.customer_id=any(v_ids) and cu.deleted_at is null
    on conflict (customer_id) do update set owner_auth_user_id=excluded.owner_auth_user_id,assigned_at=now(),assigned_by_auth_user_id=excluded.assigned_by_auth_user_id;
  end if;
  get diagnostics v_count=row_count;
  for v_complaint in update public.customer_service_complaints set owner_auth_user_id=p_owner_auth_user_id,updated_at=now()
    where customer_id=any(v_ids) and status in ('OPEN','INVESTIGATING') and owner_auth_user_id is distinct from p_owner_auth_user_id
    returning complaint_id loop
    perform public.customer_service_log(v_complaint,'OWNER_CHANGED',null,jsonb_build_object('owner_name',public.customer_service_user_name(p_owner_auth_user_id)));
  end loop;
  return v_count;
end;$$;

-- Results (same signature): overdue now and resolved on time ---------------------------------

create or replace function public.get_customer_service_results_v1(p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_from date:=p_from; v_to date:=p_to; v_period text; v_result jsonb; v_today date:=public.customer_service_today();
begin
  perform public.require_customer_service_access('VIEW');
  if v_from is null or v_to is null or v_from>v_to then raise exception using errcode='22023',message='Choose a valid period.'; end if;
  if v_to-v_from>731 then raise exception using errcode='22023',message='Choose a period of two years or less.'; end if;
  v_period:=case when v_to-v_from<=45 then 'day' when v_to-v_from<=190 then 'week' else 'month' end;

  with c as (
    select c.*,t.type_name,
      c.status in ('OPEN','INVESTIGATING') and c.resolve_by<v_today as is_overdue,
      case when c.status='RESOLVED' and c.resolve_by is not null and c.resolved_at is not null
        then (c.resolved_at at time zone 'Europe/Dublin')::date<=c.resolve_by end as on_time
    from public.customer_service_complaints c join public.customer_service_complaint_types t on t.type_code=c.type_code
    where c.status<>'CANCELLED' and c.received_on between v_from and v_to
      and public.customer_service_customer_visible(c.customer_id,c.created_by_auth_user_id)
  ), k as (
    select k.* from public.customer_service_tasks k
    join c on c.complaint_id=k.complaint_id where k.status<>'CANCELLED'
  )
  select jsonb_build_object(
    'from',v_from,'to',v_to,'period',v_period,
    'totals',jsonb_build_object(
      'complaints',(select count(*) from c),
      'open',(select count(*) from c where status in ('OPEN','INVESTIGATING')),
      'overdue',(select count(*) from c where is_overdue),
      'resolved',(select count(*) from c where status='RESOLVED'),
      'resolved_on_time',(select count(*) from c where on_time),
      'resolved_with_date',(select count(*) from c where on_time is not null),
      'justified',(select count(*) from c where outcome='JUSTIFIED'),
      'not_justified',(select count(*) from c where outcome='NOT_JUSTIFIED'),
      'high',(select count(*) from c where severity='HIGH'),
      'customers',(select count(distinct customer_id) from c),
      'linked',(select count(*) from c where linked_finish_entry_id is not null or linked_wash_run_id is not null),
      'avg_days_to_resolve',(select round(avg(extract(epoch from (resolved_at-received_on::timestamptz))/86400.0)::numeric,1) from c where status='RESOLVED' and resolved_at is not null),
      'tasks',(select count(*) from k),'tasks_open',(select count(*) from k where status in ('OPEN','IN_PROGRESS')),
      'tasks_overdue',(select count(*) from k where status in ('OPEN','IN_PROGRESS') and due_on<v_today)),
    'by_period',coalesce((select jsonb_agg(jsonb_build_object('period_start',p,'complaints',n,'justified',j) order by p) from (
      select date_trunc(v_period,received_on)::date p,count(*) n,count(*) filter (where outcome='JUSTIFIED') j from c group by 1) x),'[]'::jsonb),
    'by_type',coalesce((select jsonb_agg(jsonb_build_object('type_code',type_code,'type_name',type_name,'complaints',n,'justified',j) order by n desc,type_name) from (
      select type_code,type_name,count(*) n,count(*) filter (where outcome='JUSTIFIED') j from c group by 1,2) x),'[]'::jsonb),
    'by_customer',coalesce((select jsonb_agg(jsonb_build_object('customer_id',customer_id,'customer_name',customer_name,'complaints',n,'open',o,'last_received_on',l) order by n desc,customer_name) from (
      select c.customer_id,cu.customer_name,count(*) n,count(*) filter (where c.status in ('OPEN','INVESTIGATING')) o,max(c.received_on) l
      from c join public.customers cu on cu.customer_id=c.customer_id group by 1,2 order by 3 desc,2 limit 20) x),'[]'::jsonb),
    'by_finish_shift',coalesce((select jsonb_agg(jsonb_build_object('shift_code',finish_shift_code,'complaints',n) order by finish_shift_code) from (
      select finish_shift_code,count(*) n from c where finish_shift_code is not null group by 1) x),'[]'::jsonb),
    'by_finish_table',coalesce((select jsonb_agg(jsonb_build_object('table_code',finish_table_code,'shift_code',finish_shift_code,'complaints',n) order by finish_table_code,finish_shift_code) from (
      select finish_table_code,finish_shift_code,count(*) n from c where finish_table_code is not null group by 1,2) x),'[]'::jsonb),
    'by_sorting_shift',coalesce((select jsonb_agg(jsonb_build_object('shift_code',sorting_shift_code,'complaints',n) order by sorting_shift_code) from (
      select sorting_shift_code,count(*) n from c where sorting_shift_code is not null group by 1) x),'[]'::jsonb),
    'by_owner',coalesce((select jsonb_agg(jsonb_build_object('owner_name',coalesce(public.customer_service_user_name(owner_auth_user_id),'Not assigned'),'complaints',n,'open',o,'overdue',d,'resolved',r,'on_time',ot) order by n desc) from (
      select owner_auth_user_id,count(*) n,count(*) filter (where status in ('OPEN','INVESTIGATING')) o,count(*) filter (where is_overdue) d,
        count(*) filter (where status='RESOLVED') r,count(*) filter (where on_time) ot from c group by 1) x),'[]'::jsonb),
    'by_department',coalesce((select jsonb_agg(jsonb_build_object('department_code',department_code,'tasks',n,'open',o,'overdue',d) order by n desc) from (
      select department_code,count(*) n,count(*) filter (where status in ('OPEN','IN_PROGRESS')) o,
        count(*) filter (where status in ('OPEN','IN_PROGRESS') and due_on<v_today) d from k group by 1) x),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;$$;

-- Grants ----------------------------------------------------------------------------

revoke all on function public.get_customer_service_workspace_v1(),
  public.save_customer_service_complaint_v1(uuid,uuid,date,text,text,text,date,text,text),
  public.set_customer_service_complaint_due_v1(uuid,date,text),
  public.set_customer_service_complaint_status_v1(uuid,text,text,text),
  public.set_customer_service_customer_owner_v1(uuid[],uuid),
  public.get_customer_service_results_v1(date,date)
from public,anon;

grant execute on function public.get_customer_service_workspace_v1(),
  public.save_customer_service_complaint_v1(uuid,uuid,date,text,text,text,date,text,text),
  public.set_customer_service_complaint_due_v1(uuid,date,text),
  public.set_customer_service_complaint_status_v1(uuid,text,text,text),
  public.set_customer_service_customer_owner_v1(uuid[],uuid),
  public.get_customer_service_results_v1(date,date)
to authenticated;
