-- Staff -> Driver transfer with an effective date.
--
-- Before: the transfer kept the staff member in Production until the end of the
-- current roster week and created the Driver at once, so the person showed in
-- both the Production Roster and the Driver Roster.
--
-- Now the transfer takes the first day as Driver (p_effective_on):
-- * Production: production_roster_until = the day before. From that day the
--   person is OFF in the Production Roster; later weeks no longer include them.
--   Draft versions are changed in place. A published week with no draft gets a
--   new published version (the previous one is kept as SUPERSEDED), so past
--   days and the published history are never overwritten.
-- * Driver: joined_on = the first day as Driver, so the Driver Roster shows the
--   person only from that week and blocks the days before.
-- * On that day process_production_roster_exits() moves the Staff Master record
--   to Driver/Distribution (immediately when the date is today).
-- * The Production and Driver roster checks reject working days outside these
--   dates.

begin;

-- 1. Close a staff member's Production Roster from a date onwards (internal).
create or replace function public.production_roster_close_staff_from(
  p_staff_id uuid,
  p_effective_on date,
  p_reason text,
  p_source_application text
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_version record;
  v_new public.production_roster_versions%rowtype;
  v_changed integer;
  v_drafts integer := 0;
  v_published integer := 0;
  v_actor_staff uuid := public.current_staff_id();
  v_source text := coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI');
begin
  if p_staff_id is null or p_effective_on is null then
    raise exception using errcode = '22023', message = 'Staff member and effective date are required.';
  end if;

  -- Drafts: weeks starting on or after the date lose the person's rows; the week
  -- that contains the date gets OFF from that day.
  for v_version in
    select prv.roster_version_id, rp.week_start
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where prv.status = 'DRAFT'
      and rp.week_start + 6 >= p_effective_on
      and exists (
        select 1 from public.production_roster_entries pre
        where pre.roster_version_id = prv.roster_version_id
          and pre.staff_id = p_staff_id
          and pre.work_date >= p_effective_on
      )
    order by rp.week_start
    for update of prv
  loop
    if v_version.week_start >= p_effective_on then
      delete from public.production_roster_shift_overrides pro
      where pro.roster_version_id = v_version.roster_version_id and pro.staff_id = p_staff_id;
      delete from public.production_roster_entries pre
      where pre.roster_version_id = v_version.roster_version_id and pre.staff_id = p_staff_id;
      get diagnostics v_changed = row_count;
    else
      update public.production_roster_entries pre set
        day_status = 'OFF', assignment_type = 'BASE',
        operational_role_id = null, operational_role_code_snapshot = null, operational_role_name_snapshot = null,
        area_id = null, area_code_snapshot = null, area_name_snapshot = null,
        station_id = null, station_code_snapshot = null, station_name_snapshot = null,
        planned_start_time = null, planned_end_time = null, sorting_work_mode = null,
        updated_by = auth.uid()
      where pre.roster_version_id = v_version.roster_version_id
        and pre.staff_id = p_staff_id
        and pre.work_date >= p_effective_on
        and (pre.day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') or pre.assignment_type = 'COVER');
      get diagnostics v_changed = row_count;
    end if;

    if v_changed > 0 then
      update public.production_roster_versions prv set
        row_version = prv.row_version + 1, saved_at = now(), saved_by = auth.uid(), updated_by = auth.uid()
      where prv.roster_version_id = v_version.roster_version_id;

      insert into public.production_roster_events(roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason, metadata)
      values (v_version.roster_version_id, 'DRAFT_SAVED', auth.uid(), v_actor_staff, nullif(trim(p_reason), ''),
        jsonb_build_object('source_application', v_source, 'staff_id', p_staff_id, 'off_from', p_effective_on, 'rows_changed', v_changed));
      v_drafts := v_drafts + 1;
    end if;
  end loop;

  -- Published weeks without a draft: publish a new version with the same rows,
  -- except the person, who is OFF from the date (or left out of a week that
  -- starts on or after it). The previous version stays as SUPERSEDED history.
  for v_version in
    select prv.*, rp.week_start
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where prv.status = 'PUBLISHED'
      and rp.week_start + 6 >= p_effective_on
      and not exists (
        select 1 from public.production_roster_versions d
        where d.roster_period_id = prv.roster_period_id and d.shift_id = prv.shift_id and d.status = 'DRAFT'
      )
      and exists (
        select 1 from public.production_roster_entries pre
        where pre.roster_version_id = prv.roster_version_id
          and pre.staff_id = p_staff_id
          and pre.work_date >= p_effective_on
          and (rp.week_start >= p_effective_on
               or pre.day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS')
               or pre.assignment_type = 'COVER')
      )
    order by rp.week_start
    for update of prv
  loop
    insert into public.production_roster_versions(
      roster_period_id, shift_id, version_number, status, include_sunday, week_note,
      based_on_version_id, saved_at, saved_by, created_by, updated_by
    ) values (
      v_version.roster_period_id, v_version.shift_id,
      (select max(x.version_number) + 1 from public.production_roster_versions x
        where x.roster_period_id = v_version.roster_period_id and x.shift_id = v_version.shift_id),
      'DRAFT', v_version.include_sunday, v_version.week_note,
      v_version.roster_version_id, now(), auth.uid(), auth.uid(), auth.uid()
    ) returning * into v_new;

    insert into public.production_roster_entries(
      roster_version_id, work_date, staff_id, day_status, assignment_type,
      operational_role_id, area_id, station_id, planned_start_time, planned_end_time, notes,
      staff_display_name_snapshot, employee_code_snapshot, shift_code_snapshot, shift_name_snapshot,
      operational_role_code_snapshot, operational_role_name_snapshot, area_code_snapshot, area_name_snapshot,
      station_code_snapshot, station_name_snapshot, staff_primary_role_code_snapshot, staff_primary_role_name_snapshot,
      staff_default_area_code_snapshot, staff_default_area_name_snapshot,
      staff_default_station_code_snapshot, staff_default_station_name_snapshot,
      fire_training_snapshot, first_aid_training_snapshot, eod_capable_snapshot,
      display_section_code, staff_default_shift_code_snapshot, staff_default_shift_name_snapshot,
      sorting_work_mode, created_by, updated_by
    )
    select
      v_new.roster_version_id, pre.work_date, pre.staff_id,
      case when x.closes then 'OFF' else pre.day_status end,
      case when x.closes then 'BASE' else pre.assignment_type end,
      case when x.closes then null else pre.operational_role_id end,
      case when x.closes then null else pre.area_id end,
      case when x.closes then null else pre.station_id end,
      case when x.closes then null else pre.planned_start_time end,
      case when x.closes then null else pre.planned_end_time end,
      pre.notes,
      pre.staff_display_name_snapshot, pre.employee_code_snapshot, pre.shift_code_snapshot, pre.shift_name_snapshot,
      case when x.closes then null else pre.operational_role_code_snapshot end,
      case when x.closes then null else pre.operational_role_name_snapshot end,
      case when x.closes then null else pre.area_code_snapshot end,
      case when x.closes then null else pre.area_name_snapshot end,
      case when x.closes then null else pre.station_code_snapshot end,
      case when x.closes then null else pre.station_name_snapshot end,
      pre.staff_primary_role_code_snapshot, pre.staff_primary_role_name_snapshot,
      pre.staff_default_area_code_snapshot, pre.staff_default_area_name_snapshot,
      pre.staff_default_station_code_snapshot, pre.staff_default_station_name_snapshot,
      pre.fire_training_snapshot, pre.first_aid_training_snapshot, pre.eod_capable_snapshot,
      pre.display_section_code, pre.staff_default_shift_code_snapshot, pre.staff_default_shift_name_snapshot,
      case when x.closes then null else pre.sorting_work_mode end,
      auth.uid(), auth.uid()
    from public.production_roster_entries pre
    cross join lateral (
      select pre.staff_id = p_staff_id
        and pre.work_date >= p_effective_on
        and (pre.day_status in ('WORKING', 'TRAINING', 'QUALITY_ANALYSIS') or pre.assignment_type = 'COVER') as closes
    ) x
    where pre.roster_version_id = v_version.roster_version_id
      and not (pre.staff_id = p_staff_id and v_version.week_start >= p_effective_on);

    insert into public.production_roster_shift_overrides(
      roster_version_id, staff_id, staff_default_shift_code_snapshot, staff_default_shift_name_snapshot,
      roster_shift_code_snapshot, roster_shift_name_snapshot, confirmed_days, source_application,
      created_by, updated_by
    )
    select v_new.roster_version_id, pro.staff_id, pro.staff_default_shift_code_snapshot, pro.staff_default_shift_name_snapshot,
      pro.roster_shift_code_snapshot, pro.roster_shift_name_snapshot, pro.confirmed_days, pro.source_application,
      auth.uid(), auth.uid()
    from public.production_roster_shift_overrides pro
    where pro.roster_version_id = v_version.roster_version_id
      and not (pro.staff_id = p_staff_id and v_version.week_start >= p_effective_on);

    update public.production_roster_versions set
      status = 'SUPERSEDED', updated_by = auth.uid(), row_version = row_version + 1
    where roster_version_id = v_version.roster_version_id;

    update public.production_roster_versions set
      status = 'PUBLISHED', published_at = now(), published_by = auth.uid(),
      updated_by = auth.uid(), row_version = row_version + 1
    where roster_version_id = v_new.roster_version_id
    returning * into v_new;

    insert into public.production_roster_events(roster_version_id, event_type, actor_auth_user_id, actor_staff_id, reason, metadata)
    values
      (v_version.roster_version_id, 'SUPERSEDED', auth.uid(), v_actor_staff, nullif(trim(p_reason), ''),
        jsonb_build_object('superseded_by', v_new.roster_version_id, 'staff_id', p_staff_id, 'off_from', p_effective_on)),
      (v_new.roster_version_id, 'PUBLISHED', auth.uid(), v_actor_staff, nullif(trim(p_reason), ''),
        jsonb_build_object('source_application', v_source, 'staff_id', p_staff_id, 'off_from', p_effective_on,
          'based_on_version_id', v_version.roster_version_id));

    insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data, reason, source_application)
    values (auth.uid(), v_actor_staff, 'PRODUCTION_ROSTER_PUBLISHED', 'production_roster_versions', v_new.roster_version_id::text,
      jsonb_build_object('version_number', v_new.version_number, 'published_at', v_new.published_at,
        'superseded_version_id', v_version.roster_version_id, 'staff_id', p_staff_id, 'off_from', p_effective_on),
      nullif(trim(p_reason), ''), v_source);

    v_published := v_published + 1;
  end loop;

  return jsonb_build_object('draft_rosters_updated', v_drafts, 'published_rosters_republished', v_published);
end;
$$;

revoke all on function public.production_roster_close_staff_from(uuid, date, text, text) from public, anon, authenticated;

comment on function public.production_roster_close_staff_from(uuid, date, text, text) is
  'Internal: sets a staff member OFF in the Production Roster from a date (drafts in place, published weeks through a new version) and removes them from weeks that start on or after it.';


-- 2. The transfer takes the first day as Driver.
drop function if exists public.transfer_staff_to_distribution_driver(
  uuid, integer, uuid, text, text, text, text, text[], date, date, text, text, text
);

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
  p_source_application text default 'STAFF_MASTER_UI',
  p_effective_on date default null
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
  v_today date := (now() at time zone 'Europe/Dublin')::date;
  -- Without a date (older screens) the person starts as Driver next Monday.
  v_effective date := coalesce(p_effective_on, public.production_roster_week_start((now() at time zone 'Europe/Dublin')::date) + 7);
  v_until date;
  v_roster jsonb;
  v_completed boolean := false;
  v_source text := coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI');
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
  if v_effective < v_today then
    raise exception using errcode='22023', message='The first day as Driver cannot be in the past.';
  end if;
  if v_effective > v_today + 90 then
    raise exception using errcode='22023', message='The first day as Driver must be within the next 90 days.';
  end if;
  v_until := v_effective - 1;

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
  if v_staff.deactivated_on is not null and v_staff.deactivated_on < v_effective then
    raise exception using errcode='22023', message='This staff member leaves the company before the first day as Driver.';
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
      -- A record already used in Driver Rosters before the date keeps its start;
      -- otherwise it starts on the first day as Driver.
      joined_on=case
        when exists(
          select 1 from public.distribution_roster_entries e
          where (e.primary_driver_id=d.driver_id or e.support_driver_id=d.driver_id) and e.work_date<v_effective
        ) then d.joined_on
        else v_effective
      end,
      employment_status='ACTIVE', availability_status='AVAILABLE', updated_by=auth.uid(), row_version=d.row_version+1
    where d.driver_id=p_existing_driver_id returning * into v_driver;
  else
    insert into public.distribution_drivers(
      staff_id,driver_code,display_name,phone,email,licence_number,licence_categories,
      licence_expires_on,cpc_expires_on,employment_status,availability_status,notes,joined_on,created_by,updated_by
    ) values (
      p_staff_id,upper(trim(p_driver_code)),v_staff.display_name,trim(p_phone),nullif(trim(p_email),''),
      trim(p_licence_number),p_licence_categories,p_licence_expires_on,p_cpc_expires_on,
      'ACTIVE','AVAILABLE',nullif(trim(p_notes),''),v_effective,auth.uid(),auth.uid()
    ) returning * into v_driver;
  end if;

  -- Production until the day before the first day as Driver.
  update public.staff_members sm set
    production_roster_until=least(coalesce(sm.production_roster_until, v_until), v_until),
    row_version=sm.row_version+1, updated_by=auth.uid()
  where sm.staff_id=p_staff_id;

  v_roster := public.production_roster_close_staff_from(p_staff_id, v_effective, trim(p_change_reason), v_source);

  insert into public.audit_log(actor_auth_user_id,actor_staff_id,action,entity_table,entity_id,old_data,new_data,reason,source_application)
  values(auth.uid(),public.current_staff_id(),'TRANSFER_STAFF_TO_DRIVER','staff_members',p_staff_id::text,
    to_jsonb(v_staff),
    jsonb_build_object('driver_id',v_driver.driver_id,'driver_code',v_driver.driver_code,
      'first_day_as_driver',v_effective,'production_roster_until',v_until) || v_roster,
    trim(p_change_reason),v_source);

  -- Starting today: complete the move now instead of waiting for the nightly job.
  if v_effective <= v_today then
    perform public.process_production_roster_exits();
    v_completed := true;
  end if;

  return jsonb_build_object(
    'staff_id',p_staff_id,'driver_id',v_driver.driver_id,'driver_code',v_driver.driver_code,
    'first_day_as_driver',v_effective,'production_roster_until',v_until,'completed_now',v_completed
  ) || v_roster;
end;
$$;

revoke all on function public.transfer_staff_to_distribution_driver(
  uuid, integer, uuid, text, text, text, text, text[], date, date, text, text, text, date
) from public, anon;
grant execute on function public.transfer_staff_to_distribution_driver(
  uuid, integer, uuid, text, text, text, text, text[], date, date, text, text, text, date
) to authenticated;

comment on function public.transfer_staff_to_distribution_driver(uuid, integer, uuid, text, text, text, text, text[], date, date, text, text, text, date) is
  'Transfers a Production staff member to Driver from p_effective_on: OFF in the Production Roster from that day (published weeks through a new version), Driver Roster from that day, Staff Master moved on that day.';


-- 3. Production Roster: no working day after the last Production day.
create or replace function public.production_roster_assert_operational_rules(p_roster_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_version public.production_roster_versions%rowtype;
  v_period public.roster_periods%rowtype;
  v_bad record;
begin
  select * into v_version
  from public.production_roster_versions prv
  where prv.roster_version_id = p_roster_version_id;

  if not found then
    raise exception using errcode='P0002', message='Production Roster version not found.';
  end if;

  select * into v_period
  from public.roster_periods rp
  where rp.roster_period_id = v_version.roster_period_id;

  select sm.display_name, sm.joined_on, sm.deactivated_on
  into v_bad
  from public.production_roster_entries pre
  join public.staff_members sm on sm.staff_id = pre.staff_id
  where pre.roster_version_id = p_roster_version_id
  group by sm.staff_id, sm.display_name, sm.joined_on, sm.deactivated_on, sm.production_staff, sm.deleted_at, sm.production_roster_until
  having sm.production_staff is not true
      or sm.deleted_at is not null
      or (sm.joined_on is not null and sm.joined_on > v_period.week_start + 6)
      or (sm.deactivated_on is not null and sm.deactivated_on < v_period.week_start)
      or (sm.production_roster_until is not null and sm.production_roster_until < v_period.week_start)
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        '%s is outside the Staff Master employment dates for this roster week, or has moved out of Production. Remove the staff row before saving or publishing.',
        v_bad.display_name
      );
  end if;

  select sm.display_name, pre.work_date, sm.joined_on, sm.deactivated_on
  into v_bad
  from public.production_roster_entries pre
  join public.staff_members sm on sm.staff_id = pre.staff_id
  where pre.roster_version_id = p_roster_version_id
    and pre.day_status in ('WORKING','TRAINING','QUALITY_ANALYSIS')
    and (
      (sm.joined_on is not null and pre.work_date < sm.joined_on)
      or (sm.deactivated_on is not null and pre.work_date > sm.deactivated_on)
      or (sm.production_roster_until is not null and pre.work_date > sm.production_roster_until)
      or (
        sm.deactivated_on is null
        and (sm.active is not true or sm.roster_eligible is not true)
      )
    )
  order by pre.work_date, sm.display_name
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        '%s cannot be planned as working on %s because Staff Master employment/eligibility does not allow that date.',
        v_bad.display_name,
        to_char(v_bad.work_date,'YYYY-MM-DD')
      );
  end if;

  -- Valid Sorting daily decisions:
  -- 1) one or two MOP, with all other Working Sorting rows explicitly CLOTHES;
  -- 2) zero MOP and every Working Sorting row NULL = explicit No dedicated MOP.
  select
    pre.work_date,
    count(*) as sorting_count,
    count(*) filter (where pre.sorting_work_mode = 'MOP') as mop_count,
    count(*) filter (where pre.sorting_work_mode = 'CLOTHES') as clothes_count,
    count(*) filter (where pre.sorting_work_mode is null) as null_count
  into v_bad
  from public.production_roster_entries pre
  where pre.roster_version_id = p_roster_version_id
    and pre.day_status = 'WORKING'
    and (
      pre.area_code_snapshot = 'SORTING'
      or pre.operational_role_code_snapshot = 'SORTING_AREA'
    )
  group by pre.work_date
  having not (
    (
      count(*) filter (where pre.sorting_work_mode = 'MOP') between 1 and 2
      and count(*) filter (where pre.sorting_work_mode is null) = 0
    )
    or
    (
      count(*) filter (where pre.sorting_work_mode = 'MOP') = 0
      and count(*) filter (where pre.sorting_work_mode is null) = count(*)
    )
  )
  order by pre.work_date
  limit 1;

  if found then
    raise exception using
      errcode='22023',
      message=format(
        'Choose the Sorting MOP coverage for %s: select one or two dedicated MOP staff members, or explicitly choose No dedicated MOP. Sorting staff=%s, MOP=%s, Clothes=%s, undecided=%s.',
        to_char(v_bad.work_date,'YYYY-MM-DD'),
        v_bad.sorting_count,
        v_bad.mop_count,
        v_bad.clothes_count,
        v_bad.null_count
      );
  end if;
end;
$$;


-- 4. Driver Roster: no assignment before the Driver's first day.
create or replace function public.validate_distribution_roster_version(p_roster_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare v_conflict record;
begin
  select a.work_date, a.driver_id into v_conflict from (
    select work_date, primary_driver_id as driver_id from public.distribution_roster_entries where distribution_roster_version_id = p_roster_version_id and primary_driver_id is not null
    union all select work_date, support_driver_id from public.distribution_roster_entries where distribution_roster_version_id = p_roster_version_id and assignment_status = 'PLANNED' and support_driver_id is not null
  ) a group by a.work_date, a.driver_id having count(*) > 1 limit 1;
  if found then raise exception using errcode = '23505', message = format('A driver has more than one roster state on %s.', v_conflict.work_date); end if;

  select e.work_date, d.display_name, d.joined_on into v_conflict from public.distribution_roster_entries e
  join lateral (values (e.primary_driver_id), (e.support_driver_id)) x(driver_id) on x.driver_id is not null
  join public.distribution_drivers d on d.driver_id = x.driver_id
  where e.distribution_roster_version_id = p_roster_version_id
    and d.joined_on is not null and e.work_date < d.joined_on
  order by e.work_date limit 1;
  if found then raise exception using errcode = '22023', message = format('Driver %s starts on %s and cannot be rostered on %s.', v_conflict.display_name, to_char(v_conflict.joined_on, 'Dy DD Mon'), to_char(v_conflict.work_date, 'Dy DD Mon')); end if;

  select e.work_date, e.vehicle_id into v_conflict from public.distribution_roster_entries e join public.fleet_vehicles v on v.vehicle_id = e.vehicle_id
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED' and e.vehicle_id is not null
  group by e.work_date, e.vehicle_id, v.vehicle_type having count(*) > case when v.vehicle_type = 'VAN' then 2 else 1 end limit 1;
  if found then raise exception using errcode = '23505', message = format('This vehicle exceeds its daily route limit on %s.', v_conflict.work_date); end if;

  select e.work_date, d.display_name into v_conflict from public.distribution_roster_entries e
  join lateral (values (e.primary_driver_id), (e.support_driver_id)) x(driver_id) on x.driver_id is not null
  join public.distribution_drivers d on d.driver_id = x.driver_id
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED'
    and (d.deleted_at is not null or d.employment_status <> 'ACTIVE' or d.availability_status <> 'AVAILABLE') limit 1;
  if found then raise exception using errcode = '22023', message = format('Driver %s is not available for the roster.', v_conflict.display_name); end if;

  select e.work_date, d.display_name into v_conflict from public.distribution_roster_entries e
  join lateral (values (e.primary_driver_id), (e.support_driver_id)) x(driver_id) on x.driver_id is not null
  join public.distribution_drivers d on d.driver_id = x.driver_id
  join public.distribution_driver_absences a on a.driver_id = d.driver_id and a.absence_status = 'APPROVED' and e.work_date between a.starts_on and a.ends_on
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED' limit 1;
  if found then raise exception using errcode = '22023', message = format('Driver %s has approved leave on %s.', v_conflict.display_name, v_conflict.work_date); end if;

  select e.work_date, e.vehicle_registration_snapshot as registration_number, public.distribution_vehicle_block_reason(e.vehicle_id, e.work_date) as reason
  into v_conflict
  from public.distribution_roster_entries e
  where e.distribution_roster_version_id = p_roster_version_id and e.assignment_status = 'PLANNED' and e.vehicle_id is not null
    and e.work_date >= current_date
    and public.distribution_vehicle_block_reason(e.vehicle_id, e.work_date) is not null
    -- An assignment already in the published roster stays; the roster warns on it instead.
    and not exists (
      select 1 from public.distribution_roster_entries p
      join public.distribution_roster_versions pv on pv.distribution_roster_version_id = p.distribution_roster_version_id
      join public.distribution_roster_versions cv on cv.distribution_roster_version_id = e.distribution_roster_version_id
      where pv.roster_status = 'PUBLISHED' and pv.week_start = cv.week_start
        and pv.distribution_roster_version_id <> e.distribution_roster_version_id
        and p.assignment_status = 'PLANNED' and p.work_date = e.work_date
        and p.route_id is not distinct from e.route_id and p.vehicle_id = e.vehicle_id
    )
  order by e.work_date limit 1;
  if found then raise exception using errcode = '22023', message = format('Vehicle %s cannot be used on %s: %s.', v_conflict.registration_number, to_char(v_conflict.work_date, 'Dy DD Mon'), v_conflict.reason); end if;
end;
$$;


-- 5. Driver Roster week: a Driver appears from the week of their first day.
create or replace function public.get_distribution_roster_week(p_week_start date, p_roster_version_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.distribution_roster_week_start(p_week_start);
  v_roster public.distribution_roster_versions%rowtype;
begin
  perform public.require_distribution_read_access();
  if p_week_start is null or p_week_start <> v_week_start then
    raise exception using errcode = '22023', message = 'The Distribution roster must start on a Monday.';
  end if;
  if p_roster_version_id is not null then
    select * into v_roster from public.distribution_roster_versions where distribution_roster_version_id = p_roster_version_id and week_start = v_week_start;
  else
    select * into v_roster from public.distribution_roster_versions where week_start = v_week_start and roster_status in ('DRAFT', 'PUBLISHED') order by case roster_status when 'DRAFT' then 0 else 1 end, version_number desc limit 1;
  end if;
  return jsonb_build_object(
    'week_start', v_week_start, 'week_end', v_week_start + 6,
    'can_manage', public.account_module_allowed(array['DISTRIBUTION'],'EDIT',array['ADMIN','MANAGER','SUPERVISOR','DISTRIBUTION_OPERATOR']),
    'is_past', v_week_start + 6 < current_date,
    'document', case when v_roster.distribution_roster_version_id is null then null else to_jsonb(v_roster) end,
    'required_routes', coalesce(v_roster.required_routes, '{}'::jsonb),
    'routes', coalesce((select jsonb_agg(to_jsonb(r) order by r.sort_order, r.route_code) from public.distribution_routes r where r.active and r.deleted_at is null), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(to_jsonb(d) order by d.display_name) from public.distribution_drivers d where d.deleted_at is null and d.employment_status = 'ACTIVE' and (d.joined_on is null or d.joined_on <= v_week_start + 6)), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(to_jsonb(v) order by v.registration_number) from public.fleet_vehicles v where v.deleted_at is null and v.active), '[]'::jsonb),
    'vehicle_blocks', coalesce((
      select jsonb_agg(jsonb_build_object('vehicle_id', b.vehicle_id, 'work_date', b.work_date, 'reason', b.reason) order by b.work_date)
      from (
        select v.vehicle_id, days.work_date, public.distribution_vehicle_block_reason(v.vehicle_id, days.work_date) as reason
        from public.fleet_vehicles v
        cross join (select generate_series(v_week_start, v_week_start + 6, interval '1 day')::date as work_date) days
        where v.deleted_at is null and v.active and days.work_date >= current_date
      ) b where b.reason is not null
    ), '[]'::jsonb),
    'absences', coalesce((select jsonb_agg(to_jsonb(a) order by a.starts_on, a.driver_id) from public.distribution_driver_absences a where a.absence_status = 'APPROVED' and a.starts_on <= v_week_start + 6 and a.ends_on >= v_week_start), '[]'::jsonb),
    'entries', coalesce((select jsonb_agg(to_jsonb(e) order by e.work_date, e.route_code_snapshot) from public.distribution_roster_entries e where e.distribution_roster_version_id = v_roster.distribution_roster_version_id), '[]'::jsonb),
    'daily_metrics', coalesce((
      with days as (select generate_series(v_week_start, v_week_start + 6, interval '1 day')::date as work_date),
      demand as (
        select days.work_date, count(distinct d.default_route_id)::integer as scheduled_routes, count(d.schedule_day_id)::integer as scheduled_stops
        from days left join public.customer_schedule_versions sv on sv.status='PUBLISHED' and sv.effective_from <= days.work_date and (sv.effective_until is null or sv.effective_until >= days.work_date)
        left join public.customer_schedule_days d on d.schedule_version_id=sv.schedule_version_id and d.active and d.delivery_weekday=extract(isodow from days.work_date)::smallint and d.default_route_id is not null
        group by days.work_date
      )
      select jsonb_agg(jsonb_build_object('work_date',work_date,'scheduled_routes',scheduled_routes,'scheduled_stops',scheduled_stops) order by work_date) from demand
    ), '[]'::jsonb),
    'route_day_metrics', coalesce((
      with days as (select generate_series(v_week_start, v_week_start + 6, interval '1 day')::date as work_date)
      select jsonb_agg(jsonb_build_object('route_id',r.route_id,'work_date',days.work_date,'stops',coalesce(s.stop_count,0),'km',r.default_km,'hours',r.default_hours) order by days.work_date,r.sort_order,r.route_code)
      from public.distribution_routes r cross join days
      left join lateral (
        select count(d.schedule_day_id)::integer as stop_count
        from public.customer_schedule_versions sv join public.customer_schedule_days d on d.schedule_version_id=sv.schedule_version_id and d.active
        where sv.status='PUBLISHED' and sv.effective_from <= days.work_date and (sv.effective_until is null or sv.effective_until >= days.work_date)
          and d.default_route_id=r.route_id and d.delivery_weekday=extract(isodow from days.work_date)::smallint
      ) s on true
      where r.active and r.deleted_at is null
    ), '[]'::jsonb)
  );
end;
$$;

commit;
