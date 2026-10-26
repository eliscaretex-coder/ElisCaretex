-- Distribution: record infringements (fines, notices, incidents) per driver.
--
-- The owner asked for a "Add Driver Infringement" window in Distribution: driver,
-- date/time it happened, severity level, infringement type (pick or type a new one)
-- and an explanation. Each record belongs to one driver and appears in Drivers and in
-- History, so whoever plans the roster can follow each driver.
--
-- An infringement counts as active for 7 months after the day it happened (owner
-- rule, Ireland). After that it stays in the history as "Expired" and no longer
-- counts in the driver's active total. The expiry date is stored on each record when
-- it is saved, so a later change of the rule never rewrites old records.
--
-- Records are never deleted. A wrong record is corrected with Edit (kept in the
-- audit trail through distribution_master_events) or cancelled with a reason; a
-- cancelled record stays visible in the history.
--
-- Access: everyone with Distribution VIEW reads (require_distribution_read_access);
-- Distribution EDIT records, edits and cancels (require_distribution_plan_access:
-- ADMIN, MANAGER, SUPERVISOR, DISTRIBUTION_OPERATOR). The table has RLS enabled with
-- no policies and no grants: it is only reached through these functions.
--
-- The table already exists in the database: 12 records imported on 2026-08-17 from the
-- old CentralDB (import_source 'CENTRALDB_2026-08-17', severity stored as text such as
-- 'Very serious infringement'), with no screen and no migration file. It is adopted, not
-- recreated: the legacy columns stay as they are, the missing columns are added and the
-- imported records get severity_level and expires_on from their own values.
--
-- Also replaced: get_distribution_driver_master (adds an "infringements" summary per
-- driver) and get_distribution_activity_history (labels infringement events). Both
-- keep their previous output; only new keys or labels are added.

-- Shape of the imported table (only created here if it does not exist yet).
create table if not exists public.distribution_driver_infringements (
  driver_infringement_id uuid primary key default gen_random_uuid(),
  legacy_infringement_id text unique,
  driver_id uuid references public.distribution_drivers(driver_id),
  legacy_driver_id text,
  driver_name_snapshot text not null,
  occurred_at timestamptz not null,
  severity text not null,
  infringement_type text not null,
  description text,
  legacy_created_at timestamptz,
  legacy_updated_at timestamptz,
  import_source text not null default 'CENTRALDB_LEGACY',
  created_at timestamptz not null default now()
);

alter table public.distribution_driver_infringements
  add column if not exists severity_level text,
  add column if not exists expires_on date,
  add column if not exists status text not null default 'ACTIVE',
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid,
  add column if not exists cancel_reason text,
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid,
  add column if not exists row_version integer not null default 1;

alter table public.distribution_driver_infringements alter column description drop not null;

-- Imported records: severity code from the text label, expiry 7 months after the day it happened.
update public.distribution_driver_infringements
set severity_level = case lower(btrim(severity))
      when 'minor infringement' then 'MINOR'
      when 'serious infringement' then 'SERIOUS'
      when 'very serious infringement' then 'VERY_SERIOUS'
      when 'most serious infringement' then 'MOST_SERIOUS'
      else 'NO_SEVERITY' end
where severity_level is null;

update public.distribution_driver_infringements
set expires_on = ((occurred_at at time zone 'Europe/Dublin')::date + interval '7 months')::date
where expires_on is null;

alter table public.distribution_driver_infringements
  alter column severity_level set not null,
  alter column expires_on set not null;

alter table public.distribution_driver_infringements drop constraint if exists distribution_driver_infringements_severity_level_check;
alter table public.distribution_driver_infringements add constraint distribution_driver_infringements_severity_level_check
  check (severity_level in ('NO_SEVERITY', 'MINOR', 'SERIOUS', 'VERY_SERIOUS', 'MOST_SERIOUS'));
alter table public.distribution_driver_infringements drop constraint if exists distribution_driver_infringements_status_check;
alter table public.distribution_driver_infringements add constraint distribution_driver_infringements_status_check
  check (status in ('ACTIVE', 'CANCELLED'));
alter table public.distribution_driver_infringements drop constraint if exists distribution_driver_infringements_cancel_check;
alter table public.distribution_driver_infringements add constraint distribution_driver_infringements_cancel_check
  check ((status = 'CANCELLED') = (cancelled_at is not null and cancel_reason is not null));

comment on table public.distribution_driver_infringements is
  'Driver infringements (imported from CentralDB and recorded in Distribution). Active until expires_on (7 months after the day it happened); kept afterwards as history. Never deleted: cancelled with a reason.';

create index if not exists distribution_driver_infringements_driver_idx
  on public.distribution_driver_infringements (driver_id, occurred_at desc);

alter table public.distribution_driver_infringements enable row level security;
revoke all on table public.distribution_driver_infringements from public, anon, authenticated;

drop trigger if exists distribution_driver_infringements_set_updated_at on public.distribution_driver_infringements;
create trigger distribution_driver_infringements_set_updated_at
  before update on public.distribution_driver_infringements
  for each row execute function public.set_updated_at();

drop trigger if exists distribution_driver_infringements_master_event on public.distribution_driver_infringements;
create trigger distribution_driver_infringements_master_event
  after insert or update or delete on public.distribution_driver_infringements
  for each row execute function public.record_distribution_master_event();

-- Owner rule: an infringement stops counting 7 months after the day it happened.
create or replace function public.distribution_infringement_validity_months()
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$ select 7 $$;

revoke all on function public.distribution_infringement_validity_months() from public, anon, authenticated;

create or replace function public.distribution_infringement_severity_rank(p_severity text)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_severity
    when 'NO_SEVERITY' then 0 when 'MINOR' then 1 when 'SERIOUS' then 2
    when 'VERY_SERIOUS' then 3 when 'MOST_SERIOUS' then 4 else -1 end
$$;

revoke all on function public.distribution_infringement_severity_rank(text) from public, anon, authenticated;

create or replace function public.distribution_infringement_severity_label(p_severity text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_severity
    when 'NO_SEVERITY' then 'No Severity' when 'MINOR' then 'Minor infringement' when 'SERIOUS' then 'Serious infringement'
    when 'VERY_SERIOUS' then 'Very serious infringement' when 'MOST_SERIOUS' then 'Most serious infringement' else p_severity end
$$;

revoke all on function public.distribution_infringement_severity_label(text) from public, anon, authenticated;

create or replace function public.distribution_infringement_item(p_row public.distribution_driver_infringements)
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select jsonb_build_object(
    'infringement_id', (p_row).driver_infringement_id,
    'driver_id', (p_row).driver_id,
    'driver_name', d.display_name,
    'driver_code', d.driver_code,
    'occurred_at', (p_row).occurred_at,
    'occurred_local', to_char((p_row).occurred_at at time zone 'Europe/Dublin', 'YYYY-MM-DD"T"HH24:MI'),
    'severity_level', (p_row).severity_level,
    'severity_rank', public.distribution_infringement_severity_rank((p_row).severity_level),
    'infringement_type', (p_row).infringement_type,
    'description', (p_row).description,
    'expires_on', (p_row).expires_on,
    'status', (p_row).status,
    'is_active', (p_row).status = 'ACTIVE' and (p_row).expires_on > (now() at time zone 'Europe/Dublin')::date,
    'state', case when (p_row).status = 'CANCELLED' then 'CANCELLED'
                  when (p_row).expires_on > (now() at time zone 'Europe/Dublin')::date then 'ACTIVE'
                  else 'EXPIRED' end,
    'cancelled_at', (p_row).cancelled_at,
    'cancelled_by_name', case when (p_row).cancelled_by is null then null else coalesce(public.production_roster_actor_name((p_row).cancelled_by, null), 'Account user') end,
    'cancel_reason', (p_row).cancel_reason,
    'created_at', (p_row).created_at,
    'created_by_name', coalesce(public.production_roster_actor_name((p_row).created_by, null), case when (p_row).import_source <> 'APP' then 'Imported from CentralDB' else 'System' end),
    'updated_at', (p_row).updated_at,
    'updated_by_name', case when (p_row).updated_by is null then null else coalesce(public.production_roster_actor_name((p_row).updated_by, null), 'Account user') end,
    'imported', (p_row).import_source <> 'APP',
    'row_version', (p_row).row_version
  )
  from public.distribution_drivers d
  where d.driver_id = (p_row).driver_id
$$;

revoke all on function public.distribution_infringement_item(public.distribution_driver_infringements) from public, anon, authenticated;

-- Read: every infringement (or one driver's), newest first, with the types already used.
create or replace function public.get_distribution_driver_infringements(p_driver_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_distribution_read_access();
  return jsonb_build_object(
    'today', (now() at time zone 'Europe/Dublin')::date,
    'validity_months', public.distribution_infringement_validity_months(),
    'can_record', public.account_module_allowed(array['DISTRIBUTION'], 'EDIT', array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'types', coalesce((
      select jsonb_agg(t.infringement_type order by t.uses desc, t.infringement_type)
      from (
        select min(btrim(i.infringement_type)) as infringement_type, count(*) as uses
        from public.distribution_driver_infringements i
        group by lower(btrim(i.infringement_type))
      ) t
    ), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(public.distribution_infringement_item(i) order by i.occurred_at desc, i.created_at desc)
      from public.distribution_driver_infringements i
      join public.distribution_drivers d on d.driver_id = i.driver_id and d.deleted_at is null
      where p_driver_id is null or i.driver_id = p_driver_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_distribution_driver_infringements(uuid) from public, anon;
grant execute on function public.get_distribution_driver_infringements(uuid) to authenticated;

-- Record or edit one infringement.
-- p_infringement: infringement_id (null = new), driver_id, occurred_local
-- ('YYYY-MM-DDTHH:MI', Irish time), severity_level, infringement_type, description,
-- row_version (required when editing).
create or replace function public.save_distribution_driver_infringement(p_infringement jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid := nullif(p_infringement->>'infringement_id', '')::uuid;
  v_driver_id uuid := nullif(p_infringement->>'driver_id', '')::uuid;
  v_local text := nullif(btrim(coalesce(p_infringement->>'occurred_local', '')), '');
  v_severity text := upper(nullif(btrim(coalesce(p_infringement->>'severity_level', '')), ''));
  v_type text := regexp_replace(btrim(coalesce(p_infringement->>'infringement_type', '')), '\s+', ' ', 'g');
  v_description text := nullif(btrim(coalesce(p_infringement->>'description', '')), '');
  v_version integer := nullif(p_infringement->>'row_version', '')::integer;
  v_occurred timestamptz;
  v_expires date;
  v_row public.distribution_driver_infringements;
begin
  perform public.require_distribution_plan_access();

  if v_driver_id is null or not exists (
    select 1 from public.distribution_drivers d where d.driver_id = v_driver_id and d.deleted_at is null
  ) then
    raise exception using errcode = '22023', message = 'Select the driver.';
  end if;
  if v_local is null then
    raise exception using errcode = '22023', message = 'Enter the date and time it happened.';
  end if;
  begin
    v_occurred := v_local::timestamp at time zone 'Europe/Dublin';
  exception when others then
    raise exception using errcode = '22023', message = 'The date and time are not valid.';
  end;
  if v_occurred > now() + interval '1 hour' then
    raise exception using errcode = '22023', message = 'The date and time cannot be in the future.';
  end if;
  if v_occurred < now() - interval '10 years' then
    raise exception using errcode = '22023', message = 'The date is too far in the past.';
  end if;
  if v_severity is null or public.distribution_infringement_severity_rank(v_severity) < 0 then
    raise exception using errcode = '22023', message = 'Select the severity level.';
  end if;
  if v_type = '' then
    raise exception using errcode = '22023', message = 'Select or type the infringement type.';
  end if;
  if length(v_type) > 120 then
    raise exception using errcode = '22023', message = 'The infringement type is too long (maximum 120 characters).';
  end if;
  if length(coalesce(v_description, '')) > 4000 then
    raise exception using errcode = '22023', message = 'The explanation is too long (maximum 4000 characters).';
  end if;

  -- Reuse the spelling of a type already in use, so the list does not fill with near duplicates.
  select coalesce((
    select btrim(i.infringement_type) from public.distribution_driver_infringements i
    where lower(btrim(i.infringement_type)) = lower(v_type)
    order by i.created_at
    limit 1
  ), v_type) into v_type;

  v_expires := ((v_occurred at time zone 'Europe/Dublin')::date
                + make_interval(months => public.distribution_infringement_validity_months()))::date;

  if v_id is null then
    insert into public.distribution_driver_infringements (
      driver_id, driver_name_snapshot, occurred_at, severity, severity_level, infringement_type, description,
      expires_on, import_source, created_by
    ) values (
      v_driver_id, (select d.display_name from public.distribution_drivers d where d.driver_id = v_driver_id),
      v_occurred, public.distribution_infringement_severity_label(v_severity), v_severity, v_type, v_description,
      v_expires, 'APP', auth.uid()
    )
    returning * into v_row;
  else
    select * into v_row from public.distribution_driver_infringements where driver_infringement_id = v_id for update;
    if not found then
      raise exception using errcode = 'P0002', message = 'This infringement was not found.';
    end if;
    if v_row.status = 'CANCELLED' then
      raise exception using errcode = '22023', message = 'A cancelled infringement cannot be edited.';
    end if;
    if v_version is null or v_version <> v_row.row_version then
      raise exception using errcode = '40001', message = 'This infringement was changed by someone else. Close the window and open it again.';
    end if;
    update public.distribution_driver_infringements
    set driver_id = v_driver_id,
        driver_name_snapshot = (select d.display_name from public.distribution_drivers d where d.driver_id = v_driver_id),
        occurred_at = v_occurred,
        severity = public.distribution_infringement_severity_label(v_severity),
        severity_level = v_severity,
        infringement_type = v_type,
        description = v_description,
        expires_on = v_expires,
        updated_by = auth.uid(),
        row_version = row_version + 1
    where driver_infringement_id = v_id
    returning * into v_row;
  end if;

  return public.distribution_infringement_item(v_row);
end;
$$;

revoke all on function public.save_distribution_driver_infringement(jsonb) from public, anon;
grant execute on function public.save_distribution_driver_infringement(jsonb) to authenticated;

-- Cancel a wrong record. It stays in the history with the reason.
create or replace function public.cancel_distribution_driver_infringement(
  p_infringement_id uuid,
  p_expected_row_version integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_row public.distribution_driver_infringements;
begin
  perform public.require_distribution_plan_access();
  if v_reason is null then
    raise exception using errcode = '22023', message = 'A reason is required.';
  end if;
  if length(v_reason) > 1000 then
    raise exception using errcode = '22023', message = 'The reason is too long (maximum 1000 characters).';
  end if;
  select * into v_row from public.distribution_driver_infringements where driver_infringement_id = p_infringement_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'This infringement was not found.';
  end if;
  if v_row.status = 'CANCELLED' then
    raise exception using errcode = '22023', message = 'This infringement is already cancelled.';
  end if;
  if p_expected_row_version is null or p_expected_row_version <> v_row.row_version then
    raise exception using errcode = '40001', message = 'This infringement was changed by someone else. Close the window and open it again.';
  end if;
  update public.distribution_driver_infringements
  set status = 'CANCELLED',
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancel_reason = v_reason,
      updated_by = auth.uid(),
      row_version = row_version + 1
  where driver_infringement_id = p_infringement_id
  returning * into v_row;
  return public.distribution_infringement_item(v_row);
end;
$$;

revoke all on function public.cancel_distribution_driver_infringement(uuid, integer, text) from public, anon;
grant execute on function public.cancel_distribution_driver_infringement(uuid, integer, text) to authenticated;

-- Driver master: same output as before plus an "infringements" summary per driver.
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
        ),
        'infringements', (
          select jsonb_build_object(
            'recorded_count', count(*) filter (where i.status = 'ACTIVE'),
            'active_count', count(*) filter (where i.status = 'ACTIVE' and i.expires_on > (now() at time zone 'Europe/Dublin')::date),
            'highest_active_rank', max(public.distribution_infringement_severity_rank(i.severity_level)) filter (where i.status = 'ACTIVE' and i.expires_on > (now() at time zone 'Europe/Dublin')::date),
            'last_occurred_at', max(i.occurred_at) filter (where i.status = 'ACTIVE'),
            'next_expiry_on', min(i.expires_on) filter (where i.status = 'ACTIVE' and i.expires_on > (now() at time zone 'Europe/Dublin')::date)
          )
          from public.distribution_driver_infringements i
          where i.driver_id = d.driver_id
        )
      ) order by lower(d.display_name), d.driver_code)
    from public.distribution_drivers d
    left join public.staff_members sm on sm.staff_id = d.staff_id
    where d.deleted_at is null
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.get_distribution_driver_master() from public, anon;
grant execute on function public.get_distribution_driver_master() to authenticated;

-- History: same output as before; infringement records get their own source and summary.
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
          case e.entity_table when 'distribution_drivers' then 'Driver records' when 'distribution_driver_absences' then 'Driver leave' when 'distribution_driver_infringements' then 'Driver infringements' when 'fleet_vehicles' then 'Fleet records' when 'distribution_routes' then 'Route records' else 'Master data' end,
          case when e.entity_table='distribution_driver_infringements' and e.event_payload->'old'->>'status'='ACTIVE' and e.event_payload->'new'->>'status'='CANCELLED' then 'CANCELLED' else e.event_type end,
          e.event_at,e.recorded_by,null::date,null::integer,e.entity_table,
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
            when e.entity_table='distribution_driver_infringements' then
              format('%s: %s · %s · happened %s%s',
                coalesce(d.display_name,'Driver'),
                case coalesce(e.event_payload->'new'->>'severity_level',e.event_payload->'old'->>'severity_level')
                  when 'NO_SEVERITY' then 'No severity' when 'MINOR' then 'Minor infringement' when 'SERIOUS' then 'Serious infringement'
                  when 'VERY_SERIOUS' then 'Very serious infringement' when 'MOST_SERIOUS' then 'Most serious infringement' else 'Infringement' end,
                coalesce(e.event_payload->'new'->>'infringement_type',e.event_payload->'old'->>'infringement_type',''),
                to_char((coalesce(e.event_payload->'new'->>'occurred_at',e.event_payload->'old'->>'occurred_at'))::timestamptz at time zone 'Europe/Dublin','DD/MM/YYYY HH24:MI'),
                case when e.event_payload->'new'->>'status'='CANCELLED' and e.event_payload->'old'->>'status'='ACTIVE' then ' · cancelled: ' || coalesce(e.event_payload->'new'->>'cancel_reason','')
                     when e.event_type='UPDATE' then ' · edited'
                     else '' end)
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

revoke all on function public.get_distribution_activity_history(date, date, integer) from public, anon;
grant execute on function public.get_distribution_activity_history(date, date, integer) to authenticated;
