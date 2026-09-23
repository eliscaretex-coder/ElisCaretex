-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608040005_staff_production_scope.sql
-- Purpose:
--   - separate production/roster staff from authentication-only profiles;
--   - keep ADMIN and other non-production user profiles out of Staff Master;
--   - establish the mandatory scope filter for the future Production Roster;
--   - preserve the possibility of linking an auth user to a real production
--     staff record without changing that staff member's production scope.
-- =====================================================================

begin;

alter table public.staff_members
  add column if not exists production_staff boolean not null default false;

comment on column public.staff_members.production_staff is
  'True only for staff who belong to the productive workforce and may be managed in Staff Master. Authentication-only profiles remain false.';

alter table public.staff_members
  alter column roster_eligible set default false;

-- Existing imported or manually created operational records are production
-- staff. Auth-linked profiles with no operational assignment remain system-only.
update public.staff_members sm
set production_staff = true
where sm.deleted_at is null
  and (
    sm.legacy_user_id is not null
    or sm.primary_operational_role_id is not null
    or sm.default_area_id is not null
    or sm.default_station_id is not null
  );

update public.staff_members sm
set roster_eligible = false
where sm.production_staff = false
  and sm.roster_eligible = true;

create or replace function public.apply_staff_production_scope()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.production_staff = false
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

drop trigger if exists staff_members_production_scope_trigger
  on public.staff_members;

create trigger staff_members_production_scope_trigger
before insert or update of
  production_staff,
  legacy_user_id,
  primary_operational_role_id,
  default_area_id,
  default_station_id,
  roster_eligible
on public.staff_members
for each row
execute function public.apply_staff_production_scope();

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'staff_members_roster_scope_check'
      and conrelid = 'public.staff_members'::regclass
  ) then
    alter table public.staff_members
      add constraint staff_members_roster_scope_check
      check (production_staff = true or roster_eligible = false);
  end if;
end;
$$;

create index if not exists staff_members_production_directory_idx
  on public.staff_members (
    production_staff,
    active,
    roster_eligible,
    default_shift_id,
    display_name
  )
  where deleted_at is null;

-- Staff Master APIs are redefined below so they can never expose or mutate
-- authentication-only profiles.

create or replace function public.get_staff_directory(
  p_status text default 'ACTIVE',
  p_shift_code text default null,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_status text := upper(coalesce(nullif(trim(p_status), ''), 'ACTIVE'));
  v_shift_code text := upper(nullif(trim(p_shift_code), ''));
  v_search text := lower(nullif(trim(p_search), ''));
begin
  perform public.require_staff_master_read_role();

  if v_status not in ('ALL', 'ACTIVE', 'INACTIVE', 'REVIEW') then
    raise exception 'Invalid Staff Master status filter.';
  end if;

  return jsonb_build_object(
    'summary', jsonb_build_object(
      'total', (select count(*) from public.staff_members sm where sm.production_staff = true and sm.deleted_at is null),
      'active', (select count(*) from public.staff_members sm where sm.production_staff = true and sm.active = true and sm.deleted_at is null),
      'inactive', (select count(*) from public.staff_members sm where sm.production_staff = true and sm.active = false and sm.deleted_at is null),
      'roster_eligible', (select count(*) from public.staff_members sm where sm.production_staff = true and sm.active = true and sm.roster_eligible = true and sm.deleted_at is null),
      'review_required', (select count(*) from public.staff_members sm where sm.production_staff = true and sm.import_review_required = true and sm.deleted_at is null)
    ),
    'staff', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'staff_id', sm.staff_id,
          'legacy_user_id', sm.legacy_user_id,
          'employee_code', sm.employee_code,
          'display_name', sm.display_name,
          'active', sm.active,
          'production_staff', sm.production_staff,
          'roster_eligible', sm.roster_eligible,
          'default_shift_code', sh.shift_code,
          'default_shift_name', sh.shift_name,
          'primary_role_code', opr.role_code,
          'primary_role_name', opr.role_name,
          'default_area_code', a.area_code,
          'default_area_name', a.area_name,
          'default_station_code', st.station_code,
          'default_station_name', st.station_name,
          'fire_training', sm.fire_training,
          'first_aid_training', sm.first_aid_training,
          'eod_capable', sm.eod_capable,
          'joined_on', sm.joined_on,
          'deactivated_on', sm.deactivated_on,
          'deactivation_reason', sm.deactivation_reason,
          'import_review_required', sm.import_review_required,
          'import_review_notes', sm.import_review_notes,
          'cover_roles', coalesce((
            select jsonb_agg(jsonb_build_object(
              'role_code', cover_role.role_code,
              'role_name', cover_role.role_name
            ) order by cover_role.sort_order, cover_role.role_name)
            from public.staff_cover_capabilities scc
            join public.operational_roles cover_role
              on cover_role.operational_role_id = scc.operational_role_id
            where scc.staff_id = sm.staff_id
              and scc.active = true
              and scc.effective_from <= current_date
              and (scc.effective_until is null or scc.effective_until >= current_date)
              and scc.deleted_at is null
              and cover_role.active = true
              and cover_role.deleted_at is null
          ), '[]'::jsonb),
          'row_version', sm.row_version,
          'updated_at', sm.updated_at
        )
        order by
          case when sm.active then 0 else 1 end,
          coalesce(sh.sort_order, 999),
          coalesce(opr.sort_order, 999),
          lower(sm.display_name)
      )
      from public.staff_members sm
      left join public.shifts sh on sh.shift_id = sm.default_shift_id
      left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
      left join public.areas a on a.area_id = sm.default_area_id
      left join public.stations st on st.station_id = sm.default_station_id
      where sm.production_staff = true
        and sm.deleted_at is null
        and (
          v_status = 'ALL'
          or (v_status = 'ACTIVE' and sm.active = true)
          or (v_status = 'INACTIVE' and sm.active = false)
          or (v_status = 'REVIEW' and sm.import_review_required = true)
        )
        and (v_shift_code is null or sh.shift_code = v_shift_code)
        and (
          v_search is null
          or lower(sm.display_name) like '%' || v_search || '%'
          or lower(coalesce(sm.employee_code, '')) like '%' || v_search || '%'
          or lower(coalesce(opr.role_name, '')) like '%' || v_search || '%'
          or lower(coalesce(st.station_name, '')) like '%' || v_search || '%'
        )
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_staff_master_record(
  p_staff_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_result jsonb;
begin
  perform public.require_staff_master_read_role();

  if p_staff_id is null then
    raise exception 'Staff ID is required.';
  end if;

  select jsonb_build_object(
    'staff_id', sm.staff_id,
    'legacy_user_id', sm.legacy_user_id,
    'employee_code', sm.employee_code,
    'display_name', sm.display_name,
    'active', sm.active,
    'production_staff', sm.production_staff,
    'roster_eligible', sm.roster_eligible,
    'default_shift_code', sh.shift_code,
    'primary_role_code', opr.role_code,
    'default_area_code', a.area_code,
    'default_station_code', st.station_code,
    'fire_training', sm.fire_training,
    'first_aid_training', sm.first_aid_training,
    'eod_capable', sm.eod_capable,
    'joined_on', sm.joined_on,
    'deactivated_on', sm.deactivated_on,
    'deactivation_reason', sm.deactivation_reason,
    'notes', sm.notes,
    'import_review_required', sm.import_review_required,
    'import_review_notes', sm.import_review_notes,
    'cover_role_codes', coalesce((
      select array_agg(cover_role.role_code order by cover_role.sort_order, cover_role.role_code)
      from public.staff_cover_capabilities scc
      join public.operational_roles cover_role
        on cover_role.operational_role_id = scc.operational_role_id
      where scc.staff_id = sm.staff_id
        and scc.active = true
        and scc.effective_from <= current_date
        and (scc.effective_until is null or scc.effective_until >= current_date)
        and scc.deleted_at is null
    ), array[]::text[]),
    'row_version', sm.row_version,
    'created_at', sm.created_at,
    'updated_at', sm.updated_at
  )
  into v_result
  from public.staff_members sm
  left join public.shifts sh on sh.shift_id = sm.default_shift_id
  left join public.operational_roles opr on opr.operational_role_id = sm.primary_operational_role_id
  left join public.areas a on a.area_id = sm.default_area_id
  left join public.stations st on st.station_id = sm.default_station_id
  where sm.staff_id = p_staff_id
    and sm.production_staff = true
    and sm.deleted_at is null;

  if v_result is null then
    raise exception using errcode = 'P0002', message = 'Staff member not found.';
  end if;

  return v_result;
end;
$$;

create or replace function public.create_staff_master(
  p_display_name text,
  p_employee_code text default null,
  p_default_shift_code text default null,
  p_primary_role_code text default null,
  p_default_area_code text default null,
  p_default_station_code text default null,
  p_roster_eligible boolean default true,
  p_cover_role_codes text[] default array[]::text[],
  p_fire_training boolean default false,
  p_first_aid_training boolean default false,
  p_eod_capable boolean default false,
  p_joined_on date default null,
  p_notes text default null,
  p_change_reason text default null,
  p_source_application text default 'STAFF_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_defaults record;
  v_shift_id uuid;
  v_staff public.staff_members%rowtype;
  v_employee_code text;
begin
  perform public.require_staff_master_manage_role();

  if nullif(trim(p_display_name), '') is null then
    raise exception 'Staff name is required.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception 'A creation reason is required.';
  end if;

  select * into v_defaults
  from public.validate_staff_work_defaults(
    p_primary_role_code,
    p_default_area_code,
    p_default_station_code
  );

  if nullif(trim(p_default_shift_code), '') is not null then
    select s.shift_id into v_shift_id
    from public.shifts s
    where s.shift_code = upper(trim(p_default_shift_code))
      and s.active = true
      and s.deleted_at is null;

    if v_shift_id is null then
      raise exception 'Default shift is invalid or inactive.';
    end if;
  end if;

  v_employee_code := upper(nullif(trim(p_employee_code), ''));
  if v_employee_code is null then
    v_employee_code := public.generate_staff_employee_code();
  end if;

  if exists (
    select 1 from public.staff_members sm where sm.employee_code = v_employee_code
  ) then
    raise exception 'Employee code already exists.';
  end if;

  insert into public.staff_members (
    employee_code,
    display_name,
    active,
    production_staff,
    roster_eligible,
    default_shift_id,
    primary_operational_role_id,
    default_area_id,
    default_station_id,
    fire_training,
    first_aid_training,
    eod_capable,
    joined_on,
    notes,
    row_version,
    created_by,
    updated_by
  )
  values (
    v_employee_code,
    trim(p_display_name),
    true,
    true,
    coalesce(p_roster_eligible, true),
    v_shift_id,
    v_defaults.operational_role_id,
    v_defaults.area_id,
    v_defaults.station_id,
    coalesce(p_fire_training, false),
    coalesce(p_first_aid_training, false),
    coalesce(p_eod_capable, false),
    p_joined_on,
    nullif(trim(p_notes), ''),
    1,
    auth.uid(),
    auth.uid()
  )
  returning * into v_staff;

  perform public.sync_staff_cover_capabilities(v_staff.staff_id, p_cover_role_codes);

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'CREATE_STAFF_MEMBER',
    'staff_members',
    v_staff.staff_id::text,
    public.get_staff_master_record(v_staff.staff_id),
    trim(p_change_reason),
    coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI')
  );

  return public.get_staff_master_record(v_staff.staff_id);
end;
$$;

create or replace function public.update_staff_master(
  p_staff_id uuid,
  p_expected_row_version integer,
  p_display_name text,
  p_employee_code text,
  p_default_shift_code text,
  p_primary_role_code text,
  p_default_area_code text,
  p_default_station_code text,
  p_roster_eligible boolean,
  p_cover_role_codes text[],
  p_fire_training boolean,
  p_first_aid_training boolean,
  p_eod_capable boolean,
  p_joined_on date,
  p_notes text,
  p_import_review_required boolean default false,
  p_import_review_notes text default null,
  p_change_reason text default null,
  p_source_application text default 'STAFF_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before jsonb;
  v_defaults record;
  v_shift_id uuid;
  v_staff public.staff_members%rowtype;
  v_employee_code text := upper(nullif(trim(p_employee_code), ''));
begin
  perform public.require_staff_master_manage_role();

  if p_staff_id is null then
    raise exception 'Staff ID is required.';
  end if;

  if p_expected_row_version is null or p_expected_row_version < 1 then
    raise exception 'A valid row version is required.';
  end if;

  if nullif(trim(p_display_name), '') is null then
    raise exception 'Staff name is required.';
  end if;

  if v_employee_code is null then
    raise exception 'Employee code is required.';
  end if;

  if nullif(trim(p_change_reason), '') is null then
    raise exception 'A change reason is required.';
  end if;

  v_before := public.get_staff_master_record(p_staff_id);

  select * into v_defaults
  from public.validate_staff_work_defaults(
    p_primary_role_code,
    p_default_area_code,
    p_default_station_code
  );

  if nullif(trim(p_default_shift_code), '') is not null then
    select s.shift_id into v_shift_id
    from public.shifts s
    where s.shift_code = upper(trim(p_default_shift_code))
      and s.active = true
      and s.deleted_at is null;

    if v_shift_id is null then
      raise exception 'Default shift is invalid or inactive.';
    end if;
  end if;

  if exists (
    select 1
    from public.staff_members sm
    where sm.employee_code = v_employee_code
      and sm.staff_id <> p_staff_id
  ) then
    raise exception 'Employee code already exists.';
  end if;

  update public.staff_members sm
  set
    employee_code = v_employee_code,
    display_name = trim(p_display_name),
    roster_eligible = coalesce(p_roster_eligible, false),
    default_shift_id = v_shift_id,
    primary_operational_role_id = v_defaults.operational_role_id,
    default_area_id = v_defaults.area_id,
    default_station_id = v_defaults.station_id,
    fire_training = coalesce(p_fire_training, false),
    first_aid_training = coalesce(p_first_aid_training, false),
    eod_capable = coalesce(p_eod_capable, false),
    joined_on = p_joined_on,
    notes = nullif(trim(p_notes), ''),
    import_review_required = coalesce(p_import_review_required, false),
    import_review_notes = case
      when coalesce(p_import_review_required, false) then nullif(trim(p_import_review_notes), '')
      else null
    end,
    row_version = sm.row_version + 1,
    updated_by = auth.uid()
  where sm.staff_id = p_staff_id
    and sm.row_version = p_expected_row_version
    and sm.production_staff = true
    and sm.deleted_at is null
  returning * into v_staff;

  if not found then
    if not exists (
      select 1 from public.staff_members sm
      where sm.staff_id = p_staff_id
        and sm.production_staff = true
        and sm.deleted_at is null
    ) then
      raise exception using errcode = 'P0002', message = 'Staff member not found.';
    end if;

    raise exception using
      errcode = '40001',
      message = 'Staff record changed in another session. Reload before saving.';
  end if;

  perform public.sync_staff_cover_capabilities(v_staff.staff_id, p_cover_role_codes);

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'UPDATE_STAFF_MEMBER',
    'staff_members',
    v_staff.staff_id::text,
    v_before,
    public.get_staff_master_record(v_staff.staff_id),
    trim(p_change_reason),
    coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI')
  );

  return public.get_staff_master_record(v_staff.staff_id);
end;
$$;

create or replace function public.deactivate_staff_member(
  p_staff_id uuid,
  p_expected_row_version integer,
  p_deactivated_on date default current_date,
  p_reason text default null,
  p_source_application text default 'STAFF_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before jsonb;
  v_staff public.staff_members%rowtype;
begin
  perform public.require_staff_master_manage_role();

  if p_staff_id is null then
    raise exception 'Staff ID is required.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A deactivation reason is required.';
  end if;

  if exists (
    select 1
    from public.staff_members sm
    where sm.staff_id = p_staff_id
      and sm.auth_user_id = auth.uid()
  ) then
    raise exception 'You cannot deactivate your own signed-in staff profile.';
  end if;

  v_before := public.get_staff_master_record(p_staff_id);

  update public.staff_members sm
  set
    active = false,
    roster_eligible = false,
    deactivated_on = coalesce(p_deactivated_on, current_date),
    deactivation_reason = trim(p_reason),
    row_version = sm.row_version + 1,
    updated_by = auth.uid()
  where sm.staff_id = p_staff_id
    and sm.row_version = p_expected_row_version
    and sm.active = true
    and sm.production_staff = true
    and sm.deleted_at is null
  returning * into v_staff;

  if not found then
    raise exception 'Staff member is inactive, missing or has changed. Reload before continuing.';
  end if;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'DEACTIVATE_STAFF_MEMBER',
    'staff_members',
    v_staff.staff_id::text,
    v_before,
    public.get_staff_master_record(v_staff.staff_id),
    trim(p_reason),
    coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI')
  );

  return public.get_staff_master_record(v_staff.staff_id);
end;
$$;

create or replace function public.reactivate_staff_member(
  p_staff_id uuid,
  p_expected_row_version integer,
  p_roster_eligible boolean default true,
  p_reason text default null,
  p_source_application text default 'STAFF_MASTER_UI'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before jsonb;
  v_staff public.staff_members%rowtype;
begin
  perform public.require_staff_master_manage_role();

  if p_staff_id is null then
    raise exception 'Staff ID is required.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'A reactivation reason is required.';
  end if;

  v_before := public.get_staff_master_record(p_staff_id);

  update public.staff_members sm
  set
    active = true,
    roster_eligible = coalesce(p_roster_eligible, true),
    deactivated_on = null,
    deactivation_reason = null,
    row_version = sm.row_version + 1,
    updated_by = auth.uid()
  where sm.staff_id = p_staff_id
    and sm.row_version = p_expected_row_version
    and sm.active = false
    and sm.production_staff = true
    and sm.deleted_at is null
  returning * into v_staff;

  if not found then
    raise exception 'Staff member is active, missing or has changed. Reload before continuing.';
  end if;

  insert into public.audit_log (
    actor_auth_user_id,
    actor_staff_id,
    action,
    entity_table,
    entity_id,
    old_data,
    new_data,
    reason,
    source_application
  )
  values (
    auth.uid(),
    public.current_staff_id(),
    'REACTIVATE_STAFF_MEMBER',
    'staff_members',
    v_staff.staff_id::text,
    v_before,
    public.get_staff_master_record(v_staff.staff_id),
    trim(p_reason),
    coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI')
  );

  return public.get_staff_master_record(v_staff.staff_id);
end;
$$;

commit;
