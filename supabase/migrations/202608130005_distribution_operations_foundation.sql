-- =====================================================================
-- ElisCaretex V2
-- Distribution operations foundation
--
-- The published customer schedule remains the source of expected stops.
-- This module owns the daily operational execution: drivers, fleet, route
-- runs, manual collection/external stops and reported delivery outcomes.
-- =====================================================================

begin;

create table public.distribution_drivers (
  driver_id uuid primary key default gen_random_uuid(),
  staff_id uuid references public.staff_members(staff_id) on delete restrict,
  driver_code text not null unique,
  display_name text not null,
  phone text,
  email text,
  licence_number text,
  licence_categories text[] not null default array[]::text[],
  licence_expires_on date,
  cpc_expires_on date,
  employment_status text not null default 'ACTIVE',
  availability_status text not null default 'AVAILABLE',
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  row_version integer not null default 1,
  constraint distribution_drivers_employment_status_check
    check (employment_status in ('ACTIVE', 'INACTIVE', 'SUSPENDED')),
  constraint distribution_drivers_availability_status_check
    check (availability_status in ('AVAILABLE', 'LEAVE', 'UNAVAILABLE')),
  constraint distribution_drivers_row_version_check check (row_version > 0)
);

create unique index distribution_drivers_staff_unique
  on public.distribution_drivers(staff_id)
  where staff_id is not null and deleted_at is null;

create table public.fleet_vehicles (
  vehicle_id uuid primary key default gen_random_uuid(),
  registration_number text not null unique,
  display_name text,
  vehicle_type text not null default 'TRUCK',
  capacity_kg numeric(12,2),
  capacity_m3 numeric(12,2),
  capacity_trolleys integer,
  operational_status text not null default 'AVAILABLE',
  active boolean not null default true,
  road_tax_expires_on date,
  insurance_expires_on date,
  test_expires_on date,
  service_due_on date,
  odometer_km numeric(12,1),
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  row_version integer not null default 1,
  constraint fleet_vehicles_type_check check (vehicle_type in ('TRUCK', 'VAN', 'OTHER')),
  constraint fleet_vehicles_status_check check (operational_status in ('AVAILABLE', 'MAINTENANCE', 'OUT_OF_SERVICE')),
  constraint fleet_vehicles_capacity_check check (
    (capacity_kg is null or capacity_kg >= 0)
    and (capacity_m3 is null or capacity_m3 >= 0)
    and (capacity_trolleys is null or capacity_trolleys >= 0)
  ),
  constraint fleet_vehicles_row_version_check check (row_version > 0)
);

create table public.fleet_vehicle_maintenance (
  maintenance_id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.fleet_vehicles(vehicle_id) on delete restrict,
  maintenance_type text not null,
  maintenance_status text not null default 'PLANNED',
  starts_on date not null,
  ends_on date,
  supplier_name text,
  cost_amount numeric(12,2),
  notes text,
  completed_at timestamptz,
  completed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint fleet_vehicle_maintenance_status_check check (maintenance_status in ('PLANNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
  constraint fleet_vehicle_maintenance_dates_check check (ends_on is null or ends_on >= starts_on),
  constraint fleet_vehicle_maintenance_cost_check check (cost_amount is null or cost_amount >= 0),
  constraint fleet_vehicle_maintenance_row_version_check check (row_version > 0)
);

create table public.fleet_vehicle_defects (
  defect_id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.fleet_vehicles(vehicle_id) on delete restrict,
  reported_on timestamptz not null default now(),
  severity text not null default 'MEDIUM',
  defect_category text not null,
  description text not null,
  defect_status text not null default 'OPEN',
  closed_at timestamptz,
  closed_by uuid references auth.users(id) on delete set null,
  closure_notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint fleet_vehicle_defects_severity_check check (severity in ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
  constraint fleet_vehicle_defects_status_check check (defect_status in ('OPEN', 'IN_REPAIR', 'CLOSED', 'CANCELLED')),
  constraint fleet_vehicle_defects_row_version_check check (row_version > 0)
);

create table public.distribution_driver_absences (
  absence_id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.distribution_drivers(driver_id) on delete restrict,
  absence_type text not null default 'LEAVE',
  starts_on date not null,
  ends_on date not null,
  absence_status text not null default 'APPROVED',
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint distribution_driver_absences_dates_check check (ends_on >= starts_on),
  constraint distribution_driver_absences_status_check check (absence_status in ('REQUESTED', 'APPROVED', 'REJECTED', 'CANCELLED')),
  constraint distribution_driver_absences_row_version_check check (row_version > 0)
);

create table public.distribution_route_runs (
  run_id uuid primary key default gen_random_uuid(),
  business_date date not null,
  route_id uuid not null references public.distribution_routes(route_id) on delete restrict,
  run_status text not null default 'DRAFT',
  primary_driver_id uuid references public.distribution_drivers(driver_id) on delete restrict,
  support_driver_id uuid references public.distribution_drivers(driver_id) on delete restrict,
  vehicle_id uuid references public.fleet_vehicles(vehicle_id) on delete restrict,
  dispatch_notes text,
  dispatched_at timestamptz,
  dispatched_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz,
  completed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint distribution_route_runs_status_check check (run_status in ('DRAFT', 'READY', 'DISPATCHED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
  constraint distribution_route_runs_driver_check check (primary_driver_id is null or support_driver_id is null or primary_driver_id <> support_driver_id),
  constraint distribution_route_runs_not_sunday check (extract(isodow from business_date) <> 7),
  constraint distribution_route_runs_route_day_unique unique (business_date, route_id),
  constraint distribution_route_runs_row_version_check check (row_version > 0)
);

create table public.distribution_route_run_stops (
  run_stop_id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.distribution_route_runs(run_id) on delete cascade,
  source_schedule_day_id uuid references public.customer_schedule_days(schedule_day_id) on delete restrict,
  customer_id uuid references public.customers(customer_id) on delete restrict,
  stop_kind text not null default 'SCHEDULED',
  stop_order integer not null,
  stop_status text not null default 'PLANNED',
  customer_code_snapshot text,
  customer_name_snapshot text not null,
  eircode_snapshot text,
  delivery_window_start time,
  delivery_window_end time,
  planned_product_codes text[] not null default array[]::text[],
  planned_trolley_total integer not null default 0,
  planned_trolley_summary text,
  estimated_kg numeric(12,2),
  stop_units integer,
  distribution_instructions text,
  operational_notes text,
  reported_at timestamptz,
  reported_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  row_version integer not null default 1,
  constraint distribution_route_run_stops_kind_check check (stop_kind in ('SCHEDULED', 'COLLECTION', 'EXTERNAL')),
  constraint distribution_route_run_stops_status_check check (stop_status in ('PLANNED', 'LOADED', 'OUT_FOR_DELIVERY', 'DELIVERED', 'SKIPPED', 'COLLECTION_COMPLETED')),
  constraint distribution_route_run_stops_order_check check (stop_order > 0),
  constraint distribution_route_run_stops_trolley_check check (planned_trolley_total >= 0),
  constraint distribution_route_run_stops_row_version_check check (row_version > 0)
);

create unique index distribution_route_run_stops_source_unique
  on public.distribution_route_run_stops(run_id, source_schedule_day_id)
  where source_schedule_day_id is not null;

create table public.distribution_run_events (
  event_id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.distribution_route_runs(run_id) on delete cascade,
  event_type text not null,
  event_payload jsonb not null default '{}'::jsonb,
  event_at timestamptz not null default now(),
  recorded_by uuid references auth.users(id) on delete set null
);

create index distribution_route_runs_date_idx on public.distribution_route_runs(business_date, run_status);
create index distribution_route_runs_vehicle_idx on public.distribution_route_runs(vehicle_id, business_date) where vehicle_id is not null;
create index distribution_route_runs_primary_driver_idx on public.distribution_route_runs(primary_driver_id, business_date) where primary_driver_id is not null;
create index distribution_route_runs_support_driver_idx on public.distribution_route_runs(support_driver_id, business_date) where support_driver_id is not null;
create index distribution_route_run_stops_run_order_idx on public.distribution_route_run_stops(run_id, stop_order);
create index fleet_vehicle_maintenance_vehicle_idx on public.fleet_vehicle_maintenance(vehicle_id, maintenance_status, starts_on desc);
create index fleet_vehicle_defects_vehicle_idx on public.fleet_vehicle_defects(vehicle_id, defect_status, reported_on desc);
create index distribution_driver_absences_driver_idx on public.distribution_driver_absences(driver_id, starts_on, ends_on) where absence_status = 'APPROVED';

create trigger distribution_drivers_set_updated_at before update on public.distribution_drivers for each row execute function public.set_updated_at();
create trigger fleet_vehicles_set_updated_at before update on public.fleet_vehicles for each row execute function public.set_updated_at();
create trigger fleet_vehicle_maintenance_set_updated_at before update on public.fleet_vehicle_maintenance for each row execute function public.set_updated_at();
create trigger fleet_vehicle_defects_set_updated_at before update on public.fleet_vehicle_defects for each row execute function public.set_updated_at();
create trigger distribution_driver_absences_set_updated_at before update on public.distribution_driver_absences for each row execute function public.set_updated_at();
create trigger distribution_route_runs_set_updated_at before update on public.distribution_route_runs for each row execute function public.set_updated_at();
create trigger distribution_route_run_stops_set_updated_at before update on public.distribution_route_run_stops for each row execute function public.set_updated_at();

alter table public.distribution_drivers enable row level security;
alter table public.fleet_vehicles enable row level security;
alter table public.fleet_vehicle_maintenance enable row level security;
alter table public.fleet_vehicle_defects enable row level security;
alter table public.distribution_driver_absences enable row level security;
alter table public.distribution_route_runs enable row level security;
alter table public.distribution_route_run_stops enable row level security;
alter table public.distribution_run_events enable row level security;

revoke all on table public.distribution_drivers, public.fleet_vehicles, public.fleet_vehicle_maintenance,
  public.fleet_vehicle_defects, public.distribution_driver_absences, public.distribution_route_runs,
  public.distribution_route_run_stops, public.distribution_run_events from public, anon, authenticated;

create or replace function public.require_distribution_read_access()
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  if auth.uid() is null or public.current_staff_id() is null then
    raise exception using errcode = '42501', message = 'An active authenticated staff account is required.';
  end if;
  if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR','AUDITOR']) then
    raise exception using errcode = '42501', message = 'Your active role does not allow access to Distribution.';
  end if;
end;
$$;

create or replace function public.require_distribution_plan_access()
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  perform public.require_distribution_read_access();
  if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']) then
    raise exception using errcode = '42501', message = 'Your active role cannot plan Distribution routes.';
  end if;
end;
$$;

create or replace function public.require_distribution_master_access()
returns void language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
begin
  perform public.require_distribution_read_access();
  if not public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR']) then
    raise exception using errcode = '42501', message = 'Your active role cannot manage Distribution master data.';
  end if;
end;
$$;

create or replace function public.get_distribution_operations_capabilities()
returns jsonb language sql stable security definer set search_path = public, auth, pg_temp as $$
  select jsonb_build_object(
    'can_view_distribution_operations', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR','AUDITOR']),
    'can_plan_runs', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'can_dispatch_runs', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'can_record_stop_outcomes', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'can_manage_drivers', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR']),
    'can_manage_fleet', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR']),
    'can_manage_routes', public.has_any_role(array['ADMIN','MANAGER','SUPERVISOR'])
  );
$$;

create or replace function public.distribution_source_stops(
  p_business_date date,
  p_route_id uuid default null
)
returns table (
  source_schedule_day_id uuid, customer_id uuid, route_id uuid, route_code text,
  route_display_name text, route_color text, source_delivery_order integer,
  customer_code text, customer_name text, eircode text, delivery_window_start time,
  delivery_window_end time, planned_product_codes text[], planned_trolley_total integer,
  planned_trolley_summary text, estimated_kg numeric, stop_units integer,
  distribution_instructions text, day_alert text
)
language sql stable security definer set search_path = public, auth, pg_temp as $$
  select d.schedule_day_id, c.customer_id, r.route_id, r.route_code, r.display_name, r.route_color,
    d.delivery_order, c.customer_code, c.customer_name, c.eircode, d.delivery_window_start,
    d.delivery_window_end, coalesce(products.product_codes, array[]::text[]),
    coalesce(trolleys.total_quantity, 0)::integer, trolleys.trolley_summary,
    c.distribution_estimated_kg, c.distribution_stop_count, d.distribution_instructions, d.day_alert
  from public.customer_schedule_versions v
  join public.customer_schedule_days d on d.schedule_version_id = v.schedule_version_id and d.active
  join public.customers c on c.customer_id = v.customer_id and c.active and c.deleted_at is null
  join public.distribution_routes r on r.route_id = d.default_route_id and r.active and r.deleted_at is null
  left join lateral (
    select array_agg(pt.product_code order by pt.sort_order, pt.product_code) as product_codes
    from public.customer_schedule_products sp
    join public.product_types pt on pt.product_type_id = sp.product_type_id
    where sp.schedule_day_id = d.schedule_day_id and sp.active and pt.active and pt.deleted_at is null
  ) products on true
  left join lateral (
    select sum(req.quantity)::integer as total_quantity,
      string_agg(concat(req.quantity, coalesce(tt.display_code, tt.trolley_type_code)), ' + ' order by tt.sort_order, tt.trolley_type_code) as trolley_summary
    from public.customer_schedule_trolley_requirements req
    join public.trolley_types tt on tt.trolley_type_id = req.trolley_type_id
    where req.schedule_day_id = d.schedule_day_id and req.active
  ) trolleys on true
  where v.status = 'PUBLISHED'
    and v.effective_from <= p_business_date
    and (v.effective_until is null or v.effective_until >= p_business_date)
    and d.delivery_weekday = extract(isodow from p_business_date)::smallint
    and (p_route_id is null or d.default_route_id = p_route_id);
$$;

create or replace function public.sync_distribution_route_run_stops(p_run_id uuid)
returns void language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_run public.distribution_route_runs%rowtype;
begin
  select * into v_run from public.distribution_route_runs where run_id = p_run_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'Distribution route run was not found.'; end if;
  if v_run.run_status not in ('DRAFT','READY') then
    raise exception using errcode = '22023', message = 'Only Draft or Ready runs can be synchronized with the published schedule.';
  end if;
  insert into public.distribution_route_run_stops (
    run_id, source_schedule_day_id, customer_id, stop_kind, stop_order, customer_code_snapshot,
    customer_name_snapshot, eircode_snapshot, delivery_window_start, delivery_window_end,
    planned_product_codes, planned_trolley_total, planned_trolley_summary, estimated_kg,
    stop_units, distribution_instructions, created_by, updated_by
  )
  select p_run_id, s.source_schedule_day_id, s.customer_id, 'SCHEDULED',
    coalesce(s.source_delivery_order, 10000), s.customer_code, s.customer_name, s.eircode,
    s.delivery_window_start, s.delivery_window_end, s.planned_product_codes,
    s.planned_trolley_total, s.planned_trolley_summary, s.estimated_kg, s.stop_units,
    concat_ws(E'\n', s.distribution_instructions, s.day_alert), auth.uid(), auth.uid()
  from public.distribution_source_stops(v_run.business_date, v_run.route_id) s
  on conflict (run_id, source_schedule_day_id) where source_schedule_day_id is not null do update set
    stop_order = excluded.stop_order,
    customer_code_snapshot = excluded.customer_code_snapshot,
    customer_name_snapshot = excluded.customer_name_snapshot,
    eircode_snapshot = excluded.eircode_snapshot,
    delivery_window_start = excluded.delivery_window_start,
    delivery_window_end = excluded.delivery_window_end,
    planned_product_codes = excluded.planned_product_codes,
    planned_trolley_total = excluded.planned_trolley_total,
    planned_trolley_summary = excluded.planned_trolley_summary,
    estimated_kg = excluded.estimated_kg,
    stop_units = excluded.stop_units,
    distribution_instructions = excluded.distribution_instructions,
    updated_by = auth.uid(), row_version = public.distribution_route_run_stops.row_version + 1
  where public.distribution_route_run_stops.stop_status = 'PLANNED';
end;
$$;

create or replace function public.get_distribution_operations_dashboard(p_business_date date default current_date)
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
declare v_date date := coalesce(p_business_date, current_date);
begin
  perform public.require_distribution_read_access();
  if extract(isodow from v_date) = 7 then
    raise exception using errcode = '22023', message = 'Distribution does not operate on Sunday.';
  end if;
  return jsonb_build_object(
    'schema_version', 'DISTRIBUTION_OPERATIONS_V1',
    'business_date', v_date,
    'capabilities', public.get_distribution_operations_capabilities(),
    'reference_stops', coalesce((select jsonb_agg(jsonb_build_object(
      'source_schedule_day_id', s.source_schedule_day_id, 'customer_id', s.customer_id,
      'route_id', s.route_id, 'route_code', s.route_code, 'route_display_name', s.route_display_name,
      'route_color', s.route_color, 'delivery_order', s.source_delivery_order,
      'customer_code', s.customer_code, 'customer_name', s.customer_name, 'eircode', s.eircode,
      'delivery_window_start', s.delivery_window_start, 'delivery_window_end', s.delivery_window_end,
      'planned_product_codes', s.planned_product_codes, 'planned_trolley_total', s.planned_trolley_total,
      'planned_trolley_summary', s.planned_trolley_summary, 'estimated_kg', s.estimated_kg,
      'stop_units', s.stop_units, 'distribution_instructions', s.distribution_instructions, 'day_alert', s.day_alert
    ) order by s.route_code, s.source_delivery_order nulls last, lower(s.customer_name)) from public.distribution_source_stops(v_date, null) s), '[]'::jsonb),
    'runs', coalesce((select jsonb_agg(jsonb_build_object(
      'run_id', dr.run_id, 'route_id', dr.route_id, 'route_code', r.route_code, 'route_display_name', r.display_name,
      'route_color', r.route_color, 'run_status', dr.run_status, 'dispatch_notes', dr.dispatch_notes,
      'primary_driver_id', dr.primary_driver_id, 'primary_driver_name', pd.display_name,
      'support_driver_id', dr.support_driver_id, 'support_driver_name', sd.display_name,
      'vehicle_id', dr.vehicle_id, 'vehicle_registration', fv.registration_number,
      'vehicle_capacity_kg', fv.capacity_kg, 'row_version', dr.row_version,
      'stop_count', (select count(*) from public.distribution_route_run_stops rs where rs.run_id = dr.run_id),
      'completed_stop_count', (select count(*) from public.distribution_route_run_stops rs where rs.run_id = dr.run_id and rs.stop_status in ('DELIVERED','COLLECTION_COMPLETED'))
    ) order by r.sort_order, r.route_code) from public.distribution_route_runs dr
      join public.distribution_routes r on r.route_id = dr.route_id
      left join public.distribution_drivers pd on pd.driver_id = dr.primary_driver_id
      left join public.distribution_drivers sd on sd.driver_id = dr.support_driver_id
      left join public.fleet_vehicles fv on fv.vehicle_id = dr.vehicle_id
      where dr.business_date = v_date), '[]'::jsonb),
    'routes', coalesce((select jsonb_agg(jsonb_build_object(
      'route_id', r.route_id, 'route_code', r.route_code, 'display_name', r.display_name,
      'route_color', r.route_color, 'route_kind', r.route_kind, 'allow_as_default', r.allow_as_default,
      'active', r.active, 'sort_order', r.sort_order, 'notes', r.notes, 'row_version', r.row_version
    ) order by r.sort_order, r.route_code) from public.distribution_routes r where r.deleted_at is null), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object(
      'driver_id', d.driver_id, 'driver_code', d.driver_code, 'display_name', d.display_name,
      'phone', d.phone, 'licence_expires_on', d.licence_expires_on, 'cpc_expires_on', d.cpc_expires_on,
      'employment_status', d.employment_status, 'availability_status', d.availability_status, 'row_version', d.row_version
    ) order by lower(d.display_name)) from public.distribution_drivers d where d.deleted_at is null), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object(
      'vehicle_id', f.vehicle_id, 'registration_number', f.registration_number, 'display_name', f.display_name,
      'vehicle_type', f.vehicle_type, 'capacity_kg', f.capacity_kg, 'capacity_trolleys', f.capacity_trolleys,
      'operational_status', f.operational_status, 'active', f.active, 'road_tax_expires_on', f.road_tax_expires_on,
      'insurance_expires_on', f.insurance_expires_on, 'test_expires_on', f.test_expires_on,
      'service_due_on', f.service_due_on, 'row_version', f.row_version
    ) order by f.registration_number) from public.fleet_vehicles f where f.deleted_at is null), '[]'::jsonb),
    'fleet_summary', jsonb_build_object(
      'open_defects', (select count(*) from public.fleet_vehicle_defects where defect_status in ('OPEN','IN_REPAIR')),
      'maintenance_unavailable', (select count(*) from public.fleet_vehicles where deleted_at is null and operational_status <> 'AVAILABLE'),
      'compliance_due', (select count(*) from public.fleet_vehicles where deleted_at is null and active and least(
        coalesce(road_tax_expires_on, 'infinity'::date), coalesce(insurance_expires_on, 'infinity'::date),
        coalesce(test_expires_on, 'infinity'::date), coalesce(service_due_on, 'infinity'::date)
      ) <= current_date + 30)
    ),
    'fleet_defects', coalesce((select jsonb_agg(jsonb_build_object(
      'defect_id', d.defect_id, 'vehicle_id', d.vehicle_id, 'registration_number', f.registration_number,
      'reported_on', d.reported_on, 'severity', d.severity, 'defect_category', d.defect_category,
      'description', d.description, 'defect_status', d.defect_status, 'closure_notes', d.closure_notes,
      'row_version', d.row_version
    ) order by d.reported_on desc) from public.fleet_vehicle_defects d join public.fleet_vehicles f on f.vehicle_id=d.vehicle_id where d.defect_status in ('OPEN','IN_REPAIR')), '[]'::jsonb),
    'fleet_maintenance', coalesce((select jsonb_agg(jsonb_build_object(
      'maintenance_id', m.maintenance_id, 'vehicle_id', m.vehicle_id, 'registration_number', f.registration_number,
      'maintenance_type', m.maintenance_type, 'maintenance_status', m.maintenance_status,
      'starts_on', m.starts_on, 'ends_on', m.ends_on, 'supplier_name', m.supplier_name,
      'cost_amount', m.cost_amount, 'notes', m.notes, 'row_version', m.row_version
    ) order by m.starts_on desc) from public.fleet_vehicle_maintenance m join public.fleet_vehicles f on f.vehicle_id=m.vehicle_id where m.maintenance_status in ('PLANNED','IN_PROGRESS')), '[]'::jsonb),
    'trolley_handoff', public.get_trolley_distribution_handoff(v_date)
  );
end;
$$;

create or replace function public.get_distribution_route_run_detail(p_run_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, auth, pg_temp as $$
declare v_run public.distribution_route_runs%rowtype;
begin
  perform public.require_distribution_read_access();
  select * into v_run from public.distribution_route_runs where run_id = p_run_id;
  if not found then raise exception using errcode = 'P0002', message = 'Distribution route run was not found.'; end if;
  return jsonb_build_object(
    'run_id', v_run.run_id, 'business_date', v_run.business_date, 'route_id', v_run.route_id,
    'run_status', v_run.run_status, 'row_version', v_run.row_version,
    'stops', coalesce((select jsonb_agg(jsonb_build_object(
      'run_stop_id', s.run_stop_id, 'source_schedule_day_id', s.source_schedule_day_id, 'customer_id', s.customer_id,
      'stop_kind', s.stop_kind, 'stop_order', s.stop_order, 'stop_status', s.stop_status,
      'customer_code_snapshot', s.customer_code_snapshot, 'customer_name_snapshot', s.customer_name_snapshot,
      'eircode_snapshot', s.eircode_snapshot, 'delivery_window_start', s.delivery_window_start,
      'delivery_window_end', s.delivery_window_end, 'planned_product_codes', s.planned_product_codes,
      'planned_trolley_total', s.planned_trolley_total, 'planned_trolley_summary', s.planned_trolley_summary,
      'estimated_kg', s.estimated_kg, 'stop_units', s.stop_units, 'distribution_instructions', s.distribution_instructions,
      'operational_notes', s.operational_notes, 'reported_at', s.reported_at, 'row_version', s.row_version
    ) order by s.stop_order, lower(s.customer_name_snapshot)) from public.distribution_route_run_stops s where s.run_id = p_run_id), '[]'::jsonb)
  );
end;
$$;

create or replace function public.save_distribution_route_run(p_run jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_id uuid := nullif(p_run ->> 'run_id','')::uuid; v_date date := (p_run ->> 'business_date')::date;
  v_route uuid := (p_run ->> 'route_id')::uuid; v_primary uuid := nullif(p_run ->> 'primary_driver_id','')::uuid;
  v_support uuid := nullif(p_run ->> 'support_driver_id','')::uuid; v_vehicle uuid := nullif(p_run ->> 'vehicle_id','')::uuid;
  v_status text := upper(coalesce(nullif(p_run ->> 'run_status',''), 'DRAFT')); v_run_id uuid; v_expected integer := nullif(p_run ->> 'row_version','')::integer;
begin
  perform public.require_distribution_plan_access();
  if v_date is null or extract(isodow from v_date) = 7 then raise exception using errcode = '22023', message = 'Choose a valid Distribution operating date.'; end if;
  if v_status not in ('DRAFT','READY') then raise exception using errcode = '22023', message = 'Use the dispatch action to change an operational route status.'; end if;
  if v_primary is not null and v_primary = v_support then raise exception using errcode = '22023', message = 'Primary and support driver must be different.'; end if;
  if not exists (select 1 from public.distribution_routes where route_id = v_route and active and deleted_at is null) then raise exception using errcode = '22023', message = 'Choose an active Route.'; end if;
  if v_primary is not null and not exists (select 1 from public.distribution_drivers where driver_id = v_primary and deleted_at is null and employment_status = 'ACTIVE' and availability_status = 'AVAILABLE') then raise exception using errcode = '22023', message = 'The selected primary driver is unavailable.'; end if;
  if v_support is not null and not exists (select 1 from public.distribution_drivers where driver_id = v_support and deleted_at is null and employment_status = 'ACTIVE' and availability_status = 'AVAILABLE') then raise exception using errcode = '22023', message = 'The selected support driver is unavailable.'; end if;
  if v_vehicle is not null and not exists (select 1 from public.fleet_vehicles where vehicle_id = v_vehicle and active and deleted_at is null and operational_status = 'AVAILABLE') then raise exception using errcode = '22023', message = 'The selected vehicle is unavailable.'; end if;
  if exists (select 1 from public.distribution_driver_absences a where a.absence_status = 'APPROVED' and v_date between a.starts_on and a.ends_on and a.driver_id in (v_primary, v_support)) then raise exception using errcode = '22023', message = 'A selected driver has approved leave on this date.'; end if;
  if exists (select 1 from public.distribution_route_runs x where x.business_date = v_date and x.run_id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid) and x.run_status not in ('CANCELLED','COMPLETED') and (x.vehicle_id = v_vehicle and v_vehicle is not null or x.primary_driver_id in (v_primary,v_support) or x.support_driver_id in (v_primary,v_support))) then raise exception using errcode = '23505', message = 'The selected driver or vehicle is already allocated to another active Route.'; end if;
  insert into public.distribution_route_runs(run_id,business_date,route_id,run_status,primary_driver_id,support_driver_id,vehicle_id,dispatch_notes,created_by,updated_by)
  values (coalesce(v_id,gen_random_uuid()),v_date,v_route,v_status,v_primary,v_support,v_vehicle,nullif(p_run ->> 'dispatch_notes',''),auth.uid(),auth.uid())
  on conflict (business_date,route_id) do update set
    primary_driver_id=excluded.primary_driver_id, support_driver_id=excluded.support_driver_id, vehicle_id=excluded.vehicle_id,
    run_status=excluded.run_status, dispatch_notes=excluded.dispatch_notes, updated_by=auth.uid(), row_version=public.distribution_route_runs.row_version+1
  where v_expected is null or public.distribution_route_runs.row_version = v_expected
  returning run_id into v_run_id;
  if v_run_id is null then raise exception using errcode = '40001', message = 'This Route changed in another session. Refresh before saving again.'; end if;
  perform public.sync_distribution_route_run_stops(v_run_id);
  insert into public.distribution_run_events(run_id,event_type,event_payload,recorded_by) values (v_run_id,'RUN_SAVED',jsonb_build_object('status',v_status),auth.uid());
  return public.get_distribution_route_run_detail(v_run_id);
end;
$$;

create or replace function public.set_distribution_route_run_status(p_run_id uuid, p_status text, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_status text := upper(trim(p_status));
begin
  perform public.require_distribution_plan_access();
  if v_status not in ('DRAFT','READY','DISPATCHED','IN_PROGRESS','COMPLETED','CANCELLED') then raise exception using errcode = '22023', message = 'Unknown Distribution Route status.'; end if;
  update public.distribution_route_runs set run_status=v_status, dispatch_notes=coalesce(nullif(p_notes,''),dispatch_notes),
    dispatched_at=case when v_status='DISPATCHED' then now() else dispatched_at end,
    dispatched_by=case when v_status='DISPATCHED' then auth.uid() else dispatched_by end,
    completed_at=case when v_status='COMPLETED' then now() else completed_at end,
    completed_by=case when v_status='COMPLETED' then auth.uid() else completed_by end,
    updated_by=auth.uid(), row_version=row_version+1
  where run_id=p_run_id;
  if not found then raise exception using errcode = 'P0002', message = 'Distribution route run was not found.'; end if;
  insert into public.distribution_run_events(run_id,event_type,event_payload,recorded_by) values (p_run_id,'RUN_STATUS_CHANGED',jsonb_build_object('status',v_status,'notes',p_notes),auth.uid());
  return public.get_distribution_route_run_detail(p_run_id);
end;
$$;

create or replace function public.save_distribution_manual_stop(p_stop jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_run uuid := (p_stop ->> 'run_id')::uuid; v_stop uuid := nullif(p_stop ->> 'run_stop_id','')::uuid; v_kind text := upper(coalesce(nullif(p_stop ->> 'stop_kind',''),'COLLECTION'));
begin
  perform public.require_distribution_plan_access();
  if v_kind not in ('COLLECTION','EXTERNAL') then raise exception using errcode = '22023', message = 'Manual stops must be Collection or External.'; end if;
  if not exists(select 1 from public.distribution_route_runs where run_id=v_run and run_status in ('DRAFT','READY')) then raise exception using errcode='22023', message='Manual stops can only be changed before dispatch.'; end if;
  insert into public.distribution_route_run_stops(run_stop_id,run_id,customer_id,stop_kind,stop_order,customer_name_snapshot,eircode_snapshot,estimated_kg,planned_trolley_total,distribution_instructions,operational_notes,created_by,updated_by)
  values(coalesce(v_stop,gen_random_uuid()),v_run,nullif(p_stop ->> 'customer_id','')::uuid,v_kind,coalesce(nullif(p_stop ->> 'stop_order','')::integer,(select coalesce(max(stop_order),0)+1 from public.distribution_route_run_stops where run_id=v_run)),
    coalesce(nullif(p_stop ->> 'customer_name',''),'Unnamed stop'),nullif(p_stop ->> 'eircode',''),nullif(p_stop ->> 'estimated_kg','')::numeric,coalesce(nullif(p_stop ->> 'planned_trolley_total','')::integer,0),nullif(p_stop ->> 'distribution_instructions',''),nullif(p_stop ->> 'operational_notes',''),auth.uid(),auth.uid())
  on conflict (run_stop_id) do update set stop_order=excluded.stop_order, customer_name_snapshot=excluded.customer_name_snapshot, eircode_snapshot=excluded.eircode_snapshot, estimated_kg=excluded.estimated_kg, planned_trolley_total=excluded.planned_trolley_total, distribution_instructions=excluded.distribution_instructions, operational_notes=excluded.operational_notes, updated_by=auth.uid(), row_version=public.distribution_route_run_stops.row_version+1;
  return public.get_distribution_route_run_detail(v_run);
end;
$$;

create or replace function public.set_distribution_stop_status(p_run_stop_id uuid, p_status text, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_run uuid; v_status text := upper(trim(p_status));
begin
  perform public.require_distribution_plan_access();
  if v_status not in ('PLANNED','LOADED','OUT_FOR_DELIVERY','DELIVERED','SKIPPED','COLLECTION_COMPLETED') then raise exception using errcode='22023', message='Unknown stop status.'; end if;
  update public.distribution_route_run_stops set stop_status=v_status, operational_notes=coalesce(nullif(p_notes,''),operational_notes), reported_at=now(), reported_by=auth.uid(), updated_by=auth.uid(), row_version=row_version+1 where run_stop_id=p_run_stop_id returning run_id into v_run;
  if v_run is null then raise exception using errcode='P0002', message='Distribution stop was not found.'; end if;
  insert into public.distribution_run_events(run_id,event_type,event_payload,recorded_by) values(v_run,'STOP_STATUS_REPORTED',jsonb_build_object('run_stop_id',p_run_stop_id,'status',v_status,'notes',p_notes),auth.uid());
  return public.get_distribution_route_run_detail(v_run);
end;
$$;

create or replace function public.save_distribution_driver(p_driver jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_id uuid := nullif(p_driver ->> 'driver_id','')::uuid; v_result public.distribution_drivers%rowtype;
begin
  perform public.require_distribution_master_access();
  insert into public.distribution_drivers(driver_id,staff_id,driver_code,display_name,phone,email,licence_number,licence_categories,licence_expires_on,cpc_expires_on,employment_status,availability_status,notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),nullif(p_driver ->> 'staff_id','')::uuid,upper(trim(p_driver ->> 'driver_code')),trim(p_driver ->> 'display_name'),nullif(p_driver ->> 'phone',''),nullif(p_driver ->> 'email',''),nullif(p_driver ->> 'licence_number',''),coalesce(array(select jsonb_array_elements_text(coalesce(p_driver -> 'licence_categories','[]'::jsonb))),array[]::text[]),nullif(p_driver ->> 'licence_expires_on','')::date,nullif(p_driver ->> 'cpc_expires_on','')::date,upper(coalesce(nullif(p_driver ->> 'employment_status',''),'ACTIVE')),upper(coalesce(nullif(p_driver ->> 'availability_status',''),'AVAILABLE')),nullif(p_driver ->> 'notes',''),auth.uid(),auth.uid())
  on conflict (driver_id) do update set staff_id=excluded.staff_id,driver_code=excluded.driver_code,display_name=excluded.display_name,phone=excluded.phone,email=excluded.email,licence_number=excluded.licence_number,licence_categories=excluded.licence_categories,licence_expires_on=excluded.licence_expires_on,cpc_expires_on=excluded.cpc_expires_on,employment_status=excluded.employment_status,availability_status=excluded.availability_status,notes=excluded.notes,updated_by=auth.uid(),row_version=public.distribution_drivers.row_version+1
  returning * into v_result;
  return to_jsonb(v_result);
end;
$$;

create or replace function public.save_fleet_vehicle(p_vehicle jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_id uuid := nullif(p_vehicle ->> 'vehicle_id','')::uuid; v_result public.fleet_vehicles%rowtype;
begin
  perform public.require_distribution_master_access();
  insert into public.fleet_vehicles(vehicle_id,registration_number,display_name,vehicle_type,capacity_kg,capacity_m3,capacity_trolleys,operational_status,active,road_tax_expires_on,insurance_expires_on,test_expires_on,service_due_on,odometer_km,notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),upper(replace(trim(p_vehicle ->> 'registration_number'),' ','')),nullif(p_vehicle ->> 'display_name',''),upper(coalesce(nullif(p_vehicle ->> 'vehicle_type',''),'TRUCK')),nullif(p_vehicle ->> 'capacity_kg','')::numeric,nullif(p_vehicle ->> 'capacity_m3','')::numeric,nullif(p_vehicle ->> 'capacity_trolleys','')::integer,upper(coalesce(nullif(p_vehicle ->> 'operational_status',''),'AVAILABLE')),coalesce((p_vehicle ->> 'active')::boolean,true),nullif(p_vehicle ->> 'road_tax_expires_on','')::date,nullif(p_vehicle ->> 'insurance_expires_on','')::date,nullif(p_vehicle ->> 'test_expires_on','')::date,nullif(p_vehicle ->> 'service_due_on','')::date,nullif(p_vehicle ->> 'odometer_km','')::numeric,nullif(p_vehicle ->> 'notes',''),auth.uid(),auth.uid())
  on conflict (vehicle_id) do update set registration_number=excluded.registration_number,display_name=excluded.display_name,vehicle_type=excluded.vehicle_type,capacity_kg=excluded.capacity_kg,capacity_m3=excluded.capacity_m3,capacity_trolleys=excluded.capacity_trolleys,operational_status=excluded.operational_status,active=excluded.active,road_tax_expires_on=excluded.road_tax_expires_on,insurance_expires_on=excluded.insurance_expires_on,test_expires_on=excluded.test_expires_on,service_due_on=excluded.service_due_on,odometer_km=excluded.odometer_km,notes=excluded.notes,updated_by=auth.uid(),row_version=public.fleet_vehicles.row_version+1
  returning * into v_result;
  return to_jsonb(v_result);
end;
$$;

create or replace function public.save_distribution_route(p_route jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_id uuid := nullif(p_route ->> 'route_id','')::uuid; v_result public.distribution_routes%rowtype;
begin
  perform public.require_distribution_master_access();
  insert into public.distribution_routes(route_id,route_code,display_name,route_color,route_kind,allow_as_default,active,sort_order,notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),upper(trim(p_route ->> 'route_code')),trim(p_route ->> 'display_name'),nullif(p_route ->> 'route_color',''),upper(coalesce(nullif(p_route ->> 'route_kind',''),'STANDARD')),coalesce((p_route ->> 'allow_as_default')::boolean,true),coalesce((p_route ->> 'active')::boolean,true),coalesce(nullif(p_route ->> 'sort_order','')::integer,0),nullif(p_route ->> 'notes',''),auth.uid(),auth.uid())
  on conflict (route_id) do update set route_code=excluded.route_code,display_name=excluded.display_name,route_color=excluded.route_color,route_kind=excluded.route_kind,allow_as_default=excluded.allow_as_default,active=excluded.active,sort_order=excluded.sort_order,notes=excluded.notes,updated_by=auth.uid(),row_version=public.distribution_routes.row_version+1
  returning * into v_result;
  return to_jsonb(v_result);
end;
$$;

create or replace function public.save_fleet_vehicle_maintenance(p_maintenance jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_id uuid := nullif(p_maintenance ->> 'maintenance_id','')::uuid; v_result public.fleet_vehicle_maintenance%rowtype;
begin
  perform public.require_distribution_master_access();
  insert into public.fleet_vehicle_maintenance(maintenance_id,vehicle_id,maintenance_type,maintenance_status,starts_on,ends_on,supplier_name,cost_amount,notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),(p_maintenance ->> 'vehicle_id')::uuid,trim(p_maintenance ->> 'maintenance_type'),upper(coalesce(nullif(p_maintenance ->> 'maintenance_status',''),'PLANNED')),(p_maintenance ->> 'starts_on')::date,nullif(p_maintenance ->> 'ends_on','')::date,nullif(p_maintenance ->> 'supplier_name',''),nullif(p_maintenance ->> 'cost_amount','')::numeric,nullif(p_maintenance ->> 'notes',''),auth.uid(),auth.uid())
  on conflict (maintenance_id) do update set vehicle_id=excluded.vehicle_id,maintenance_type=excluded.maintenance_type,maintenance_status=excluded.maintenance_status,starts_on=excluded.starts_on,ends_on=excluded.ends_on,supplier_name=excluded.supplier_name,cost_amount=excluded.cost_amount,notes=excluded.notes,completed_at=case when excluded.maintenance_status='COMPLETED' then now() else public.fleet_vehicle_maintenance.completed_at end,completed_by=case when excluded.maintenance_status='COMPLETED' then auth.uid() else public.fleet_vehicle_maintenance.completed_by end,updated_by=auth.uid(),row_version=public.fleet_vehicle_maintenance.row_version+1
  returning * into v_result;
  return to_jsonb(v_result);
end;
$$;

create or replace function public.save_fleet_vehicle_defect(p_defect jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_id uuid := nullif(p_defect ->> 'defect_id','')::uuid; v_result public.fleet_vehicle_defects%rowtype;
begin
  perform public.require_distribution_master_access();
  insert into public.fleet_vehicle_defects(defect_id,vehicle_id,severity,defect_category,description,defect_status,closure_notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),(p_defect ->> 'vehicle_id')::uuid,upper(coalesce(nullif(p_defect ->> 'severity',''),'MEDIUM')),trim(p_defect ->> 'defect_category'),trim(p_defect ->> 'description'),upper(coalesce(nullif(p_defect ->> 'defect_status',''),'OPEN')),nullif(p_defect ->> 'closure_notes',''),auth.uid(),auth.uid())
  on conflict (defect_id) do update set severity=excluded.severity,defect_category=excluded.defect_category,description=excluded.description,defect_status=excluded.defect_status,closure_notes=excluded.closure_notes,closed_at=case when excluded.defect_status='CLOSED' then now() else public.fleet_vehicle_defects.closed_at end,closed_by=case when excluded.defect_status='CLOSED' then auth.uid() else public.fleet_vehicle_defects.closed_by end,updated_by=auth.uid(),row_version=public.fleet_vehicle_defects.row_version+1
  returning * into v_result;
  if v_result.defect_status in ('OPEN','IN_REPAIR') then
    update public.fleet_vehicles set operational_status = case when v_result.severity in ('HIGH','CRITICAL') then 'OUT_OF_SERVICE' else operational_status end, updated_by=auth.uid(), row_version=row_version+1 where vehicle_id=v_result.vehicle_id;
  end if;
  return to_jsonb(v_result);
end;
$$;

create or replace function public.save_distribution_driver_absence(p_absence jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_id uuid := nullif(p_absence ->> 'absence_id','')::uuid; v_result public.distribution_driver_absences%rowtype;
begin
  perform public.require_distribution_master_access();
  insert into public.distribution_driver_absences(absence_id,driver_id,absence_type,starts_on,ends_on,absence_status,notes,created_by,updated_by)
  values(coalesce(v_id,gen_random_uuid()),(p_absence ->> 'driver_id')::uuid,upper(coalesce(nullif(p_absence ->> 'absence_type',''),'LEAVE')),(p_absence ->> 'starts_on')::date,(p_absence ->> 'ends_on')::date,upper(coalesce(nullif(p_absence ->> 'absence_status',''),'APPROVED')),nullif(p_absence ->> 'notes',''),auth.uid(),auth.uid())
  on conflict (absence_id) do update set driver_id=excluded.driver_id,absence_type=excluded.absence_type,starts_on=excluded.starts_on,ends_on=excluded.ends_on,absence_status=excluded.absence_status,notes=excluded.notes,updated_by=auth.uid(),row_version=public.distribution_driver_absences.row_version+1
  returning * into v_result;
  return to_jsonb(v_result);
end;
$$;

revoke all on function public.require_distribution_read_access(), public.require_distribution_plan_access(), public.require_distribution_master_access(), public.distribution_source_stops(date,uuid), public.sync_distribution_route_run_stops(uuid) from public, anon, authenticated;
revoke all on function public.get_distribution_operations_capabilities(), public.get_distribution_operations_dashboard(date), public.get_distribution_route_run_detail(uuid), public.save_distribution_route_run(jsonb), public.set_distribution_route_run_status(uuid,text,text), public.save_distribution_manual_stop(jsonb), public.set_distribution_stop_status(uuid,text,text), public.save_distribution_driver(jsonb), public.save_fleet_vehicle(jsonb), public.save_distribution_route(jsonb), public.save_fleet_vehicle_maintenance(jsonb), public.save_fleet_vehicle_defect(jsonb), public.save_distribution_driver_absence(jsonb) from public, anon;
grant execute on function public.get_distribution_operations_capabilities(), public.get_distribution_operations_dashboard(date), public.get_distribution_route_run_detail(uuid), public.save_distribution_route_run(jsonb), public.set_distribution_route_run_status(uuid,text,text), public.save_distribution_manual_stop(jsonb), public.set_distribution_stop_status(uuid,text,text), public.save_distribution_driver(jsonb), public.save_fleet_vehicle(jsonb), public.save_distribution_route(jsonb), public.save_fleet_vehicle_maintenance(jsonb), public.save_fleet_vehicle_defect(jsonb), public.save_distribution_driver_absence(jsonb) to authenticated;

comment on table public.distribution_route_runs is 'Daily operational Distribution execution. It never rewrites the published Customer Schedule.';
comment on table public.distribution_route_run_stops is 'Historical daily Route stop snapshot and reported outcome. Delivery reporting does not imply a physical trolley scan.';

commit;
