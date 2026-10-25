-- Production Roster history: show who saved and who published each version.
--
-- production_roster_versions already stores saved_by / published_by and
-- production_roster_events already stores every DRAFT_CREATED, DRAFT_SAVED,
-- PUBLISHED, SUPERSEDED and DRAFT_CANCELLED action with its actor. The history RPC
-- only returned the dates, so the History window could not say who did what.
--
-- This migration replaces get_production_roster_history only. No table, column or
-- row changes. Names are resolved in the same order as the other modules: account
-- display name, then Staff Master name, then the login email.
-- Versions published without a person are labelled by their source: the Sunday
-- automatic publish, or the legacy spreadsheet import (with its recorded editor).

-- Internal helper: a person's display name for roster history. Not callable directly.
create or replace function public.production_roster_actor_name(p_auth_user_id uuid, p_staff_id uuid)
returns text
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select coalesce(
    (select nullif(trim(ap.display_name), '') from public.account_access_profiles ap where p_auth_user_id is not null and ap.auth_user_id = p_auth_user_id),
    (select sm.display_name from public.staff_members sm where p_auth_user_id is not null and sm.auth_user_id = p_auth_user_id and sm.deleted_at is null order by sm.active desc limit 1),
    (select sm.display_name from public.staff_members sm where p_staff_id is not null and sm.staff_id = p_staff_id),
    (select u.email::text from auth.users u where p_auth_user_id is not null and u.id = p_auth_user_id)
  );
$$;

revoke all on function public.production_roster_actor_name(uuid, uuid) from public, anon, authenticated;

create or replace function public.get_production_roster_history(p_week_start date, p_shift_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_week_start date := public.production_roster_week_start(p_week_start);
  v_shift_id uuid;
begin
  perform public.require_production_roster_read_role();

  select s.shift_id into v_shift_id
  from public.shifts s
  where s.shift_code = upper(trim(p_shift_code)) and s.active = true and s.deleted_at is null;

  if v_shift_id is null then
    raise exception using errcode = '22023', message = 'Invalid shift.';
  end if;

  return jsonb_build_object(
    'week_start', v_week_start,
    'shift_code', upper(trim(p_shift_code)),
    'versions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'roster_version_id', prv.roster_version_id,
        'version_number', prv.version_number,
        'status', prv.status,
        'include_sunday', prv.include_sunday,
        'week_note', prv.week_note,
        'saved_at', prv.saved_at,
        'saved_by_name', public.production_roster_actor_name(prv.saved_by, null),
        'published_at', prv.published_at,
        'published_by_name', case
          when prv.published_at is null then null
          else coalesce(public.production_roster_actor_name(prv.published_by, pub.actor_staff_id), pub.metadata->>'legacy_updated_by')
        end,
        'publish_source', case
          when prv.published_at is null then null
          when prv.published_by is not null or pub.actor_auth_user_id is not null then 'MANUAL'
          when coalesce((pub.metadata->>'automatic')::boolean, false) then 'AUTOMATIC'
          when pub.metadata ? 'source_batch' then 'LEGACY_IMPORT'
          else 'UNKNOWN'
        end,
        'created_at', prv.created_at,
        'entry_count', (select count(*) from public.production_roster_entries pre where pre.roster_version_id = prv.roster_version_id),
        'staff_count', (select count(distinct pre.staff_id) from public.production_roster_entries pre where pre.roster_version_id = prv.roster_version_id),
        'activity', coalesce((
          select jsonb_agg(jsonb_build_object(
            'event_type', ev.event_type,
            'occurred_at', ev.occurred_at,
            'actor_name', coalesce(
              public.production_roster_actor_name(ev.actor_auth_user_id, ev.actor_staff_id),
              ev.metadata->>'legacy_updated_by',
              case when coalesce((ev.metadata->>'automatic')::boolean, false) then 'Automatic Sunday publish' end
            ),
            'reason', ev.reason
          ) order by ev.occurred_at, ev.roster_event_id)
          from public.production_roster_events ev
          where ev.roster_version_id = prv.roster_version_id
        ), '[]'::jsonb)
      ) order by prv.version_number desc)
      from public.production_roster_versions prv
      join public.roster_periods rp on rp.roster_period_id = prv.roster_period_id
      left join lateral (
        select e.actor_auth_user_id, e.actor_staff_id, e.metadata
        from public.production_roster_events e
        where e.roster_version_id = prv.roster_version_id and e.event_type = 'PUBLISHED'
        order by e.occurred_at desc
        limit 1
      ) pub on true
      where rp.week_start = v_week_start
        and prv.shift_id = v_shift_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_production_roster_history(date, text) from public, anon;
grant execute on function public.get_production_roster_history(date, text) to authenticated;
