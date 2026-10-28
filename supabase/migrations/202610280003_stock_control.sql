-- =====================================================================
-- ElisCaretex V2
-- Stock Control: items, movements, counts, PPE/uniforms, locker keys and
-- staff requests for PPE and uniforms
--
-- Owner request 2026-10-28: bring the "Elis Stock Control" Apps Script into
-- the platform.
-- * Three stock areas: PPE and uniforms, chemicals, miscellaneous (packing
--   and other material).
-- * Every item says who it is booked to when it leaves the store:
--     STAFF    - uniforms, safety shoes, PPE and tools (a person);
--     CUSTOMER - packing material (a customer);
--     NONE     - chemicals: nobody registers a take, usage comes from the
--                periodic count (a drop between counts is CONSUMPTION).
-- * Uniforms and PPE held by each person (issued minus returned) and the
--   locker key each person holds, with the list of people who left the
--   company still holding items.
-- * New: every staff member who has a roster login (My Production Roster or
--   My Driver Roster) can request PPE and uniform items. Supervisors,
--   managers and Distribution (Logistics Manager) approve and issue them.
--   Issuing takes the item out of stock and adds it to what the person holds.
--
-- History is append-only: stock_qty on the item is the running balance kept
-- by the RPCs, and every change is a stock_movements row. Corrections are new
-- ADJUST or COUNT movements, never edits of old rows.
--
-- Permissions (module STOCK, already listed in application_modules):
-- * VIEW            see the Stock Control workspace (read only);
-- * EDIT or APPROVE register receipts, takes, adjustments and counts, issue
--                   and return PPE, assign and return locker keys, approve,
--                   reject and issue staff requests;
-- * MANAGE          maintain the item catalogue, locker list and settings.
-- Requesting needs no STOCK grant: any enabled personal account linked to an
-- active Staff Master record with My Roster or My Driver Roster access.
-- Legacy accounts without an access profile fall back to the roles
-- ADMIN/MANAGER (manage), SUPERVISOR (operate) and AUDITOR (view).
-- =====================================================================

begin;

-- 1. Module and permission templates -----------------------------------

insert into public.application_modules(module_code,module_name,module_group,display_order)
values ('STOCK','Stock Control','PRODUCTION',150)
on conflict(module_code) do update set module_name=excluded.module_name,active=true;

with rows(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage) as (values
  ('ADMINISTRATOR','STOCK','ALL',true,true,true,true,true),
  ('GENERAL_MANAGER','STOCK','ALL',true,true,true,true,true),
  ('PRODUCTION_MANAGER','STOCK','ALL',true,true,true,true,true),
  ('LOGISTICS_MANAGER','STOCK','ALL',true,true,true,true,false),
  ('PRODUCTION_SUPERVISOR','STOCK','ALL',true,true,true,true,false),
  ('AUDITOR','STOCK','ALL',true,false,false,false,false)
), templates as (
  insert into public.job_title_permission_templates(job_title_code,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage)
  select * from rows
  on conflict(job_title_code,module_code) do update set access_scope=excluded.access_scope,can_view=excluded.can_view,can_create=excluded.can_create,can_edit=excluded.can_edit,can_approve=excluded.can_approve,can_manage=excluded.can_manage
  returning 1
)
-- Existing accounts of these titles receive the module (additions only).
insert into public.account_permission_grants(auth_user_id,module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage,granted_by_auth_user_id)
select ap.auth_user_id,r.module_code,r.access_scope,r.can_view,r.can_create,r.can_edit,r.can_approve,r.can_manage,null
from rows r
join public.account_access_profiles ap on ap.job_title_code=r.job_title_code and ap.account_type='USER'
on conflict (auth_user_id,module_code) do update set
  can_view=public.account_permission_grants.can_view or excluded.can_view,
  can_create=public.account_permission_grants.can_create or excluded.can_create,
  can_edit=public.account_permission_grants.can_edit or excluded.can_edit,
  can_approve=public.account_permission_grants.can_approve or excluded.can_approve,
  can_manage=public.account_permission_grants.can_manage or excluded.can_manage,
  updated_at=now();

-- 2. Tables -------------------------------------------------------------

create table public.stock_categories (
  category_code text primary key check (category_code ~ '^[A-Z][A-Z0-9_]{1,29}$'),
  category_name text not null unique,
  stock_area text not null check (stock_area in ('PPE_UNIFORM','CHEMICAL','MISCELLANEOUS')),
  default_track_by text not null check (default_track_by in ('STAFF','CUSTOMER','NONE')),
  default_requestable boolean not null default false,
  display_order integer not null default 100,
  active boolean not null default true
);

insert into public.stock_categories(category_code,category_name,stock_area,default_track_by,default_requestable,display_order) values
  ('UNIFORM','Uniform','PPE_UNIFORM','STAFF',true,10),
  ('SAFETY_SHOES','Safety Shoes','PPE_UNIFORM','STAFF',true,20),
  ('PPE','PPE','PPE_UNIFORM','STAFF',true,30),
  ('CHEMICAL','Chemical','CHEMICAL','NONE',false,40),
  ('PACKING','Packing','MISCELLANEOUS','CUSTOMER',false,50),
  ('OTHER','Other','MISCELLANEOUS','STAFF',false,60);

create table public.stock_items (
  item_id uuid primary key default gen_random_uuid(),
  legacy_item_code text unique,
  item_code text,
  item_name text not null,
  category_code text not null references public.stock_categories(category_code),
  supplier text,
  unit text not null default 'unit',
  unit_price numeric(12,2) not null default 0 check (unit_price>=0),
  stock_qty numeric(12,2) not null default 0 check (stock_qty>=0),
  min_stock numeric(12,2) not null default 0 check (min_stock>=0),
  location text,
  track_by text not null check (track_by in ('STAFF','CUSTOMER','NONE')),
  requestable boolean not null default false,
  size_options text[] not null default array[]::text[],
  active boolean not null default true,
  last_counted_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint stock_items_name_check check (length(trim(item_name)) between 1 and 120),
  constraint stock_items_unit_check check (length(trim(unit)) between 1 and 20),
  -- Only items booked to a person can be requested by staff.
  constraint stock_items_requestable_check check (not requestable or track_by='STAFF'),
  constraint stock_items_sizes_check check (cardinality(size_options)<=20)
);

create unique index stock_items_name_uidx on public.stock_items(lower(item_name));
create index stock_items_list_idx on public.stock_items(active,category_code,item_name);

create table public.stock_count_sessions (
  session_id uuid primary key default gen_random_uuid(),
  session_code text not null unique,
  counted_at timestamptz not null default now(),
  counted_by uuid references auth.users(id) on delete set null,
  counted_by_name text,
  notes text check (notes is null or length(notes)<=500),
  items_counted integer not null default 0,
  items_adjusted integer not null default 0,
  consumption_lines integer not null default 0,
  variance_value numeric(12,2) not null default 0,
  consumption_value numeric(12,2) not null default 0,
  source text not null default 'APP' check (source in ('APP','APPS_SCRIPT'))
);

create table public.stock_count_lines (
  session_id uuid not null references public.stock_count_sessions(session_id) on delete restrict,
  item_id uuid not null references public.stock_items(item_id) on delete restrict,
  expected_qty numeric(12,2) not null,
  counted_qty numeric(12,2) not null check (counted_qty>=0),
  variance_qty numeric(12,2) not null,
  variance_value numeric(12,2) not null default 0,
  primary key (session_id,item_id)
);

create table public.stock_requests (
  request_id uuid primary key default gen_random_uuid(),
  request_number integer generated always as identity unique,
  staff_id uuid not null references public.staff_members(staff_id) on delete restrict,
  requested_by uuid references auth.users(id) on delete set null,
  request_status text not null default 'REQUESTED' check (request_status in ('REQUESTED','APPROVED','REJECTED','CANCELLED','ISSUED')),
  reason text check (reason is null or length(reason)<=500),
  decision_note text check (decision_note is null or length(decision_note)<=500),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  issued_at timestamptz,
  issued_by uuid references auth.users(id) on delete set null,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version integer not null default 1
);

create index stock_requests_status_idx on public.stock_requests(request_status,created_at);
create index stock_requests_staff_idx on public.stock_requests(staff_id,created_at desc);

create table public.stock_request_lines (
  line_id bigint generated always as identity primary key,
  request_id uuid not null references public.stock_requests(request_id) on delete restrict,
  item_id uuid not null references public.stock_items(item_id) on delete restrict,
  size text check (size is null or length(size) between 1 and 20),
  qty numeric(12,2) not null check (qty>0 and qty<=20),
  issued_qty numeric(12,2) check (issued_qty is null or issued_qty>=0)
);

create index stock_request_lines_request_idx on public.stock_request_lines(request_id);

create table public.stock_movements (
  movement_id bigint generated always as identity primary key,
  item_id uuid not null references public.stock_items(item_id) on delete restrict,
  movement_type text not null check (movement_type in ('IN','OUT','ADJUST','COUNT','CONSUMPTION')),
  qty_change numeric(12,2) not null,
  stock_after numeric(12,2) not null,
  unit_price numeric(12,2),
  staff_id uuid references public.staff_members(staff_id) on delete restrict,
  driver_id uuid references public.distribution_drivers(driver_id) on delete restrict,
  holder_name text,
  customer_id uuid references public.customers(customer_id) on delete restrict,
  customer_name text,
  po_number text check (po_number is null or length(po_number)<=60),
  notes text check (notes is null or length(notes)<=500),
  count_session_id uuid references public.stock_count_sessions(session_id) on delete restrict,
  request_id uuid references public.stock_requests(request_id) on delete restrict,
  recorded_at timestamptz not null default now(),
  recorded_by uuid references auth.users(id) on delete set null,
  recorded_by_name text,
  source text not null default 'APP' check (source in ('APP','APPS_SCRIPT')),
  source_key text unique,
  constraint stock_movements_one_holder check (staff_id is null or driver_id is null)
);

create index stock_movements_item_idx on public.stock_movements(item_id,recorded_at desc);
create index stock_movements_time_idx on public.stock_movements(recorded_at desc);
create index stock_movements_staff_idx on public.stock_movements(staff_id) where staff_id is not null;
create index stock_movements_driver_idx on public.stock_movements(driver_id) where driver_id is not null;

-- Uniforms and PPE given to and returned by each person.
create table public.stock_ppe_events (
  event_id bigint generated always as identity primary key,
  staff_id uuid references public.staff_members(staff_id) on delete restrict,
  driver_id uuid references public.distribution_drivers(driver_id) on delete restrict,
  holder_name text not null,
  item_id uuid references public.stock_items(item_id) on delete restrict,
  item_type text not null check (length(trim(item_type)) between 1 and 40),
  description text not null check (length(trim(description)) between 1 and 120),
  size text check (size is null or length(size) between 1 and 20),
  qty numeric(12,2) not null check (qty>0),
  ppe_action text not null check (ppe_action in ('ISSUED','RETURNED')),
  request_id uuid references public.stock_requests(request_id) on delete restrict,
  movement_id bigint references public.stock_movements(movement_id) on delete restrict,
  notes text check (notes is null or length(notes)<=500),
  recorded_at timestamptz not null default now(),
  recorded_by uuid references auth.users(id) on delete set null,
  recorded_by_name text,
  source text not null default 'APP' check (source in ('APP','APPS_SCRIPT')),
  source_key text unique,
  constraint stock_ppe_events_holder check (
    (staff_id is null or driver_id is null)
    and (source='APPS_SCRIPT' or staff_id is not null or driver_id is not null))
);

create index stock_ppe_events_staff_idx on public.stock_ppe_events(staff_id,recorded_at desc) where staff_id is not null;
create index stock_ppe_events_driver_idx on public.stock_ppe_events(driver_id,recorded_at desc) where driver_id is not null;

create table public.stock_lockers (
  locker_id uuid primary key default gen_random_uuid(),
  legacy_key_id text unique,
  label text not null,
  locker_status text not null default 'AVAILABLE' check (locker_status in ('AVAILABLE','ASSIGNED','OUT_OF_SERVICE')),
  staff_id uuid references public.staff_members(staff_id) on delete restrict,
  driver_id uuid references public.distribution_drivers(driver_id) on delete restrict,
  holder_name text,
  assigned_at timestamptz,
  notes text check (notes is null or length(notes)<=300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint stock_lockers_label_check check (length(trim(label)) between 1 and 30),
  -- A locker is assigned exactly when it has a holder (a legacy assignment
  -- whose person could not be matched keeps only the name).
  constraint stock_lockers_holder_check check (
    (staff_id is null or driver_id is null)
    and ((locker_status='ASSIGNED') = (holder_name is not null))
    and (locker_status='ASSIGNED' or (staff_id is null and driver_id is null)))
);

create unique index stock_lockers_label_uidx on public.stock_lockers(upper(label));

create table public.stock_locker_events (
  event_id bigint generated always as identity primary key,
  locker_id uuid not null references public.stock_lockers(locker_id) on delete restrict,
  label text not null,
  locker_action text not null check (locker_action in ('ADDED','ASSIGNED','RETURNED','OUT_OF_SERVICE','BACK_IN_SERVICE')),
  staff_id uuid references public.staff_members(staff_id) on delete restrict,
  driver_id uuid references public.distribution_drivers(driver_id) on delete restrict,
  holder_name text,
  notes text check (notes is null or length(notes)<=300),
  recorded_at timestamptz not null default now(),
  recorded_by uuid references auth.users(id) on delete set null,
  recorded_by_name text,
  source text not null default 'APP' check (source in ('APP','APPS_SCRIPT')),
  source_key text unique
);

create index stock_locker_events_locker_idx on public.stock_locker_events(locker_id,recorded_at desc);

create table public.stock_settings (
  settings_id boolean primary key default true check (settings_id),
  chemical_count_days integer not null default 7 check (chemical_count_days between 1 and 60),
  consumption_weeks integer not null default 8 check (consumption_weeks between 1 and 52),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into public.stock_settings(settings_id) values (true);

alter table public.stock_categories enable row level security;
alter table public.stock_items enable row level security;
alter table public.stock_count_sessions enable row level security;
alter table public.stock_count_lines enable row level security;
alter table public.stock_requests enable row level security;
alter table public.stock_request_lines enable row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_ppe_events enable row level security;
alter table public.stock_lockers enable row level security;
alter table public.stock_locker_events enable row level security;
alter table public.stock_settings enable row level security;
revoke all on public.stock_categories,public.stock_items,public.stock_count_sessions,public.stock_count_lines,
  public.stock_requests,public.stock_request_lines,public.stock_movements,public.stock_ppe_events,
  public.stock_lockers,public.stock_locker_events,public.stock_settings
from public,anon,authenticated;

-- 3. Access helpers ----------------------------------------------------

create or replace function public.can_view_stock()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.account_module_allowed(array['STOCK'],'VIEW',array['ADMIN','MANAGER','SUPERVISOR','AUDITOR'])
$$;

create or replace function public.can_operate_stock()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.account_module_allowed(array['STOCK'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR'])
      or public.account_module_allowed(array['STOCK'],'APPROVE',array['ADMIN','MANAGER','SUPERVISOR'])
$$;

create or replace function public.can_manage_stock()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.account_module_allowed(array['STOCK'],'MANAGE',array['ADMIN','MANAGER'])
$$;

-- Staff who can request PPE and uniforms: an enabled personal account linked
-- to an active Staff Master record, with roster access (or Stock access).
create or replace function public.can_request_stock_items()
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.current_account_is_enabled()
    and public.current_staff_id() is not null
    and not exists(select 1 from public.production_station_devices d where d.device_auth_user_id=auth.uid())
    and (not public.account_uses_module_permissions()
         or public.has_account_permission('MY_ROSTER','VIEW',null)
         or public.has_account_permission('MY_DRIVER_ROSTER','VIEW',null)
         or public.can_view_stock())
$$;

create or replace function public.stock_require(p_level text)
returns void language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
  if auth.uid() is null then raise exception using errcode='42501',message='Sign in is required.'; end if;
  if (p_level='VIEW' and not public.can_view_stock())
     or (p_level='OPERATE' and not public.can_operate_stock())
     or (p_level='MANAGE' and not public.can_manage_stock()) then
    raise exception using errcode='42501',message=case p_level
      when 'MANAGE' then 'Stock Control management access is required.'
      when 'OPERATE' then 'Your account cannot register stock. Ask a manager for Stock Control access.'
      else 'Stock Control access is required.' end;
  end if;
end;$$;

create or replace function public.stock_clean_text(p_value text,p_max integer)
returns text language sql immutable set search_path=public,pg_temp as $$
  select nullif(left(trim(regexp_replace(coalesce(p_value,''),'\s+',' ','g')),p_max),'')
$$;

create or replace function public.stock_actor_name()
returns text language sql stable security definer set search_path=public,auth,pg_temp as $$
  select coalesce(ap.display_name,sm.display_name,u.email,'Account')
  from auth.users u
  left join public.account_access_profiles ap on ap.auth_user_id=u.id
  left join public.staff_members sm on sm.auth_user_id=u.id and sm.deleted_at is null
  where u.id=auth.uid()
$$;

create or replace function public.stock_person_active(p_staff_id uuid,p_driver_id uuid)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select case
    when p_staff_id is not null then exists(select 1 from public.staff_members s where s.staff_id=p_staff_id and s.active and s.deleted_at is null and (s.deactivated_on is null or s.deactivated_on>=current_date))
    when p_driver_id is not null then exists(select 1 from public.distribution_drivers d where d.driver_id=p_driver_id and d.employment_status='ACTIVE' and d.deleted_at is null and (d.deactivated_on is null or d.deactivated_on>=current_date))
    else false end
$$;

-- Validates a person (exactly one of staff or driver) and returns the name.
create or replace function public.stock_holder_name(p_staff_id uuid,p_driver_id uuid,p_require_active boolean)
returns text language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_name text;
begin
  if (p_staff_id is null)=(p_driver_id is null) then raise exception using errcode='22023',message='Select the person.'; end if;
  if p_staff_id is not null then
    select display_name into v_name from public.staff_members where staff_id=p_staff_id and deleted_at is null;
  else
    select display_name into v_name from public.distribution_drivers where driver_id=p_driver_id and deleted_at is null;
  end if;
  if v_name is null then raise exception using errcode='P0002',message='Person not found.'; end if;
  if p_require_active and not public.stock_person_active(p_staff_id,p_driver_id) then
    raise exception using errcode='22023',message=format('%s is no longer active. Items can only be returned.',v_name);
  end if;
  return v_name;
end;$$;

-- Uniforms and PPE each person still holds (issued minus returned), grouped
-- by type, description and size. A null filter returns everyone.
create or replace function public.stock_ppe_balances(p_staff_id uuid default null,p_driver_id uuid default null)
returns table(staff_id uuid,driver_id uuid,holder_name text,item_type text,description text,size text,qty numeric,first_issued_at timestamptz,last_issued_at timestamptz)
language sql stable security definer set search_path=public,auth,pg_temp as $$
  select e.staff_id,e.driver_id,max(e.holder_name),e.item_type,e.description,e.size,
    sum(case when e.ppe_action='RETURNED' then -e.qty else e.qty end),
    min(e.recorded_at) filter (where e.ppe_action='ISSUED'),
    max(e.recorded_at) filter (where e.ppe_action='ISSUED')
  from public.stock_ppe_events e
  where (e.staff_id is not null or e.driver_id is not null)
    and (p_staff_id is null or e.staff_id=p_staff_id)
    and (p_driver_id is null or e.driver_id=p_driver_id)
  group by e.staff_id,e.driver_id,e.item_type,e.description,e.size
  having sum(case when e.ppe_action='RETURNED' then -e.qty else e.qty end)>0
$$;

-- People shown in the Stock workspace: active staff, active drivers that are
-- not linked to a Staff Master record, and anyone inactive who still holds
-- PPE or a locker key.
create or replace function public.stock_people()
returns table(staff_id uuid,driver_id uuid,display_name text,employee_code text,person_group text,is_active boolean,ppe_items numeric,locker_labels text[])
language sql stable security definer set search_path=public,auth,pg_temp as $$
  with ppe as (
    select b.staff_id,b.driver_id,sum(b.qty) qty from public.stock_ppe_balances() b group by b.staff_id,b.driver_id
  ), lockers as (
    select l.staff_id,l.driver_id,array_agg(l.label order by l.label) labels from public.stock_lockers l
    where l.locker_status='ASSIGNED' and (l.staff_id is not null or l.driver_id is not null) group by l.staff_id,l.driver_id
  ), people as (
    select s.staff_id,null::uuid driver_id,s.display_name,s.employee_code,
      case when exists(select 1 from public.distribution_drivers d where d.staff_id=s.staff_id and d.deleted_at is null) then 'Driver' else 'Production' end person_group,
      public.stock_person_active(s.staff_id,null) is_active
    from public.staff_members s where s.deleted_at is null
    union all
    select null,d.driver_id,d.display_name,d.driver_code,'Driver',public.stock_person_active(null,d.driver_id)
    from public.distribution_drivers d where d.deleted_at is null and d.staff_id is null
  )
  select p.staff_id,p.driver_id,p.display_name,p.employee_code,p.person_group,p.is_active,coalesce(ppe.qty,0),coalesce(lk.labels,array[]::text[])
  from people p
  left join ppe on ppe.staff_id is not distinct from p.staff_id and ppe.driver_id is not distinct from p.driver_id
  left join lockers lk on lk.staff_id is not distinct from p.staff_id and lk.driver_id is not distinct from p.driver_id
  where p.is_active or ppe.qty>0 or lk.labels is not null
$$;

-- Applies one stock change under a row lock and writes the movement.
-- IN and OUT take a positive quantity; ADJUST takes the new total.
create or replace function public.stock_apply_movement(
  p_item_id uuid,p_type text,p_qty numeric,p_staff_id uuid,p_driver_id uuid,p_customer_id uuid,
  p_po text,p_notes text,p_request_id uuid,p_count_session_id uuid)
returns public.stock_movements language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_item public.stock_items%rowtype; v_after numeric; v_change numeric; v_holder text; v_customer text; v_row public.stock_movements%rowtype;
begin
  select * into v_item from public.stock_items where item_id=p_item_id for update;
  if not found then raise exception using errcode='P0002',message='Item not found.'; end if;
  if p_qty is null or p_qty<0 or (p_type in ('IN','OUT') and p_qty=0) then raise exception using errcode='22023',message='Enter a quantity greater than zero.'; end if;
  if p_type in ('IN','OUT') and not v_item.active then raise exception using errcode='22023',message=format('%s is inactive.',v_item.item_name); end if;
  if p_staff_id is not null or p_driver_id is not null then v_holder:=public.stock_holder_name(p_staff_id,p_driver_id,p_type='OUT'); end if;
  if p_customer_id is not null then
    select customer_name into v_customer from public.customers where customer_id=p_customer_id and deleted_at is null;
    if v_customer is null then raise exception using errcode='P0002',message='Customer not found.'; end if;
  end if;
  if p_type='OUT' then
    if v_item.track_by='STAFF' and v_holder is null then raise exception using errcode='22023',message='Select who is taking the item.'; end if;
    if v_item.track_by='CUSTOMER' and v_customer is null then raise exception using errcode='22023',message='Select the customer this material is for.'; end if;
    if p_qty>v_item.stock_qty then raise exception using errcode='22023',message=format('Only %s %s of %s in stock.',trim(to_char(v_item.stock_qty,'FM999999990.##')),v_item.unit,v_item.item_name); end if;
    v_change:=-p_qty;
  elsif p_type='IN' then v_change:=p_qty;
  elsif p_type in ('ADJUST','COUNT','CONSUMPTION') then v_change:=p_qty-v_item.stock_qty;
  else raise exception using errcode='22023',message='Unknown movement type.';
  end if;
  v_after:=v_item.stock_qty+v_change;
  update public.stock_items set stock_qty=v_after,updated_at=now(),updated_by=auth.uid(),row_version=row_version+1 where item_id=p_item_id;
  insert into public.stock_movements(item_id,movement_type,qty_change,stock_after,unit_price,staff_id,driver_id,holder_name,customer_id,customer_name,po_number,notes,count_session_id,request_id,recorded_by,recorded_by_name)
  values(p_item_id,p_type,v_change,v_after,v_item.unit_price,p_staff_id,p_driver_id,v_holder,p_customer_id,v_customer,
    public.stock_clean_text(p_po,60),public.stock_clean_text(p_notes,500),p_count_session_id,p_request_id,auth.uid(),public.stock_actor_name())
  returning * into v_row;
  return v_row;
end;$$;

create or replace function public.stock_item_json(p_item public.stock_items)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select to_jsonb(p_item) || jsonb_build_object(
    'category_name',c.category_name,'stock_area',c.stock_area,
    'is_low',p_item.active and p_item.min_stock>0 and p_item.stock_qty<=p_item.min_stock,
    'stock_value',round(p_item.stock_qty*p_item.unit_price,2))
  from public.stock_categories c where c.category_code=p_item.category_code
$$;

create or replace function public.stock_request_json(p_request public.stock_requests)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select to_jsonb(p_request) || jsonb_build_object(
    'staff_name',(select display_name from public.staff_members where staff_id=p_request.staff_id),
    'employee_code',(select employee_code from public.staff_members where staff_id=p_request.staff_id),
    'decided_by_name',(select coalesce(ap.display_name,u.email) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=p_request.decided_by),
    'issued_by_name',(select coalesce(ap.display_name,u.email) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=p_request.issued_by),
    'lines',coalesce((select jsonb_agg(jsonb_build_object('line_id',l.line_id,'item_id',l.item_id,'item_name',i.item_name,'category_name',c.category_name,
        'unit',i.unit,'size',l.size,'qty',l.qty,'issued_qty',l.issued_qty,'stock_qty',i.stock_qty,'size_options',i.size_options) order by l.line_id)
      from public.stock_request_lines l join public.stock_items i on i.item_id=l.item_id join public.stock_categories c on c.category_code=i.category_code
      where l.request_id=p_request.request_id),'[]'::jsonb))
$$;

-- 4. Staff self-service ------------------------------------------------

create or replace function public.get_my_stock()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_staff uuid:=public.current_staff_id(); v_drivers uuid[];
begin
  if not public.can_request_stock_items() then raise exception using errcode='42501',message='Sign in with a staff account linked to Staff Master to request PPE and uniforms.'; end if;
  -- A driver account also holds what was issued to its Distribution driver record.
  select coalesce(array_agg(driver_id),array[]::uuid[]) into v_drivers from public.distribution_drivers where staff_id=v_staff and deleted_at is null;
  return jsonb_build_object(
    'staff_name',(select display_name from public.staff_members where staff_id=v_staff),
    'can_view_stock',public.can_view_stock(),
    'can_operate_stock',public.can_operate_stock(),
    'holding',coalesce((select jsonb_agg(to_jsonb(b) order by b.item_type,b.description) from public.stock_ppe_balances() b where b.staff_id=v_staff or b.driver_id=any(v_drivers)),'[]'::jsonb),
    'lockers',coalesce((select jsonb_agg(jsonb_build_object('label',l.label,'assigned_at',l.assigned_at) order by l.label) from public.stock_lockers l
      where l.locker_status='ASSIGNED' and (l.staff_id=v_staff or l.driver_id=any(v_drivers))),'[]'::jsonb),
    -- Exact quantities stay with the store; staff only see whether it is available.
    'items',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.item_id,'item_name',i.item_name,'category_code',i.category_code,'category_name',c.category_name,
        'unit',i.unit,'size_options',i.size_options,'available',i.stock_qty>0) order by c.display_order,i.item_name)
      from public.stock_items i join public.stock_categories c on c.category_code=i.category_code where i.active and i.requestable),'[]'::jsonb),
    'requests',coalesce((select jsonb_agg(public.stock_request_json(r) order by r.created_at desc) from (
      select * from public.stock_requests where staff_id=v_staff and (request_status in ('REQUESTED','APPROVED') or created_at>=now()-interval '180 days') order by created_at desc limit 30) r),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(jsonb_build_object('recorded_at',e.recorded_at,'ppe_action',e.ppe_action,'item_type',e.item_type,'description',e.description,'size',e.size,'qty',e.qty) order by e.recorded_at desc)
      from (select * from public.stock_ppe_events where staff_id=v_staff or driver_id=any(v_drivers) order by recorded_at desc limit 50) e),'[]'::jsonb)
  );
end;$$;

create or replace function public.submit_my_stock_request(p_lines jsonb,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_staff uuid:=public.current_staff_id(); v_request public.stock_requests%rowtype; v_line jsonb; v_item public.stock_items%rowtype; v_size text; v_qty numeric;
begin
  if not public.can_request_stock_items() then raise exception using errcode='42501',message='Sign in with a staff account linked to Staff Master to request PPE and uniforms.'; end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception using errcode='22023',message='Add at least one item to the request.'; end if;
  if jsonb_array_length(p_lines)>10 then raise exception using errcode='22023',message='A request can have up to 10 items.'; end if;
  if (select count(*) from public.stock_requests where staff_id=v_staff and request_status in ('REQUESTED','APPROVED'))>=5 then
    raise exception using errcode='22023',message='You already have 5 open requests. Wait for them to be answered before asking again.';
  end if;
  insert into public.stock_requests(staff_id,requested_by,reason) values(v_staff,auth.uid(),public.stock_clean_text(p_reason,500)) returning * into v_request;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    select * into v_item from public.stock_items where item_id=nullif(v_line->>'item_id','')::uuid and active and requestable;
    if not found then raise exception using errcode='22023',message='One of the items can no longer be requested. Reload the page.'; end if;
    v_qty:=coalesce(nullif(v_line->>'qty','')::numeric,1);
    if v_qty<=0 or v_qty>20 or v_qty<>trunc(v_qty) then raise exception using errcode='22023',message=format('Enter a quantity from 1 to 20 for %s.',v_item.item_name); end if;
    v_size:=public.stock_clean_text(v_line->>'size',20);
    if cardinality(v_item.size_options)>0 and (v_size is null or not v_size=any(v_item.size_options)) then
      raise exception using errcode='22023',message=format('Choose the size for %s.',v_item.item_name);
    end if;
    insert into public.stock_request_lines(request_id,item_id,size,qty) values(v_request.request_id,v_item.item_id,v_size,v_qty);
  end loop;
  return public.stock_request_json(v_request);
end;$$;

create or replace function public.cancel_my_stock_request(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.stock_requests%rowtype;
begin
  if not public.can_request_stock_items() then raise exception using errcode='42501',message='Sign in with a staff account linked to Staff Master to request PPE and uniforms.'; end if;
  select * into v_row from public.stock_requests where request_id=p_request_id and staff_id=public.current_staff_id() for update;
  if not found then raise exception using errcode='P0002',message='Request not found.'; end if;
  if v_row.request_status<>'REQUESTED' then raise exception using errcode='22023',message='Only a request that was not answered yet can be cancelled.'; end if;
  update public.stock_requests set request_status='CANCELLED',cancelled_at=now(),updated_at=now(),row_version=row_version+1
  where request_id=p_request_id returning * into v_row;
  return public.stock_request_json(v_row);
end;$$;

-- Badge counts for the sidebar and Home.
create or replace function public.get_stock_attention()
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select jsonb_build_object(
    'pending_requests',case when public.can_operate_stock() then (select count(*) from public.stock_requests where request_status in ('REQUESTED','APPROVED')) else 0 end,
    'low_stock',case when public.can_view_stock() then (select count(*) from public.stock_items where active and min_stock>0 and stock_qty<=min_stock) else 0 end)
$$;

-- 5. Workspace (read) --------------------------------------------------

create or replace function public.stock_usage_stats()
returns table(item_id uuid,used_total numeric,per_week numeric,weeks_cover numeric,days_since_count integer)
language sql stable security definer set search_path=public,auth,pg_temp as $$
  with s as (select consumption_weeks from public.stock_settings limit 1),
  used as (
    select m.item_id,sum(abs(m.qty_change)) total,min(m.recorded_at) first_seen
    from public.stock_movements m, s
    where m.movement_type in ('OUT','CONSUMPTION') and m.recorded_at>=now()-make_interval(weeks=>s.consumption_weeks)
    group by m.item_id
  )
  select i.item_id,coalesce(u.total,0),
    round(coalesce(u.total,0)/greatest(1,case when u.first_seen is null then s.consumption_weeks else extract(epoch from now()-u.first_seen)/604800 end),2),
    case when coalesce(u.total,0)>0 then round(i.stock_qty/(u.total/greatest(1,extract(epoch from now()-u.first_seen)/604800)),1) end,
    case when i.last_counted_at is not null then (current_date-(i.last_counted_at at time zone 'Europe/Dublin')::date) end
  from public.stock_items i cross join s left join used u on u.item_id=i.item_id
$$;

create or replace function public.get_stock_workspace()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_settings public.stock_settings%rowtype;
begin
  perform public.stock_require('VIEW');
  select * into v_settings from public.stock_settings limit 1;
  return jsonb_build_object(
    'can_operate',public.can_operate_stock(),
    'can_manage',public.can_manage_stock(),
    'settings',to_jsonb(v_settings),
    'categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.display_order) from public.stock_categories c where c.active),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(public.stock_item_json(i) || jsonb_build_object('per_week',u.per_week,'weeks_cover',u.weeks_cover,'days_since_count',u.days_since_count) order by i.item_name)
      from public.stock_items i left join public.stock_usage_stats() u on u.item_id=i.item_id),'[]'::jsonb),
    'people',coalesce((select jsonb_agg(to_jsonb(p) order by p.display_name) from public.stock_people() p),'[]'::jsonb),
    'customers',coalesce((select jsonb_agg(jsonb_build_object('customer_id',c.customer_id,'customer_name',c.customer_name) order by c.customer_name)
      from public.customers c where c.active and c.deleted_at is null),'[]'::jsonb),
    'lockers',coalesce((select jsonb_agg(to_jsonb(l) order by l.label) from public.stock_lockers l),'[]'::jsonb),
    'requests',coalesce((select jsonb_agg(public.stock_request_json(r) order by r.created_at) from public.stock_requests r where r.request_status in ('REQUESTED','APPROVED')),'[]'::jsonb),
    'overdue_counts',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.item_id,'item_name',i.item_name,'last_counted_at',i.last_counted_at) order by i.last_counted_at nulls first)
      from public.stock_items i where i.active and i.track_by='NONE'
        and (i.last_counted_at is null or i.last_counted_at<now()-make_interval(days=>v_settings.chemical_count_days))),'[]'::jsonb),
    'pending_returns',coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object('ppe',(select coalesce(jsonb_agg(to_jsonb(b)),'[]'::jsonb) from public.stock_ppe_balances(p.staff_id,p.driver_id) b
        where b.staff_id is not distinct from p.staff_id and b.driver_id is not distinct from p.driver_id)) order by p.display_name)
      from public.stock_people() p where not p.is_active),'[]'::jsonb),
    'recent',coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('item_name',i.item_name,'unit',i.unit) order by m.recorded_at desc,m.movement_id desc)
      from (select * from public.stock_movements order by recorded_at desc,movement_id desc limit 40) m join public.stock_items i on i.item_id=m.item_id),'[]'::jsonb)
  );
end;$$;

create or replace function public.get_stock_person(p_staff_id uuid,p_driver_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_name text;
begin
  perform public.stock_require('VIEW');
  v_name:=public.stock_holder_name(p_staff_id,p_driver_id,false);
  return jsonb_build_object(
    'display_name',v_name,'staff_id',p_staff_id,'driver_id',p_driver_id,'is_active',public.stock_person_active(p_staff_id,p_driver_id),
    'holding',coalesce((select jsonb_agg(to_jsonb(b) order by b.item_type,b.description) from public.stock_ppe_balances(p_staff_id,p_driver_id) b
      where b.staff_id is not distinct from p_staff_id and b.driver_id is not distinct from p_driver_id),'[]'::jsonb),
    'lockers',coalesce((select jsonb_agg(to_jsonb(l) order by l.label) from public.stock_lockers l where l.locker_status='ASSIGNED'
      and l.staff_id is not distinct from p_staff_id and l.driver_id is not distinct from p_driver_id),'[]'::jsonb),
    'ppe_log',coalesce((select jsonb_agg(to_jsonb(e) order by e.recorded_at desc) from (select * from public.stock_ppe_events
      where staff_id is not distinct from p_staff_id and driver_id is not distinct from p_driver_id order by recorded_at desc limit 200) e),'[]'::jsonb),
    'locker_log',coalesce((select jsonb_agg(to_jsonb(e) order by e.recorded_at desc) from (select * from public.stock_locker_events
      where staff_id is not distinct from p_staff_id and driver_id is not distinct from p_driver_id order by recorded_at desc limit 100) e),'[]'::jsonb),
    'stock_taken',coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('item_name',i.item_name,'unit',i.unit) order by m.recorded_at desc)
      from (select * from public.stock_movements where movement_type='OUT' and staff_id is not distinct from p_staff_id and driver_id is not distinct from p_driver_id order by recorded_at desc limit 200) m
      join public.stock_items i on i.item_id=m.item_id),'[]'::jsonb),
    'requests',case when p_staff_id is null then '[]'::jsonb else coalesce((select jsonb_agg(public.stock_request_json(r) order by r.created_at desc)
      from (select * from public.stock_requests where staff_id=p_staff_id order by created_at desc limit 50) r),'[]'::jsonb) end
  );
end;$$;

-- p_kind: MOVEMENTS, PPE, LOCKERS, COUNTS or REQUESTS.
create or replace function public.get_stock_history(p_kind text,p_from date default null,p_to date default null,p_item_id uuid default null,p_limit integer default 300)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_from timestamptz:=coalesce(p_from,current_date-90)::timestamp at time zone 'Europe/Dublin';
  v_to timestamptz:=(coalesce(p_to,current_date)+1)::timestamp at time zone 'Europe/Dublin';
  v_limit integer:=least(greatest(coalesce(p_limit,300),1),2000);
begin
  perform public.stock_require('VIEW');
  return case upper(coalesce(p_kind,'MOVEMENTS'))
    when 'PPE' then coalesce((select jsonb_agg(to_jsonb(e) order by e.recorded_at desc) from (select * from public.stock_ppe_events
      where recorded_at>=v_from and recorded_at<v_to and (p_item_id is null or item_id=p_item_id) order by recorded_at desc limit v_limit) e),'[]'::jsonb)
    when 'LOCKERS' then coalesce((select jsonb_agg(to_jsonb(e) order by e.recorded_at desc) from (select * from public.stock_locker_events
      where recorded_at>=v_from and recorded_at<v_to order by recorded_at desc limit v_limit) e),'[]'::jsonb)
    when 'COUNTS' then coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('lines',(select jsonb_agg(to_jsonb(l) || jsonb_build_object('item_name',i.item_name,'unit',i.unit) order by i.item_name)
        from public.stock_count_lines l join public.stock_items i on i.item_id=l.item_id where l.session_id=s.session_id)) order by s.counted_at desc)
      from (select * from public.stock_count_sessions where counted_at>=v_from and counted_at<v_to order by counted_at desc limit v_limit) s),'[]'::jsonb)
    when 'REQUESTS' then coalesce((select jsonb_agg(public.stock_request_json(r) order by r.created_at desc) from (select * from public.stock_requests
      where created_at>=v_from and created_at<v_to order by created_at desc limit v_limit) r),'[]'::jsonb)
    else coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('item_name',i.item_name,'unit',i.unit,'category_code',i.category_code) order by m.recorded_at desc,m.movement_id desc)
      from (select * from public.stock_movements where recorded_at>=v_from and recorded_at<v_to and (p_item_id is null or item_id=p_item_id)
        order by recorded_at desc,movement_id desc limit v_limit) m join public.stock_items i on i.item_id=m.item_id),'[]'::jsonb)
  end;
end;$$;

-- 6. Operate: movements, counts, PPE, lockers, requests -----------------

create or replace function public.record_stock_movement(p_movement jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_type text:=upper(coalesce(p_movement->>'movement_type','')); v_row public.stock_movements%rowtype; v_item public.stock_items%rowtype;
begin
  perform public.stock_require('OPERATE');
  if v_type not in ('IN','OUT','ADJUST') then raise exception using errcode='22023',message='Choose Receive, Take or Adjust.'; end if;
  if v_type='ADJUST' and public.stock_clean_text(p_movement->>'notes',500) is null then raise exception using errcode='22023',message='Say why the stock is being adjusted.'; end if;
  v_row:=public.stock_apply_movement(nullif(p_movement->>'item_id','')::uuid,v_type,nullif(p_movement->>'qty','')::numeric,
    nullif(p_movement->>'staff_id','')::uuid,nullif(p_movement->>'driver_id','')::uuid,nullif(p_movement->>'customer_id','')::uuid,
    p_movement->>'po_number',p_movement->>'notes',null,null);
  -- A uniform or PPE item taken by a person is also added to what they hold.
  select * into v_item from public.stock_items where item_id=v_row.item_id;
  if v_type='OUT' and v_item.track_by='STAFF' and exists(select 1 from public.stock_categories c where c.category_code=v_item.category_code and c.stock_area='PPE_UNIFORM') then
    insert into public.stock_ppe_events(staff_id,driver_id,holder_name,item_id,item_type,description,size,qty,ppe_action,movement_id,notes,recorded_by,recorded_by_name)
    values(v_row.staff_id,v_row.driver_id,v_row.holder_name,v_item.item_id,(select category_name from public.stock_categories where category_code=v_item.category_code),
      v_item.item_name,public.stock_clean_text(p_movement->>'size',20),abs(v_row.qty_change),'ISSUED',v_row.movement_id,v_row.notes,auth.uid(),v_row.recorded_by_name);
  end if;
  return to_jsonb(v_row) || jsonb_build_object('item',public.stock_item_json(v_item));
end;$$;

-- p_entries: [{item_id, counted_qty}]. Items left out are not counted.
create or replace function public.save_stock_count(p_entries jsonb,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_session public.stock_count_sessions%rowtype; v_entry jsonb; v_item public.stock_items%rowtype; v_counted numeric; v_variance numeric; v_type text;
begin
  perform public.stock_require('OPERATE');
  if jsonb_typeof(p_entries)<>'array' or jsonb_array_length(p_entries)=0 then raise exception using errcode='22023',message='Type the quantity of at least one item.'; end if;
  insert into public.stock_count_sessions(session_code,counted_by,counted_by_name,notes)
  values('CNT-'||to_char(now() at time zone 'Europe/Dublin','YYYYMMDD-HH24MISS')||'-'||substr(gen_random_uuid()::text,1,4),auth.uid(),public.stock_actor_name(),public.stock_clean_text(p_notes,500))
  returning * into v_session;
  for v_entry in select * from jsonb_array_elements(p_entries) loop
    v_counted:=nullif(v_entry->>'counted_qty','')::numeric;
    if v_counted is null then continue; end if;
    if v_counted<0 then raise exception using errcode='22023',message='A counted quantity cannot be negative.'; end if;
    select * into v_item from public.stock_items where item_id=nullif(v_entry->>'item_id','')::uuid for update;
    if not found then raise exception using errcode='P0002',message='Item not found. Reload the page.'; end if;
    if exists(select 1 from public.stock_count_lines where session_id=v_session.session_id and item_id=v_item.item_id) then
      raise exception using errcode='22023',message=format('%s was entered twice.',v_item.item_name);
    end if;
    v_variance:=v_counted-v_item.stock_qty;
    insert into public.stock_count_lines(session_id,item_id,expected_qty,counted_qty,variance_qty,variance_value)
    values(v_session.session_id,v_item.item_id,v_item.stock_qty,v_counted,v_variance,round(v_variance*v_item.unit_price,2));
    update public.stock_items set last_counted_at=now() where item_id=v_item.item_id;
    v_session.items_counted:=v_session.items_counted+1;
    if v_variance<>0 then
      -- Chemicals are not booked when taken: a drop since the last count is usage.
      v_type:=case when v_item.track_by='NONE' and v_variance<0 then 'CONSUMPTION' else 'COUNT' end;
      perform public.stock_apply_movement(v_item.item_id,v_type,v_counted,null,null,null,null,
        case when v_type='CONSUMPTION' then 'Usage since last count ('||v_session.session_code||')' else 'Stock count '||v_session.session_code end,null,v_session.session_id);
      if v_type='CONSUMPTION' then
        v_session.consumption_lines:=v_session.consumption_lines+1;
        v_session.consumption_value:=v_session.consumption_value+round(abs(v_variance)*v_item.unit_price,2);
      else
        v_session.items_adjusted:=v_session.items_adjusted+1;
        v_session.variance_value:=v_session.variance_value+round(v_variance*v_item.unit_price,2);
      end if;
    end if;
  end loop;
  if v_session.items_counted=0 then raise exception using errcode='22023',message='Type the quantity of at least one item.'; end if;
  update public.stock_count_sessions set items_counted=v_session.items_counted,items_adjusted=v_session.items_adjusted,consumption_lines=v_session.consumption_lines,
    variance_value=v_session.variance_value,consumption_value=v_session.consumption_value
  where session_id=v_session.session_id returning * into v_session;
  return to_jsonb(v_session);
end;$$;

-- Issue or return uniforms and PPE. With an item_id, issuing takes it out of
-- stock and a return can put it back (restock=true, for items in good order).
create or replace function public.record_ppe_event(p_event jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_action text:=upper(coalesce(p_event->>'ppe_action','')); v_staff uuid:=nullif(p_event->>'staff_id','')::uuid; v_driver uuid:=nullif(p_event->>'driver_id','')::uuid;
  v_item public.stock_items%rowtype; v_name text; v_qty numeric:=coalesce(nullif(p_event->>'qty','')::numeric,1); v_move public.stock_movements%rowtype;
  v_type text; v_desc text; v_size text:=public.stock_clean_text(p_event->>'size',20); v_row public.stock_ppe_events%rowtype; v_held numeric;
begin
  perform public.stock_require('OPERATE');
  if v_action not in ('ISSUED','RETURNED') then raise exception using errcode='22023',message='Choose Issue or Return.'; end if;
  if v_qty<=0 or v_qty>50 then raise exception using errcode='22023',message='Enter a quantity from 1 to 50.'; end if;
  v_name:=public.stock_holder_name(v_staff,v_driver,v_action='ISSUED');
  if nullif(p_event->>'item_id','') is not null then
    select * into v_item from public.stock_items where item_id=(p_event->>'item_id')::uuid;
    if not found then raise exception using errcode='P0002',message='Item not found.'; end if;
    select category_name into v_type from public.stock_categories where category_code=v_item.category_code;
    v_desc:=v_item.item_name;
  else
    v_type:=public.stock_clean_text(p_event->>'item_type',40);
    v_desc:=public.stock_clean_text(p_event->>'description',120);
    if v_type is null or v_desc is null then raise exception using errcode='22023',message='Choose the item or type a description.'; end if;
  end if;
  if v_action='RETURNED' then
    select coalesce(sum(b.qty),0) into v_held from public.stock_ppe_balances(v_staff,v_driver) b
    where b.staff_id is not distinct from v_staff and b.driver_id is not distinct from v_driver and b.item_type=v_type and lower(b.description)=lower(v_desc) and b.size is not distinct from v_size;
    if v_qty>v_held then raise exception using errcode='22023',message=format('%s holds %s of %s%s.',v_name,trim(to_char(v_held,'FM999990.##')),v_desc,coalesce(' size '||v_size,'')); end if;
  end if;
  if v_item.item_id is not null and (v_action='ISSUED' or coalesce((p_event->>'restock')::boolean,false)) then
    v_move:=public.stock_apply_movement(v_item.item_id,case when v_action='ISSUED' then 'OUT' else 'IN' end,v_qty,v_staff,v_driver,null,null,
      case when v_action='ISSUED' then 'Issued' else 'Returned to stock' end||coalesce(' (size '||v_size||')','')||coalesce(': '||public.stock_clean_text(p_event->>'notes',400),''),null,null);
  end if;
  insert into public.stock_ppe_events(staff_id,driver_id,holder_name,item_id,item_type,description,size,qty,ppe_action,movement_id,notes,recorded_by,recorded_by_name)
  values(v_staff,v_driver,v_name,v_item.item_id,v_type,v_desc,v_size,v_qty,v_action,v_move.movement_id,public.stock_clean_text(p_event->>'notes',500),auth.uid(),public.stock_actor_name())
  returning * into v_row;
  return to_jsonb(v_row);
end;$$;

create or replace function public.record_locker_action(p_locker_id uuid,p_action text,p_staff_id uuid,p_driver_id uuid,p_notes text,p_row_version integer)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.stock_lockers%rowtype; v_row public.stock_lockers%rowtype; v_action text:=upper(trim(coalesce(p_action,''))); v_name text;
begin
  perform public.stock_require('OPERATE');
  select * into v_old from public.stock_lockers where locker_id=p_locker_id for update;
  if not found then raise exception using errcode='P0002',message='Locker not found.'; end if;
  if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='Someone else changed this locker. Reload and try again.'; end if;
  if v_action='ASSIGN' then
    if v_old.locker_status<>'AVAILABLE' then raise exception using errcode='22023',message=format('Locker %s is not available.',v_old.label); end if;
    v_name:=public.stock_holder_name(p_staff_id,p_driver_id,true);
    update public.stock_lockers set locker_status='ASSIGNED',staff_id=p_staff_id,driver_id=p_driver_id,holder_name=v_name,assigned_at=now(),
      updated_at=now(),updated_by=auth.uid(),row_version=row_version+1 where locker_id=p_locker_id returning * into v_row;
  elsif v_action='RETURN' then
    if v_old.locker_status<>'ASSIGNED' then raise exception using errcode='22023',message=format('Locker %s is not assigned.',v_old.label); end if;
    update public.stock_lockers set locker_status='AVAILABLE',staff_id=null,driver_id=null,holder_name=null,assigned_at=null,
      updated_at=now(),updated_by=auth.uid(),row_version=row_version+1 where locker_id=p_locker_id returning * into v_row;
  elsif v_action in ('OUT_OF_SERVICE','BACK_IN_SERVICE') then
    if not public.can_manage_stock() then raise exception using errcode='42501',message='Stock Control management access is required.'; end if;
    if v_action='OUT_OF_SERVICE' and v_old.locker_status<>'AVAILABLE' then raise exception using errcode='22023',message='Return the key before taking the locker out of service.'; end if;
    if v_action='BACK_IN_SERVICE' and v_old.locker_status<>'OUT_OF_SERVICE' then raise exception using errcode='22023',message='This locker is in service.'; end if;
    update public.stock_lockers set locker_status=case v_action when 'OUT_OF_SERVICE' then 'OUT_OF_SERVICE' else 'AVAILABLE' end,
      notes=coalesce(public.stock_clean_text(p_notes,300),notes),updated_at=now(),updated_by=auth.uid(),row_version=row_version+1
    where locker_id=p_locker_id returning * into v_row;
  else raise exception using errcode='22023',message='Unknown locker action.';
  end if;
  insert into public.stock_locker_events(locker_id,label,locker_action,staff_id,driver_id,holder_name,notes,recorded_by,recorded_by_name)
  values(v_row.locker_id,v_row.label,case v_action when 'ASSIGN' then 'ASSIGNED' when 'RETURN' then 'RETURNED' else v_action end,
    coalesce(v_row.staff_id,v_old.staff_id),coalesce(v_row.driver_id,v_old.driver_id),coalesce(v_row.holder_name,v_old.holder_name),
    public.stock_clean_text(p_notes,300),auth.uid(),public.stock_actor_name());
  return to_jsonb(v_row);
end;$$;

-- APPROVE: REQUESTED -> APPROVED (items will be handed over later).
-- REJECT:  REQUESTED/APPROVED -> REJECTED, with a reason for the person.
-- ISSUE:   REQUESTED/APPROVED -> ISSUED. p_lines may change the size or the
--          quantity handed over ([{line_id, size, qty}], qty 0 = not given).
--          Each item leaves stock and is added to what the person holds.
create or replace function public.decide_stock_request(p_request_id uuid,p_decision text,p_note text,p_lines jsonb,p_row_version integer)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.stock_requests%rowtype; v_row public.stock_requests%rowtype; v_decision text:=upper(trim(coalesce(p_decision,'')));
  v_line record; v_override jsonb; v_qty numeric; v_size text; v_move public.stock_movements%rowtype; v_issued integer:=0; v_name text;
begin
  perform public.stock_require('OPERATE');
  select * into v_old from public.stock_requests where request_id=p_request_id for update;
  if not found then raise exception using errcode='P0002',message='Request not found.'; end if;
  if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='This request was changed by someone else. Reload and try again.'; end if;
  if v_old.request_status not in ('REQUESTED','APPROVED') then raise exception using errcode='22023',message='This request was already answered.'; end if;
  if v_decision='APPROVE' then
    if v_old.request_status<>'REQUESTED' then raise exception using errcode='22023',message='This request is already approved.'; end if;
    update public.stock_requests set request_status='APPROVED',decision_note=public.stock_clean_text(p_note,500),decided_at=now(),decided_by=auth.uid(),
      updated_at=now(),row_version=row_version+1 where request_id=p_request_id returning * into v_row;
  elsif v_decision='REJECT' then
    if public.stock_clean_text(p_note,500) is null then raise exception using errcode='22023',message='Tell the person why the request was declined.'; end if;
    update public.stock_requests set request_status='REJECTED',decision_note=public.stock_clean_text(p_note,500),decided_at=now(),decided_by=auth.uid(),
      updated_at=now(),row_version=row_version+1 where request_id=p_request_id returning * into v_row;
  elsif v_decision='ISSUE' then
    v_name:=public.stock_holder_name(v_old.staff_id,null,true);
    for v_line in select l.*,i.item_name,i.size_options,i.category_code from public.stock_request_lines l join public.stock_items i on i.item_id=l.item_id
                  where l.request_id=p_request_id order by l.line_id loop
      v_override:=null;
      select x into v_override from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) x where (x->>'line_id')::bigint=v_line.line_id limit 1;
      v_qty:=coalesce(nullif(v_override->>'qty','')::numeric,v_line.qty);
      v_size:=case when v_override ? 'size' then public.stock_clean_text(v_override->>'size',20) else v_line.size end;
      if v_qty<0 or v_qty>v_line.qty or v_qty<>trunc(v_qty) then raise exception using errcode='22023',message=format('Hand over from 0 to %s of %s.',trim(to_char(v_line.qty,'FM990')),v_line.item_name); end if;
      if v_qty>0 and cardinality(v_line.size_options)>0 and (v_size is null or not v_size=any(v_line.size_options)) then
        raise exception using errcode='22023',message=format('Choose the size for %s.',v_line.item_name);
      end if;
      update public.stock_request_lines set issued_qty=v_qty,size=v_size where line_id=v_line.line_id;
      if v_qty>0 then
        v_move:=public.stock_apply_movement(v_line.item_id,'OUT',v_qty,v_old.staff_id,null,null,null,
          format('Request #%s%s',v_old.request_number,coalesce(' (size '||v_size||')','')),p_request_id,null);
        insert into public.stock_ppe_events(staff_id,holder_name,item_id,item_type,description,size,qty,ppe_action,request_id,movement_id,recorded_by,recorded_by_name)
        values(v_old.staff_id,v_name,v_line.item_id,(select category_name from public.stock_categories where category_code=v_line.category_code),
          v_line.item_name,v_size,v_qty,'ISSUED',p_request_id,v_move.movement_id,auth.uid(),v_move.recorded_by_name);
        v_issued:=v_issued+1;
      end if;
    end loop;
    if v_issued=0 then raise exception using errcode='22023',message='Nothing to hand over. Decline the request instead.'; end if;
    update public.stock_requests set request_status='ISSUED',decision_note=coalesce(public.stock_clean_text(p_note,500),decision_note),
      decided_at=coalesce(decided_at,now()),decided_by=coalesce(decided_by,auth.uid()),issued_at=now(),issued_by=auth.uid(),
      updated_at=now(),row_version=row_version+1 where request_id=p_request_id returning * into v_row;
  else raise exception using errcode='22023',message='Choose Approve, Decline or Hand over.';
  end if;
  return public.stock_request_json(v_row);
end;$$;

-- 7. Manage: catalogue, lockers, settings ------------------------------

create or replace function public.save_stock_item(p_item jsonb,p_row_version integer default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_id uuid:=nullif(p_item->>'item_id','')::uuid; v_old public.stock_items%rowtype; v_row public.stock_items%rowtype; v_cat public.stock_categories%rowtype;
  v_name text:=public.stock_clean_text(p_item->>'item_name',120); v_track text; v_sizes text[]; v_initial numeric;
begin
  perform public.stock_require('MANAGE');
  select * into v_cat from public.stock_categories where category_code=upper(coalesce(p_item->>'category_code','')) and active;
  if not found then raise exception using errcode='22023',message='Choose the category.'; end if;
  if v_name is null then raise exception using errcode='22023',message='Enter the item name.'; end if;
  v_track:=upper(coalesce(nullif(p_item->>'track_by',''),v_cat.default_track_by));
  if v_track not in ('STAFF','CUSTOMER','NONE') then raise exception using errcode='22023',message='Choose who the item is booked to.'; end if;
  select coalesce(array_agg(distinct s order by s),array[]::text[]) into v_sizes
  from (select public.stock_clean_text(x,20) s from jsonb_array_elements_text(coalesce(p_item->'size_options','[]'::jsonb)) x) t where s is not null;
  if exists(select 1 from public.stock_items where lower(item_name)=lower(v_name) and item_id is distinct from v_id) then
    raise exception using errcode='23505',message=format('An item called %s already exists.',v_name);
  end if;
  if v_id is null then
    v_initial:=coalesce(nullif(p_item->>'stock_qty','')::numeric,0);
    if v_initial<0 then raise exception using errcode='22023',message='The opening stock cannot be negative.'; end if;
    insert into public.stock_items(item_code,item_name,category_code,supplier,unit,unit_price,min_stock,location,track_by,requestable,size_options,created_by,updated_by)
    values(public.stock_clean_text(p_item->>'item_code',40),v_name,v_cat.category_code,public.stock_clean_text(p_item->>'supplier',80),
      coalesce(public.stock_clean_text(p_item->>'unit',20),'unit'),coalesce(nullif(p_item->>'unit_price','')::numeric,0),coalesce(nullif(p_item->>'min_stock','')::numeric,0),
      public.stock_clean_text(p_item->>'location',60),v_track,coalesce((p_item->>'requestable')::boolean,v_cat.default_requestable) and v_track='STAFF',v_sizes,auth.uid(),auth.uid())
    returning * into v_row;
    if v_initial>0 then perform public.stock_apply_movement(v_row.item_id,'IN',v_initial,null,null,null,null,'Opening stock',null,null); end if;
    select * into v_row from public.stock_items where item_id=v_row.item_id;
  else
    select * into v_old from public.stock_items where item_id=v_id for update;
    if not found then raise exception using errcode='P0002',message='Item not found.'; end if;
    if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='Someone else changed this item. Reload and try again.'; end if;
    update public.stock_items set item_code=public.stock_clean_text(p_item->>'item_code',40),item_name=v_name,category_code=v_cat.category_code,
      supplier=public.stock_clean_text(p_item->>'supplier',80),unit=coalesce(public.stock_clean_text(p_item->>'unit',20),'unit'),
      unit_price=coalesce(nullif(p_item->>'unit_price','')::numeric,0),min_stock=coalesce(nullif(p_item->>'min_stock','')::numeric,0),
      location=public.stock_clean_text(p_item->>'location',60),track_by=v_track,
      requestable=coalesce((p_item->>'requestable')::boolean,false) and v_track='STAFF',size_options=v_sizes,
      active=coalesce((p_item->>'active')::boolean,active),updated_at=now(),updated_by=auth.uid(),row_version=row_version+1
    where item_id=v_id returning * into v_row;
  end if;
  return public.stock_item_json(v_row);
end;$$;

create or replace function public.add_stock_lockers(p_labels text[])
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_label text; v_row public.stock_lockers%rowtype; v_added integer:=0;
begin
  perform public.stock_require('MANAGE');
  if cardinality(coalesce(p_labels,array[]::text[]))=0 or cardinality(p_labels)>200 then raise exception using errcode='22023',message='Enter from 1 to 200 locker labels.'; end if;
  foreach v_label in array p_labels loop
    v_label:=upper(public.stock_clean_text(v_label,30));
    if v_label is null or exists(select 1 from public.stock_lockers where upper(label)=v_label) then continue; end if;
    insert into public.stock_lockers(label,updated_by) values(v_label,auth.uid()) returning * into v_row;
    insert into public.stock_locker_events(locker_id,label,locker_action,recorded_by,recorded_by_name) values(v_row.locker_id,v_row.label,'ADDED',auth.uid(),public.stock_actor_name());
    v_added:=v_added+1;
  end loop;
  return jsonb_build_object('added',v_added,'skipped',cardinality(p_labels)-v_added);
end;$$;

create or replace function public.save_stock_settings(p_settings jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.stock_settings%rowtype;
begin
  perform public.stock_require('MANAGE');
  update public.stock_settings set
    chemical_count_days=coalesce(nullif(p_settings->>'chemical_count_days','')::integer,chemical_count_days),
    consumption_weeks=coalesce(nullif(p_settings->>'consumption_weeks','')::integer,consumption_weeks),
    updated_at=now(),updated_by=auth.uid()
  returning * into v_row;
  return to_jsonb(v_row);
end;$$;

-- 8. Grants ------------------------------------------------------------

revoke all on function
  public.can_view_stock(),public.can_operate_stock(),public.can_manage_stock(),public.can_request_stock_items(),
  public.stock_require(text),public.stock_clean_text(text,integer),public.stock_actor_name(),public.stock_person_active(uuid,uuid),
  public.stock_holder_name(uuid,uuid,boolean),public.stock_ppe_balances(uuid,uuid),public.stock_people(),
  public.stock_apply_movement(uuid,text,numeric,uuid,uuid,uuid,text,text,uuid,uuid),
  public.stock_item_json(public.stock_items),public.stock_request_json(public.stock_requests),public.stock_usage_stats(),
  public.get_my_stock(),public.submit_my_stock_request(jsonb,text),public.cancel_my_stock_request(uuid),public.get_stock_attention(),
  public.get_stock_workspace(),public.get_stock_person(uuid,uuid),public.get_stock_history(text,date,date,uuid,integer),
  public.record_stock_movement(jsonb),public.save_stock_count(jsonb,text),public.record_ppe_event(jsonb),
  public.record_locker_action(uuid,text,uuid,uuid,text,integer),public.decide_stock_request(uuid,text,text,jsonb,integer),
  public.save_stock_item(jsonb,integer),public.add_stock_lockers(text[]),public.save_stock_settings(jsonb)
from public,anon,authenticated;

grant execute on function
  public.get_my_stock(),public.submit_my_stock_request(jsonb,text),public.cancel_my_stock_request(uuid),public.get_stock_attention(),
  public.get_stock_workspace(),public.get_stock_person(uuid,uuid),public.get_stock_history(text,date,date,uuid,integer),
  public.record_stock_movement(jsonb),public.save_stock_count(jsonb,text),public.record_ppe_event(jsonb),
  public.record_locker_action(uuid,text,uuid,uuid,text,integer),public.decide_stock_request(uuid,text,text,jsonb,integer),
  public.save_stock_item(jsonb,integer),public.add_stock_lockers(text[]),public.save_stock_settings(jsonb)
to authenticated;

commit;
