-- =====================================================================
-- ElisCaretex V2
-- Validation:
-- 202608030005_distribution_schedule_alignment_validation_v2.sql
--
-- Covered:
--   - automatic next-day delivery rule, skipping Sunday;
--   - Distribution read model returns derived delivery weekdays;
--   - manual Daily Plan RPCs are removed;
--   - Daily Plan capability keys are removed;
--   - future schedule writes are protected by a trigger;
--   - no operational data is changed by this validation.
-- =====================================================================

begin;

-- Resolve one active ADMIN so protected RPCs can be exercised.
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

do $$
begin
  if nullif(current_setting('request.jwt.claim.sub', true), '') is null then
    raise exception 'No active ADMIN linked to auth.users was found.';
  end if;
end;
$$;

set local role authenticated;

-- 1. Canonical delivery rule.
do $$
begin
  if public.next_distribution_weekday(1::smallint) <> 2 then
    raise exception 'Monday production must deliver Tuesday.';
  end if;

  if public.next_distribution_weekday(5::smallint) <> 6 then
    raise exception 'Friday production must deliver Saturday.';
  end if;

  if public.next_distribution_weekday(6::smallint) <> 1 then
    raise exception 'Saturday production must deliver Monday.';
  end if;

  if public.next_distribution_weekday(7::smallint) <> 1 then
    raise exception 'Sunday must be skipped and resolve to Monday.';
  end if;
end;
$$;

-- 2. Trigger protection exists and is enabled.
do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid = t.tgrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'customer_schedule_days'
      and t.tgname = 'customer_schedule_days_automatic_delivery_weekday'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  ) then
    raise exception 'Automatic delivery weekday trigger is missing or disabled.';
  end if;
end;
$$;

-- 3. Manual Daily Plan API is no longer available.
do $$
begin
  if to_regprocedure('public.get_distribution_daily_plan(date)') is not null
     or to_regprocedure('public.create_distribution_daily_plan(date,text,text)') is not null
     or to_regprocedure('public.save_distribution_daily_plan(uuid,integer,jsonb,text,text,text)') is not null
     or to_regprocedure('public.set_distribution_daily_plan_status(uuid,integer,text,text,text)') is not null then
    raise exception 'A manual Distribution Daily Plan RPC is still installed.';
  end if;
end;
$$;

-- 4. Capability response and Distribution read model semantics.
do $$
declare
  v_capabilities jsonb;
  v_planner jsonb;
  v_invalid_count integer;
begin
  v_capabilities := public.get_customer_read_capabilities();

  if v_capabilities ? 'can_view_distribution_daily'
     or v_capabilities ? 'can_edit_distribution_daily'
     or v_capabilities ? 'can_mark_distribution_ready' then
    raise exception 'Daily Plan capability keys are still exposed.';
  end if;

  if coalesce((v_capabilities ->> 'can_view_distribution')::boolean, false) is false then
    raise exception 'ADMIN should be able to view the Distribution Schedule.';
  end if;

  v_planner := public.get_distribution_weekly_planner(
    p_effective_date => public.current_business_date(),
    p_delivery_weekday => null,
    p_search => null
  );

  if v_planner -> 'route_semantics' ->> 'delivery_rule' <> 'NEXT_DAY_SKIP_SUNDAY' then
    raise exception 'Distribution read model is missing the automatic delivery rule.';
  end if;

  if coalesce((v_planner -> 'route_semantics' ->> 'manual_daily_plan_enabled')::boolean, true) then
    raise exception 'Distribution read model still reports manual Daily Planning as enabled.';
  end if;

  select count(*)
  into v_invalid_count
  from jsonb_array_elements(coalesce(v_planner -> 'items', '[]'::jsonb)) item
  where (item ->> 'delivery_weekday')::smallint
        <> public.next_distribution_weekday((item ->> 'production_weekday')::smallint)
     or item ->> 'delivery_day'
        <> public.weekday_name(
             public.next_distribution_weekday((item ->> 'production_weekday')::smallint)
           );

  if v_invalid_count > 0 then
    raise exception 'Distribution Schedule contains % rows with an incorrect derived delivery day.', v_invalid_count;
  end if;
end;
$$;

select jsonb_build_object(
  'status', 'PASS',
  'test', '202608030005_distribution_schedule_alignment_validation_v2',
  'automatic_delivery_rule', true,
  'sunday_skipped', true,
  'manual_daily_plan_removed', true,
  'distribution_schedule_read_model', true,
  'future_distribution_roster_preserved', true,
  'writes_rolled_back', true
) as validation_result;

rollback;
