-- =====================================================================
-- ElisCaretex V2
-- Distribution driver and fleet master completion
--
-- * Driver records can be linked to a non-production Staff Master record
--   from Distribution. Production staff still move through the Staff
--   Master "Transfer to Driver" workflow.
-- * Driver and vehicle saves merge the submitted fields into the stored
--   record, so fields a screen does not send (Staff link, capacity m3,
--   odometer, notes) are no longer cleared on edit.
-- * Optional optimistic concurrency through row_version.
-- * get_fleet_vehicle_master returns full vehicle rows for the Fleet tab.
-- Missing master data stays a visible warning, never a save requirement.
-- =====================================================================

begin;

create or replace function public.get_distribution_driver_master()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_distribution_read_access();
  return coalesce((
    select jsonb_agg(
      to_jsonb(d) || jsonb_build_object(
        'staff_display_name', sm.display_name,
        'staff_employee_code', sm.employee_code,
        'staff_active', sm.active and sm.deleted_at is null
      ) order by lower(d.display_name), d.driver_code)
    from public.distribution_drivers d
    left join public.staff_members sm on sm.staff_id = d.staff_id
    where d.deleted_at is null
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_distribution_driver_staff_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_distribution_master_access();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'staff_id', sm.staff_id,
      'employee_code', sm.employee_code,
      'display_name', sm.display_name,
      'is_driver_role', coalesce(r.role_code = 'DRIVER', false),
      'linked_driver_id', d.driver_id
    ) order by coalesce(r.role_code = 'DRIVER', false) desc, lower(sm.display_name))
    from public.staff_members sm
    left join public.operational_roles r on r.operational_role_id = sm.primary_operational_role_id
    left join public.distribution_drivers d on d.staff_id = sm.staff_id and d.deleted_at is null
    where sm.deleted_at is null and sm.active and not sm.production_staff
  ), '[]'::jsonb);
end;
$$;

create or replace function public.save_distribution_driver(p_driver jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid := nullif(p_driver ->> 'driver_id','')::uuid;
  v_existing public.distribution_drivers%rowtype;
  v_payload jsonb;
  v_code text;
  v_next integer;
  v_staff_id uuid;
  v_staff public.staff_members%rowtype;
  v_result public.distribution_drivers%rowtype;
begin
  perform public.require_distribution_master_access();

  if v_id is not null then
    select d.* into v_existing
    from public.distribution_drivers d
    where d.driver_id = v_id and d.deleted_at is null
    for update;
    if not found then
      raise exception using errcode = 'P0002', message = 'Driver was not found.';
    end if;
    if nullif(p_driver ->> 'row_version','') is not null
       and (p_driver ->> 'row_version')::integer <> v_existing.row_version then
      raise exception using errcode = '40001', message = 'This driver was changed by someone else. Reload and try again.';
    end if;
    v_code := v_existing.driver_code;
    v_payload := to_jsonb(v_existing) || p_driver;
  else
    v_payload := p_driver;
  end if;

  if nullif(trim(v_payload ->> 'display_name'), '') is null then
    raise exception using errcode = '22023', message = 'Driver name is required.';
  end if;

  v_staff_id := nullif(v_payload ->> 'staff_id','')::uuid;
  if v_staff_id is not null and v_staff_id is distinct from v_existing.staff_id then
    select sm.* into v_staff
    from public.staff_members sm
    where sm.staff_id = v_staff_id and sm.deleted_at is null;
    if not found or not v_staff.active then
      raise exception using errcode = '22023', message = 'The selected Staff record is not active.';
    end if;
    if v_staff.production_staff then
      raise exception using errcode = '22023', message = 'This person is production staff. Use Transfer to Driver in Staff Master.';
    end if;
    if exists (
      select 1 from public.distribution_drivers d
      where d.staff_id = v_staff_id and d.deleted_at is null and d.driver_id is distinct from v_id
    ) then
      raise exception using errcode = '23505', message = 'The selected Staff record is already linked to another driver.';
    end if;
  end if;

  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('distribution_driver_code'));
    select coalesce(max((regexp_match(driver_code, '^DRV-([0-9]+)$'))[1]::integer), 0) + 1
      into v_next
    from public.distribution_drivers
    where driver_code ~ '^DRV-[0-9]+$';
    v_code := 'DRV-' || lpad(v_next::text, 3, '0');
  end if;

  insert into public.distribution_drivers(
    driver_id,staff_id,driver_code,display_name,phone,email,licence_number,
    licence_categories,licence_expires_on,cpc_expires_on,employment_status,
    availability_status,notes,created_by,updated_by
  ) values(
    coalesce(v_id,gen_random_uuid()),v_staff_id,v_code,
    trim(v_payload ->> 'display_name'),nullif(trim(v_payload ->> 'phone'),''),
    nullif(lower(trim(v_payload ->> 'email')),''),nullif(upper(trim(v_payload ->> 'licence_number')),''),
    coalesce(array(
      select distinct upper(trim(value))
      from jsonb_array_elements_text(coalesce(v_payload -> 'licence_categories','[]'::jsonb)) as value
      where nullif(trim(value),'') is not null
      order by 1
    ),array[]::text[]),
    nullif(v_payload ->> 'licence_expires_on','')::date,
    nullif(v_payload ->> 'cpc_expires_on','')::date,
    upper(coalesce(nullif(v_payload ->> 'employment_status',''),'ACTIVE')),
    upper(coalesce(nullif(v_payload ->> 'availability_status',''),'AVAILABLE')),
    nullif(trim(v_payload ->> 'notes'),''),auth.uid(),auth.uid()
  )
  on conflict (driver_id) do update set
    staff_id=excluded.staff_id,display_name=excluded.display_name,phone=excluded.phone,
    email=excluded.email,licence_number=excluded.licence_number,
    licence_categories=excluded.licence_categories,
    licence_expires_on=excluded.licence_expires_on,cpc_expires_on=excluded.cpc_expires_on,
    employment_status=excluded.employment_status,availability_status=excluded.availability_status,
    notes=excluded.notes,updated_at=now(),updated_by=auth.uid(),
    row_version=public.distribution_drivers.row_version+1
  returning * into v_result;

  return to_jsonb(v_result);
end;
$$;

create or replace function public.get_fleet_vehicle_master()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_distribution_read_access();
  return coalesce((
    select jsonb_agg(
      to_jsonb(f) || jsonb_build_object(
        'open_defect_count', (
          select count(*) from public.fleet_vehicle_defects fd
          where fd.vehicle_id = f.vehicle_id and fd.defect_status in ('OPEN','IN_REPAIR')
        )
      ) order by f.active desc, f.registration_number)
    from public.fleet_vehicles f
    where f.deleted_at is null
  ), '[]'::jsonb);
end;
$$;

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
    test_expires_on,service_due_on,odometer_km,notes,created_by,updated_by
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
    auth.uid(),auth.uid()
  )
  on conflict (vehicle_id) do update set
    registration_number=excluded.registration_number,display_name=excluded.display_name,
    vehicle_type=excluded.vehicle_type,capacity_kg=excluded.capacity_kg,capacity_m3=excluded.capacity_m3,
    capacity_trolleys=excluded.capacity_trolleys,operational_status=excluded.operational_status,
    active=excluded.active,road_tax_expires_on=excluded.road_tax_expires_on,
    insurance_expires_on=excluded.insurance_expires_on,test_expires_on=excluded.test_expires_on,
    service_due_on=excluded.service_due_on,odometer_km=excluded.odometer_km,notes=excluded.notes,
    updated_at=now(),updated_by=auth.uid(),row_version=public.fleet_vehicles.row_version+1
  returning * into v_result;

  return to_jsonb(v_result);
end;
$$;

revoke all on function public.get_distribution_driver_master() from public, anon;
revoke all on function public.get_distribution_driver_staff_options() from public, anon;
revoke all on function public.save_distribution_driver(jsonb) from public, anon;
revoke all on function public.get_fleet_vehicle_master() from public, anon;
revoke all on function public.save_fleet_vehicle(jsonb) from public, anon;
grant execute on function public.get_distribution_driver_master() to authenticated;
grant execute on function public.get_distribution_driver_staff_options() to authenticated;
grant execute on function public.save_distribution_driver(jsonb) to authenticated;
grant execute on function public.get_fleet_vehicle_master() to authenticated;
grant execute on function public.save_fleet_vehicle(jsonb) to authenticated;

commit;
