-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608040007_production_roster_compatibility_fix.sql
-- Purpose:
--   Correct Production Roster compatibility in already-applied databases:
--   1. replace unavailable gen_random_bytes(integer) with gen_random_uuid();
--   2. replace pgcrypto digest() dependency with a portable built-in hash;
--   3. preserve controlled/revocable RosterView access.
--
-- Existing active RosterView links are revoked because the stored hash
-- format changes. Create a new Staff link after applying this migration.
-- =====================================================================

begin;

create or replace function public.production_roster_view_token_hash(p_token text)
returns text
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select md5('ELISCARETEXT-ROSTER-VIEW-A:' || p_token)
      || md5('ELISCARETEXT-ROSTER-VIEW-B:' || p_token);
$$;

create or replace function public.rotate_production_roster_view_link(p_shift_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_shift public.shifts%rowtype;
  v_token text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_hint text;
begin
  perform public.require_production_roster_manage_role();

  select * into v_shift
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code))
    and s.active = true
    and s.deleted_at is null;

  if not found then
    raise exception using errcode = '22023', message = 'Invalid shift.';
  end if;

  v_hint := left(v_token, 4) || '…' || right(v_token, 4);

  update public.production_roster_view_links
  set active = false,
      revoked_at = now(),
      revoked_by = auth.uid()
  where shift_id = v_shift.shift_id
    and active = true;

  insert into public.production_roster_view_links (
    shift_id,
    token_hash,
    token_hint,
    active,
    created_by
  ) values (
    v_shift.shift_id,
    public.production_roster_view_token_hash(v_token),
    v_hint,
    true,
    auth.uid()
  );

  return jsonb_build_object(
    'token', v_token,
    'token_hint', v_hint,
    'shift_code', v_shift.shift_code,
    'shift_name', v_shift.shift_name,
    'created_at', now()
  );
end;
$$;

create or replace function public.get_published_production_roster(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_link public.production_roster_view_links%rowtype;
  v_shift public.shifts%rowtype;
  v_current_week date := public.production_roster_week_start(current_date);
begin
  if nullif(trim(p_token), '') is null then
    raise exception using errcode = '42501', message = 'A valid RosterView link is required.';
  end if;

  select * into v_link
  from public.production_roster_view_links prvl
  where prvl.token_hash = public.production_roster_view_token_hash(trim(p_token))
    and prvl.active = true;

  if not found then
    raise exception using errcode = '42501', message = 'This RosterView link is invalid or has been replaced.';
  end if;

  select * into v_shift
  from public.shifts
  where shift_id = v_link.shift_id;

  update public.production_roster_view_links
  set last_used_at = now()
  where roster_view_link_id = v_link.roster_view_link_id;

  return jsonb_build_object(
    'shift', jsonb_build_object(
      'shift_code', v_shift.shift_code,
      'shift_name', v_shift.shift_name
    ),
    'generated_at', now(),
    'weeks', coalesce((
      select jsonb_agg(week_json order by (week_json ->> 'week_start')::date)
      from (
        select jsonb_build_object(
          'week_start', rp.week_start,
          'week_end', rp.week_start + 6,
          'version_number', prv.version_number,
          'published_at', prv.published_at,
          'week_note', prv.week_note,
          'include_sunday', prv.include_sunday,
          'entries', coalesce((
            select jsonb_agg(jsonb_build_object(
              'staff_id', pre.staff_id,
              'display_name', pre.staff_display_name_snapshot,
              'employee_code', pre.employee_code_snapshot,
              'work_date', pre.work_date,
              'day_status', pre.day_status,
              'assignment_type', pre.assignment_type,
              'operational_role_code', pre.operational_role_code_snapshot,
              'operational_role_name', pre.operational_role_name_snapshot,
              'area_code', pre.area_code_snapshot,
              'area_name', pre.area_name_snapshot,
              'station_code', pre.station_code_snapshot,
              'station_name', pre.station_name_snapshot
            ) order by lower(pre.staff_display_name_snapshot), pre.work_date)
            from public.production_roster_entries pre
            where pre.roster_version_id = prv.roster_version_id
          ), '[]'::jsonb)
        ) as week_json
        from public.production_roster_versions prv
        join public.roster_periods rp
          on rp.roster_period_id = prv.roster_period_id
        where prv.shift_id = v_shift.shift_id
          and prv.status = 'PUBLISHED'
          and rp.week_start in (v_current_week, v_current_week + 7)
      ) published_weeks
    ), '[]'::jsonb)
  );
end;
$$;

-- Revoke old active links because their hash cannot be verified by the new
-- portable helper. No roster publication or history row is changed.
update public.production_roster_view_links
set active = false,
    revoked_at = coalesce(revoked_at, now())
where active = true;

revoke all on function public.production_roster_view_token_hash(text)
from public, anon, authenticated;

revoke all on function public.rotate_production_roster_view_link(text)
from public, anon, authenticated;

revoke all on function public.get_published_production_roster(text)
from public, anon, authenticated;

grant execute on function public.rotate_production_roster_view_link(text)
to authenticated;

grant execute on function public.get_published_production_roster(text)
to anon, authenticated;

commit;
