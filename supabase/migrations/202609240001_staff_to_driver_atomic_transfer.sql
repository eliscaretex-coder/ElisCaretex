-- Complete a production Staff Master to Distribution Driver transfer atomically.

create or replace function public.get_staff_driver_transfer_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_staff_master_manage_role();
  perform public.require_distribution_master_access();

  return jsonb_build_object(
    'drivers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'driver_id', d.driver_id,
        'driver_code', d.driver_code,
        'display_name', d.display_name,
        'phone', d.phone,
        'email', d.email,
        'licence_number', d.licence_number,
        'licence_categories', d.licence_categories,
        'licence_expires_on', d.licence_expires_on,
        'cpc_expires_on', d.cpc_expires_on,
        'notes', d.notes
      ) order by lower(d.display_name))
      from public.distribution_drivers d
      where d.deleted_at is null and d.staff_id is null
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.transfer_staff_to_distribution_driver(
  p_staff_id uuid,
  p_expected_row_version integer,
  p_existing_driver_id uuid,
  p_driver_code text,
  p_phone text,
  p_email text,
  p_licence_number text,
  p_licence_categories text[],
  p_licence_expires_on date,
  p_cpc_expires_on date,
  p_notes text,
  p_change_reason text,
  p_source_application text default 'STAFF_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff public.staff_members%rowtype;
  v_driver public.distribution_drivers%rowtype;
  v_driver_role_id uuid;
  v_distribution_area_id uuid;
  v_deleted_drafts integer := 0;
begin
  perform public.require_staff_master_manage_role();
  perform public.require_distribution_master_access();

  if nullif(trim(p_driver_code), '') is null
     or nullif(trim(p_phone), '') is null
     or nullif(trim(p_licence_number), '') is null
     or coalesce(array_length(p_licence_categories, 1), 0) = 0
     or p_licence_expires_on is null
     or p_cpc_expires_on is null then
    raise exception using errcode='22023', message='Driver code, phone, licence number, licence category, licence expiry and CPC expiry are required.';
  end if;
  if nullif(trim(p_change_reason), '') is null then
    raise exception using errcode='22023', message='A transfer reason is required.';
  end if;

  select sm.* into v_staff
  from public.staff_members sm
  where sm.staff_id=p_staff_id and sm.deleted_at is null
  for update;
  if not found then raise exception using errcode='P0002', message='Staff member not found.'; end if;
  if v_staff.row_version <> p_expected_row_version then
    raise exception using errcode='40001', message='Staff record changed in another session. Reload before saving.';
  end if;
  if not v_staff.production_staff then
    raise exception using errcode='22023', message='This staff member has already left the Production Staff Master.';
  end if;

  select operational_role_id into v_driver_role_id from public.operational_roles
  where role_code='DRIVER' and active and allow_as_primary and deleted_at is null;
  select area_id into v_distribution_area_id from public.areas
  where area_code='DISTRIBUTION' and active and deleted_at is null;
  if v_driver_role_id is null or v_distribution_area_id is null then
    raise exception using errcode='22023', message='Driver role or Distribution area is not configured.';
  end if;

  if exists(select 1 from public.distribution_drivers d where d.staff_id=p_staff_id and d.deleted_at is null) then
    raise exception using errcode='23505', message='This staff member is already linked to a Driver record.';
  end if;

  if p_existing_driver_id is not null then
    select d.* into v_driver from public.distribution_drivers d
    where d.driver_id=p_existing_driver_id and d.deleted_at is null for update;
    if not found then raise exception using errcode='P0002', message='Selected Driver record was not found.'; end if;
    if v_driver.staff_id is not null then raise exception using errcode='23505', message='Selected Driver is already linked to another staff member.'; end if;
    update public.distribution_drivers d set
      staff_id=p_staff_id, driver_code=upper(trim(p_driver_code)), display_name=v_staff.display_name,
      phone=trim(p_phone), email=nullif(trim(p_email),''), licence_number=trim(p_licence_number),
      licence_categories=p_licence_categories, licence_expires_on=p_licence_expires_on,
      cpc_expires_on=p_cpc_expires_on, notes=nullif(trim(p_notes),''),
      employment_status='ACTIVE', availability_status='AVAILABLE', updated_by=auth.uid(), row_version=d.row_version+1
    where d.driver_id=p_existing_driver_id returning * into v_driver;
  else
    insert into public.distribution_drivers(
      staff_id,driver_code,display_name,phone,email,licence_number,licence_categories,
      licence_expires_on,cpc_expires_on,employment_status,availability_status,notes,created_by,updated_by
    ) values (
      p_staff_id,upper(trim(p_driver_code)),v_staff.display_name,trim(p_phone),nullif(trim(p_email),''),
      trim(p_licence_number),p_licence_categories,p_licence_expires_on,p_cpc_expires_on,
      'ACTIVE','AVAILABLE',nullif(trim(p_notes),''),auth.uid(),auth.uid()
    ) returning * into v_driver;
  end if;

  update public.staff_members sm set
    production_staff=false, roster_eligible=false, default_shift_id=null,
    primary_operational_role_id=v_driver_role_id, default_area_id=v_distribution_area_id,
    default_station_id=null, row_version=sm.row_version+1, updated_by=auth.uid()
  where sm.staff_id=p_staff_id;

  with removed as (
    delete from public.production_roster_entries pre
    using public.production_roster_versions prv, public.roster_periods rp
    where pre.roster_version_id=prv.roster_version_id
      and prv.roster_period_id=rp.roster_period_id
      and pre.staff_id=p_staff_id and prv.status='DRAFT'
      and rp.week_start>=public.production_roster_week_start(current_date)
    returning pre.roster_version_id
  ), touched as (
    select distinct roster_version_id from removed
  )
  update public.production_roster_versions prv set
    row_version=prv.row_version+1, saved_at=now(), saved_by=auth.uid(), updated_by=auth.uid()
  where prv.roster_version_id in (select roster_version_id from touched);
  get diagnostics v_deleted_drafts=row_count;

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),public.current_staff_id(),'TRANSFER_STAFF_TO_DRIVER','staff_members',p_staff_id::text,
    to_jsonb(v_staff),jsonb_build_object('driver_id',v_driver.driver_id,'driver_code',v_driver.driver_code,'production_staff',false),
    trim(p_change_reason),coalesce(nullif(trim(p_source_application),''),'STAFF_MASTER_UI'));

  return jsonb_build_object('staff_id',p_staff_id,'driver_id',v_driver.driver_id,'driver_code',v_driver.driver_code,'draft_rosters_updated',v_deleted_drafts);
end;
$$;

revoke all on function public.get_staff_driver_transfer_options() from public, anon;
revoke all on function public.transfer_staff_to_distribution_driver(uuid,integer,uuid,text,text,text,text,text[],date,date,text,text,text) from public, anon;
grant execute on function public.get_staff_driver_transfer_options() to authenticated;
grant execute on function public.transfer_staff_to_distribution_driver(uuid,integer,uuid,text,text,text,text,text[],date,date,text,text,text) to authenticated;
