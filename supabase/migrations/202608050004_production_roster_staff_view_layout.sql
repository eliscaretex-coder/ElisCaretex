-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608050004_production_roster_staff_view_layout.sql
--
-- Purpose:
--   Enrich the anonymous, token-protected Production Roster staff view
--   payload so the mobile RosterView can reproduce the accepted legacy
--   card layout without querying protected tables from the browser.
--
-- Governance:
--   - published roster entries remain immutable;
--   - no existing roster row is updated or deleted;
--   - only PUBLISHED current/next-week versions are returned;
--   - employee codes are deliberately omitted from the anonymous payload;
--   - training, section, default assignment and shift values come from the
--     immutable snapshots stored on each published entry.
-- =====================================================================

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
              'work_date', pre.work_date,
              'day_status', pre.day_status,
              'assignment_type', pre.assignment_type,
              'operational_role_code', pre.operational_role_code_snapshot,
              'operational_role_name', pre.operational_role_name_snapshot,
              'area_code', pre.area_code_snapshot,
              'area_name', pre.area_name_snapshot,
              'station_code', pre.station_code_snapshot,
              'station_name', pre.station_name_snapshot,
              'display_section_code', coalesce(
                pre.display_section_code,
                public.production_roster_default_display_section(
                  pre.staff_primary_role_code_snapshot,
                  pre.staff_default_station_code_snapshot
                )
              ),
              'staff_primary_role_code', pre.staff_primary_role_code_snapshot,
              'staff_primary_role_name', pre.staff_primary_role_name_snapshot,
              'staff_default_area_code', pre.staff_default_area_code_snapshot,
              'staff_default_area_name', pre.staff_default_area_name_snapshot,
              'staff_default_station_code', pre.staff_default_station_code_snapshot,
              'staff_default_station_name', pre.staff_default_station_name_snapshot,
              'staff_default_shift_code', coalesce(
                pre.staff_default_shift_code_snapshot,
                pre.shift_code_snapshot
              ),
              'staff_default_shift_name', coalesce(
                pre.staff_default_shift_name_snapshot,
                pre.shift_name_snapshot
              ),
              'roster_shift_code', pre.shift_code_snapshot,
              'roster_shift_name', pre.shift_name_snapshot,
              'fire_training', pre.fire_training_snapshot,
              'first_aid_training', pre.first_aid_training_snapshot,
              'eod_capable', pre.eod_capable_snapshot,
              'notes', pre.notes
            ) order by
              public.production_roster_display_section_sort(coalesce(
                pre.display_section_code,
                public.production_roster_default_display_section(
                  pre.staff_primary_role_code_snapshot,
                  pre.staff_default_station_code_snapshot
                )
              )),
              lower(pre.staff_display_name_snapshot),
              pre.work_date)
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

revoke all on function public.get_published_production_roster(text)
from public, anon, authenticated;

grant execute on function public.get_published_production_roster(text)
to anon, authenticated;

comment on function public.get_published_production_roster(text) is
  'Returns current and next published Production Rosters through a revocable shift link, including immutable layout, qualification and default-assignment snapshots for the mobile staff view.';
