-- =====================================================================
-- ElisCaretex V2
-- Validation: 202608040004_staff_master_management_validation.sql
-- Covered:
--   - controlled Staff Master read/write RPCs;
--   - operational roles remain separate from system roles;
--   - COVER capabilities preserve the primary function;
--   - optimistic row-version updates;
--   - deactivation/reactivation preserves the staff record;
--   - protected tables do not receive direct browser writes;
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
  'eliscaretex_validation.staff_code',
  'VAL-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  true
);

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
end;
$$;

set local role authenticated;

-- ---------------------------------------------------------------------
-- 1. Permission boundary and reference data
-- ---------------------------------------------------------------------

do $$
declare
  v_reference jsonb;
begin
  if not has_function_privilege(
    'authenticated',
    'public.get_staff_master_reference_data()',
    'EXECUTE'
  ) or not has_function_privilege(
    'authenticated',
    'public.get_staff_directory(text,text,text)',
    'EXECUTE'
  ) then
    raise exception 'authenticated is missing required Staff Master RPC access.';
  end if;

  if has_table_privilege('authenticated', 'public.staff_members', 'INSERT')
     or has_table_privilege('authenticated', 'public.staff_members', 'UPDATE')
     or has_table_privilege('authenticated', 'public.staff_members', 'DELETE')
     or has_table_privilege('authenticated', 'public.staff_cover_capabilities', 'SELECT')
     or has_table_privilege('authenticated', 'public.staff_cover_capabilities', 'INSERT')
     or has_table_privilege('authenticated', 'public.operational_roles', 'SELECT') then
    raise exception 'Staff Master protected tables expose direct browser access.';
  end if;

  v_reference := public.get_staff_master_reference_data();

  if coalesce((v_reference ->> 'can_edit_staff')::boolean, false) is not true then
    raise exception 'ADMIN did not receive Staff Master edit capability.';
  end if;

  if jsonb_array_length(coalesce(v_reference -> 'shifts', '[]'::jsonb)) < 2 then
    raise exception 'Morning and Evening shifts were not returned.';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(coalesce(v_reference -> 'operational_roles', '[]'::jsonb)) role_item
    where role_item ->> 'role_code' = 'TEAM_LEADER'
      and (role_item ->> 'allow_as_cover')::boolean = true
  ) then
    raise exception 'TEAM_LEADER COVER role was not returned.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Create a General Operative who can cover two different functions
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.created_staff',
  public.create_staff_master(
    p_display_name => 'Temporary Staff Master Validation',
    p_employee_code => current_setting('eliscaretex_validation.staff_code'),
    p_default_shift_code => 'MORNING',
    p_primary_role_code => 'GENERAL_OPERATIVE',
    p_default_area_code => 'FINISH',
    p_default_station_code => 'FINISH_TABLE_1',
    p_roster_eligible => true,
    p_cover_role_codes => array['TEAM_LEADER', 'SORTING_AREA'],
    p_fire_training => false,
    p_first_aid_training => true,
    p_eod_capable => false,
    p_joined_on => null,
    p_notes => 'Temporary validation record.',
    p_change_reason => 'Validate Staff Master create workflow.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

select set_config(
  'eliscaretex_validation.staff_id',
  (current_setting('eliscaretex_validation.created_staff')::jsonb ->> 'staff_id'),
  true
);

do $$
declare
  v_record jsonb := current_setting('eliscaretex_validation.created_staff')::jsonb;
begin
  if v_record ->> 'primary_role_code' <> 'GENERAL_OPERATIVE' then
    raise exception 'Primary operational role was not preserved.';
  end if;

  if v_record ->> 'default_station_code' <> 'FINISH_TABLE_1' then
    raise exception 'Default station was not saved.';
  end if;

  if not ((v_record -> 'cover_role_codes') ? 'TEAM_LEADER')
     or not ((v_record -> 'cover_role_codes') ? 'SORTING_AREA') then
    raise exception 'Expected COVER capabilities were not saved.';
  end if;

  if (v_record ->> 'first_aid_training')::boolean is not true
     or (v_record ->> 'fire_training')::boolean is not false then
    raise exception 'Training flags were not saved correctly.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Update with optimistic concurrency and change COVER to Supervisor
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.updated_staff',
  public.update_staff_master(
    p_staff_id => current_setting('eliscaretex_validation.staff_id')::uuid,
    p_expected_row_version => (
      current_setting('eliscaretex_validation.created_staff')::jsonb ->> 'row_version'
    )::integer,
    p_display_name => 'Temporary Staff Master Validation Updated',
    p_employee_code => current_setting('eliscaretex_validation.staff_code'),
    p_default_shift_code => 'EVENING',
    p_primary_role_code => 'GENERAL_OPERATIVE',
    p_default_area_code => 'FINISH',
    p_default_station_code => 'FINISH_TABLE_2',
    p_roster_eligible => true,
    p_cover_role_codes => array['SUPERVISOR'],
    p_fire_training => true,
    p_first_aid_training => true,
    p_eod_capable => true,
    p_joined_on => null,
    p_notes => 'Updated temporary validation record.',
    p_import_review_required => false,
    p_import_review_notes => null,
    p_change_reason => 'Validate Staff Master update workflow.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
declare
  v_record jsonb := current_setting('eliscaretex_validation.updated_staff')::jsonb;
begin
  if v_record ->> 'primary_role_code' <> 'GENERAL_OPERATIVE' then
    raise exception 'COVER update replaced the primary role.';
  end if;

  if v_record ->> 'default_shift_code' <> 'EVENING'
     or v_record ->> 'default_station_code' <> 'FINISH_TABLE_2' then
    raise exception 'Updated work defaults were not returned.';
  end if;

  if jsonb_array_length(v_record -> 'cover_role_codes') <> 1
     or not ((v_record -> 'cover_role_codes') ? 'SUPERVISOR') then
    raise exception 'COVER capabilities were not synchronized.';
  end if;

  if (v_record ->> 'row_version')::integer <> 2 then
    raise exception 'Row version did not increment after update.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Deactivate and reactivate without deleting history
-- ---------------------------------------------------------------------

select set_config(
  'eliscaretex_validation.deactivated_staff',
  public.deactivate_staff_member(
    p_staff_id => current_setting('eliscaretex_validation.staff_id')::uuid,
    p_expected_row_version => (
      current_setting('eliscaretex_validation.updated_staff')::jsonb ->> 'row_version'
    )::integer,
    p_deactivated_on => current_date,
    p_reason => 'Validate Staff Master deactivation.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
declare
  v_record jsonb := current_setting('eliscaretex_validation.deactivated_staff')::jsonb;
begin
  if (v_record ->> 'active')::boolean is not false
     or (v_record ->> 'roster_eligible')::boolean is not false then
    raise exception 'Deactivation did not remove the staff member from active roster eligibility.';
  end if;

  if v_record ->> 'deactivated_on' <> current_date::text then
    raise exception 'Deactivation date was not saved.';
  end if;
end;
$$;

select set_config(
  'eliscaretex_validation.reactivated_staff',
  public.reactivate_staff_member(
    p_staff_id => current_setting('eliscaretex_validation.staff_id')::uuid,
    p_expected_row_version => (
      current_setting('eliscaretex_validation.deactivated_staff')::jsonb ->> 'row_version'
    )::integer,
    p_roster_eligible => true,
    p_reason => 'Validate Staff Master reactivation.',
    p_source_application => 'DATABASE_TEST'
  )::text,
  true
);

do $$
declare
  v_record jsonb := current_setting('eliscaretex_validation.reactivated_staff')::jsonb;
begin
  if (v_record ->> 'active')::boolean is not true
     or (v_record ->> 'roster_eligible')::boolean is not true then
    raise exception 'Reactivation did not restore the staff member.';
  end if;

  if v_record ->> 'deactivated_on' is not null then
    raise exception 'Reactivation did not clear the deactivation date.';
  end if;
end;
$$;

reset role;

-- Internal verification under the SQL test owner, not authenticated.
do $$
declare
  v_staff_id uuid := current_setting('eliscaretex_validation.staff_id')::uuid;
begin
  if not exists (
    select 1 from public.staff_members sm
    where sm.staff_id = v_staff_id
      and sm.deleted_at is null
  ) then
    raise exception 'Staff record was physically removed.';
  end if;

  if (
    select count(*)
    from public.audit_log al
    where al.entity_table = 'staff_members'
      and al.entity_id = v_staff_id::text
      and al.action in (
        'CREATE_STAFF_MEMBER',
        'UPDATE_STAFF_MEMBER',
        'DEACTIVATE_STAFF_MEMBER',
        'REACTIVATE_STAFF_MEMBER'
      )
  ) <> 4 then
    raise exception 'Expected Staff Master audit events were not written.';
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608040004_staff_master_management_validation',
  'controlled_rpc_access', true,
  'primary_role_preserved_during_cover', true,
  'cover_capabilities', true,
  'optimistic_concurrency', true,
  'deactivation_preserves_history', true,
  'training_flags', true,
  'writes_rolled_back', true
) as result;

rollback;
