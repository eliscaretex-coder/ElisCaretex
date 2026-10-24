-- =====================================================================
-- ElisCaretex V2
-- Driver role transfer (Driver -> another job title)
--
-- Owner decision 2026-10-24. The reverse of the Staff -> Driver transfer:
-- * Distribution (Distribution MANAGE) starts it from the Drivers list:
--   Remove -> "Moving to another role", with the last day as a driver, the
--   new job title (short list) and a reason. Nothing changes yet.
-- * A manager approves it in Staff Master (Staff Master APPROVE: Production
--   Manager, General Manager or Administrator). A non-administrator can only
--   approve a job title below their own in the hierarchy. For a Production
--   job title the approver also sets the primary role, area, station, shift
--   and roster eligibility. The approver can also reject it.
-- * On approval the driver exit is scheduled on the last driver day, the
--   same way as Remove: pending leave after that day is cancelled and
--   published roster assignments after it are returned for reassignment.
--   The linked Staff Master record is NOT deactivated.
-- * The day after the last driver day (at approval when that day is already
--   past, otherwise by a daily job) the move is applied: the person's Staff
--   Master record is reused (or created, with a new employee code, when the
--   driver had none), set to the new role, the driver record is unlinked
--   from it, and an existing login gets the new job title with that job
--   title's standard permissions.
-- * Distribution or an approver can cancel an open transfer until it is
--   applied; an approved one also clears the scheduled driver exit.
--
-- Also fixes apply_staff_production_scope: on every update it turned
-- production_staff back to true when the record had a legacy id, role or
-- area, so the Staff -> Driver transfer never left Production (verified on
-- the live database: the completion job left production_staff = true with
-- the Driver role). The inference now applies to new records only.
-- =====================================================================

begin;

-- 1. Respect an explicit move out of Production.
create or replace function public.apply_staff_production_scope()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- Only a new record is inferred. On update the stored value wins, so a
  -- person moved out of Production keeps production_staff = false even
  -- though their record still carries a legacy id, role or area.
  if tg_op = 'INSERT'
     and new.production_staff = false
     and (
       new.legacy_user_id is not null
       or new.primary_operational_role_id is not null
       or new.default_area_id is not null
       or new.default_station_id is not null
     ) then
    new.production_staff := true;
  end if;

  if new.production_staff = false then
    new.roster_eligible := false;
  end if;

  return new;
end;
$$;

-- 2. The approved transfer is applied by a controlled function, sometimes by
--    an approver who holds Staff Master APPROVE but not CREATE or MANAGE.
create or replace function public.enforce_staff_master_write_permission()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_action text;
begin
  -- Trusted database maintenance and service operations do not carry an end
  -- user identity. Signed-in application RPC calls always carry auth.uid().
  if auth.uid() is null then
    return new;
  end if;

  -- Set only inside apply_driver_role_transfer, for the current transaction.
  if current_setting('eliscaretex.staff_write_context', true) = 'DRIVER_ROLE_TRANSFER' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_action := 'CREATE';
  elsif new.active is distinct from old.active
     or new.production_staff is distinct from old.production_staff
     or new.deleted_at is distinct from old.deleted_at then
    v_action := 'MANAGE';
  else
    v_action := 'EDIT';
  end if;

  if not public.staff_master_action_allowed(v_action) then
    raise exception using
      errcode = '42501',
      message = format('Your account does not have %s permission for Staff Master.', initcap(lower(v_action)));
  end if;

  return new;
end;
$$;

-- 3. Transfer requests.
create table if not exists public.distribution_driver_role_transfers (
  transfer_id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.distribution_drivers(driver_id) on delete restrict,
  staff_id uuid references public.staff_members(staff_id) on delete restrict,
  last_driver_day date not null,
  job_title_code text not null references public.account_job_titles(job_title_code) on delete restrict,
  reason text not null check (length(trim(reason)) > 0),
  transfer_status text not null default 'PENDING'
    check (transfer_status in ('PENDING', 'APPROVED', 'COMPLETED', 'REJECTED', 'CANCELLED')),
  primary_operational_role_id uuid references public.operational_roles(operational_role_id) on delete restrict,
  default_area_id uuid references public.areas(area_id) on delete restrict,
  default_station_id uuid references public.stations(station_id) on delete restrict,
  default_shift_id uuid references public.shifts(shift_id) on delete restrict,
  roster_eligible boolean,
  requested_by uuid references auth.users(id) on delete set null,
  requested_at timestamptz not null default now(),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  decision_note text,
  cancelled_by uuid references auth.users(id) on delete set null,
  cancelled_at timestamptz,
  cancel_reason text,
  applied_at timestamptz,
  account_job_title_updated boolean not null default false,
  row_version integer not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.distribution_driver_role_transfers is
  'Driver to another job title: requested by Distribution, approved by a manager in Staff Master, applied the day after the last driver day.';

create unique index if not exists distribution_driver_role_transfers_one_open
  on public.distribution_driver_role_transfers(driver_id)
  where transfer_status in ('PENDING', 'APPROVED');

create index if not exists distribution_driver_role_transfers_status_idx
  on public.distribution_driver_role_transfers(transfer_status, last_driver_day);

alter table public.distribution_driver_role_transfers enable row level security;
revoke all on public.distribution_driver_role_transfers from public, anon, authenticated;

drop trigger if exists distribution_driver_role_transfers_set_updated_at on public.distribution_driver_role_transfers;
create trigger distribution_driver_role_transfers_set_updated_at
before update on public.distribution_driver_role_transfers
for each row execute function public.set_updated_at();

-- 4. Job titles a driver can move to.
create or replace function public.driver_role_transfer_job_title_allowed(p_job_title_code text)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select upper(trim(coalesce(p_job_title_code, ''))) in (
    'GENERAL_OPERATIVE', 'LABEL_OPERATIVE', 'TEAM_LEADER', 'PRODUCTION_SUPERVISOR',
    'CLEANER', 'LOGISTICS_MANAGER', 'MAINTENANCE', 'PRODUCTION_MANAGER'
  )
$$;

revoke all on function public.driver_role_transfer_job_title_allowed(text) from public, anon, authenticated;

-- Staff Master APPROVE, and a non-administrator only below their own rank.
create or replace function public.driver_role_transfer_can_approve(p_job_title_code text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_my_rank integer;
  v_target_rank integer;
begin
  if auth.uid() is null or not public.staff_master_action_allowed('APPROVE') then
    return false;
  end if;
  if public.has_any_role(array['ADMIN']) then
    return true;
  end if;

  select jt.hierarchy_rank into v_my_rank
  from public.account_access_profiles ap
  join public.account_job_titles jt on jt.job_title_code = ap.job_title_code
  where ap.auth_user_id = auth.uid() and ap.account_type = 'USER';

  select jt.hierarchy_rank into v_target_rank
  from public.account_job_titles jt
  where jt.job_title_code = upper(trim(p_job_title_code));

  return v_my_rank is not null and v_target_rank is not null and v_my_rank < v_target_rank;
end;
$$;

revoke all on function public.driver_role_transfer_can_approve(text) from public, anon, authenticated;

create or replace function public.driver_role_transfer_json(p_transfer_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select jsonb_build_object(
    'transfer_id', t.transfer_id,
    'transfer_status', t.transfer_status,
    'driver_id', t.driver_id,
    'driver_code', d.driver_code,
    'driver_name', d.display_name,
    'driver_joined_on', d.joined_on,
    'staff_id', coalesce(t.staff_id, d.staff_id),
    'staff_employee_code', sm.employee_code,
    'staff_display_name', sm.display_name,
    'has_login', sm.auth_user_id is not null,
    'last_driver_day', t.last_driver_day,
    'effective_on', t.last_driver_day + 1,
    'job_title_code', t.job_title_code,
    'job_title_name', jt.job_title_name,
    'production_job_title', public.job_title_keeps_production_roster(t.job_title_code),
    'reason', t.reason,
    'primary_role_code', opr.role_code,
    'primary_role_name', opr.role_name,
    'default_area_code', a.area_code,
    'default_area_name', a.area_name,
    'default_station_code', st.station_code,
    'default_station_name', st.station_name,
    'default_shift_code', sh.shift_code,
    'default_shift_name', sh.shift_name,
    'roster_eligible', t.roster_eligible,
    'requested_at', t.requested_at,
    'requested_by_name', coalesce(rp.display_name, rq.email),
    'decided_at', t.decided_at,
    'decided_by_name', coalesce(dp.display_name, dq.email),
    'decision_note', t.decision_note,
    'cancelled_at', t.cancelled_at,
    'cancel_reason', t.cancel_reason,
    'applied_at', t.applied_at,
    'account_job_title_updated', t.account_job_title_updated,
    'row_version', t.row_version
  )
  from public.distribution_driver_role_transfers t
  join public.distribution_drivers d on d.driver_id = t.driver_id
  join public.account_job_titles jt on jt.job_title_code = t.job_title_code
  left join public.staff_members sm on sm.staff_id = coalesce(t.staff_id, d.staff_id)
  left join public.operational_roles opr on opr.operational_role_id = t.primary_operational_role_id
  left join public.areas a on a.area_id = t.default_area_id
  left join public.stations st on st.station_id = t.default_station_id
  left join public.shifts sh on sh.shift_id = t.default_shift_id
  left join public.account_access_profiles rp on rp.auth_user_id = t.requested_by
  left join auth.users rq on rq.id = t.requested_by
  left join public.account_access_profiles dp on dp.auth_user_id = t.decided_by
  left join auth.users dq on dq.id = t.decided_by
  where t.transfer_id = p_transfer_id
$$;

revoke all on function public.driver_role_transfer_json(uuid) from public, anon, authenticated;

-- 5. Distribution starts the transfer.
create or replace function public.request_driver_role_transfer(
  p_driver_id uuid,
  p_expected_row_version integer,
  p_last_driver_day date,
  p_job_title_code text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_driver public.distribution_drivers%rowtype;
  v_job_title text := upper(trim(coalesce(p_job_title_code, '')));
  v_transfer_id uuid;
begin
  perform public.require_distribution_master_access();

  if p_driver_id is null then
    raise exception using errcode = '22023', message = 'Driver is required.';
  end if;
  if p_last_driver_day is null then
    raise exception using errcode = '22023', message = 'The last day as a driver is required.';
  end if;
  if not public.driver_role_transfer_job_title_allowed(v_job_title)
     or not exists(select 1 from public.account_job_titles jt where jt.job_title_code = v_job_title and jt.active) then
    raise exception using errcode = '22023', message = 'Choose one of the job titles offered for a driver transfer.';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason for the transfer is required.';
  end if;

  select d.* into v_driver
  from public.distribution_drivers d
  where d.driver_id = p_driver_id and d.deleted_at is null
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Driver was not found.';
  end if;
  if p_expected_row_version is not null and v_driver.row_version <> p_expected_row_version then
    raise exception using errcode = '40001', message = 'This driver was changed by someone else. Reload and try again.';
  end if;
  if v_driver.employment_status = 'INACTIVE' then
    raise exception using errcode = '22023', message = 'This driver has already left. Reinstate them first.';
  end if;
  if v_driver.deactivated_on is not null then
    raise exception using errcode = '22023', message = 'This driver already has a scheduled exit. Cancel it first.';
  end if;
  if v_driver.joined_on is not null and p_last_driver_day < v_driver.joined_on then
    raise exception using errcode = '22023', message = 'The last day as a driver cannot be before the joining date.';
  end if;
  if exists(
    select 1 from public.staff_members sm
    where sm.staff_id = v_driver.staff_id and sm.auth_user_id = auth.uid()
  ) then
    raise exception using errcode = '42501', message = 'You cannot transfer your own driver record.';
  end if;
  if exists(
    select 1 from public.distribution_driver_role_transfers t
    where t.driver_id = p_driver_id and t.transfer_status in ('PENDING', 'APPROVED')
  ) then
    raise exception using errcode = '23505', message = 'This driver already has an open transfer.';
  end if;

  insert into public.distribution_driver_role_transfers(driver_id, staff_id, last_driver_day, job_title_code, reason, requested_by)
  values (p_driver_id, v_driver.staff_id, p_last_driver_day, v_job_title, trim(p_reason), auth.uid())
  returning transfer_id into v_transfer_id;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data, reason, source_application)
  values (
    auth.uid(), public.current_staff_id(), 'REQUEST_DRIVER_ROLE_TRANSFER',
    'distribution_driver_role_transfers', v_transfer_id::text,
    public.driver_role_transfer_json(v_transfer_id), trim(p_reason), 'DISTRIBUTION_UI'
  );

  return public.driver_role_transfer_json(v_transfer_id);
end;
$$;

revoke all on function public.request_driver_role_transfer(uuid, integer, date, text, text) from public, anon;
grant execute on function public.request_driver_role_transfer(uuid, integer, date, text, text) to authenticated;

-- 6. Applies an approved transfer. Internal: approval and the daily job only.
create or replace function public.apply_driver_role_transfer(p_transfer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_transfer public.distribution_driver_role_transfers%rowtype;
  v_driver public.distribution_drivers%rowtype;
  v_staff public.staff_members%rowtype;
  v_production boolean;
  v_staff_id uuid;
  v_created boolean := false;
  v_account_updated boolean := false;
  v_effective date;
begin
  select t.* into v_transfer
  from public.distribution_driver_role_transfers t
  where t.transfer_id = p_transfer_id
  for update;
  if not found or v_transfer.transfer_status <> 'APPROVED' or v_transfer.applied_at is not null then
    return null;
  end if;

  select d.* into v_driver from public.distribution_drivers d where d.driver_id = v_transfer.driver_id for update;
  v_production := public.job_title_keeps_production_roster(v_transfer.job_title_code);
  v_effective := v_transfer.last_driver_day + 1;
  v_staff_id := coalesce(v_driver.staff_id, v_transfer.staff_id);

  perform set_config('eliscaretex.staff_write_context', 'DRIVER_ROLE_TRANSFER', true);

  if v_staff_id is not null then
    select sm.* into v_staff from public.staff_members sm where sm.staff_id = v_staff_id and sm.deleted_at is null for update;
    if not found then
      v_staff_id := null;
    end if;
  end if;

  if v_staff_id is not null then
    update public.staff_members sm set
      active = true,
      deactivated_on = null,
      deactivation_reason = null,
      production_staff = v_production,
      roster_eligible = v_production and coalesce(v_transfer.roster_eligible, true),
      primary_operational_role_id = case when v_production then v_transfer.primary_operational_role_id else null end,
      default_area_id = case when v_production then v_transfer.default_area_id else null end,
      default_station_id = case when v_production then v_transfer.default_station_id else null end,
      default_shift_id = case when v_production then v_transfer.default_shift_id else null end,
      production_roster_until = null,
      updated_by = coalesce(auth.uid(), v_transfer.decided_by),
      row_version = sm.row_version + 1
    where sm.staff_id = v_staff_id;
  elsif v_production then
    insert into public.staff_members(
      employee_code, display_name, active, production_staff, roster_eligible,
      default_shift_id, primary_operational_role_id, default_area_id, default_station_id,
      joined_on, notes, row_version, created_by, updated_by
    )
    values (
      public.generate_staff_employee_code(), v_driver.display_name, true, true, coalesce(v_transfer.roster_eligible, true),
      v_transfer.default_shift_id, v_transfer.primary_operational_role_id, v_transfer.default_area_id, v_transfer.default_station_id,
      case when v_driver.joined_on <= v_effective then v_driver.joined_on else null end,
      format('Moved from Distribution driver %s on %s.', v_driver.driver_code, to_char(v_effective, 'DD Mon YYYY')),
      1, coalesce(auth.uid(), v_transfer.decided_by), coalesce(auth.uid(), v_transfer.decided_by)
    )
    returning staff_id into v_staff_id;
    v_created := true;
    select sm.* into v_staff from public.staff_members sm where sm.staff_id = v_staff_id;
  end if;

  -- The driver record stays as history; the person is no longer a driver.
  if v_driver.staff_id is not null then
    update public.distribution_drivers d set
      staff_id = null,
      updated_by = coalesce(auth.uid(), v_transfer.decided_by),
      row_version = d.row_version + 1
    where d.driver_id = v_driver.driver_id;
  end if;

  -- An existing login gets the new job title with its standard permissions,
  -- the same result as choosing that job title in Accounts & access.
  if v_staff.auth_user_id is not null and exists(
    select 1 from public.account_access_profiles ap
    where ap.auth_user_id = v_staff.auth_user_id and ap.account_type = 'USER'
  ) then
    update public.account_access_profiles ap set
      job_title_code = v_transfer.job_title_code,
      updated_at = now()
    where ap.auth_user_id = v_staff.auth_user_id and ap.account_type = 'USER';

    update public.account_permission_grants g set active = false, updated_at = now()
    where g.auth_user_id = v_staff.auth_user_id
      and g.active
      and not exists(
        select 1 from public.job_title_permission_templates t
        where t.job_title_code = v_transfer.job_title_code and t.module_code = g.module_code
      );

    insert into public.account_permission_grants(
      auth_user_id, module_code, access_scope, can_view, can_create, can_edit, can_approve, can_manage,
      effective_from, effective_until, active, granted_by_auth_user_id
    )
    select v_staff.auth_user_id, t.module_code, t.access_scope, t.can_view, t.can_create, t.can_edit, t.can_approve, t.can_manage,
      current_date, null, true, coalesce(auth.uid(), v_transfer.decided_by)
    from public.job_title_permission_templates t
    where t.job_title_code = v_transfer.job_title_code
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
    where ar.auth_user_id = v_staff.auth_user_id and ar.active;

    insert into public.account_roles(auth_user_id, role_id, active)
    select v_staff.auth_user_id, r.role_id, true
    from public.job_title_legacy_roles l
    join public.roles r on r.role_code = l.role_code and r.active
    where l.job_title_code = v_transfer.job_title_code
    on conflict (auth_user_id, role_id) do update set active = true;

    v_account_updated := true;
  end if;

  update public.distribution_driver_role_transfers t set
    transfer_status = 'COMPLETED',
    staff_id = v_staff_id,
    applied_at = now(),
    account_job_title_updated = v_account_updated,
    row_version = t.row_version + 1
  where t.transfer_id = p_transfer_id;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data, reason, source_application)
  values (
    auth.uid(), public.current_staff_id(), 'COMPLETE_DRIVER_ROLE_TRANSFER',
    'distribution_driver_role_transfers', p_transfer_id::text,
    public.driver_role_transfer_json(p_transfer_id) || jsonb_build_object('staff_created', v_created),
    format('Driver %s moved to %s from %s.', v_driver.driver_code, v_transfer.job_title_code, v_effective),
    case when auth.uid() is null then 'DRIVER_ROLE_TRANSFER_JOB' else 'STAFF_MASTER_UI' end
  );

  perform set_config('eliscaretex.staff_write_context', '', true);

  return jsonb_build_object('staff_id', v_staff_id, 'staff_created', v_created, 'account_job_title_updated', v_account_updated);
end;
$$;

revoke all on function public.apply_driver_role_transfer(uuid) from public, anon, authenticated;

-- 7. A manager approves.
create or replace function public.approve_driver_role_transfer(
  p_transfer_id uuid,
  p_expected_row_version integer,
  p_primary_role_code text,
  p_default_area_code text,
  p_default_station_code text,
  p_default_shift_code text,
  p_roster_eligible boolean,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_transfer public.distribution_driver_role_transfers%rowtype;
  v_before public.distribution_drivers%rowtype;
  v_driver public.distribution_drivers%rowtype;
  v_production boolean;
  v_defaults record;
  v_shift_id uuid;
  v_immediate boolean;
  v_cancelled_leave integer := 0;
  v_conflicts jsonb;
  v_applied jsonb;
  v_job_title_name text;
begin
  perform public.require_staff_master_read_role();

  select t.* into v_transfer
  from public.distribution_driver_role_transfers t
  where t.transfer_id = p_transfer_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Transfer was not found.';
  end if;
  if not public.driver_role_transfer_can_approve(v_transfer.job_title_code) then
    raise exception using errcode = '42501', message = 'Your account cannot approve a transfer to this job title.';
  end if;
  if v_transfer.transfer_status <> 'PENDING' then
    raise exception using errcode = '22023', message = 'This transfer is no longer waiting for approval.';
  end if;
  if p_expected_row_version is not null and v_transfer.row_version <> p_expected_row_version then
    raise exception using errcode = '40001', message = 'This transfer was changed by someone else. Reload and try again.';
  end if;

  select d.* into v_before
  from public.distribution_drivers d
  where d.driver_id = v_transfer.driver_id and d.deleted_at is null
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Driver was not found.';
  end if;
  if v_before.employment_status = 'INACTIVE' or v_before.deactivated_on is not null then
    raise exception using errcode = '22023', message = 'This driver already has a recorded exit in Distribution. Ask Distribution to cancel it or cancel this transfer.';
  end if;
  if exists(
    select 1 from public.staff_members sm
    where sm.staff_id = v_before.staff_id and sm.auth_user_id = auth.uid()
  ) then
    raise exception using errcode = '42501', message = 'You cannot approve your own transfer.';
  end if;

  v_production := public.job_title_keeps_production_roster(v_transfer.job_title_code);
  if v_production then
    select * into v_defaults from public.validate_staff_work_defaults(p_primary_role_code, p_default_area_code, p_default_station_code);
    if exists(select 1 from public.operational_roles r where r.operational_role_id = v_defaults.operational_role_id and r.role_code = 'DRIVER') then
      raise exception using errcode = '22023', message = 'Choose the new role, not Driver.';
    end if;
    if nullif(trim(p_default_shift_code), '') is not null then
      select s.shift_id into v_shift_id
      from public.shifts s
      where s.shift_code = upper(trim(p_default_shift_code)) and s.active and s.deleted_at is null;
      if v_shift_id is null then
        raise exception using errcode = '22023', message = 'Default shift is invalid or inactive.';
      end if;
    end if;
  end if;

  select jt.job_title_name into v_job_title_name from public.account_job_titles jt where jt.job_title_code = v_transfer.job_title_code;

  update public.distribution_driver_role_transfers t set
    transfer_status = 'APPROVED',
    primary_operational_role_id = case when v_production then v_defaults.operational_role_id else null end,
    default_area_id = case when v_production then v_defaults.area_id else null end,
    default_station_id = case when v_production then v_defaults.station_id else null end,
    default_shift_id = case when v_production then v_shift_id else null end,
    roster_eligible = case when v_production then coalesce(p_roster_eligible, true) else false end,
    decided_by = auth.uid(),
    decided_at = now(),
    decision_note = nullif(trim(p_note), ''),
    row_version = t.row_version + 1
  where t.transfer_id = p_transfer_id;

  -- Schedule the driver exit exactly like Remove, without touching Staff Master.
  v_immediate := v_transfer.last_driver_day <= current_date;

  update public.distribution_drivers d set
    deactivated_on = v_transfer.last_driver_day,
    deactivation_reason = format('Moved to %s: %s', v_job_title_name, v_transfer.reason),
    exit_recorded_at = now(),
    exit_recorded_by = auth.uid(),
    employment_status = case when v_immediate then 'INACTIVE' else d.employment_status end,
    availability_status = case when v_immediate then 'UNAVAILABLE' else d.availability_status end,
    updated_at = now(),
    updated_by = auth.uid(),
    row_version = d.row_version + 1
  where d.driver_id = v_transfer.driver_id
  returning * into v_driver;

  update public.distribution_driver_absences a set
    absence_status = 'CANCELLED',
    notes = concat_ws(' | ', nullif(a.notes, ''), format('Cancelled: driver moves to %s after %s.', v_job_title_name, v_transfer.last_driver_day)),
    updated_by = auth.uid(),
    row_version = a.row_version + 1
  where a.driver_id = v_transfer.driver_id and a.absence_status = 'REQUESTED' and a.starts_on > v_transfer.last_driver_day;
  get diagnostics v_cancelled_leave = row_count;

  select coalesce(jsonb_agg(jsonb_build_object(
      'work_date', e.work_date,
      'route_code', coalesce(r.route_code, e.route_code_snapshot),
      'role', case when e.primary_driver_id = v_transfer.driver_id then 'PRIMARY' else 'SUPPORT' end
    ) order by e.work_date, r.route_code), '[]'::jsonb)
    into v_conflicts
  from public.distribution_roster_entries e
  join public.distribution_roster_versions v on v.distribution_roster_version_id = e.distribution_roster_version_id
  left join public.distribution_routes r on r.route_id = e.route_id
  where v.roster_status = 'PUBLISHED'
    and e.assignment_status = 'PLANNED'
    and e.work_date > v_transfer.last_driver_day
    and v_transfer.driver_id in (e.primary_driver_id, e.support_driver_id);

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
  values (
    auth.uid(), public.current_staff_id(), 'APPROVE_DRIVER_ROLE_TRANSFER',
    'distribution_driver_role_transfers', p_transfer_id::text,
    jsonb_build_object('driver', to_jsonb(v_before)),
    public.driver_role_transfer_json(p_transfer_id) || jsonb_build_object('driver', to_jsonb(v_driver)),
    coalesce(nullif(trim(p_note), ''), v_transfer.reason), 'STAFF_MASTER_UI'
  );

  if v_transfer.last_driver_day < current_date then
    v_applied := public.apply_driver_role_transfer(p_transfer_id);
  end if;

  return public.driver_role_transfer_json(p_transfer_id) || jsonb_build_object(
    'applied_now', v_applied is not null,
    'staff_created', coalesce((v_applied ->> 'staff_created')::boolean, false),
    'cancelled_leave_requests', v_cancelled_leave,
    'published_roster_conflicts', v_conflicts
  );
end;
$$;

revoke all on function public.approve_driver_role_transfer(uuid, integer, text, text, text, text, boolean, text) from public, anon;
grant execute on function public.approve_driver_role_transfer(uuid, integer, text, text, text, text, boolean, text) to authenticated;

-- 8. A manager rejects.
create or replace function public.reject_driver_role_transfer(p_transfer_id uuid, p_expected_row_version integer, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_transfer public.distribution_driver_role_transfers%rowtype;
begin
  perform public.require_staff_master_read_role();

  if nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason for the rejection is required.';
  end if;

  select t.* into v_transfer from public.distribution_driver_role_transfers t where t.transfer_id = p_transfer_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Transfer was not found.';
  end if;
  if not public.driver_role_transfer_can_approve(v_transfer.job_title_code) then
    raise exception using errcode = '42501', message = 'Your account cannot decide a transfer to this job title.';
  end if;
  if v_transfer.transfer_status <> 'PENDING' then
    raise exception using errcode = '22023', message = 'This transfer is no longer waiting for approval.';
  end if;
  if p_expected_row_version is not null and v_transfer.row_version <> p_expected_row_version then
    raise exception using errcode = '40001', message = 'This transfer was changed by someone else. Reload and try again.';
  end if;

  update public.distribution_driver_role_transfers t set
    transfer_status = 'REJECTED',
    decided_by = auth.uid(),
    decided_at = now(),
    decision_note = trim(p_reason),
    row_version = t.row_version + 1
  where t.transfer_id = p_transfer_id;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data, reason, source_application)
  values (auth.uid(), public.current_staff_id(), 'REJECT_DRIVER_ROLE_TRANSFER', 'distribution_driver_role_transfers', p_transfer_id::text,
    public.driver_role_transfer_json(p_transfer_id), trim(p_reason), 'STAFF_MASTER_UI');

  return public.driver_role_transfer_json(p_transfer_id);
end;
$$;

revoke all on function public.reject_driver_role_transfer(uuid, integer, text) from public, anon;
grant execute on function public.reject_driver_role_transfer(uuid, integer, text) to authenticated;

-- 9. Distribution or an approver cancels an open transfer before it applies.
create or replace function public.cancel_driver_role_transfer(p_transfer_id uuid, p_expected_row_version integer, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_transfer public.distribution_driver_role_transfers%rowtype;
  v_driver_restored boolean := false;
  v_source text;
begin
  if nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason for cancelling the transfer is required.';
  end if;

  select t.* into v_transfer from public.distribution_driver_role_transfers t where t.transfer_id = p_transfer_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Transfer was not found.';
  end if;

  if public.account_module_allowed(array['DISTRIBUTION'], 'MANAGE', array['ADMIN', 'MANAGER', 'SUPERVISOR']) then
    v_source := 'DISTRIBUTION_UI';
  elsif public.driver_role_transfer_can_approve(v_transfer.job_title_code) then
    v_source := 'STAFF_MASTER_UI';
  else
    raise exception using errcode = '42501', message = 'Your account cannot cancel this transfer.';
  end if;

  if v_transfer.transfer_status not in ('PENDING', 'APPROVED') or v_transfer.applied_at is not null then
    raise exception using errcode = '22023', message = 'Only an open transfer can be cancelled.';
  end if;
  if p_expected_row_version is not null and v_transfer.row_version <> p_expected_row_version then
    raise exception using errcode = '40001', message = 'This transfer was changed by someone else. Reload and try again.';
  end if;

  -- An approved transfer scheduled the driver exit: clear it again.
  if v_transfer.transfer_status = 'APPROVED' then
    update public.distribution_drivers d set
      employment_status = case when d.employment_status = 'INACTIVE' then 'ACTIVE' else d.employment_status end,
      availability_status = case when d.employment_status = 'INACTIVE' then 'AVAILABLE' else d.availability_status end,
      deactivated_on = null,
      deactivation_reason = null,
      exit_recorded_at = null,
      exit_recorded_by = null,
      updated_at = now(),
      updated_by = auth.uid(),
      row_version = d.row_version + 1
    where d.driver_id = v_transfer.driver_id
      and d.deleted_at is null
      and d.deactivated_on = v_transfer.last_driver_day;
    v_driver_restored := found;
  end if;

  update public.distribution_driver_role_transfers t set
    transfer_status = 'CANCELLED',
    cancelled_by = auth.uid(),
    cancelled_at = now(),
    cancel_reason = trim(p_reason),
    row_version = t.row_version + 1
  where t.transfer_id = p_transfer_id;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data, reason, source_application)
  values (auth.uid(), public.current_staff_id(), 'CANCEL_DRIVER_ROLE_TRANSFER', 'distribution_driver_role_transfers', p_transfer_id::text,
    public.driver_role_transfer_json(p_transfer_id) || jsonb_build_object('driver_restored', v_driver_restored), trim(p_reason), v_source);

  return public.driver_role_transfer_json(p_transfer_id) || jsonb_build_object('driver_restored', v_driver_restored);
end;
$$;

revoke all on function public.cancel_driver_role_transfer(uuid, integer, text) from public, anon;
grant execute on function public.cancel_driver_role_transfer(uuid, integer, text) to authenticated;

-- 10. Staff Master list.
create or replace function public.get_driver_role_transfers(p_include_closed boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_staff_master_read_role();

  return jsonb_build_object(
    'business_date', current_date,
    'transfers', coalesce((
      select jsonb_agg(
        public.driver_role_transfer_json(t.transfer_id)
          || jsonb_build_object('can_decide', t.transfer_status = 'PENDING' and public.driver_role_transfer_can_approve(t.job_title_code),
                                'can_cancel', t.transfer_status in ('PENDING', 'APPROVED') and t.applied_at is null and public.driver_role_transfer_can_approve(t.job_title_code))
        order by case t.transfer_status when 'PENDING' then 0 when 'APPROVED' then 1 else 2 end, t.last_driver_day, t.requested_at)
      from public.distribution_driver_role_transfers t
      where t.transfer_status in ('PENDING', 'APPROVED')
         or (coalesce(p_include_closed, false) and t.updated_at >= now() - interval '90 days')
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_driver_role_transfers(boolean) from public, anon;
grant execute on function public.get_driver_role_transfers(boolean) to authenticated;

-- Job titles offered in the Distribution dialog.
create or replace function public.get_driver_role_transfer_job_titles()
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
      'job_title_code', jt.job_title_code,
      'job_title_name', jt.job_title_name,
      'production', public.job_title_keeps_production_roster(jt.job_title_code)
    ) order by jt.hierarchy_rank desc, jt.job_title_name)
    from public.account_job_titles jt
    where jt.active and public.driver_role_transfer_job_title_allowed(jt.job_title_code)
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.get_driver_role_transfer_job_titles() from public, anon;
grant execute on function public.get_driver_role_transfer_job_titles() to authenticated;

-- 11. Drivers list shows the open transfer.
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
        'staff_active', sm.active and sm.deleted_at is null,
        'role_transfer', (
          select jsonb_build_object(
            'transfer_id', t.transfer_id,
            'transfer_status', t.transfer_status,
            'last_driver_day', t.last_driver_day,
            'job_title_code', t.job_title_code,
            'job_title_name', jt.job_title_name,
            'reason', t.reason,
            'row_version', t.row_version
          )
          from public.distribution_driver_role_transfers t
          join public.account_job_titles jt on jt.job_title_code = t.job_title_code
          where t.driver_id = d.driver_id and t.transfer_status in ('PENDING', 'APPROVED')
          limit 1
        )
      ) order by lower(d.display_name), d.driver_code)
    from public.distribution_drivers d
    left join public.staff_members sm on sm.staff_id = d.staff_id
    where d.deleted_at is null
  ), '[]'::jsonb);
end;
$$;

-- 12. Daily job: apply approved transfers the day after the last driver day.
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
    where t.transfer_status = 'APPROVED' and t.applied_at is null and t.last_driver_day < current_date
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

do $$ begin
  if exists(select 1 from cron.job where jobname = 'driver-role-transfers') then perform cron.unschedule('driver-role-transfers'); end if;
  perform cron.schedule('driver-role-transfers', '8 0 * * *', $job$select public.process_driver_role_transfers();$job$);
end $$;

commit;
