-- Transfer to Driver keeps the current Production Roster week.
--
-- Same rule as 202610230002 for job titles: a staff member transferred to
-- Driver stays in the current roster week and is left out of later weeks.
-- The transfer now creates or links the Driver record and sets
-- staff_members.production_roster_until; the Staff Master record keeps its
-- Production role, area, shift and roster eligibility until that date. A daily
-- job then completes the move (Driver role, Distribution area, no shift, not
-- roster-eligible), as the transfer did immediately before.

begin;

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
  v_until date := public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 6;
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

  -- The staff member stays in Production until the end of the current roster
  -- week. process_production_roster_exits() moves the Staff Master record to
  -- Driver/Distribution after that week.
  update public.staff_members sm set
    production_roster_until=least(coalesce(sm.production_roster_until, v_until), v_until),
    row_version=sm.row_version+1, updated_by=auth.uid()
  where sm.staff_id=p_staff_id;

  with removed as (
    delete from public.production_roster_entries pre
    using public.production_roster_versions prv, public.roster_periods rp
    where pre.roster_version_id=prv.roster_version_id
      and prv.roster_period_id=rp.roster_period_id
      and pre.staff_id=p_staff_id and prv.status='DRAFT'
      and rp.week_start>v_until
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
    to_jsonb(v_staff),jsonb_build_object('driver_id',v_driver.driver_id,'driver_code',v_driver.driver_code,'production_roster_until',v_until),
    trim(p_change_reason),coalesce(nullif(trim(p_source_application),''),'STAFF_MASTER_UI'));

  return jsonb_build_object('staff_id',p_staff_id,'driver_id',v_driver.driver_id,'driver_code',v_driver.driver_code,'draft_rosters_updated',v_deleted_drafts,'production_roster_until',v_until);
end;
$$;


-- A job title sync must not bring a transferred driver back to Production.
create or replace function public.sync_staff_production_roster_exit(p_staff_id uuid, p_source_application text)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff public.staff_members%rowtype;
  v_job_title_code text;
  v_until date := public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 6;
  v_drafts_updated integer := 0;
begin
  select sm.* into v_staff
  from public.staff_members sm
  where sm.staff_id = p_staff_id
    and sm.deleted_at is null
  for update;

  if not found or v_staff.auth_user_id is null then
    return;
  end if;

  select ap.job_title_code into v_job_title_code
  from public.account_access_profiles ap
  where ap.auth_user_id = v_staff.auth_user_id
    and ap.account_type = 'USER';

  if not public.job_title_keeps_production_roster(v_job_title_code) then
    if v_staff.production_roster_until is not null or v_staff.production_staff is not true then
      return;
    end if;

    update public.staff_members sm
    set production_roster_until = v_until,
        row_version = sm.row_version + 1,
        updated_by = auth.uid()
    where sm.staff_id = p_staff_id;

    delete from public.production_roster_shift_overrides pro
    using public.production_roster_versions prv, public.roster_periods rp
    where pro.roster_version_id = prv.roster_version_id
      and prv.roster_period_id = rp.roster_period_id
      and pro.staff_id = p_staff_id
      and prv.status = 'DRAFT'
      and rp.week_start > v_until;

    with removed as (
      delete from public.production_roster_entries pre
      using public.production_roster_versions prv, public.roster_periods rp
      where pre.roster_version_id = prv.roster_version_id
        and prv.roster_period_id = rp.roster_period_id
        and pre.staff_id = p_staff_id
        and prv.status = 'DRAFT'
        and rp.week_start > v_until
      returning pre.roster_version_id
    )
    update public.production_roster_versions prv
    set row_version = prv.row_version + 1,
        saved_at = now(),
        saved_by = auth.uid(),
        updated_by = auth.uid()
    where prv.roster_version_id in (select distinct roster_version_id from removed);
    get diagnostics v_drafts_updated = row_count;

    insert into public.audit_log (actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
    values (
      auth.uid(), public.current_staff_id(), 'STAFF_PRODUCTION_ROSTER_EXIT_SET', 'staff_members', p_staff_id::text,
      jsonb_build_object('production_roster_until', null),
      jsonb_build_object('production_roster_until', v_until, 'job_title_code', v_job_title_code, 'future_drafts_updated', v_drafts_updated),
      'Job title moved out of Production: kept in the current roster week, left out of later weeks.',
      coalesce(nullif(trim(p_source_application), ''), 'ACCOUNT_JOB_TITLE')
    );
  elsif v_staff.production_roster_until is not null
    and not exists(select 1 from public.distribution_drivers d where d.staff_id = p_staff_id and d.deleted_at is null) then
    update public.staff_members sm
    set production_roster_until = null,
        row_version = sm.row_version + 1,
        updated_by = auth.uid()
    where sm.staff_id = p_staff_id;

    insert into public.audit_log (actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
    values (
      auth.uid(), public.current_staff_id(), 'STAFF_PRODUCTION_ROSTER_EXIT_CLEARED', 'staff_members', p_staff_id::text,
      jsonb_build_object('production_roster_until', v_staff.production_roster_until),
      jsonb_build_object('production_roster_until', null, 'job_title_code', v_job_title_code),
      'Job title moved back to Production: the staff member returns to future Production Rosters.',
      coalesce(nullif(trim(p_source_application), ''), 'ACCOUNT_JOB_TITLE')
    );
  end if;
end;
$$;

create or replace function public.process_production_roster_exits()
returns integer
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  v_driver_role_id uuid;
  v_distribution_area_id uuid;
  v_count integer := 0;
begin
  select operational_role_id into v_driver_role_id from public.operational_roles
  where role_code='DRIVER' and active and allow_as_primary and deleted_at is null;
  select area_id into v_distribution_area_id from public.areas
  where area_code='DISTRIBUTION' and active and deleted_at is null;
  if v_driver_role_id is null or v_distribution_area_id is null then
    return 0;
  end if;

  with moved as (
    update public.staff_members sm set
      production_staff=false, roster_eligible=false, default_shift_id=null,
      primary_operational_role_id=v_driver_role_id, default_area_id=v_distribution_area_id,
      default_station_id=null, row_version=sm.row_version+1
    where sm.deleted_at is null
      and sm.production_roster_until < v_today
      and exists(select 1 from public.distribution_drivers d where d.staff_id=sm.staff_id and d.deleted_at is null)
      and (sm.roster_eligible or sm.default_shift_id is not null or sm.primary_operational_role_id is distinct from v_driver_role_id)
    returning sm.staff_id, sm.production_roster_until
  )
  insert into public.audit_log(action,entity_table,entity_id,new_data,reason,source_application)
  select 'COMPLETE_STAFF_TO_DRIVER_TRANSFER','staff_members',m.staff_id::text,
    jsonb_build_object('production_roster_until',m.production_roster_until,'primary_role_code','DRIVER','default_area_code','DISTRIBUTION','roster_eligible',false),
    'Driver transfer completed after the last Production Roster week.','PRODUCTION_ROSTER_EXIT_JOB'
  from moved m;
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;

revoke all on function public.process_production_roster_exits() from public, anon, authenticated;

do $$ begin
  if exists(select 1 from cron.job where jobname='production-roster-exits') then perform cron.unschedule('production-roster-exits'); end if;
  perform cron.schedule('production-roster-exits','7 0 * * *',$job$select public.process_production_roster_exits();$job$);
end $$;

commit;
