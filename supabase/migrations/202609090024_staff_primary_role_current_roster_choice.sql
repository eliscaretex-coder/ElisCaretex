-- Staff Master remains the source of truth for future planning. A manager can
-- explicitly refresh only the editable current-week roster draft when a saved
-- primary role was wrong. Published roster versions remain immutable history.

create or replace function public.get_staff_primary_role_change_impact(
  p_staff_id uuid,
  p_new_primary_role_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(current_date);
  v_staff public.staff_members%rowtype;
  v_old_role public.operational_roles%rowtype;
  v_new_role public.operational_roles%rowtype;
  v_draft_base_count integer := 0;
  v_draft_snapshot_count integer := 0;
  v_published_base_count integer := 0;
  v_published_snapshot_count integer := 0;
  v_drafts jsonb := '[]'::jsonb;
begin
  perform public.require_staff_master_manage_role();
  perform public.require_production_roster_manage_role();

  select * into v_staff
  from public.staff_members
  where staff_id = p_staff_id
    and production_staff = true
    and deleted_at is null;
  if not found then
    raise exception using errcode = 'P0002', message = 'Staff member not found.';
  end if;

  select * into v_old_role
  from public.operational_roles
  where operational_role_id = v_staff.primary_operational_role_id;

  select * into v_new_role
  from public.operational_roles
  where role_code = upper(trim(coalesce(p_new_primary_role_code, '')))
    and active = true
    and allow_as_primary = true
    and deleted_at is null;
  if not found then
    raise exception using errcode = '22023', message = 'Primary role is invalid or inactive.';
  end if;

  if v_old_role.operational_role_id is not distinct from v_new_role.operational_role_id then
    return jsonb_build_object('role_changed', false, 'week_start', v_week_start);
  end if;

  with current_versions as (
    select prv.roster_version_id, prv.status, sh.shift_code, sh.shift_name
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    join public.shifts sh on sh.shift_id = prv.shift_id
    where rp.week_start = v_week_start
      and prv.status in ('DRAFT', 'PUBLISHED')
  ), counts as (
    select
      cv.roster_version_id,
      cv.status,
      cv.shift_code,
      cv.shift_name,
      count(pre.roster_entry_id) filter (
        where pre.assignment_type = 'BASE'
          and pre.operational_role_id = v_old_role.operational_role_id
      )::integer as matching_base_count,
      count(pre.roster_entry_id)::integer as staff_snapshot_count
    from current_versions cv
    left join public.production_roster_entries pre
      on pre.roster_version_id = cv.roster_version_id
      and pre.staff_id = v_staff.staff_id
    group by cv.roster_version_id, cv.status, cv.shift_code, cv.shift_name
  )
  select
    coalesce(sum(matching_base_count) filter (where status = 'DRAFT'), 0)::integer,
    coalesce(sum(staff_snapshot_count) filter (where status = 'DRAFT'), 0)::integer,
    coalesce(sum(matching_base_count) filter (where status = 'PUBLISHED'), 0)::integer,
    coalesce(sum(staff_snapshot_count) filter (where status = 'PUBLISHED'), 0)::integer,
    coalesce(jsonb_agg(jsonb_build_object(
      'roster_version_id', roster_version_id,
      'shift_code', shift_code,
      'shift_name', shift_name,
      'matching_base_count', matching_base_count,
      'staff_snapshot_count', staff_snapshot_count
    ) order by shift_code) filter (where status = 'DRAFT'), '[]'::jsonb)
  into v_draft_base_count, v_draft_snapshot_count, v_published_base_count, v_published_snapshot_count, v_drafts
  from counts;

  return jsonb_build_object(
    'role_changed', true,
    'staff_id', v_staff.staff_id,
    'staff_name', v_staff.display_name,
    'previous_role_code', v_old_role.role_code,
    'previous_role_name', v_old_role.role_name,
    'new_role_code', v_new_role.role_code,
    'new_role_name', v_new_role.role_name,
    'week_start', v_week_start,
    'draft_base_assignment_count', v_draft_base_count,
    'draft_staff_snapshot_count', v_draft_snapshot_count,
    'published_base_assignment_count', v_published_base_count,
    'published_staff_snapshot_count', v_published_snapshot_count,
    'drafts', v_drafts
  );
end;
$$;

create or replace function public.update_staff_master_with_current_roster_role(
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
  p_source_application text default 'STAFF_MASTER_UI',
  p_apply_current_roster_role boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(current_date);
  v_staff public.staff_members%rowtype;
  v_old_role public.operational_roles%rowtype;
  v_new_role public.operational_roles%rowtype;
  v_result jsonb;
  v_base_updated integer := 0;
  v_snapshots_updated integer := 0;
  v_versions_updated integer := 0;
begin
  perform public.require_staff_master_manage_role();

  select sm.* into v_staff
  from public.staff_members sm
  where sm.staff_id = p_staff_id
    and sm.production_staff = true
    and sm.deleted_at is null
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Staff member not found.';
  end if;

  select * into v_old_role
  from public.operational_roles
  where operational_role_id = v_staff.primary_operational_role_id;

  select * into v_new_role
  from public.operational_roles
  where role_code = upper(trim(coalesce(p_primary_role_code, '')))
    and active = true
    and allow_as_primary = true
    and deleted_at is null;
  if not found then
    raise exception using errcode = '22023', message = 'Primary role is invalid or inactive.';
  end if;

  if coalesce(p_apply_current_roster_role, false)
     and v_old_role.operational_role_id is distinct from v_new_role.operational_role_id then
    perform public.require_production_roster_manage_role();
  end if;

  v_result := public.update_staff_master(
    p_staff_id, p_expected_row_version, p_display_name, p_employee_code,
    p_default_shift_code, p_primary_role_code, p_default_area_code,
    p_default_station_code, p_roster_eligible, p_cover_role_codes,
    p_fire_training, p_first_aid_training, p_eod_capable, p_joined_on,
    p_notes, p_import_review_required, p_import_review_notes,
    p_change_reason, p_source_application
  );

  if coalesce(p_apply_current_roster_role, false)
     and v_old_role.operational_role_id is distinct from v_new_role.operational_role_id then
    update public.production_roster_entries pre
    set
      operational_role_id = v_new_role.operational_role_id,
      operational_role_code_snapshot = v_new_role.role_code,
      operational_role_name_snapshot = v_new_role.role_name,
      updated_by = auth.uid()
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where pre.roster_version_id = prv.roster_version_id
      and rp.week_start = v_week_start
      and prv.status = 'DRAFT'
      and pre.staff_id = p_staff_id
      and pre.assignment_type = 'BASE'
      and pre.operational_role_id = v_old_role.operational_role_id;
    get diagnostics v_base_updated = row_count;

    update public.production_roster_entries pre
    set
      staff_primary_role_code_snapshot = v_new_role.role_code,
      staff_primary_role_name_snapshot = v_new_role.role_name,
      updated_by = auth.uid()
    from public.production_roster_versions prv
    join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
    where pre.roster_version_id = prv.roster_version_id
      and rp.week_start = v_week_start
      and prv.status = 'DRAFT'
      and pre.staff_id = p_staff_id;
    get diagnostics v_snapshots_updated = row_count;

    update public.production_roster_versions prv
    set
      row_version = prv.row_version + 1,
      saved_at = now(),
      saved_by = auth.uid(),
      updated_by = auth.uid()
    from public.roster_periods rp
    where rp.roster_period_id = prv.roster_period_id
      and rp.week_start = v_week_start
      and prv.status = 'DRAFT'
      and exists (
        select 1
        from public.production_roster_entries pre
        where pre.roster_version_id = prv.roster_version_id
          and pre.staff_id = p_staff_id
      );
    get diagnostics v_versions_updated = row_count;

    insert into public.audit_log(
      actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
      old_data, new_data, reason, source_application
    ) values (
      auth.uid(), public.current_staff_id(), 'APPLY_STAFF_PRIMARY_ROLE_TO_CURRENT_ROSTER',
      'production_roster_entries', p_staff_id::text,
      jsonb_build_object('primary_role_code', v_old_role.role_code),
      jsonb_build_object(
        'primary_role_code', v_new_role.role_code,
        'week_start', v_week_start,
        'base_assignments_updated', v_base_updated,
        'staff_snapshots_updated', v_snapshots_updated,
        'draft_versions_updated', v_versions_updated
      ),
      trim(p_change_reason), coalesce(nullif(trim(p_source_application), ''), 'STAFF_MASTER_UI')
    );
  end if;

  return v_result || jsonb_build_object(
    'current_roster_role_applied', coalesce(p_apply_current_roster_role, false)
      and v_old_role.operational_role_id is distinct from v_new_role.operational_role_id,
    'current_roster_base_assignments_updated', v_base_updated,
    'current_roster_staff_snapshots_updated', v_snapshots_updated,
    'current_roster_draft_versions_updated', v_versions_updated
  );
end;
$$;

revoke all on function public.get_staff_primary_role_change_impact(uuid, text) from public, anon;
revoke all on function public.update_staff_master_with_current_roster_role(
  uuid, integer, text, text, text, text, text, text, boolean, text[],
  boolean, boolean, boolean, date, text, boolean, text, text, text, boolean
) from public, anon;

grant execute on function public.get_staff_primary_role_change_impact(uuid, text) to authenticated;
grant execute on function public.update_staff_master_with_current_roster_role(
  uuid, integer, text, text, text, text, text, text, boolean, text[],
  boolean, boolean, boolean, date, text, boolean, text, text, text, boolean
) to authenticated;

comment on function public.get_staff_primary_role_change_impact(uuid, text) is
  'Previews an explicit current-week DRAFT Roster refresh before a Staff Master primary-role correction.';
comment on function public.update_staff_master_with_current_roster_role(uuid, integer, text, text, text, text, text, text, boolean, text[], boolean, boolean, boolean, date, text, boolean, text, text, text, boolean) is
  'Atomically updates Staff Master and, only when chosen, refreshes matching BASE role snapshots in the editable current-week Roster draft. Published Roster history remains immutable.';
