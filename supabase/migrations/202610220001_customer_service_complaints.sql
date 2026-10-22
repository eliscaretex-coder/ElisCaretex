-- Customer Service: complaints, customer blocks, customer alerts for production and
-- department tasks.
--
-- Access goes through the new CUSTOMER_SERVICE application module:
--   * scope OWN  -> an agent sees the customers of their own block (and anything they logged);
--   * scope ALL  -> the Customer Service manager sees every customer;
--   * Manage     -> maintains complaint types and customer blocks.
-- ADMIN and MANAGER roles have full access. Production areas only read the active alerts
-- and their department's open tasks, and can mark those tasks done.

alter table public.application_modules drop constraint if exists application_modules_module_group_check;
alter table public.application_modules add constraint application_modules_module_group_check
  check (module_group in ('SELF_SERVICE','PRODUCTION','DISTRIBUTION','PEOPLE','ADMINISTRATION','CUSTOMER_SERVICE'));

insert into public.application_modules (module_code,module_name,module_group,display_order)
values ('CUSTOMER_SERVICE','Customer Service','CUSTOMER_SERVICE',250)
on conflict (module_code) do update set module_name=excluded.module_name,module_group=excluded.module_group,display_order=excluded.display_order,active=true;

insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage) values
 ('CUSTOMER_SERVICE','CUSTOMER_SERVICE','ALL',true,true,true,false,true),
 ('GENERAL_MANAGER','CUSTOMER_SERVICE','ALL',true,false,false,false,false)
on conflict (job_title_code,module_code) do update set access_scope=excluded.access_scope,can_view=excluded.can_view,can_create=excluded.can_create,can_edit=excluded.can_edit,can_approve=excluded.can_approve,can_manage=excluded.can_manage;

insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage)
select 'ADMINISTRATOR','CUSTOMER_SERVICE','ALL',true,true,true,true,true
where exists (select 1 from public.account_job_titles where job_title_code='ADMINISTRATOR')
on conflict do nothing;

-- Tables ---------------------------------------------------------------------------

create table if not exists public.customer_service_complaint_types (
  type_code text primary key check (type_code ~ '^[A-Z0-9_]{2,40}$'),
  type_name text not null check (length(trim(type_name)) between 2 and 80),
  default_department_code text check (default_department_code in ('SORTING','FINISH','MOP','DISTRIBUTION','CUSTOMER_SERVICE','MAINTENANCE','MANAGEMENT')),
  sort_order integer not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.customer_service_complaint_types(type_code,type_name,default_department_code,sort_order) values
 ('LOST_ITEM','Lost item','SORTING',10),
 ('MISSING_ITEMS','Missing items / short delivery','FINISH',20),
 ('WRONG_CUSTOMER_ITEMS','Items from another customer','FINISH',30),
 ('DAMAGED_ITEM','Damaged item','FINISH',40),
 ('STAINED_NOT_CLEAN','Stained / not clean','SORTING',50),
 ('WET_OR_DAMP','Wet or damp','SORTING',60),
 ('BAD_SMELL','Bad smell','SORTING',70),
 ('FOLDING_PRESENTATION','Folding / presentation','FINISH',80),
 ('WRONG_LABEL','Wrong or missing label','FINISH',90),
 ('LATE_DELIVERY','Late delivery','DISTRIBUTION',100),
 ('MISSED_COLLECTION','Missed collection','DISTRIBUTION',110),
 ('TROLLEY_ISSUE','Trolley issue','DISTRIBUTION',120),
 ('DRIVER_BEHAVIOUR','Driver behaviour','DISTRIBUTION',130),
 ('OTHER','Other',null,999)
on conflict (type_code) do nothing;

create table if not exists public.customer_service_customer_owners (
  customer_id uuid primary key references public.customers(customer_id) on delete cascade,
  owner_auth_user_id uuid not null references auth.users(id) on delete cascade,
  assigned_at timestamptz not null default now(),
  assigned_by_auth_user_id uuid references auth.users(id) on delete set null
);
create index if not exists customer_service_customer_owners_owner_idx on public.customer_service_customer_owners(owner_auth_user_id);

create sequence if not exists public.customer_service_complaint_seq;

create table if not exists public.customer_service_complaints (
  complaint_id uuid primary key default gen_random_uuid(),
  complaint_code text not null unique default ('CS-'||lpad(nextval('public.customer_service_complaint_seq')::text,5,'0')),
  customer_id uuid not null references public.customers(customer_id) on delete restrict,
  received_on date not null,
  delivery_date date,
  channel text check (channel in ('PHONE','EMAIL','DRIVER','IN_PERSON','OTHER')),
  type_code text not null references public.customer_service_complaint_types(type_code) on delete restrict,
  severity text not null default 'MEDIUM' check (severity in ('LOW','MEDIUM','HIGH')),
  description text not null check (length(trim(description)) between 3 and 4000),
  customer_reference text check (customer_reference is null or length(customer_reference)<=120),
  status text not null default 'OPEN' check (status in ('OPEN','INVESTIGATING','RESOLVED','CANCELLED')),
  outcome text check (outcome in ('JUSTIFIED','NOT_JUSTIFIED','UNDETERMINED')),
  resolution_notes text,
  resolved_at timestamptz,
  resolved_by_auth_user_id uuid references auth.users(id) on delete set null,
  owner_auth_user_id uuid references auth.users(id) on delete set null,
  -- Production link, copied when Customer Service matches the complaint to a record.
  linked_finish_entry_id uuid references public.finish_production_entries(finish_production_entry_id) on delete set null,
  linked_wash_run_id uuid references public.sorting_wash_runs(wash_run_id) on delete set null,
  linked_production_flow_item_id uuid,
  finish_business_date date,
  finish_shift_code text,
  finish_table_code text,
  finish_processed_by text,
  sorting_business_date date,
  sorting_shift_code text,
  sorting_washer_name text,
  sorting_operator_name text,
  linked_at timestamptz,
  linked_by_auth_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists customer_service_complaints_received_idx on public.customer_service_complaints(received_on desc);
create index if not exists customer_service_complaints_customer_idx on public.customer_service_complaints(customer_id,received_on desc);
create index if not exists customer_service_complaints_status_idx on public.customer_service_complaints(status) where status in ('OPEN','INVESTIGATING');

create table if not exists public.customer_service_alerts (
  alert_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(customer_id) on delete cascade,
  complaint_id uuid references public.customer_service_complaints(complaint_id) on delete set null,
  message text not null check (length(trim(message)) between 3 and 500),
  areas text[] not null check (cardinality(areas)>0 and areas <@ array['SORTING','FINISH','MOP','DISTRIBUTION']::text[]),
  starts_on date not null,
  ends_on date,
  ended_at timestamptz,
  ended_by_auth_user_id uuid references auth.users(id) on delete set null,
  end_reason text,
  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  check (ends_on is null or ends_on>=starts_on)
);
create index if not exists customer_service_alerts_open_idx on public.customer_service_alerts(customer_id) where ended_at is null;

create table if not exists public.customer_service_tasks (
  task_id uuid primary key default gen_random_uuid(),
  complaint_id uuid references public.customer_service_complaints(complaint_id) on delete set null,
  customer_id uuid references public.customers(customer_id) on delete set null,
  department_code text not null check (department_code in ('SORTING','FINISH','MOP','DISTRIBUTION','CUSTOMER_SERVICE','MAINTENANCE','MANAGEMENT')),
  title text not null check (length(trim(title)) between 3 and 160),
  details text,
  due_on date,
  status text not null default 'OPEN' check (status in ('OPEN','IN_PROGRESS','DONE','CANCELLED')),
  completion_notes text,
  completed_at timestamptz,
  completed_by_auth_user_id uuid references auth.users(id) on delete set null,
  completed_by_name text,
  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists customer_service_tasks_open_idx on public.customer_service_tasks(department_code) where status in ('OPEN','IN_PROGRESS');
create index if not exists customer_service_tasks_complaint_idx on public.customer_service_tasks(complaint_id);

-- Append-only history of every Customer Service action.
create table if not exists public.customer_service_events (
  event_id uuid primary key default gen_random_uuid(),
  complaint_id uuid references public.customer_service_complaints(complaint_id) on delete cascade,
  alert_id uuid references public.customer_service_alerts(alert_id) on delete set null,
  task_id uuid references public.customer_service_tasks(task_id) on delete set null,
  event_type text not null,
  notes text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by_auth_user_id uuid references auth.users(id) on delete set null,
  created_by_name text
);
create index if not exists customer_service_events_complaint_idx on public.customer_service_events(complaint_id,created_at);

alter table public.customer_service_complaint_types enable row level security;
alter table public.customer_service_customer_owners enable row level security;
alter table public.customer_service_complaints enable row level security;
alter table public.customer_service_alerts enable row level security;
alter table public.customer_service_tasks enable row level security;
alter table public.customer_service_events enable row level security;
revoke all on public.customer_service_complaint_types,public.customer_service_customer_owners,public.customer_service_complaints,
  public.customer_service_alerts,public.customer_service_tasks,public.customer_service_events from public,anon,authenticated;
revoke all on sequence public.customer_service_complaint_seq from public,anon,authenticated;

-- Access helpers -------------------------------------------------------------------

create or replace function public.customer_service_access_scope()
returns text language sql stable security definer set search_path=public,auth,pg_temp as $$
  select case
    when auth.uid() is null or not public.current_account_is_enabled() then null
    when public.has_any_role(array['ADMIN','MANAGER']) then 'ALL'
    when public.has_account_permission('CUSTOMER_SERVICE','VIEW','ALL') then 'ALL'
    when public.has_account_permission('CUSTOMER_SERVICE','VIEW',null) then 'OWN'
    else null end;
$$;

create or replace function public.customer_service_can(p_action text)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.customer_service_access_scope() is not null and (
    public.has_any_role(array['ADMIN','MANAGER'])
    or public.has_account_permission('CUSTOMER_SERVICE',p_action,null));
$$;

create or replace function public.require_customer_service_access(p_action text default 'VIEW')
returns void language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
  if public.customer_service_access_scope() is null then
    raise exception using errcode='42501',message='This account cannot use Customer Service.';
  end if;
  if upper(coalesce(p_action,'VIEW'))<>'VIEW' and not public.customer_service_can(upper(p_action)) then
    raise exception using errcode='42501',message='This account cannot change Customer Service records.';
  end if;
end;$$;

create or replace function public.customer_service_user_name(p_auth_user_id uuid)
returns text language sql stable security definer set search_path=public,auth,pg_temp as $$
  select coalesce(
    (select nullif(trim(ap.display_name),'') from public.account_access_profiles ap where ap.auth_user_id=p_auth_user_id),
    (select sm.display_name from public.staff_members sm where sm.auth_user_id=p_auth_user_id and sm.deleted_at is null order by sm.active desc limit 1),
    (select u.email from auth.users u where u.id=p_auth_user_id));
$$;

create or replace function public.customer_service_customer_visible(p_customer_id uuid,p_created_by uuid default null)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.customer_service_access_scope()='ALL'
    or (p_created_by is not null and p_created_by=auth.uid())
    or exists(select 1 from public.customer_service_customer_owners o where o.customer_id=p_customer_id and o.owner_auth_user_id=auth.uid());
$$;

create or replace function public.customer_service_today()
returns date language sql stable security definer set search_path=public,auth,pg_temp as $$
  select (now() at time zone coalesce((select nullif(value_json #>> '{}','') from public.app_config where config_key='business_timezone'),'Europe/Dublin'))::date;
$$;

create or replace function public.customer_service_log(p_complaint_id uuid,p_event_type text,p_notes text default null,p_details jsonb default '{}'::jsonb,p_alert_id uuid default null,p_task_id uuid default null)
returns void language sql security definer set search_path=public,auth,pg_temp as $$
  insert into public.customer_service_events(complaint_id,alert_id,task_id,event_type,notes,details,created_by_auth_user_id,created_by_name)
  values(p_complaint_id,p_alert_id,p_task_id,p_event_type,nullif(trim(p_notes),''),coalesce(p_details,'{}'::jsonb),auth.uid(),public.customer_service_user_name(auth.uid()));
$$;

revoke all on function public.customer_service_access_scope(),public.customer_service_can(text),public.require_customer_service_access(text),
  public.customer_service_user_name(uuid),public.customer_service_customer_visible(uuid,uuid),public.customer_service_today(),
  public.customer_service_log(uuid,text,text,jsonb,uuid,uuid) from public,anon,authenticated;

-- JSON shapes -----------------------------------------------------------------------

create or replace function public.customer_service_complaint_json(p_complaint_id uuid)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object(
    'complaint_id',c.complaint_id,'complaint_code',c.complaint_code,
    'customer_id',c.customer_id,'customer_code',cu.customer_code,'customer_name',cu.customer_name,
    'received_on',c.received_on,'delivery_date',c.delivery_date,'channel',c.channel,
    'type_code',c.type_code,'type_name',t.type_name,'severity',c.severity,
    'description',c.description,'customer_reference',c.customer_reference,
    'status',c.status,'outcome',c.outcome,'resolution_notes',c.resolution_notes,'resolved_at',c.resolved_at,
    'resolved_by_name',public.customer_service_user_name(c.resolved_by_auth_user_id),
    'owner_auth_user_id',c.owner_auth_user_id,'owner_name',public.customer_service_user_name(c.owner_auth_user_id),
    'created_at',c.created_at,'created_by_name',public.customer_service_user_name(c.created_by_auth_user_id),
    'days_open',case when c.status in ('OPEN','INVESTIGATING') then public.customer_service_today()-c.received_on else coalesce(c.resolved_at::date,c.updated_at::date)-c.received_on end,
    'link',case when c.linked_finish_entry_id is null and c.linked_wash_run_id is null then null else jsonb_build_object(
      'finish_entry_id',c.linked_finish_entry_id,'wash_run_id',c.linked_wash_run_id,'production_flow_item_id',c.linked_production_flow_item_id,
      'finish_business_date',c.finish_business_date,'finish_shift_code',c.finish_shift_code,'finish_table_code',c.finish_table_code,'finish_processed_by',c.finish_processed_by,
      'sorting_business_date',c.sorting_business_date,'sorting_shift_code',c.sorting_shift_code,'sorting_washer_name',c.sorting_washer_name,'sorting_operator_name',c.sorting_operator_name,
      'linked_at',c.linked_at,'linked_by_name',public.customer_service_user_name(c.linked_by_auth_user_id)) end,
    'open_task_count',(select count(*) from public.customer_service_tasks k where k.complaint_id=c.complaint_id and k.status in ('OPEN','IN_PROGRESS')),
    'task_count',(select count(*) from public.customer_service_tasks k where k.complaint_id=c.complaint_id and k.status<>'CANCELLED'),
    'active_alert',exists(select 1 from public.customer_service_alerts a where a.customer_id=c.customer_id and a.ended_at is null
      and a.starts_on<=public.customer_service_today() and (a.ends_on is null or a.ends_on>=public.customer_service_today()))
  )
  from public.customer_service_complaints c
  join public.customers cu on cu.customer_id=c.customer_id
  join public.customer_service_complaint_types t on t.type_code=c.type_code
  where c.complaint_id=p_complaint_id;
$$;

create or replace function public.customer_service_alert_json(p_alert_id uuid)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object(
    'alert_id',a.alert_id,'customer_id',a.customer_id,'customer_code',cu.customer_code,'customer_name',cu.customer_name,
    'complaint_id',a.complaint_id,'complaint_code',c.complaint_code,'message',a.message,'areas',to_jsonb(a.areas),
    'starts_on',a.starts_on,'ends_on',a.ends_on,'ended_at',a.ended_at,'end_reason',a.end_reason,
    'ended_by_name',public.customer_service_user_name(a.ended_by_auth_user_id),
    'created_at',a.created_at,'created_by_name',public.customer_service_user_name(a.created_by_auth_user_id),
    'state',case when a.ended_at is not null then 'ENDED'
      when a.ends_on is not null and a.ends_on<public.customer_service_today() then 'EXPIRED'
      when a.starts_on>public.customer_service_today() then 'SCHEDULED' else 'ACTIVE' end)
  from public.customer_service_alerts a
  join public.customers cu on cu.customer_id=a.customer_id
  left join public.customer_service_complaints c on c.complaint_id=a.complaint_id
  where a.alert_id=p_alert_id;
$$;

create or replace function public.customer_service_task_json(p_task_id uuid)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object(
    'task_id',k.task_id,'complaint_id',k.complaint_id,'complaint_code',c.complaint_code,
    'customer_id',k.customer_id,'customer_code',cu.customer_code,'customer_name',cu.customer_name,
    'department_code',k.department_code,'title',k.title,'details',k.details,'due_on',k.due_on,'status',k.status,
    'overdue',k.status in ('OPEN','IN_PROGRESS') and k.due_on is not null and k.due_on<public.customer_service_today(),
    'completion_notes',k.completion_notes,'completed_at',k.completed_at,'completed_by_name',k.completed_by_name,
    'created_at',k.created_at,'created_by_name',public.customer_service_user_name(k.created_by_auth_user_id))
  from public.customer_service_tasks k
  left join public.customers cu on cu.customer_id=k.customer_id
  left join public.customer_service_complaints c on c.complaint_id=k.complaint_id
  where k.task_id=p_task_id;
$$;

revoke all on function public.customer_service_complaint_json(uuid),public.customer_service_alert_json(uuid),public.customer_service_task_json(uuid) from public,anon,authenticated;

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
    'customers',coalesce((select jsonb_agg(jsonb_build_object('customer_id',cu.customer_id,'customer_code',cu.customer_code,'customer_name',cu.customer_name,
        'owner_auth_user_id',o.owner_auth_user_id,'owner_name',public.customer_service_user_name(o.owner_auth_user_id),'mine',o.owner_auth_user_id=auth.uid())
      order by lower(cu.customer_name)) from public.customers cu left join public.customer_service_customer_owners o on o.customer_id=cu.customer_id
      where cu.deleted_at is null and cu.active),'[]'::jsonb),
    'types',coalesce((select jsonb_agg(to_jsonb(t)-'created_at'-'updated_at' order by t.sort_order,t.type_name) from public.customer_service_complaint_types t),'[]'::jsonb),
    'agents',coalesce((select jsonb_agg(jsonb_build_object('auth_user_id',x.auth_user_id,'display_name',public.customer_service_user_name(x.auth_user_id),'scope',x.access_scope,'can_manage',x.can_manage)
      order by lower(public.customer_service_user_name(x.auth_user_id))) from (
        select g.auth_user_id,g.access_scope,g.can_manage from public.account_permission_grants g
        where g.module_code='CUSTOMER_SERVICE' and g.active and g.effective_from<=current_date and (g.effective_until is null or g.effective_until>=current_date)
          and (g.can_create or g.can_edit or g.can_manage)) x),'[]'::jsonb),
    'counts',jsonb_build_object(
      'open_complaints',(select count(*) from public.customer_service_complaints c where c.status in ('OPEN','INVESTIGATING') and public.customer_service_customer_visible(c.customer_id,c.created_by_auth_user_id)),
      'active_alerts',(select count(*) from public.customer_service_alerts a where a.ended_at is null and a.starts_on<=v_today and (a.ends_on is null or a.ends_on>=v_today) and public.customer_service_customer_visible(a.customer_id,a.created_by_auth_user_id)),
      'open_tasks',(select count(*) from public.customer_service_tasks k where k.status in ('OPEN','IN_PROGRESS') and (k.customer_id is null or public.customer_service_customer_visible(k.customer_id,k.created_by_auth_user_id))),
      'overdue_tasks',(select count(*) from public.customer_service_tasks k where k.status in ('OPEN','IN_PROGRESS') and k.due_on<v_today and (k.customer_id is null or public.customer_service_customer_visible(k.customer_id,k.created_by_auth_user_id))))
  );
end;$$;

-- Complaints ------------------------------------------------------------------------

create or replace function public.get_customer_service_complaints_v1(p_from date default null,p_to date default null,p_status text default null,p_customer_id uuid default null,p_only_mine boolean default false)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_to date; v_from date; v_status text:=upper(nullif(trim(p_status),''));
begin
  perform public.require_customer_service_access('VIEW');
  v_to:=coalesce(p_to,public.customer_service_today());
  v_from:=coalesce(p_from,v_to-30);
  if v_from>v_to then raise exception using errcode='22023',message='The start date must be on or before the end date.'; end if;
  if v_to-v_from>731 then raise exception using errcode='22023',message='Choose a period of two years or less.'; end if;
  return jsonb_build_object('from',v_from,'to',v_to,'complaints',coalesce((
    select jsonb_agg(public.customer_service_complaint_json(c.complaint_id) order by c.received_on desc,c.created_at desc)
    from public.customer_service_complaints c
    where public.customer_service_customer_visible(c.customer_id,c.created_by_auth_user_id)
      and (p_customer_id is null or c.customer_id=p_customer_id)
      and (not coalesce(p_only_mine,false) or c.owner_auth_user_id=auth.uid() or c.created_by_auth_user_id=auth.uid())
      and case
        when v_status='ACTIVE' then c.status in ('OPEN','INVESTIGATING')
        when v_status is null or v_status='ALL' then c.received_on between v_from and v_to
        else c.status=v_status and c.received_on between v_from and v_to end
  ),'[]'::jsonb));
end;$$;

create or replace function public.get_customer_service_complaint_v1(p_complaint_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints;
begin
  perform public.require_customer_service_access('VIEW');
  select * into v_row from public.customer_service_complaints where complaint_id=p_complaint_id;
  if v_row.complaint_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Complaint not found.';
  end if;
  return jsonb_build_object(
    'complaint',public.customer_service_complaint_json(p_complaint_id),
    'events',coalesce((select jsonb_agg(jsonb_build_object('event_type',e.event_type,'notes',e.notes,'details',e.details,'created_at',e.created_at,'created_by_name',e.created_by_name) order by e.created_at desc)
      from public.customer_service_events e where e.complaint_id=p_complaint_id),'[]'::jsonb),
    'alerts',coalesce((select jsonb_agg(public.customer_service_alert_json(a.alert_id) order by a.created_at desc)
      from public.customer_service_alerts a where a.complaint_id=p_complaint_id),'[]'::jsonb),
    'tasks',coalesce((select jsonb_agg(public.customer_service_task_json(k.task_id) order by k.created_at desc)
      from public.customer_service_tasks k where k.complaint_id=p_complaint_id),'[]'::jsonb),
    'customer_history',coalesce((select jsonb_agg(jsonb_build_object('complaint_id',c.complaint_id,'complaint_code',c.complaint_code,'received_on',c.received_on,'type_name',t.type_name,'status',c.status) order by c.received_on desc)
      from (select * from public.customer_service_complaints c2 where c2.customer_id=v_row.customer_id and c2.complaint_id<>p_complaint_id and c2.status<>'CANCELLED' order by c2.received_on desc limit 10) c
      join public.customer_service_complaint_types t on t.type_code=c.type_code),'[]'::jsonb)
  );
end;$$;

create or replace function public.save_customer_service_complaint_v1(
  p_complaint_id uuid,p_customer_id uuid,p_received_on date,p_type_code text,p_description text,
  p_severity text default 'MEDIUM',p_delivery_date date default null,p_channel text default null,p_customer_reference text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints; v_id uuid; v_owner uuid; v_changes jsonb:='{}'::jsonb;
begin
  perform public.require_customer_service_access(case when p_complaint_id is null then 'CREATE' else 'EDIT' end);
  if not exists(select 1 from public.customers where customer_id=p_customer_id and deleted_at is null) then
    raise exception using errcode='22023',message='Choose a customer.';
  end if;
  if not exists(select 1 from public.customer_service_complaint_types where type_code=upper(trim(p_type_code)) and active) then
    raise exception using errcode='22023',message='Choose a complaint type.';
  end if;
  if p_received_on is null or p_received_on>public.customer_service_today()+1 then
    raise exception using errcode='22023',message='The received date is required and cannot be in the future.';
  end if;
  if length(trim(coalesce(p_description,'')))<3 then
    raise exception using errcode='22023',message='Describe the complaint.';
  end if;

  if p_complaint_id is null then
    select owner_auth_user_id into v_owner from public.customer_service_customer_owners where customer_id=p_customer_id;
    insert into public.customer_service_complaints(customer_id,received_on,delivery_date,channel,type_code,severity,description,customer_reference,owner_auth_user_id,created_by_auth_user_id)
    values(p_customer_id,p_received_on,p_delivery_date,nullif(upper(trim(p_channel)),''),upper(trim(p_type_code)),upper(coalesce(nullif(trim(p_severity),''),'MEDIUM')),
      trim(p_description),nullif(trim(p_customer_reference),''),coalesce(v_owner,auth.uid()),auth.uid())
    returning complaint_id into v_id;
    perform public.customer_service_log(v_id,'CREATED',null,jsonb_build_object('type_code',upper(trim(p_type_code))));
    return public.customer_service_complaint_json(v_id);
  end if;

  select * into v_row from public.customer_service_complaints where complaint_id=p_complaint_id for update;
  if v_row.complaint_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Complaint not found.';
  end if;
  if v_row.status='CANCELLED' then raise exception using errcode='22023',message='A cancelled complaint cannot be changed.'; end if;
  if v_row.customer_id<>p_customer_id then v_changes:=v_changes||jsonb_build_object('customer',true); end if;
  if v_row.type_code<>upper(trim(p_type_code)) then v_changes:=v_changes||jsonb_build_object('type_from',v_row.type_code,'type_to',upper(trim(p_type_code))); end if;
  if v_row.received_on<>p_received_on then v_changes:=v_changes||jsonb_build_object('received_from',v_row.received_on,'received_to',p_received_on); end if;
  if v_row.description<>trim(p_description) then v_changes:=v_changes||jsonb_build_object('description',true); end if;
  if v_row.severity<>upper(coalesce(nullif(trim(p_severity),''),'MEDIUM')) then v_changes:=v_changes||jsonb_build_object('severity_to',upper(p_severity)); end if;
  update public.customer_service_complaints set
    customer_id=p_customer_id,received_on=p_received_on,delivery_date=p_delivery_date,channel=nullif(upper(trim(p_channel)),''),
    type_code=upper(trim(p_type_code)),severity=upper(coalesce(nullif(trim(p_severity),''),'MEDIUM')),description=trim(p_description),
    customer_reference=nullif(trim(p_customer_reference),''),updated_at=now()
  where complaint_id=p_complaint_id;
  perform public.customer_service_log(p_complaint_id,'EDITED',null,v_changes);
  return public.customer_service_complaint_json(p_complaint_id);
end;$$;

create or replace function public.set_customer_service_complaint_status_v1(p_complaint_id uuid,p_status text,p_outcome text default null,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints; v_status text:=upper(trim(coalesce(p_status,''))); v_outcome text:=nullif(upper(trim(coalesce(p_outcome,''))),'');
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
  return public.customer_service_complaint_json(p_complaint_id);
end;$$;

create or replace function public.add_customer_service_note_v1(p_complaint_id uuid,p_notes text)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints;
begin
  perform public.require_customer_service_access('EDIT');
  select * into v_row from public.customer_service_complaints where complaint_id=p_complaint_id;
  if v_row.complaint_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Complaint not found.';
  end if;
  if length(trim(coalesce(p_notes,'')))<2 then raise exception using errcode='22023',message='Write the note.'; end if;
  perform public.customer_service_log(p_complaint_id,'NOTE',p_notes);
  update public.customer_service_complaints set updated_at=now() where complaint_id=p_complaint_id;
  return public.get_customer_service_complaint_v1(p_complaint_id);
end;$$;

-- Production trace: which washes, shifts, tables and staff handled the customer's goods.

create or replace function public.get_customer_service_production_trace_v1(p_customer_id uuid,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
  perform public.require_customer_service_access('VIEW');
  if p_customer_id is null or p_from is null or p_to is null then raise exception using errcode='22023',message='Choose a customer and a period.'; end if;
  if p_from>p_to then raise exception using errcode='22023',message='The start date must be on or before the end date.'; end if;
  if p_to-p_from>62 then raise exception using errcode='22023',message='Choose a period of 62 days or less.'; end if;

  -- Finish: every active record whose production or delivery date is in the period, with
  -- the staff who worked on that table in that shift (including people moved onto it).
  -- Sorting: every wash of the customer in the period (three days earlier included, since
  -- goods are washed before they are finished), with the Sorting staff of that shift.
  -- Washes and Finish share production_flow_item_id when both were recorded in this app.
  return jsonb_build_object('customer_id',p_customer_id,'from',p_from,'to',p_to,
    'finish',coalesce((select jsonb_agg(jsonb_build_object(
        'finish_production_entry_id',f.finish_production_entry_id,'production_flow_item_id',f.production_flow_item_id,
        'business_date',f.production_business_date,'delivery_date',f.delivery_date,
        'shift_code',f.shift_code_snapshot,'table_code',f.table_code_snapshot,'table_name',coalesce(f.table_name_snapshot,f.table_code_snapshot),
        'processed_by',coalesce(f.processed_by_name_snapshot,(select sm.display_name from public.staff_members sm where sm.staff_id=f.processed_by_staff_id)),
        'recorded_at',f.recorded_at,'notes',f.notes,
        'kg',(select coalesce(sum(l.quantity) filter (where l.unit_code='KG'),0) from public.finish_production_lines l where l.finish_production_entry_id=f.finish_production_entry_id),
        'units',(select coalesce(sum(l.quantity) filter (where l.unit_code='UNIT'),0) from public.finish_production_lines l where l.finish_production_entry_id=f.finish_production_entry_id),
        'batches',(select coalesce(jsonb_agg(distinct l.batch_reference) filter (where l.batch_reference is not null),'[]'::jsonb) from public.finish_production_lines l where l.finish_production_entry_id=f.finish_production_entry_id),
        'table_staff',(select coalesce(jsonb_agg(distinct sm.display_name),'[]'::jsonb)
          from public.work_sessions ws join public.staff_members sm on sm.staff_id=ws.staff_id
          where ws.work_date=f.production_business_date and ws.shift_id=f.shift_id and coalesce(ws.status,'')<>'CANCELLED'
            and (ws.station_id=f.table_station_id or exists(select 1 from public.finish_staff_table_segments s where s.work_session_id=ws.work_session_id and s.station_id=f.table_station_id)))
      ) order by f.production_business_date desc,f.recorded_at desc)
      from (select e.*,coalesce(e.station_id,st.station_id) as table_station_id
        from public.finish_production_entries e
        left join public.stations st on st.station_code=e.table_code_snapshot and st.deleted_at is null
        where e.customer_id=p_customer_id and e.status='ACTIVE'
          and (e.delivery_date between p_from and p_to or e.production_business_date between p_from and p_to)) f),'[]'::jsonb),
    'washes',coalesce((select jsonb_agg(jsonb_build_object(
        'wash_run_id',w.wash_run_id,'production_flow_item_id',w.flow_id,'wash_code',w.wash_code,'business_date',w.business_date,
        'scheduled_for_date',w.scheduled_for_date,'shift_code',w.shift_code_snapshot,
        'washer_name',w.washer_name_snapshot,'operator_name',w.operator_name_snapshot,'wash_type',w.wash_type,
        'registered_at',w.registered_at,'customer_kg',w.allocated_weight_kg,'total_kg',w.total_weight_kg,
        'sorting_staff',(select coalesce(jsonb_agg(distinct sm.display_name),'[]'::jsonb)
          from public.work_sessions ws join public.staff_members sm on sm.staff_id=ws.staff_id join public.areas a on a.area_id=ws.area_id
          where a.area_code='SORTING' and ws.work_date=w.business_date and ws.shift_id=w.shift_id and coalesce(ws.status,'')<>'CANCELLED')
      ) order by w.business_date desc,w.registered_at desc)
      from (select r.*,wc.production_flow_item_id as flow_id,wc.allocated_weight_kg,wc.scheduled_for_date
        from public.sorting_wash_run_customers wc
        join public.sorting_wash_runs r on r.wash_run_id=wc.wash_run_id
        where wc.customer_id=p_customer_id and r.cancelled_at is null and coalesce(r.status,'')<>'CANCELLED'
          and not exists(select 1 from public.sorting_wash_runs r2 where r2.replaces_wash_run_id=r.wash_run_id and r2.cancelled_at is null)
          and r.business_date between p_from-3 and p_to) w),'[]'::jsonb));
end;$$;

create or replace function public.link_customer_service_complaint_production_v1(p_complaint_id uuid,p_finish_entry_id uuid default null,p_wash_run_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_complaints; v_fin public.finish_production_entries; v_wash public.sorting_wash_runs; v_flow uuid;
begin
  perform public.require_customer_service_access('EDIT');
  select * into v_row from public.customer_service_complaints where complaint_id=p_complaint_id for update;
  if v_row.complaint_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Complaint not found.';
  end if;
  if p_finish_entry_id is not null then
    select * into v_fin from public.finish_production_entries where finish_production_entry_id=p_finish_entry_id and customer_id=v_row.customer_id;
    if v_fin.finish_production_entry_id is null then raise exception using errcode='22023',message='That Finish record is not for this customer.'; end if;
    v_flow:=v_fin.production_flow_item_id;
  end if;
  if p_wash_run_id is not null then
    select r.* into v_wash from public.sorting_wash_runs r
    where r.wash_run_id=p_wash_run_id and exists(select 1 from public.sorting_wash_run_customers wc where wc.wash_run_id=r.wash_run_id and wc.customer_id=v_row.customer_id);
    if v_wash.wash_run_id is null then raise exception using errcode='22023',message='That wash is not for this customer.'; end if;
    if v_flow is null then
      select wc.production_flow_item_id into v_flow from public.sorting_wash_run_customers wc where wc.wash_run_id=p_wash_run_id and wc.customer_id=v_row.customer_id limit 1;
    end if;
  end if;
  update public.customer_service_complaints set
    linked_finish_entry_id=v_fin.finish_production_entry_id,linked_wash_run_id=v_wash.wash_run_id,linked_production_flow_item_id=v_flow,
    finish_business_date=v_fin.production_business_date,finish_shift_code=v_fin.shift_code_snapshot,finish_table_code=v_fin.table_code_snapshot,
    finish_processed_by=coalesce(v_fin.processed_by_name_snapshot,(select sm.display_name from public.staff_members sm where sm.staff_id=v_fin.processed_by_staff_id)),
    sorting_business_date=v_wash.business_date,sorting_shift_code=v_wash.shift_code_snapshot,sorting_washer_name=v_wash.washer_name_snapshot,sorting_operator_name=v_wash.operator_name_snapshot,
    linked_at=case when p_finish_entry_id is null and p_wash_run_id is null then null else now() end,
    linked_by_auth_user_id=case when p_finish_entry_id is null and p_wash_run_id is null then null else auth.uid() end,
    status=case when status='OPEN' and (p_finish_entry_id is not null or p_wash_run_id is not null) then 'INVESTIGATING' else status end,
    updated_at=now()
  where complaint_id=p_complaint_id;
  perform public.customer_service_log(p_complaint_id,case when p_finish_entry_id is null and p_wash_run_id is null then 'UNLINKED' else 'LINKED' end,null,
    jsonb_build_object('finish_date',v_fin.production_business_date,'finish_shift',v_fin.shift_code_snapshot,'finish_table',v_fin.table_code_snapshot,
      'sorting_date',v_wash.business_date,'sorting_shift',v_wash.shift_code_snapshot,'washer',v_wash.washer_name_snapshot));
  return public.customer_service_complaint_json(p_complaint_id);
end;$$;

-- Alerts ----------------------------------------------------------------------------

create or replace function public.get_customer_service_alerts_v1(p_include_ended boolean default false)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_today date:=public.customer_service_today();
begin
  perform public.require_customer_service_access('VIEW');
  return coalesce((select jsonb_agg(public.customer_service_alert_json(a.alert_id) order by (a.ended_at is null and (a.ends_on is null or a.ends_on>=v_today)) desc,a.created_at desc)
    from public.customer_service_alerts a
    where public.customer_service_customer_visible(a.customer_id,a.created_by_auth_user_id)
      and (coalesce(p_include_ended,false) or (a.ended_at is null and (a.ends_on is null or a.ends_on>=v_today)))
      and (not coalesce(p_include_ended,false) or a.created_at>=now()-interval '180 days' or a.ended_at is null)),'[]'::jsonb);
end;$$;

create or replace function public.save_customer_service_alert_v1(p_alert_id uuid,p_customer_id uuid,p_message text,p_areas text[],p_starts_on date default null,p_ends_on date default null,p_complaint_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_id uuid; v_row public.customer_service_alerts; v_areas text[];
begin
  perform public.require_customer_service_access(case when p_alert_id is null then 'CREATE' else 'EDIT' end);
  select array_agg(distinct upper(trim(x))) into v_areas from unnest(coalesce(p_areas,array[]::text[])) x where trim(x)<>'';
  if coalesce(cardinality(v_areas),0)=0 or not v_areas <@ array['SORTING','FINISH','MOP','DISTRIBUTION']::text[] then
    raise exception using errcode='22023',message='Choose at least one area that must see the alert.';
  end if;
  if length(trim(coalesce(p_message,'')))<3 then raise exception using errcode='22023',message='Write the alert message.'; end if;
  if p_ends_on is not null and p_ends_on<coalesce(p_starts_on,public.customer_service_today()) then
    raise exception using errcode='22023',message='The end date must be on or after the start date.';
  end if;
  if not exists(select 1 from public.customers where customer_id=p_customer_id and deleted_at is null) then
    raise exception using errcode='22023',message='Choose a customer.';
  end if;
  if p_complaint_id is not null and not exists(select 1 from public.customer_service_complaints c where c.complaint_id=p_complaint_id and c.customer_id=p_customer_id) then
    raise exception using errcode='22023',message='The complaint is not for this customer.';
  end if;

  if p_alert_id is null then
    insert into public.customer_service_alerts(customer_id,complaint_id,message,areas,starts_on,ends_on,created_by_auth_user_id)
    values(p_customer_id,p_complaint_id,trim(p_message),v_areas,coalesce(p_starts_on,public.customer_service_today()),p_ends_on,auth.uid())
    returning alert_id into v_id;
    perform public.customer_service_log(p_complaint_id,'ALERT_CREATED',p_message,jsonb_build_object('areas',to_jsonb(v_areas),'ends_on',p_ends_on),v_id,null);
    return public.customer_service_alert_json(v_id);
  end if;

  select * into v_row from public.customer_service_alerts where alert_id=p_alert_id for update;
  if v_row.alert_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Alert not found.';
  end if;
  if v_row.ended_at is not null then raise exception using errcode='22023',message='An ended alert cannot be changed. Create a new one.'; end if;
  update public.customer_service_alerts set message=trim(p_message),areas=v_areas,starts_on=coalesce(p_starts_on,starts_on),ends_on=p_ends_on
  where alert_id=p_alert_id;
  perform public.customer_service_log(v_row.complaint_id,'ALERT_EDITED',p_message,jsonb_build_object('areas',to_jsonb(v_areas),'ends_on',p_ends_on),p_alert_id,null);
  return public.customer_service_alert_json(p_alert_id);
end;$$;

create or replace function public.end_customer_service_alert_v1(p_alert_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_alerts;
begin
  perform public.require_customer_service_access('EDIT');
  select * into v_row from public.customer_service_alerts where alert_id=p_alert_id for update;
  if v_row.alert_id is null or not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id) then
    raise exception using errcode='P0002',message='Alert not found.';
  end if;
  if v_row.ended_at is null then
    update public.customer_service_alerts set ended_at=now(),ended_by_auth_user_id=auth.uid(),end_reason=nullif(trim(p_reason),'') where alert_id=p_alert_id;
    perform public.customer_service_log(v_row.complaint_id,'ALERT_ENDED',p_reason,'{}'::jsonb,p_alert_id,null);
  end if;
  return public.customer_service_alert_json(p_alert_id);
end;$$;

-- Tasks -----------------------------------------------------------------------------

create or replace function public.get_customer_service_tasks_v1(p_status text default 'ACTIVE',p_department_code text default null)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_status text:=upper(coalesce(nullif(trim(p_status),''),'ACTIVE'));
begin
  perform public.require_customer_service_access('VIEW');
  return coalesce((select jsonb_agg(public.customer_service_task_json(k.task_id)
      order by (k.status in ('OPEN','IN_PROGRESS')) desc,k.due_on nulls last,k.created_at desc)
    from public.customer_service_tasks k
    where (k.customer_id is null or public.customer_service_customer_visible(k.customer_id,k.created_by_auth_user_id))
      and (p_department_code is null or k.department_code=upper(trim(p_department_code)))
      and case when v_status='ACTIVE' then k.status in ('OPEN','IN_PROGRESS')
        when v_status='ALL' then k.status in ('OPEN','IN_PROGRESS') or k.updated_at>=now()-interval '180 days'
        else k.status=v_status and k.updated_at>=now()-interval '180 days' end),'[]'::jsonb);
end;$$;

create or replace function public.save_customer_service_task_v1(p_task_id uuid,p_department_code text,p_title text,p_details text default null,p_due_on date default null,p_complaint_id uuid default null,p_customer_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_id uuid; v_row public.customer_service_tasks; v_customer uuid:=p_customer_id; v_dept text:=upper(trim(coalesce(p_department_code,'')));
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

  if p_task_id is null then
    insert into public.customer_service_tasks(complaint_id,customer_id,department_code,title,details,due_on,created_by_auth_user_id)
    values(p_complaint_id,v_customer,v_dept,trim(p_title),nullif(trim(p_details),''),p_due_on,auth.uid())
    returning task_id into v_id;
    perform public.customer_service_log(p_complaint_id,'TASK_CREATED',p_title,jsonb_build_object('department',v_dept,'due_on',p_due_on),null,v_id);
    return public.customer_service_task_json(v_id);
  end if;

  select * into v_row from public.customer_service_tasks where task_id=p_task_id for update;
  if v_row.task_id is null or (v_row.customer_id is not null and not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id)) then
    raise exception using errcode='P0002',message='Task not found.';
  end if;
  update public.customer_service_tasks set department_code=v_dept,title=trim(p_title),details=nullif(trim(p_details),''),due_on=p_due_on,updated_at=now()
  where task_id=p_task_id;
  perform public.customer_service_log(v_row.complaint_id,'TASK_EDITED',p_title,jsonb_build_object('department',v_dept,'due_on',p_due_on),null,p_task_id);
  return public.customer_service_task_json(p_task_id);
end;$$;

create or replace function public.set_customer_service_task_status_v1(p_task_id uuid,p_status text,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_tasks; v_status text:=upper(trim(coalesce(p_status,'')));
begin
  perform public.require_customer_service_access('EDIT');
  select * into v_row from public.customer_service_tasks where task_id=p_task_id for update;
  if v_row.task_id is null or (v_row.customer_id is not null and not public.customer_service_customer_visible(v_row.customer_id,v_row.created_by_auth_user_id)) then
    raise exception using errcode='P0002',message='Task not found.';
  end if;
  if v_status not in ('OPEN','IN_PROGRESS','DONE','CANCELLED') then raise exception using errcode='22023',message='Unknown task status.'; end if;
  if v_status in ('DONE','CANCELLED') and length(trim(coalesce(p_notes,'')))<2 then raise exception using errcode='22023',message='Write what was done.'; end if;
  update public.customer_service_tasks set status=v_status,
    completion_notes=case when v_status in ('DONE','CANCELLED') then trim(p_notes) else null end,
    completed_at=case when v_status in ('DONE','CANCELLED') then now() else null end,
    completed_by_auth_user_id=case when v_status in ('DONE','CANCELLED') then auth.uid() else null end,
    completed_by_name=case when v_status in ('DONE','CANCELLED') then public.customer_service_user_name(auth.uid()) else null end,
    updated_at=now()
  where task_id=p_task_id;
  perform public.customer_service_log(v_row.complaint_id,'TASK_'||v_status,p_notes,jsonb_build_object('title',v_row.title,'department',v_row.department_code),null,p_task_id);
  return public.customer_service_task_json(p_task_id);
end;$$;

-- Results ---------------------------------------------------------------------------

create or replace function public.get_customer_service_results_v1(p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_from date:=p_from; v_to date:=p_to; v_period text; v_result jsonb;
begin
  perform public.require_customer_service_access('VIEW');
  if v_from is null or v_to is null or v_from>v_to then raise exception using errcode='22023',message='Choose a valid period.'; end if;
  if v_to-v_from>731 then raise exception using errcode='22023',message='Choose a period of two years or less.'; end if;
  v_period:=case when v_to-v_from<=45 then 'day' when v_to-v_from<=190 then 'week' else 'month' end;

  with c as (
    select c.*,t.type_name from public.customer_service_complaints c join public.customer_service_complaint_types t on t.type_code=c.type_code
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
      'resolved',(select count(*) from c where status='RESOLVED'),
      'justified',(select count(*) from c where outcome='JUSTIFIED'),
      'not_justified',(select count(*) from c where outcome='NOT_JUSTIFIED'),
      'high',(select count(*) from c where severity='HIGH'),
      'customers',(select count(distinct customer_id) from c),
      'linked',(select count(*) from c where linked_finish_entry_id is not null or linked_wash_run_id is not null),
      'avg_days_to_resolve',(select round(avg(extract(epoch from (resolved_at-received_on::timestamptz))/86400.0)::numeric,1) from c where status='RESOLVED' and resolved_at is not null),
      'tasks',(select count(*) from k),'tasks_open',(select count(*) from k where status in ('OPEN','IN_PROGRESS')),
      'tasks_overdue',(select count(*) from k where status in ('OPEN','IN_PROGRESS') and due_on<public.customer_service_today())),
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
    'by_owner',coalesce((select jsonb_agg(jsonb_build_object('owner_name',coalesce(public.customer_service_user_name(owner_auth_user_id),'Not assigned'),'complaints',n,'open',o,'resolved',r) order by n desc) from (
      select owner_auth_user_id,count(*) n,count(*) filter (where status in ('OPEN','INVESTIGATING')) o,count(*) filter (where status='RESOLVED') r from c group by 1) x),'[]'::jsonb),
    'by_department',coalesce((select jsonb_agg(jsonb_build_object('department_code',department_code,'tasks',n,'open',o,'overdue',d) order by n desc) from (
      select department_code,count(*) n,count(*) filter (where status in ('OPEN','IN_PROGRESS')) o,
        count(*) filter (where status in ('OPEN','IN_PROGRESS') and due_on<public.customer_service_today()) d from k group by 1) x),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;$$;

-- Manager settings --------------------------------------------------------------------

create or replace function public.save_customer_service_complaint_type_v1(p_type_code text,p_type_name text,p_default_department_code text default null,p_sort_order integer default 100,p_active boolean default true)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_code text;
begin
  perform public.require_customer_service_access('MANAGE');
  v_code:=upper(regexp_replace(trim(coalesce(nullif(p_type_code,''),p_type_name)),'[^A-Za-z0-9]+','_','g'));
  v_code:=trim(both '_' from v_code);
  if length(trim(coalesce(p_type_name,'')))<2 then raise exception using errcode='22023',message='Write the complaint type name.'; end if;
  insert into public.customer_service_complaint_types(type_code,type_name,default_department_code,sort_order,active)
  values(left(v_code,40),trim(p_type_name),nullif(upper(trim(coalesce(p_default_department_code,''))),''),coalesce(p_sort_order,100),coalesce(p_active,true))
  on conflict (type_code) do update set type_name=excluded.type_name,default_department_code=excluded.default_department_code,
    sort_order=excluded.sort_order,active=excluded.active,updated_at=now();
  return coalesce((select jsonb_agg(to_jsonb(t)-'created_at'-'updated_at' order by t.sort_order,t.type_name) from public.customer_service_complaint_types t),'[]'::jsonb);
end;$$;

create or replace function public.set_customer_service_customer_owner_v1(p_customer_ids uuid[],p_owner_auth_user_id uuid default null)
returns integer language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_count integer;
begin
  perform public.require_customer_service_access('MANAGE');
  if p_owner_auth_user_id is not null and not exists(select 1 from public.account_permission_grants g where g.auth_user_id=p_owner_auth_user_id and g.module_code='CUSTOMER_SERVICE' and g.active) then
    raise exception using errcode='22023',message='The selected person has no Customer Service access.';
  end if;
  if p_owner_auth_user_id is null then
    delete from public.customer_service_customer_owners where customer_id=any(coalesce(p_customer_ids,array[]::uuid[]));
  else
    insert into public.customer_service_customer_owners(customer_id,owner_auth_user_id,assigned_by_auth_user_id)
    select cu.customer_id,p_owner_auth_user_id,auth.uid() from public.customers cu where cu.customer_id=any(coalesce(p_customer_ids,array[]::uuid[])) and cu.deleted_at is null
    on conflict (customer_id) do update set owner_auth_user_id=excluded.owner_auth_user_id,assigned_at=now(),assigned_by_auth_user_id=excluded.assigned_by_auth_user_id;
  end if;
  get diagnostics v_count=row_count;
  return v_count;
end;$$;

-- Production screens: active alerts and the area's open tasks --------------------------

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
        'overdue',k.due_on is not null and k.due_on<v_today,'customer_name',cu.customer_name) order by k.due_on nulls last,k.created_at)
      from public.customer_service_tasks k left join public.customers cu on cu.customer_id=k.customer_id
      where k.department_code=v_area and k.status in ('OPEN','IN_PROGRESS')),'[]'::jsonb)
  );
end;$$;

create or replace function public.complete_production_customer_task_v1(p_task_id uuid,p_notes text)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_service_tasks; v_name text;
begin
  perform public.require_production_flow_read_role();
  select * into v_row from public.customer_service_tasks where task_id=p_task_id for update;
  if v_row.task_id is null or v_row.department_code not in ('SORTING','FINISH','MOP','DISTRIBUTION') then
    raise exception using errcode='P0002',message='Task not found.';
  end if;
  if v_row.status not in ('OPEN','IN_PROGRESS') then raise exception using errcode='22023',message='This task is already closed.'; end if;
  if length(trim(coalesce(p_notes,'')))<2 then raise exception using errcode='22023',message='Write what was done and who did it.'; end if;
  v_name:=public.customer_service_user_name(auth.uid());
  update public.customer_service_tasks set status='DONE',completion_notes=trim(p_notes),completed_at=now(),completed_by_auth_user_id=auth.uid(),completed_by_name=v_name,updated_at=now()
  where task_id=p_task_id;
  perform public.customer_service_log(v_row.complaint_id,'TASK_DONE',p_notes,jsonb_build_object('title',v_row.title,'department',v_row.department_code,'from_area',true),null,p_task_id);
  return jsonb_build_object('task_id',p_task_id,'status','DONE');
end;$$;

-- Grants ----------------------------------------------------------------------------

revoke all on function public.get_customer_service_workspace_v1(),
  public.get_customer_service_complaints_v1(date,date,text,uuid,boolean),
  public.get_customer_service_complaint_v1(uuid),
  public.save_customer_service_complaint_v1(uuid,uuid,date,text,text,text,date,text,text),
  public.set_customer_service_complaint_status_v1(uuid,text,text,text),
  public.add_customer_service_note_v1(uuid,text),
  public.get_customer_service_production_trace_v1(uuid,date,date),
  public.link_customer_service_complaint_production_v1(uuid,uuid,uuid),
  public.get_customer_service_alerts_v1(boolean),
  public.save_customer_service_alert_v1(uuid,uuid,text,text[],date,date,uuid),
  public.end_customer_service_alert_v1(uuid,text),
  public.get_customer_service_tasks_v1(text,text),
  public.save_customer_service_task_v1(uuid,text,text,text,date,uuid,uuid),
  public.set_customer_service_task_status_v1(uuid,text,text),
  public.get_customer_service_results_v1(date,date),
  public.save_customer_service_complaint_type_v1(text,text,text,integer,boolean),
  public.set_customer_service_customer_owner_v1(uuid[],uuid),
  public.get_production_customer_alerts_v1(text),
  public.complete_production_customer_task_v1(uuid,text)
from public,anon;

grant execute on function public.get_customer_service_workspace_v1(),
  public.get_customer_service_complaints_v1(date,date,text,uuid,boolean),
  public.get_customer_service_complaint_v1(uuid),
  public.save_customer_service_complaint_v1(uuid,uuid,date,text,text,text,date,text,text),
  public.set_customer_service_complaint_status_v1(uuid,text,text,text),
  public.add_customer_service_note_v1(uuid,text),
  public.get_customer_service_production_trace_v1(uuid,date,date),
  public.link_customer_service_complaint_production_v1(uuid,uuid,uuid),
  public.get_customer_service_alerts_v1(boolean),
  public.save_customer_service_alert_v1(uuid,uuid,text,text[],date,date,uuid),
  public.end_customer_service_alert_v1(uuid,text),
  public.get_customer_service_tasks_v1(text,text),
  public.save_customer_service_task_v1(uuid,text,text,text,date,uuid,uuid),
  public.set_customer_service_task_status_v1(uuid,text,text),
  public.get_customer_service_results_v1(date,date),
  public.save_customer_service_complaint_type_v1(text,text,text,integer,boolean),
  public.set_customer_service_customer_owner_v1(uuid[],uuid),
  public.get_production_customer_alerts_v1(text),
  public.complete_production_customer_task_v1(uuid,text)
to authenticated;
