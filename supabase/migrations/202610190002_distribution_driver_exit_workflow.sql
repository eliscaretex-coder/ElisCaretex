-- =====================================================================
-- ElisCaretex V2
-- Distribution driver exit workflow (Remove / Reinstate)
--
-- Mirrors the Staff Master deactivation: a driver leaves the company on a
-- recorded last working day with a mandatory reason. Nothing is deleted.
-- * Exit today or in the past: the driver becomes INACTIVE at once.
-- * Future exit: the date is scheduled and a daily job deactivates the
--   driver the day after the last working day.
-- * A linked non-production Staff Master record follows the same exit, so
--   the person's system access ends with the driver record (the existing
--   staff-scheduled-deactivation job handles future dates).
-- * Pending (REQUESTED) leave starting after the exit date is cancelled.
-- * Published roster assignments after the exit date are never changed;
--   they are returned so the planner can reassign them.
-- * Every exit and reinstatement is written to audit_log with its reason,
--   and the distribution_master_events trigger keeps the field history.
-- * save_distribution_driver can no longer switch a driver to or from
--   INACTIVE, so an exit always carries a date and a reason.
--
-- joined_on, deactivated_on and roster_hidden already exist on the live
-- table (added outside migration files); they are declared here with
-- "if not exists" so the repository matches the database.
-- =====================================================================

begin;

alter table public.distribution_drivers
  add column if not exists joined_on date,
  add column if not exists deactivated_on date,
  add column if not exists roster_hidden boolean not null default false,
  add column if not exists deactivation_reason text,
  add column if not exists exit_recorded_at timestamptz,
  add column if not exists exit_recorded_by uuid references auth.users(id) on delete set null;

create or replace function public.remove_distribution_driver(
  p_driver_id uuid,
  p_expected_row_version integer,
  p_exit_on date,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before public.distribution_drivers%rowtype;
  v_driver public.distribution_drivers%rowtype;
  v_staff public.staff_members%rowtype;
  v_immediate boolean;
  v_staff_updated boolean := false;
  v_cancelled_leave integer := 0;
  v_conflicts jsonb;
begin
  perform public.require_distribution_master_access();

  if p_driver_id is null then
    raise exception using errcode = '22023', message = 'Driver is required.';
  end if;
  if p_exit_on is null then
    raise exception using errcode = '22023', message = 'The last working day is required.';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason for the exit is required.';
  end if;

  select d.* into v_before
  from public.distribution_drivers d
  where d.driver_id = p_driver_id and d.deleted_at is null
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Driver was not found.';
  end if;
  if p_expected_row_version is not null and v_before.row_version <> p_expected_row_version then
    raise exception using errcode = '40001', message = 'This driver was changed by someone else. Reload and try again.';
  end if;
  if v_before.employment_status = 'INACTIVE' then
    raise exception using errcode = '22023', message = 'This driver has already left the company.';
  end if;
  if v_before.joined_on is not null and p_exit_on < v_before.joined_on then
    raise exception using errcode = '22023', message = 'The last working day cannot be before the joining date.';
  end if;

  if v_before.staff_id is not null then
    select sm.* into v_staff from public.staff_members sm where sm.staff_id = v_before.staff_id for update;
    if v_staff.auth_user_id is not null and v_staff.auth_user_id = auth.uid() then
      raise exception using errcode = '42501', message = 'You cannot remove your own driver record.';
    end if;
  end if;

  v_immediate := p_exit_on <= current_date;

  update public.distribution_drivers d set
    deactivated_on = p_exit_on,
    deactivation_reason = trim(p_reason),
    exit_recorded_at = now(),
    exit_recorded_by = auth.uid(),
    employment_status = case when v_immediate then 'INACTIVE' else d.employment_status end,
    availability_status = case when v_immediate then 'UNAVAILABLE' else d.availability_status end,
    updated_at = now(),
    updated_by = auth.uid(),
    row_version = d.row_version + 1
  where d.driver_id = p_driver_id
  returning * into v_driver;

  if v_staff.staff_id is not null and not v_staff.production_staff and v_staff.deleted_at is null and v_staff.active then
    update public.staff_members sm set
      active = not v_immediate,
      roster_eligible = case when v_immediate then false else sm.roster_eligible end,
      deactivated_on = p_exit_on,
      deactivation_reason = 'Driver exit: ' || trim(p_reason),
      updated_by = auth.uid(),
      row_version = sm.row_version + 1
    where sm.staff_id = v_staff.staff_id;
    v_staff_updated := true;
  end if;

  update public.distribution_driver_absences a set
    absence_status = 'CANCELLED',
    notes = concat_ws(' | ', nullif(a.notes, ''), format('Cancelled: driver leaves the company on %s.', p_exit_on)),
    updated_by = auth.uid(),
    row_version = a.row_version + 1
  where a.driver_id = p_driver_id and a.absence_status = 'REQUESTED' and a.starts_on > p_exit_on;
  get diagnostics v_cancelled_leave = row_count;

  select coalesce(jsonb_agg(jsonb_build_object(
      'work_date', e.work_date,
      'route_code', coalesce(r.route_code, e.route_code_snapshot),
      'role', case when e.primary_driver_id = p_driver_id then 'PRIMARY' else 'SUPPORT' end
    ) order by e.work_date, r.route_code), '[]'::jsonb)
    into v_conflicts
  from public.distribution_roster_entries e
  join public.distribution_roster_versions v on v.distribution_roster_version_id = e.distribution_roster_version_id
  left join public.distribution_routes r on r.route_id = e.route_id
  where v.roster_status = 'PUBLISHED'
    and e.assignment_status = 'PLANNED'
    and e.work_date > p_exit_on
    and p_driver_id in (e.primary_driver_id, e.support_driver_id);

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
  values (
    auth.uid(), public.current_staff_id(),
    case when v_immediate then 'REMOVE_DISTRIBUTION_DRIVER' else 'SCHEDULE_DISTRIBUTION_DRIVER_EXIT' end,
    'distribution_drivers', p_driver_id::text, to_jsonb(v_before), to_jsonb(v_driver), trim(p_reason), 'DISTRIBUTION_UI'
  );

  return jsonb_build_object(
    'driver', to_jsonb(v_driver),
    'immediate', v_immediate,
    'staff_access_updated', v_staff_updated,
    'cancelled_leave_requests', v_cancelled_leave,
    'published_roster_conflicts', v_conflicts
  );
end;
$$;

create or replace function public.reinstate_distribution_driver(
  p_driver_id uuid,
  p_expected_row_version integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before public.distribution_drivers%rowtype;
  v_driver public.distribution_drivers%rowtype;
  v_staff_updated boolean := false;
begin
  perform public.require_distribution_master_access();

  if nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason for the reinstatement is required.';
  end if;

  select d.* into v_before
  from public.distribution_drivers d
  where d.driver_id = p_driver_id and d.deleted_at is null
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Driver was not found.';
  end if;
  if p_expected_row_version is not null and v_before.row_version <> p_expected_row_version then
    raise exception using errcode = '40001', message = 'This driver was changed by someone else. Reload and try again.';
  end if;
  if v_before.employment_status <> 'INACTIVE' and v_before.deactivated_on is null then
    raise exception using errcode = '22023', message = 'This driver has no recorded exit.';
  end if;

  update public.distribution_drivers d set
    employment_status = 'ACTIVE',
    availability_status = 'AVAILABLE',
    deactivated_on = null,
    deactivation_reason = null,
    exit_recorded_at = null,
    exit_recorded_by = null,
    updated_at = now(),
    updated_by = auth.uid(),
    row_version = d.row_version + 1
  where d.driver_id = p_driver_id
  returning * into v_driver;

  if v_driver.staff_id is not null then
    update public.staff_members sm set
      active = true,
      deactivated_on = null,
      deactivation_reason = null,
      updated_by = auth.uid(),
      row_version = sm.row_version + 1
    where sm.staff_id = v_driver.staff_id
      and sm.deleted_at is null
      and not sm.production_staff
      and sm.deactivation_reason like 'Driver exit:%';
    v_staff_updated := found;
  end if;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
  values (
    auth.uid(), public.current_staff_id(), 'REINSTATE_DISTRIBUTION_DRIVER',
    'distribution_drivers', p_driver_id::text, to_jsonb(v_before), to_jsonb(v_driver), trim(p_reason), 'DISTRIBUTION_UI'
  );

  return jsonb_build_object('driver', to_jsonb(v_driver), 'staff_access_updated', v_staff_updated);
end;
$$;

create or replace function public.process_scheduled_driver_exits()
returns integer
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_count integer;
begin
  update public.distribution_drivers set
    employment_status = 'INACTIVE',
    availability_status = 'UNAVAILABLE',
    updated_at = now(),
    row_version = row_version + 1
  where deleted_at is null and employment_status <> 'INACTIVE'
    and deactivated_on is not null and deactivated_on < current_date;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Same as 202610190001, plus: INACTIVE can only be reached through
-- remove_distribution_driver and left through reinstate_distribution_driver.
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
  v_status text;
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

  v_status := upper(coalesce(nullif(v_payload ->> 'employment_status',''),'ACTIVE'));
  if v_status = 'INACTIVE' and v_existing.employment_status is distinct from 'INACTIVE' then
    raise exception using errcode = '22023', message = 'Use Remove to record when a driver leaves the company.';
  end if;
  if v_existing.employment_status = 'INACTIVE' and v_status <> 'INACTIVE' then
    raise exception using errcode = '22023', message = 'Use Reinstate to bring a former driver back.';
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
    v_status,
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

-- Same as 202610170011, with the exit fields named in driver history.
create or replace function public.get_distribution_activity_history(p_from date default null, p_to date default null, p_limit integer default 250)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_from date := coalesce(p_from, current_date - 90);
  v_to date := coalesce(p_to, current_date + 30);
  v_limit integer := least(greatest(coalesce(p_limit, 250), 1), 500);
  v_keys text[] := array['display_name','phone','email','licence_number','licence_categories','licence_expires_on','cpc_expires_on','employment_status','availability_status','deactivated_on','deactivation_reason','notes'];
begin
  perform public.require_distribution_read_access();
  return jsonb_build_object(
    'range_from', v_from,
    'range_to', v_to,
    'events', coalesce((
      select jsonb_agg(
        to_jsonb(x) || jsonb_build_object(
          'recorded_by_name', coalesce(ap.display_name, sm.display_name, au.email, case when x.recorded_by is null then 'System' else 'Account user' end)
        ) order by x.event_at desc
      )
      from (
        select 'Roster'::text as source,e.event_type,e.event_at,e.recorded_by,rv.week_start,rv.version_number,rv.roster_status,
          case when e.event_type='DRAFT_CREATED' then format('Week %s draft created',rv.week_start)
               when e.event_type='DRAFT_SAVED' then format('Week %s draft saved with %s entries',rv.week_start,coalesce(e.event_payload->>'entry_count','0'))
               when e.event_type='PUBLISHED' then format('Week %s published as version %s',rv.week_start,rv.version_number)
               else format('Roster week %s: %s',rv.week_start,e.event_type) end as summary
        from public.distribution_roster_events e join public.distribution_roster_versions rv on rv.distribution_roster_version_id=e.distribution_roster_version_id
        where e.event_at::date between v_from and v_to
        union all
        select 'Daily route',e.event_type,e.event_at,e.recorded_by,r.business_date,null::integer,r.run_status,
          format('%s on %s: %s',coalesce(dr.display_name,dr.route_code,'Route'),r.business_date,e.event_type)
        from public.distribution_run_events e join public.distribution_route_runs r on r.run_id=e.run_id left join public.distribution_routes dr on dr.route_id=r.route_id
        where e.event_at::date between v_from and v_to
        union all
        select 'Actual hours','HOURS_SAVED',a.updated_at,a.updated_by,a.week_start,null::integer,'ACTUALS',
          format('%s: %s actual hours, planned %s',d.display_name,a.actual_hours,a.planned_hours)
        from public.distribution_driver_weekly_actuals a join public.distribution_drivers d on d.driver_id=a.driver_id
        where a.updated_at::date between v_from and v_to
        union all
        select 'Vehicle mileage','MILEAGE_SAVED',m.updated_at,m.updated_by,m.week_start,null::integer,'MILEAGE',
          format('%s: %s actual KM, odometer %s',v.registration_number,m.actual_km,coalesce(m.odometer_km::text,'not recorded'))
        from public.distribution_vehicle_weekly_mileage m join public.fleet_vehicles v on v.vehicle_id=m.vehicle_id
        where m.updated_at::date between v_from and v_to
        union all
        select
          case e.entity_table when 'distribution_drivers' then 'Driver records' when 'distribution_driver_absences' then 'Driver leave' when 'fleet_vehicles' then 'Fleet records' when 'distribution_routes' then 'Route records' else 'Master data' end,
          e.event_type,e.event_at,e.recorded_by,null::date,null::integer,e.entity_table,
          case
            when e.entity_table='distribution_drivers' then
              format('%s (%s)%s',
                coalesce(e.event_payload->'new'->>'display_name',e.event_payload->'old'->>'display_name','Driver'),
                coalesce(e.event_payload->'new'->>'driver_code',e.event_payload->'old'->>'driver_code','No code'),
                case when e.event_type='UPDATE' then ': ' || coalesce((
                  select string_agg(format('%s: %s -> %s',
                    case k when 'display_name' then 'Name' when 'phone' then 'Phone' when 'email' then 'Email' when 'licence_number' then 'Licence number' when 'licence_categories' then 'Licence type' when 'licence_expires_on' then 'Licence expiry' when 'cpc_expires_on' then 'CPC expiry' when 'employment_status' then 'Employment' when 'availability_status' then 'Availability' when 'deactivated_on' then 'Last working day' when 'deactivation_reason' then 'Exit reason' when 'notes' then 'Notes' else k end,
                    case when k='licence_categories' then coalesce((select string_agg(value,', ') from jsonb_array_elements_text(coalesce(e.event_payload->'old'->k,'[]'::jsonb))), 'Not set') else coalesce(nullif(trim(both '"' from (e.event_payload->'old'->k)::text),'null'),'Not set') end,
                    case when k='licence_categories' then coalesce((select string_agg(value,', ') from jsonb_array_elements_text(coalesce(e.event_payload->'new'->k,'[]'::jsonb))), 'Not set') else coalesce(nullif(trim(both '"' from (e.event_payload->'new'->k)::text),'null'),'Not set') end
                  ),'; ' order by array_position(v_keys,k))
                  from unnest(v_keys) k
                  where e.event_payload->'old'->k is distinct from e.event_payload->'new'->k
                ),'Record saved') else '' end)
            when e.entity_table='distribution_driver_absences' then
              format('%s leave: %s to %s',coalesce(d.display_name,'Driver'),coalesce(e.event_payload->'new'->>'starts_on',e.event_payload->'old'->>'starts_on',''),coalesce(e.event_payload->'new'->>'ends_on',e.event_payload->'old'->>'ends_on',''))
            when e.entity_table='fleet_vehicles' then format('Vehicle %s',coalesce(e.event_payload->'new'->>'registration_number',e.event_payload->'old'->>'registration_number','updated'))
            when e.entity_table='distribution_routes' then format('Route %s',coalesce(e.event_payload->'new'->>'route_code',e.event_payload->'old'->>'route_code','updated'))
            else format('%s %s',replace(e.entity_table,'_',' '),lower(e.event_type))
          end
        from public.distribution_master_events e
        left join public.distribution_drivers d on d.driver_id::text=coalesce(e.event_payload->'new'->>'driver_id',e.event_payload->'old'->>'driver_id')
        where e.event_at::date between v_from and v_to
        order by event_at desc
        limit v_limit
      ) x
      left join public.account_access_profiles ap on ap.auth_user_id=x.recorded_by
      left join public.staff_members sm on sm.auth_user_id=x.recorded_by
      left join auth.users au on au.id=x.recorded_by
    ),'[]'::jsonb),
    'roster_versions',coalesce((
      select jsonb_agg(to_jsonb(rv) || jsonb_build_object('created_by_name',coalesce(ap.display_name,sm.display_name,au.email,'System')) order by rv.week_start desc,rv.version_number desc)
      from public.distribution_roster_versions rv
      left join public.account_access_profiles ap on ap.auth_user_id=rv.created_by
      left join public.staff_members sm on sm.auth_user_id=rv.created_by
      left join auth.users au on au.id=rv.created_by
      where rv.created_at::date between v_from and v_to or coalesce(rv.published_at,rv.created_at)::date between v_from and v_to
      limit v_limit
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.remove_distribution_driver(uuid,integer,date,text) from public, anon;
revoke all on function public.reinstate_distribution_driver(uuid,integer,text) from public, anon;
revoke all on function public.process_scheduled_driver_exits() from public, anon, authenticated;
revoke all on function public.save_distribution_driver(jsonb) from public, anon;
revoke all on function public.get_distribution_activity_history(date,date,integer) from public, anon;
grant execute on function public.remove_distribution_driver(uuid,integer,date,text) to authenticated;
grant execute on function public.reinstate_distribution_driver(uuid,integer,text) to authenticated;
grant execute on function public.save_distribution_driver(jsonb) to authenticated;
grant execute on function public.get_distribution_activity_history(date,date,integer) to authenticated;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'distribution-driver-scheduled-exit') then
    perform cron.unschedule('distribution-driver-scheduled-exit');
  end if;
  perform cron.schedule('distribution-driver-scheduled-exit', '6 0 * * *', $job$select public.process_scheduled_driver_exits();$job$);
end $$;

commit;
