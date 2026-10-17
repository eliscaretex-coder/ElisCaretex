begin;

do $$
declare
  v_driver record;
  v_next integer;
begin
  perform pg_advisory_xact_lock(hashtext('distribution_driver_code'));
  select coalesce(max((regexp_match(driver_code, '^DRV-([0-9]+)$'))[1]::integer), 0)
    into v_next
  from public.distribution_drivers
  where driver_code ~ '^DRV-[0-9]+$';

  for v_driver in
    select driver_id
    from public.distribution_drivers
    where driver_code !~ '^DRV-[0-9]+$'
    order by created_at, driver_id
  loop
    v_next := v_next + 1;
    update public.distribution_drivers
       set driver_code = 'DRV-' || lpad(v_next::text, 3, '0'),
           updated_at = now()
     where driver_id = v_driver.driver_id;
  end loop;
end;
$$;

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
    select jsonb_agg(to_jsonb(d) order by lower(d.display_name), d.driver_code)
    from public.distribution_drivers d
    where d.deleted_at is null
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
  v_code text;
  v_next integer;
  v_result public.distribution_drivers%rowtype;
begin
  perform public.require_distribution_master_access();

  if nullif(trim(p_driver ->> 'display_name'), '') is null then
    raise exception using errcode = '22023', message = 'Driver name is required.';
  end if;

  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('distribution_driver_code'));
    select coalesce(max((regexp_match(driver_code, '^DRV-([0-9]+)$'))[1]::integer), 0) + 1
      into v_next
    from public.distribution_drivers
    where driver_code ~ '^DRV-[0-9]+$';
    v_code := 'DRV-' || lpad(v_next::text, 3, '0');
  else
    select driver_code into v_code
    from public.distribution_drivers
    where driver_id = v_id and deleted_at is null;
    if v_code is null then
      raise exception using errcode = 'P0002', message = 'Driver was not found.';
    end if;
  end if;

  insert into public.distribution_drivers(
    driver_id,staff_id,driver_code,display_name,phone,email,licence_number,
    licence_categories,licence_expires_on,cpc_expires_on,employment_status,
    availability_status,notes,created_by,updated_by
  ) values(
    coalesce(v_id,gen_random_uuid()),nullif(p_driver ->> 'staff_id','')::uuid,v_code,
    trim(p_driver ->> 'display_name'),nullif(p_driver ->> 'phone',''),
    nullif(p_driver ->> 'email',''),nullif(p_driver ->> 'licence_number',''),
    coalesce(array(select upper(jsonb_array_elements_text(coalesce(p_driver -> 'licence_categories','[]'::jsonb)))),array[]::text[]),
    nullif(p_driver ->> 'licence_expires_on','')::date,
    nullif(p_driver ->> 'cpc_expires_on','')::date,
    upper(coalesce(nullif(p_driver ->> 'employment_status',''),'ACTIVE')),
    upper(coalesce(nullif(p_driver ->> 'availability_status',''),'AVAILABLE')),
    nullif(p_driver ->> 'notes',''),auth.uid(),auth.uid()
  )
  on conflict (driver_id) do update set
    staff_id=excluded.staff_id,display_name=excluded.display_name,phone=excluded.phone,
    email=excluded.email,licence_number=excluded.licence_number,
    licence_categories=excluded.licence_categories,
    licence_expires_on=excluded.licence_expires_on,cpc_expires_on=excluded.cpc_expires_on,
    employment_status=excluded.employment_status,availability_status=excluded.availability_status,
    notes=excluded.notes,updated_by=auth.uid(),row_version=public.distribution_drivers.row_version+1
  returning * into v_result;

  return to_jsonb(v_result);
end;
$$;

revoke all on function public.get_distribution_driver_master() from public, anon;
grant execute on function public.get_distribution_driver_master() to authenticated;

commit;
