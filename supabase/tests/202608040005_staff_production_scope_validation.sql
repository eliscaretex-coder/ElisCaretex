-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608040005_staff_production_scope_validation.sql
-- Covered:
--   - authentication-only profiles remain outside Staff Master;
--   - Staff Master returns only production staff;
--   - new Staff Master records are production staff;
--   - system-only profiles cannot be roster eligible;
--   - future Production Roster candidate scope is explicit;
--   - all test writes are rolled back.
-- =====================================================================

begin;

select set_config(
  'request.jwt.claim.sub',
  admin_user.auth_user_id::text,
  true
)
from (
  select sm.auth_user_id
  from public.staff_members sm
  join public.staff_roles sr
    on sr.staff_id = sm.staff_id
   and sr.active = true
   and sr.effective_from <= current_date
   and (sr.effective_until is null or sr.effective_until >= current_date)
  join public.roles r
    on r.role_id = sr.role_id
   and r.active = true
   and r.role_code = 'ADMIN'
  where sm.active = true
    and sm.deleted_at is null
    and sm.auth_user_id is not null
  order by sm.created_at
  limit 1
) admin_user;

select set_config(
  'eliscaretex_validation.system_code',
  'SYS-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  true
);

select set_config(
  'eliscaretex_validation.production_code',
  'PROD-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
end;
$$;

-- Create an authentication/system-only profile directly under the test owner.
-- roster_eligible is intentionally supplied as true; the scope trigger must
-- force it to false because this is not production staff.
with inserted_system_profile as (
  insert into public.staff_members (
    employee_code,
    display_name,
    active,
    production_staff,
    roster_eligible,
    row_version
  )
  values (
    current_setting('eliscaretex_validation.system_code'),
    'Temporary Authentication Only Profile',
    true,
    false,
    true,
    1
  )
  returning staff_id
)
select set_config(
  'eliscaretex_validation.system_staff_id',
  staff_id::text,
  true
)
from inserted_system_profile;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Staff Master directory excludes authentication-only profiles.
-- ---------------------------------------------------------------------

do $$
declare
  v_directory jsonb := public.get_staff_directory('ALL', null, null);
  v_system_staff_id text := current_setting('eliscaretex_validation.system_staff_id');
begin
  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_directory -> 'staff', '[]'::jsonb)) item
    where item ->> 'staff_id' = v_system_staff_id
  ) then
    raise exception 'Authentication-only profile was exposed in Staff Master.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_directory -> 'staff', '[]'::jsonb)) item
    where coalesce((item ->> 'production_staff')::boolean, false) is not true
  ) then
    raise exception 'Staff Master returned a non-production profile.';
  end if;
end;
$$;

-- A system-only profile must also be unavailable through the Staff Master
-- record API, not merely hidden by the directory UI.
do $$
begin
  begin
    perform public.get_staff_master_record(
      current_setting('eliscaretex_validation.system_staff_id')::uuid
    );
    raise exception 'System-only profile was readable through Staff Master.';
  exception
    when sqlstate 'P0002' then
      null;
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Staff created through Staff Master is production staff.
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.created_staff',
  public.create_staff_master(
    p_display_name => 'Temporary Production Staff Scope Validation',
    p_employee_code => current_setting('eliscaretex_validation.production_code'),
    p_default_shift_code => 'MORNING',
    p_primary_role_code => 'GENERAL_OPERATIVE',
    p_default_area_code => 'FINISH',
    p_default_station_code => 'FINISH_TABLE_1',
    p_roster_eligible => true,
    p_cover_role_codes => array[]::text[],
    p_fire_training => false,
    p_first_aid_training => false,
    p_eod_capable => false,
    p_joined_on => null,
    p_notes => 'Temporary production scope validation.',
    p_change_reason => 'Validate production staff scope.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
declare
  v_record jsonb := current_setting('eliscaretex_validation.created_staff')::jsonb;
  v_directory jsonb := public.get_staff_directory(
    'ALL',
    null,
    current_setting('eliscaretex_validation.production_code')
  );
begin
  if coalesce((v_record ->> 'production_staff')::boolean, false) is not true then
    raise exception 'Staff Master creation did not mark production staff.';
  end if;

  if coalesce((v_record ->> 'roster_eligible')::boolean, false) is not true then
    raise exception 'Production staff roster eligibility was not preserved.';
  end if;

  if jsonb_array_length(coalesce(v_directory -> 'staff', '[]'::jsonb)) <> 1 then
    raise exception 'New production staff was not returned by Staff Master.';
  end if;
end;
$$;

reset role;

-- ---------------------------------------------------------------------
-- 3. Internal scope and future Roster candidate rule.
-- ---------------------------------------------------------------------

do $$
declare
  v_system_id uuid := current_setting('eliscaretex_validation.system_staff_id')::uuid;
  v_directory_count integer;
  v_production_count integer;
begin
  if exists (
    select 1
    from public.staff_members sm
    where sm.staff_id = v_system_id
      and (sm.production_staff = true or sm.roster_eligible = true)
  ) then
    raise exception 'System-only profile retained production or roster scope.';
  end if;

  select count(*) into v_production_count
  from public.staff_members sm
  where sm.production_staff = true
    and sm.deleted_at is null;

  select (public.get_staff_directory('ALL', null, null) -> 'summary' ->> 'total')::integer
  into v_directory_count;

  if v_directory_count <> v_production_count then
    raise exception 'Staff Master summary is not scoped to production staff.';
  end if;

  -- This is the mandatory candidate condition for the future Production Roster.
  if exists (
    select 1
    from public.staff_members sm
    where sm.production_staff = false
      and sm.active = true
      and sm.roster_eligible = true
      and sm.deleted_at is null
  ) then
    raise exception 'A non-production profile can still qualify for the Production Roster.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608040005_staff_production_scope_validation',
  'staff_master_contains_only_production_staff', true,
  'authentication_profiles_excluded', true,
  'new_staff_is_production_staff', true,
  'system_profiles_not_roster_eligible', true,
  'future_roster_scope_defined', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
