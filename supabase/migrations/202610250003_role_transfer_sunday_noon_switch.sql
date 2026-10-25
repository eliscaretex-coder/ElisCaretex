-- Role transfers that start on a Monday switch on Sunday at 12:00 (Dublin).
--
-- Owner request 2026-10-25: Sunday is normally not a working day, so a person
-- who starts a new role on Monday must see the new roster on Sunday. Before,
-- the nightly jobs switched the login and Staff Master only after midnight,
-- so on Sunday a driver moving to Production still had only My Driver Roster,
-- and a Production staff member moving to Driver still had only My Roster.
--
-- Now:
-- * public.role_transfer_switch_at(first_day): Sunday 12:00 Dublin when the
--   first day is a Monday, otherwise 00:00 Dublin on the first day.
-- * Driver -> another job title (process_driver_role_transfers): applied from
--   that moment (login job title and permissions, Staff Master, driver unlink).
-- * Staff -> Driver (process_production_roster_exits): Staff Master moves to
--   Driver/Distribution from that moment, and a login with a Production job
--   title up to Team Leader now gets the Driver job title with its standard
--   permissions (My Driver Roster). Before, the login had to be changed by hand.
-- * Both jobs run every hour, so the switch happens within the hour after
--   12:00 on Sunday (or after midnight), whatever the summer/winter time.

begin;

-- 1. When a role transfer takes effect.
create or replace function public.role_transfer_switch_at(p_first_day date)
returns timestamptz
language sql
stable
set search_path = public, pg_temp
as $$
  select case
    when extract(isodow from p_first_day) = 1 then ((p_first_day - 1) + time '12:00') at time zone 'Europe/Dublin'
    else p_first_day::timestamp at time zone 'Europe/Dublin'
  end;
$$;

comment on function public.role_transfer_switch_at(date) is
  'Moment a role transfer takes effect: Sunday 12:00 Europe/Dublin when the first day of the new role is a Monday, otherwise 00:00 on the first day.';

-- 2. Give a login a job title with its standard permissions (internal),
--    the same result as choosing that job title in Accounts & access.
create or replace function public.apply_account_job_title_template(p_auth_user_id uuid, p_job_title_code text, p_actor uuid)
returns boolean
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if p_auth_user_id is null or not exists(
    select 1 from public.account_access_profiles ap
    where ap.auth_user_id = p_auth_user_id and ap.account_type = 'USER'
  ) then
    return false;
  end if;

  update public.account_access_profiles ap set
    job_title_code = p_job_title_code,
    updated_at = now()
  where ap.auth_user_id = p_auth_user_id and ap.account_type = 'USER';

  update public.account_permission_grants g set active = false, updated_at = now()
  where g.auth_user_id = p_auth_user_id
    and g.active
    and not exists(
      select 1 from public.job_title_permission_templates t
      where t.job_title_code = p_job_title_code and t.module_code = g.module_code
    );

  insert into public.account_permission_grants(
    auth_user_id, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage,
    effective_from, effective_until, active, granted_by_auth_user_id
  )
  select p_auth_user_id, t.module_code, t.access_scope, t.can_view, t.can_create, t.can_edit, t.can_approve, t.can_manage,
    current_date, null, true, p_actor
  from public.job_title_permission_templates t
  where t.job_title_code = p_job_title_code
  on conflict (auth_user_id, module_code) do update set
    access_scope = excluded.access_scope,
    can_view = excluded.can_view,
    can_create = excluded.can_create,
    can_edit = excluded.can_edit,
    can_approve = excluded.can_approve,
    can_manage = excluded.can_manage,
    effective_from = least(account_permission_grants.effective_from, current_date),
    effective_until = null,
    active = true,
    granted_by_auth_user_id = excluded.granted_by_auth_user_id,
    updated_at = now();

  update public.account_roles ar set active = false
  where ar.auth_user_id = p_auth_user_id and ar.active;

  insert into public.account_roles(auth_user_id, role_id, active)
  select p_auth_user_id, r.role_id, true
  from public.job_title_legacy_roles l
  join public.roles r on r.role_code = l.role_code and r.active
  where l.job_title_code = p_job_title_code
  on conflict (auth_user_id, role_id) do update set active = true;

  return true;
end;
$$;

revoke all on function public.apply_account_job_title_template(uuid, text, uuid) from public, anon, authenticated;

-- 3. Driver -> another job title: apply from the switch moment.
create or replace function public.process_driver_role_transfers()
returns integer
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_transfer record;
  v_count integer := 0;
begin
  for v_transfer in
    select t.transfer_id, t.last_driver_day, d.deactivated_on, d.deleted_at
    from public.distribution_driver_role_transfers t
    join public.distribution_drivers d on d.driver_id = t.driver_id
    where t.transfer_status = 'APPROVED' and t.applied_at is null
      and now() >= public.role_transfer_switch_at(t.last_driver_day + 1)
    order by t.last_driver_day
  loop
    -- The driver exit was cancelled or changed in Distribution: do not move the person.
    if v_transfer.deleted_at is not null or v_transfer.deactivated_on is distinct from v_transfer.last_driver_day then
      update public.distribution_driver_role_transfers t set
        transfer_status = 'CANCELLED',
        cancelled_at = now(),
        cancel_reason = 'The driver exit was changed in Distribution before the transfer date.',
        row_version = t.row_version + 1
      where t.transfer_id = v_transfer.transfer_id;
      insert into public.audit_log(action, entity_table, entity_id, new_data, reason, source_application)
      values ('CANCEL_DRIVER_ROLE_TRANSFER', 'distribution_driver_role_transfers', v_transfer.transfer_id::text,
        public.driver_role_transfer_json(v_transfer.transfer_id), 'The driver exit was changed in Distribution before the transfer date.', 'DRIVER_ROLE_TRANSFER_JOB');
    else
      perform public.apply_driver_role_transfer(v_transfer.transfer_id);
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.process_driver_role_transfers() from public, anon, authenticated;

-- 4. Staff -> Driver: move Staff Master and the login from the switch moment.
create or replace function public.process_production_roster_exits()
returns integer
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_driver_role_id uuid;
  v_distribution_area_id uuid;
  v_staff record;
  v_job_title_code text;
  v_account_updated boolean;
  v_count integer := 0;
begin
  select operational_role_id into v_driver_role_id from public.operational_roles
  where role_code='DRIVER' and active and allow_as_primary and deleted_at is null;
  select area_id into v_distribution_area_id from public.areas
  where area_code='DISTRIBUTION' and active and deleted_at is null;
  if v_driver_role_id is null or v_distribution_area_id is null then
    return 0;
  end if;

  for v_staff in
    select sm.staff_id, sm.auth_user_id, sm.production_roster_until
    from public.staff_members sm
    where sm.deleted_at is null
      and sm.production_roster_until is not null
      and now() >= public.role_transfer_switch_at(sm.production_roster_until + 1)
      and exists(select 1 from public.distribution_drivers d where d.staff_id=sm.staff_id and d.deleted_at is null)
      and (sm.roster_eligible or sm.default_shift_id is not null or sm.primary_operational_role_id is distinct from v_driver_role_id)
    for update
  loop
    update public.staff_members sm set
      production_staff=false, roster_eligible=false, default_shift_id=null,
      primary_operational_role_id=v_driver_role_id, default_area_id=v_distribution_area_id,
      default_station_id=null, row_version=sm.row_version+1
    where sm.staff_id=v_staff.staff_id;

    -- A login with a Production job title up to Team Leader becomes Driver
    -- (My Driver Roster). Supervisors and managers are left for Accounts & access.
    v_account_updated := false;
    v_job_title_code := null;
    select ap.job_title_code into v_job_title_code
    from public.account_access_profiles ap
    where ap.auth_user_id = v_staff.auth_user_id and ap.account_type = 'USER';
    if v_job_title_code is not null
       and v_job_title_code <> 'DRIVER'
       and public.job_title_keeps_production_roster(v_job_title_code)
       and exists(select 1 from public.account_job_titles jt where jt.job_title_code = v_job_title_code and jt.hierarchy_rank >= 60) then
      v_account_updated := public.apply_account_job_title_template(v_staff.auth_user_id, 'DRIVER', auth.uid());
    end if;

    insert into public.audit_log(action,entity_table,entity_id,new_data,reason,source_application)
    values ('COMPLETE_STAFF_TO_DRIVER_TRANSFER','staff_members',v_staff.staff_id::text,
      jsonb_build_object('production_roster_until',v_staff.production_roster_until,'primary_role_code','DRIVER','default_area_code','DISTRIBUTION','roster_eligible',false,
        'previous_job_title_code',v_job_title_code,'account_job_title_updated',v_account_updated),
      'Driver transfer completed after the last Production Roster week.','PRODUCTION_ROSTER_EXIT_JOB');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.process_production_roster_exits() from public, anon, authenticated;

-- 5. Run both jobs every hour.
do $$ begin
  if exists(select 1 from cron.job where jobname='production-roster-exits') then perform cron.unschedule('production-roster-exits'); end if;
  perform cron.schedule('production-roster-exits','7 * * * *',$job$select public.process_production_roster_exits();$job$);
  if exists(select 1 from cron.job where jobname='driver-role-transfers') then perform cron.unschedule('driver-role-transfers'); end if;
  perform cron.schedule('driver-role-transfers','8 * * * *',$job$select public.process_driver_role_transfers();$job$);
end $$;

commit;
