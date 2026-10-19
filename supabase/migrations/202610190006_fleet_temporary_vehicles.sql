-- =====================================================================
-- ElisCaretex V2
-- Fleet: temporary (short hire) vehicles
--
-- Owner request (2026-10-19): most trucks are hired, and temporary trucks
-- come and go. A temporary vehicle needs only what the operation uses:
-- registration, type, capacity, the hire company and the date it leaves.
-- * Documents and other registration details are not asked for and do not
--   count as missing (the hire company is responsible for them).
-- * After its "available until" date the vehicle cannot be selected in the
--   roster or on a daily route; Fleet asks to mark it inactive.
-- =====================================================================

begin;

alter table public.fleet_vehicles add column if not exists is_temporary boolean not null default false;
alter table public.fleet_vehicles add column if not exists available_until date;
alter table public.fleet_vehicles add column if not exists hire_company text;

create or replace function public.distribution_vehicle_block_reason(p_vehicle_id uuid, p_work_date date)
returns text
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v public.fleet_vehicles%rowtype;
  v_item record;
begin
  select * into v from public.fleet_vehicles where vehicle_id = p_vehicle_id and deleted_at is null;
  if v.vehicle_id is null then return 'Vehicle not found'; end if;
  if not v.active then return 'Inactive vehicle'; end if;
  if v.is_temporary and v.available_until is not null and p_work_date > v.available_until then
    return 'Temporary vehicle, hire ended '||to_char(v.available_until, 'DD Mon');
  end if;
  if coalesce(v.operational_status, '') <> 'AVAILABLE' then
    return case v.operational_status when 'MAINTENANCE' then 'In maintenance' else 'Out of service' end
      || ' (set in the vehicle record)';
  end if;

  select * into v_item from (
    select 'Off road: '||d.defect_category as label, d.reported_on::date as starts_on, d.expected_return_on
    from public.fleet_vehicle_defects d
    where d.vehicle_id = p_vehicle_id and d.defect_status in ('OPEN', 'IN_REPAIR') and d.vehicle_condition = 'OFF_ROAD'
    union all
    select 'In maintenance: '||m.maintenance_type, m.starts_on, m.expected_return_on
    from public.fleet_vehicle_maintenance m
    where m.vehicle_id = p_vehicle_id and m.maintenance_status in ('PLANNED', 'IN_PROGRESS')
  ) x
  where x.starts_on <= p_work_date
    and (x.expected_return_on is null
      or p_work_date < x.expected_return_on
      or (p_work_date = current_date and current_date >= x.expected_return_on))
  order by x.expected_return_on nulls first
  limit 1;

  if found then
    if v_item.expected_return_on is null then return v_item.label||' (no return date)'; end if;
    if p_work_date >= v_item.expected_return_on then
      return v_item.label||', return overdue since '||to_char(v_item.expected_return_on, 'DD Mon')||'. Record the return in Fleet';
    end if;
    return v_item.label||', back '||to_char(v_item.expected_return_on, 'DD Mon');
  end if;
  return null;
end;
$$;

revoke all on function public.distribution_vehicle_block_reason(uuid, date) from public, anon, authenticated;

create or replace function public.save_fleet_vehicle(p_vehicle jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid := nullif(p_vehicle ->> 'vehicle_id','')::uuid;
  v_existing public.fleet_vehicles%rowtype;
  v_payload jsonb;
  v_registration text;
  v_result public.fleet_vehicles%rowtype;
begin
  perform public.require_distribution_master_access();

  if v_id is not null then
    select f.* into v_existing
    from public.fleet_vehicles f
    where f.vehicle_id = v_id and f.deleted_at is null
    for update;
    if not found then
      raise exception using errcode = 'P0002', message = 'Vehicle was not found.';
    end if;
    if nullif(p_vehicle ->> 'row_version','') is not null
       and (p_vehicle ->> 'row_version')::integer <> v_existing.row_version then
      raise exception using errcode = '40001', message = 'This vehicle was changed by someone else. Reload and try again.';
    end if;
    v_payload := to_jsonb(v_existing) || p_vehicle;
  else
    v_payload := p_vehicle;
  end if;

  v_registration := upper(regexp_replace(coalesce(v_payload ->> 'registration_number',''), '\s+', '', 'g'));
  if v_registration = '' then
    raise exception using errcode = '22023', message = 'Vehicle registration is required.';
  end if;
  if exists (
    select 1 from public.fleet_vehicles f
    where f.registration_number = v_registration and f.vehicle_id is distinct from v_id
  ) then
    raise exception using errcode = '23505', message = format('Registration %s is already recorded for another vehicle.', v_registration);
  end if;

  insert into public.fleet_vehicles(
    vehicle_id,registration_number,display_name,vehicle_type,capacity_kg,capacity_m3,
    capacity_trolleys,operational_status,active,road_tax_expires_on,insurance_expires_on,
    test_expires_on,service_due_on,odometer_km,notes,is_temporary,available_until,hire_company,created_by,updated_by
  ) values(
    coalesce(v_id,gen_random_uuid()),v_registration,nullif(trim(v_payload ->> 'display_name'),''),
    upper(coalesce(nullif(v_payload ->> 'vehicle_type',''),'TRUCK')),
    nullif(v_payload ->> 'capacity_kg','')::numeric,nullif(v_payload ->> 'capacity_m3','')::numeric,
    nullif(v_payload ->> 'capacity_trolleys','')::integer,
    upper(coalesce(nullif(v_payload ->> 'operational_status',''),'AVAILABLE')),
    coalesce(nullif(v_payload ->> 'active','')::boolean,true),
    nullif(v_payload ->> 'road_tax_expires_on','')::date,nullif(v_payload ->> 'insurance_expires_on','')::date,
    nullif(v_payload ->> 'test_expires_on','')::date,nullif(v_payload ->> 'service_due_on','')::date,
    nullif(v_payload ->> 'odometer_km','')::numeric,nullif(trim(v_payload ->> 'notes'),''),
    coalesce(nullif(v_payload ->> 'is_temporary','')::boolean,false),
    case when coalesce(nullif(v_payload ->> 'is_temporary','')::boolean,false) then nullif(v_payload ->> 'available_until','')::date end,
    nullif(trim(v_payload ->> 'hire_company'),''),
    auth.uid(),auth.uid()
  )
  on conflict (vehicle_id) do update set
    registration_number=excluded.registration_number,display_name=excluded.display_name,
    vehicle_type=excluded.vehicle_type,capacity_kg=excluded.capacity_kg,capacity_m3=excluded.capacity_m3,
    capacity_trolleys=excluded.capacity_trolleys,operational_status=excluded.operational_status,
    active=excluded.active,road_tax_expires_on=excluded.road_tax_expires_on,
    insurance_expires_on=excluded.insurance_expires_on,test_expires_on=excluded.test_expires_on,
    service_due_on=excluded.service_due_on,odometer_km=excluded.odometer_km,notes=excluded.notes,
    is_temporary=excluded.is_temporary,available_until=excluded.available_until,hire_company=excluded.hire_company,
    updated_at=now(),updated_by=auth.uid(),row_version=public.fleet_vehicles.row_version+1
  returning * into v_result;

  return to_jsonb(v_result) || jsonb_build_object('roster_conflicts', public.fleet_vehicle_roster_conflicts(v_result.vehicle_id));
end;
$$;

revoke all on function public.save_fleet_vehicle(jsonb) from public, anon;
grant execute on function public.save_fleet_vehicle(jsonb) to authenticated;

commit;
