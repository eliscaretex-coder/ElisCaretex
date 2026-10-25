-- Driver -> Production job title: plan the person in the Production Roster
-- before the move.
--
-- An approved Driver role transfer applied the Staff Master changes only on the
-- first day of the new role (nightly job). Until then the person was not in
-- the Production staff pool, so next week's Production Roster could not include
-- them (owner test 2026-10-25: Paulo Teste2, Driver until 25 Oct, Cleaner from
-- 26 Oct, missing from the roster of 26 Oct - 1 Nov).
--
-- Now:
-- * staff_members.production_roster_from: the first day a staff member can be
--   planned in the Production Roster (mirror of production_roster_until).
-- * When a transfer to a Production job title is approved with a future first
--   day, the Staff Master record is prepared at once: Production staff with the
--   approved role, area, station, shift and roster eligibility, and
--   production_roster_from = the first day. The driver link, the login job title
--   and the driver exit still change on the day, as before.
-- * Cancelling an approved transfer restores the previous Staff Master values
--   (a record created only for the transfer is soft-deleted).
-- * The Production Roster staff pool, week and checks respect
--   production_roster_from.

begin;

alter table public.staff_members
  add column if not exists production_roster_from date;

comment on column public.staff_members.production_roster_from is
  'First day the staff member can be planned in the Production Roster (set by an approved Driver role transfer). Null = no restriction.';

alter table public.distribution_driver_role_transfers
  add column if not exists staff_prepared_at timestamptz,
  add column if not exists staff_prepared_created boolean not null default false,
  add column if not exists staff_prepared_snapshot jsonb;


-- 1. Prepare the Staff Master record of an approved transfer (internal).
create or replace function public.prepare_driver_role_transfer_staff(p_transfer_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_transfer public.distribution_driver_role_transfers%rowtype;
  v_driver public.distribution_drivers%rowtype;
  v_staff public.staff_members%rowtype;
  v_staff_id uuid;
  v_effective date;
  v_created boolean := false;
  v_actor uuid;
begin
  select t.* into v_transfer from public.distribution_driver_role_transfers t where t.transfer_id = p_transfer_id;
  if not found
     or v_transfer.transfer_status <> 'APPROVED'
     or v_transfer.applied_at is not null
     or v_transfer.staff_prepared_at is not null
     or not public.job_title_keeps_production_roster(v_transfer.job_title_code) then
    return null;
  end if;

  v_effective := v_transfer.last_driver_day + 1;
  if v_effective <= (now() at time zone 'Europe/Dublin')::date then
    return null;  -- applied now by the approval itself
  end if;

  select d.* into v_driver from public.distribution_drivers d where d.driver_id = v_transfer.driver_id;
  v_staff_id := coalesce(v_driver.staff_id, v_transfer.staff_id);
  v_actor := coalesce(auth.uid(), v_transfer.decided_by);

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
      production_staff = true,
      roster_eligible = coalesce(v_transfer.roster_eligible, true),
      primary_operational_role_id = v_transfer.primary_operational_role_id,
      default_area_id = v_transfer.default_area_id,
      default_station_id = v_transfer.default_station_id,
      default_shift_id = v_transfer.default_shift_id,
      production_roster_until = null,
      production_roster_from = v_effective,
      updated_by = v_actor,
      row_version = sm.row_version + 1
    where sm.staff_id = v_staff_id;
  else
    insert into public.staff_members(
      employee_code, display_name, active, production_staff, roster_eligible,
      default_shift_id, primary_operational_role_id, default_area_id, default_station_id,
      joined_on, production_roster_from, notes, row_version, created_by, updated_by
    )
    values (
      public.generate_staff_employee_code(), v_driver.display_name, true, true, coalesce(v_transfer.roster_eligible, true),
      v_transfer.default_shift_id, v_transfer.primary_operational_role_id, v_transfer.default_area_id, v_transfer.default_station_id,
      case when v_driver.joined_on <= v_effective then v_driver.joined_on else null end, v_effective,
      format('Moves from Distribution driver %s on %s.', v_driver.driver_code, to_char(v_effective, 'DD Mon YYYY')),
      1, v_actor, v_actor
    )
    returning staff_id into v_staff_id;
    v_created := true;
  end if;

  update public.distribution_driver_role_transfers t set
    staff_id = v_staff_id,
    staff_prepared_at = now(),
    staff_prepared_created = v_created,
    staff_prepared_snapshot = case when v_created then null else jsonb_build_object(
      'active', v_staff.active,
      'production_staff', v_staff.production_staff,
      'roster_eligible', v_staff.roster_eligible,
      'primary_operational_role_id', v_staff.primary_operational_role_id,
      'default_area_id', v_staff.default_area_id,
      'default_station_id', v_staff.default_station_id,
      'default_shift_id', v_staff.default_shift_id,
      'production_roster_until', v_staff.production_roster_until,
      'production_roster_from', v_staff.production_roster_from
    ) end
  where t.transfer_id = p_transfer_id;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, old_data, new_data, reason, source_application)
  values (v_actor, public.current_staff_id(), 'PREPARE_DRIVER_ROLE_TRANSFER_STAFF', 'staff_members', v_staff_id::text,
    case when v_created then null else to_jsonb(v_staff) end,
    jsonb_build_object('transfer_id', p_transfer_id, 'job_title_code', v_transfer.job_title_code,
      'production_roster_from', v_effective, 'staff_created', v_created),
    'Approved Driver transfer: the person can be planned in the Production Roster from the first day of the new role.',
    'DRIVER_ROLE_TRANSFER');

  perform set_config('eliscaretex.staff_write_context', '', true);
  return v_staff_id;
end;
$$;

revoke all on function public.prepare_driver_role_transfer_staff(uuid) from public, anon, authenticated;


-- 2. Undo a prepared Staff Master record when an approved transfer is cancelled (internal).
create or replace function public.revert_driver_role_transfer_staff(p_transfer_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_transfer public.distribution_driver_role_transfers%rowtype;
  v_snapshot jsonb;
begin
  select t.* into v_transfer from public.distribution_driver_role_transfers t where t.transfer_id = p_transfer_id;
  if not found or v_transfer.staff_prepared_at is null or v_transfer.applied_at is not null or v_transfer.staff_id is null then
    return;
  end if;
  v_snapshot := v_transfer.staff_prepared_snapshot;

  perform set_config('eliscaretex.staff_write_context', 'DRIVER_ROLE_TRANSFER', true);

  if v_transfer.staff_prepared_created then
    update public.staff_members sm set
      active = false,
      production_staff = false,
      roster_eligible = false,
      production_roster_from = null,
      deleted_at = now(),
      updated_by = auth.uid(),
      row_version = sm.row_version + 1
    where sm.staff_id = v_transfer.staff_id and sm.deleted_at is null;
  else
    update public.staff_members sm set
      active = coalesce((v_snapshot->>'active')::boolean, sm.active),
      production_staff = coalesce((v_snapshot->>'production_staff')::boolean, false),
      roster_eligible = coalesce((v_snapshot->>'roster_eligible')::boolean, false),
      primary_operational_role_id = (v_snapshot->>'primary_operational_role_id')::uuid,
      default_area_id = (v_snapshot->>'default_area_id')::uuid,
      default_station_id = (v_snapshot->>'default_station_id')::uuid,
      default_shift_id = (v_snapshot->>'default_shift_id')::uuid,
      production_roster_until = (v_snapshot->>'production_roster_until')::date,
      production_roster_from = (v_snapshot->>'production_roster_from')::date,
      updated_by = auth.uid(),
      row_version = sm.row_version + 1
    where sm.staff_id = v_transfer.staff_id and sm.deleted_at is null;
  end if;

  insert into public.audit_log(actor_auth_user_id, actor_staff_id, action, entity_table, entity_id, new_data, reason, source_application)
  values (auth.uid(), public.current_staff_id(), 'REVERT_DRIVER_ROLE_TRANSFER_STAFF', 'staff_members', v_transfer.staff_id::text,
    jsonb_build_object('transfer_id', p_transfer_id, 'staff_created', v_transfer.staff_prepared_created, 'restored', v_snapshot),
    'Driver transfer cancelled: the Staff Master record is back to its values before approval.', 'DRIVER_ROLE_TRANSFER');

  perform set_config('eliscaretex.staff_write_context', '', true);
end;
$$;

revoke all on function public.revert_driver_role_transfer_staff(uuid) from public, anon, authenticated;


-- 3. Approval prepares, cancellation reverts, application clears the start date.
create or replace function public.driver_role_transfer_staff_sync()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.transfer_status = 'APPROVED' and old.transfer_status = 'PENDING' then
    perform public.prepare_driver_role_transfer_staff(new.transfer_id);
  elsif new.transfer_status = 'CANCELLED' and old.transfer_status = 'APPROVED' then
    perform public.revert_driver_role_transfer_staff(new.transfer_id);
  elsif new.transfer_status = 'COMPLETED' and old.transfer_status <> 'COMPLETED' and new.staff_id is not null then
    perform set_config('eliscaretex.staff_write_context', 'DRIVER_ROLE_TRANSFER', true);
    update public.staff_members sm set production_roster_from = null
    where sm.staff_id = new.staff_id and sm.production_roster_from is not null;
    perform set_config('eliscaretex.staff_write_context', '', true);
  end if;
  return null;
end;
$$;

revoke all on function public.driver_role_transfer_staff_sync() from public, anon, authenticated;

drop trigger if exists distribution_driver_role_transfers_staff_sync on public.distribution_driver_role_transfers;
create trigger distribution_driver_role_transfers_staff_sync
after update of transfer_status on public.distribution_driver_role_transfers
for each row execute function public.driver_role_transfer_staff_sync();


-- 4. Production Roster checks: nothing before the first Production day.
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
  group by sm.staff_id, sm.display_name, sm.joined_on, sm.deactivated_on, sm.production_staff, sm.deleted_at, sm.production_roster_until, sm.production_roster_from
  having sm.production_staff is not true
      or sm.deleted_at is not null
      or (sm.joined_on is not null and sm.joined_on > v_period.week_start + 6)
      or (sm.deactivated_on is not null and sm.deactivated_on < v_period.week_start)
      or (sm.production_roster_until is not null and sm.production_roster_until < v_period.week_start)
      or (sm.production_roster_from is not null and sm.production_roster_from > v_period.week_start + 6)
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
      or (sm.production_roster_from is not null and pre.work_date < sm.production_roster_from)
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


-- 5. Staff pool: staff starting Production later in the week are offered,
--    with their first day.
create or replace function public.get_production_roster_staff_pool(p_week_start date, p_shift_code text, p_roster_version_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift public.shifts%rowtype;
  v_version public.production_roster_versions%rowtype;
  v_period_id uuid;
begin
  perform public.require_production_roster_read_role();

  select * into v_shift
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code))
    and s.active = true
    and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid or inactive shift.';
  end if;

  select rp.roster_period_id into v_period_id
  from public.roster_periods rp
  where rp.week_start = v_week_start;

  if p_roster_version_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where prv.roster_version_id = p_roster_version_id
      and rp.week_start = v_week_start
      and prv.shift_id = v_shift.shift_id;
  elsif v_period_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id
      and prv.shift_id = v_shift.shift_id
      and prv.status in ('DRAFT', 'PUBLISHED')
    order by case prv.status when 'DRAFT' then 1 else 2 end,
             prv.version_number desc
    limit 1;
  end if;

  return jsonb_build_object(
    'week_start', v_week_start,
    'roster_shift_code', v_shift.shift_code,
    'roster_shift_name', v_shift.shift_name,
    'roster_version_id', v_version.roster_version_id,
    'staff', coalesce((
      with version_staff as (
        select distinct on (pre.staff_id)
          pre.staff_id,
          pre.staff_display_name_snapshot as display_name,
          pre.employee_code_snapshot as employee_code,
          coalesce(pre.staff_default_shift_code_snapshot, pre.shift_code_snapshot) as default_shift_code,
          coalesce(pre.staff_default_shift_name_snapshot, pre.shift_name_snapshot) as default_shift_name,
          pre.staff_primary_role_code_snapshot as primary_role_code,
          pre.staff_primary_role_name_snapshot as primary_role_name,
          pre.staff_default_area_code_snapshot as default_area_code,
          pre.staff_default_area_name_snapshot as default_area_name,
          pre.staff_default_station_code_snapshot as default_station_code,
          pre.staff_default_station_name_snapshot as default_station_name,
          pre.display_section_code,
          pre.fire_training_snapshot as fire_training,
          pre.first_aid_training_snapshot as first_aid_training,
          pre.eod_capable_snapshot as eod_capable,
          sm.joined_on,
          sm.deactivated_on,
          sm.active as master_active,
          sm.roster_eligible as master_roster_eligible,
          sm.production_staff as master_production_staff,
          sm.deleted_at as master_deleted_at,
          sm.production_roster_until,
          sm.production_roster_from
        from public.production_roster_entries pre
        left join public.staff_members sm on sm.staff_id = pre.staff_id
        where pre.roster_version_id = v_version.roster_version_id
        order by pre.staff_id, pre.work_date
      ),
      current_staff as (
        select
          sm.staff_id,
          sm.display_name,
          sm.employee_code,
          sh.shift_code as default_shift_code,
          sh.shift_name as default_shift_name,
          opr.role_code as primary_role_code,
          opr.role_name as primary_role_name,
          a.area_code as default_area_code,
          a.area_name as default_area_name,
          st.station_code as default_station_code,
          st.station_name as default_station_name,
          public.production_roster_default_display_section(opr.role_code, st.station_code) as display_section_code,
          sm.fire_training,
          sm.first_aid_training,
          sm.eod_capable,
          sm.joined_on,
          sm.deactivated_on,
          sm.active as master_active,
          sm.roster_eligible as master_roster_eligible,
          sm.production_staff as master_production_staff,
          sm.deleted_at as master_deleted_at,
          sm.production_roster_until,
          sm.production_roster_from,
          coalesce(opr.sort_order, 999) as role_sort,
          coalesce(st.sort_order, 999) as station_sort
        from public.staff_members sm
        join public.shifts sh on sh.shift_id = sm.default_shift_id
        left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
        left join public.areas a on a.area_id = sm.default_area_id
        left join public.stations st on st.station_id = sm.default_station_id
        where sm.production_staff = true
          and sm.deleted_at is null
          and (sm.joined_on is null or sm.joined_on <= v_week_start + 6)
          and (sm.deactivated_on is null or sm.deactivated_on >= v_week_start)
          and (
            (sm.active = true and sm.roster_eligible = true)
            or sm.deactivated_on is not null
          )
          and (sm.production_roster_until is null or sm.production_roster_until >= v_week_start)
          and (sm.production_roster_from is null or sm.production_roster_from <= v_week_start + 6)
          and sh.active = true
          and sh.deleted_at is null
      ),
      pool as (
        select
          cs.staff_id,
          coalesce(vs.display_name, cs.display_name) as display_name,
          coalesce(vs.employee_code, cs.employee_code) as employee_code,
          coalesce(vs.default_shift_code, cs.default_shift_code) as default_shift_code,
          coalesce(vs.default_shift_name, cs.default_shift_name) as default_shift_name,
          coalesce(vs.primary_role_code, cs.primary_role_code) as primary_role_code,
          coalesce(vs.primary_role_name, cs.primary_role_name) as primary_role_name,
          coalesce(vs.default_area_code, cs.default_area_code) as default_area_code,
          coalesce(vs.default_area_name, cs.default_area_name) as default_area_name,
          coalesce(vs.default_station_code, cs.default_station_code) as default_station_code,
          coalesce(vs.default_station_name, cs.default_station_name) as default_station_name,
          coalesce(vs.display_section_code, cs.display_section_code) as display_section_code,
          coalesce(vs.fire_training, cs.fire_training, false) as fire_training,
          coalesce(vs.first_aid_training, cs.first_aid_training, false) as first_aid_training,
          coalesce(vs.eod_capable, cs.eod_capable, false) as eod_capable,
          cs.joined_on,
          cs.deactivated_on,
          cs.master_active,
          cs.master_roster_eligible,
          cs.master_production_staff,
          cs.master_deleted_at,
          cs.production_roster_until,
          cs.production_roster_from,
          (vs.staff_id is not null) as included_in_roster,
          true as currently_eligible,
          cs.role_sort,
          cs.station_sort
        from current_staff cs
        left join version_staff vs on vs.staff_id = cs.staff_id

        union all

        select
          vs.staff_id,
          vs.display_name,
          vs.employee_code,
          vs.default_shift_code,
          vs.default_shift_name,
          vs.primary_role_code,
          vs.primary_role_name,
          vs.default_area_code,
          vs.default_area_name,
          vs.default_station_code,
          vs.default_station_name,
          vs.display_section_code,
          coalesce(vs.fire_training, false),
          coalesce(vs.first_aid_training, false),
          coalesce(vs.eod_capable, false),
          vs.joined_on,
          vs.deactivated_on,
          vs.master_active,
          vs.master_roster_eligible,
          vs.master_production_staff,
          vs.master_deleted_at,
          vs.production_roster_until,
          vs.production_roster_from,
          true,
          (
            coalesce(vs.master_production_staff, false) = true
            and vs.master_deleted_at is null
            and (vs.production_roster_until is null or vs.production_roster_until >= v_week_start)
            and (vs.production_roster_from is null or vs.production_roster_from <= v_week_start + 6)
            and (vs.joined_on is null or vs.joined_on <= v_week_start + 6)
            and (vs.deactivated_on is null or vs.deactivated_on >= v_week_start)
            and (
              (coalesce(vs.master_active, false) = true and coalesce(vs.master_roster_eligible, false) = true)
              or vs.deactivated_on is not null
            )
          ),
          999,
          999
        from version_staff vs
        where not exists (
          select 1 from current_staff cs where cs.staff_id = vs.staff_id
        )
      )
      select jsonb_agg(jsonb_build_object(
        'staff_id', p.staff_id,
        'display_name', p.display_name,
        'employee_code', p.employee_code,
        'default_shift_code', p.default_shift_code,
        'default_shift_name', p.default_shift_name,
        'primary_role_code', p.primary_role_code,
        'primary_role_name', p.primary_role_name,
        'default_area_code', p.default_area_code,
        'default_area_name', p.default_area_name,
        'default_station_code', p.default_station_code,
        'default_station_name', p.default_station_name,
        'display_section_code', p.display_section_code,
        'fire_training', p.fire_training,
        'first_aid_training', p.first_aid_training,
        'eod_capable', p.eod_capable,
        'joined_on', p.joined_on,
        'deactivated_on', p.deactivated_on,
        'master_active', p.master_active,
        'master_roster_eligible', p.master_roster_eligible,
        'master_production_staff', p.master_production_staff,
        'production_roster_until', p.production_roster_until,
        'production_roster_from', p.production_roster_from,
        'cover_role_codes', coalesce((
          select jsonb_agg(cr.role_code order by cr.sort_order)
          from public.staff_cover_capabilities scc
          join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
          where scc.staff_id = p.staff_id
            and scc.active = true
            and scc.deleted_at is null
            and scc.effective_from <= v_week_start + 6
            and (scc.effective_until is null or scc.effective_until >= v_week_start)
        ), '[]'::jsonb),
        'included_in_roster', p.included_in_roster,
        'currently_eligible', p.currently_eligible,
        'shift_override', coalesce(p.default_shift_code, '') <> v_shift.shift_code,
        'roster_shift_code', v_shift.shift_code,
        'roster_shift_name', v_shift.shift_name
      ) order by
        case when p.default_shift_code = v_shift.shift_code then 0 else 1 end,
        p.role_sort,
        p.station_sort,
        lower(p.display_name))
      from pool p
    ), '[]'::jsonb)
  );
end;
$$;


-- 6. A week without a saved version lists staff from their first Production week.
create or replace function public.get_production_roster_week(p_week_start date, p_shift_code text, p_roster_version_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift public.shifts%rowtype;
  v_version public.production_roster_versions%rowtype;
  v_period_id uuid;
  v_can_manage boolean;
  v_is_past boolean := v_week_start < public.production_roster_week_start(current_date);
begin
  perform public.require_production_roster_read_role();
  v_can_manage := public.account_module_allowed(array['PRODUCTION_ROSTER'],'EDIT',array['ADMIN', 'MANAGER', 'ROSTER_MANAGER']);

  select * into v_shift
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code))
    and s.active = true
    and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid or inactive shift.';
  end if;

  select rp.roster_period_id into v_period_id
  from public.roster_periods rp
  where rp.week_start = v_week_start;

  if p_roster_version_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where prv.roster_version_id = p_roster_version_id
      and rp.week_start = v_week_start
      and prv.shift_id = v_shift.shift_id;
  elsif v_period_id is not null then
    select prv.* into v_version
    from public.production_roster_versions prv
    where prv.roster_period_id = v_period_id
      and prv.shift_id = v_shift.shift_id
      and prv.status in ('DRAFT', 'PUBLISHED')
    order by case prv.status when 'DRAFT' then 1 else 2 end, prv.version_number desc
    limit 1;
  end if;

  return jsonb_build_object(
    'week_start', v_week_start,
    'week_end', v_week_start + 6,
    'is_past', v_is_past,
    'can_manage', v_can_manage,
    'shift', jsonb_build_object(
      'shift_id', v_shift.shift_id,
      'shift_code', v_shift.shift_code,
      'shift_name', v_shift.shift_name,
      'start_time', v_shift.start_time,
      'end_time', v_shift.end_time
    ),
    'document', case when v_version.roster_version_id is null then null else jsonb_build_object(
      'roster_version_id', v_version.roster_version_id,
      'version_number', v_version.version_number,
      'status', v_version.status,
      'include_sunday', v_version.include_sunday,
      'week_note', v_version.week_note,
      'row_version', v_version.row_version,
      'based_on_version_id', v_version.based_on_version_id,
      'saved_at', v_version.saved_at,
      'published_at', v_version.published_at,
      'is_historical', p_roster_version_id is not null
    ) end,
    'published_document', (
      select jsonb_build_object(
        'roster_version_id', p.roster_version_id,
        'version_number', p.version_number,
        'published_at', p.published_at
      )
      from public.production_roster_versions p
      where p.roster_period_id = v_period_id
        and p.shift_id = v_shift.shift_id
        and p.status = 'PUBLISHED'
      limit 1
    ),
    'staff', case
      when v_version.roster_version_id is not null then coalesce((
        select jsonb_agg(staff_row order by
          (staff_row ->> 'display_section_sort')::integer,
          (staff_row ->> 'group_sort')::integer,
          (staff_row ->> 'station_sort')::integer,
          lower(staff_row ->> 'display_name')
        )
        from (
          select distinct on (pre.staff_id)
            jsonb_build_object(
              'staff_id', pre.staff_id,
              'display_name', pre.staff_display_name_snapshot,
              'employee_code', pre.employee_code_snapshot,
              'default_shift_code', coalesce(pre.staff_default_shift_code_snapshot, pre.shift_code_snapshot),
              'default_shift_name', coalesce(pre.staff_default_shift_name_snapshot, pre.shift_name_snapshot),
              'primary_role_code', coalesce(pre.staff_primary_role_code_snapshot, sm_role.role_code),
              'primary_role_name', coalesce(pre.staff_primary_role_name_snapshot, sm_role.role_name),
              'default_area_code', coalesce(pre.staff_default_area_code_snapshot, sm_area.area_code),
              'default_area_name', coalesce(pre.staff_default_area_name_snapshot, sm_area.area_name),
              'default_station_code', coalesce(pre.staff_default_station_code_snapshot, sm_station.station_code),
              'default_station_name', coalesce(pre.staff_default_station_name_snapshot, sm_station.station_name),
              'display_section_code', pre.display_section_code,
              'shift_override_authorized', exists (
                select 1
                from public.production_roster_shift_overrides pro
                where pro.roster_version_id = pre.roster_version_id
                  and pro.staff_id = pre.staff_id
              ),
              'shift_override_source', (
                select pro.source_application
                from public.production_roster_shift_overrides pro
                where pro.roster_version_id = pre.roster_version_id
                  and pro.staff_id = pre.staff_id
                limit 1
              ),
              'display_section_sort', public.production_roster_display_section_sort(pre.display_section_code),
              'fire_training', pre.fire_training_snapshot,
              'first_aid_training', pre.first_aid_training_snapshot,
              'eod_capable', pre.eod_capable_snapshot,
              'cover_role_codes', coalesce((
                select jsonb_agg(cr.role_code order by cr.sort_order)
                from public.staff_cover_capabilities scc
                join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
                where scc.staff_id = pre.staff_id
                  and scc.active = true
                  and scc.deleted_at is null
                  and scc.effective_from <= current_date
                  and (scc.effective_until is null or scc.effective_until >= current_date)
              ), '[]'::jsonb),
              'group_sort', coalesce(sm_role.sort_order, 999),
              'station_sort', coalesce(sm_station.sort_order, 999)
            ) as staff_row
          from public.production_roster_entries pre
          left join public.staff_members sm on sm.staff_id = pre.staff_id
          left join public.operational_roles sm_role on sm_role.operational_role_id = sm.primary_operational_role_id
          left join public.areas sm_area on sm_area.area_id = sm.default_area_id
          left join public.stations sm_station on sm_station.station_id = sm.default_station_id
          where pre.roster_version_id = v_version.roster_version_id
          order by pre.staff_id, pre.work_date
        ) rows
      ), '[]'::jsonb)
      else coalesce((
        select jsonb_agg(jsonb_build_object(
          'staff_id', sm.staff_id,
          'display_name', sm.display_name,
          'employee_code', sm.employee_code,
          'default_shift_code', s.shift_code,
          'primary_role_code', opr.role_code,
          'primary_role_name', opr.role_name,
          'default_area_code', a.area_code,
          'default_area_name', a.area_name,
          'default_station_code', st.station_code,
          'default_station_name', st.station_name,
          'display_section_code', public.production_roster_default_display_section(opr.role_code, st.station_code),
          'shift_override_authorized', false,
          'shift_override_source', null,
          'display_section_sort', public.production_roster_display_section_sort(public.production_roster_default_display_section(opr.role_code, st.station_code)),
          'fire_training', sm.fire_training,
          'first_aid_training', sm.first_aid_training,
          'eod_capable', sm.eod_capable,
          'production_roster_from', sm.production_roster_from,
          'cover_role_codes', coalesce((
            select jsonb_agg(cr.role_code order by cr.sort_order)
            from public.staff_cover_capabilities scc
            join public.operational_roles cr on cr.operational_role_id = scc.operational_role_id
            where scc.staff_id = sm.staff_id
              and scc.active = true
              and scc.deleted_at is null
              and scc.effective_from <= v_week_start + 6
              and (scc.effective_until is null or scc.effective_until >= v_week_start)
          ), '[]'::jsonb),
          'group_sort', coalesce(opr.sort_order, 999),
          'station_sort', coalesce(st.sort_order, 999)
        ) order by
          public.production_roster_display_section_sort(public.production_roster_default_display_section(opr.role_code, st.station_code)),
          coalesce(opr.sort_order, 999),
          coalesce(st.sort_order, 999),
          lower(sm.display_name))
        from public.staff_members sm
        join public.shifts s on s.shift_id = sm.default_shift_id
        left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
        left join public.areas a on a.area_id = sm.default_area_id
        left join public.stations st on st.station_id = sm.default_station_id
        where sm.production_staff = true
          and sm.active = true
          and sm.roster_eligible = true
          and sm.deleted_at is null
          and (sm.production_roster_until is null or sm.production_roster_until >= v_week_start)
          and (sm.production_roster_from is null or sm.production_roster_from <= v_week_start + 6)
          and s.shift_id = v_shift.shift_id
      ), '[]'::jsonb)
    end,
    'entries', case when v_version.roster_version_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'roster_entry_id', pre.roster_entry_id,
        'staff_id', pre.staff_id,
        'work_date', pre.work_date,
        'day_status', pre.day_status,
        'assignment_type', pre.assignment_type,
        'operational_role_code', opr.role_code,
        'operational_role_name', pre.operational_role_name_snapshot,
        'area_code', a.area_code,
        'area_name', pre.area_name_snapshot,
        'station_code', st.station_code,
        'station_name', pre.station_name_snapshot,
        'sorting_work_mode', pre.sorting_work_mode,
        'display_section_code', pre.display_section_code,
        'shift_override_confirmed', exists (
          select 1
          from public.production_roster_shift_overrides pro
          where pro.roster_version_id = pre.roster_version_id
            and pro.staff_id = pre.staff_id
        ),
        'planned_start_time', pre.planned_start_time,
        'planned_end_time', pre.planned_end_time,
        'notes', pre.notes
      ) order by pre.work_date, lower(pre.staff_display_name_snapshot))
      from public.production_roster_entries pre
      left join public.operational_roles opr on opr.operational_role_id = pre.operational_role_id
      left join public.areas a on a.area_id = pre.area_id
      left join public.stations st on st.station_id = pre.station_id
      where pre.roster_version_id = v_version.roster_version_id
    ), '[]'::jsonb) end
  );
end;
$$;


-- 7. Transfers already approved for a future day are prepared now.
select public.prepare_driver_role_transfer_staff(t.transfer_id)
from public.distribution_driver_role_transfers t
where t.transfer_status = 'APPROVED' and t.applied_at is null and t.staff_prepared_at is null;

commit;
