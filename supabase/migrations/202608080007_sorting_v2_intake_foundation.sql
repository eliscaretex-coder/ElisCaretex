-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608080007_sorting_v2_intake_foundation.sql
-- Purpose:
--   - expose the current Sorting operational context from the PUBLISHED
--     Production Roster only;
--   - expose controlled trolley-intake preview and confirmation RPCs;
--   - reuse the existing Physical Trolley Lifecycle instead of duplicating
--     trolley/customer custody rules inside the Sorting frontend;
--   - keep operational tables private from browser roles.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Sorting access helper
-- ---------------------------------------------------------------------

create or replace function public.require_sorting_operational_access()
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.has_any_role(array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']) then
    raise exception using
      errcode = '42501',
      message = 'Your active role does not allow access to Sorting Area.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Published daily Sorting context
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_daily_context(
  p_business_date date default current_date,
  p_shift_code text default 'MORNING'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_business_date date := coalesce(p_business_date, current_date);
  v_shift_code text := upper(trim(coalesce(p_shift_code, '')));
  v_shift public.shifts%rowtype;
  v_week_start date;
  v_roster public.production_roster_versions%rowtype;
  v_actor_staff_id uuid := public.current_staff_id();
  v_actor_name text;
  v_staff jsonb := '[]'::jsonb;
  v_recent jsonb := '[]'::jsonb;
  v_customers jsonb := '[]'::jsonb;
begin
  perform public.require_sorting_operational_access();

  if v_shift_code not in ('MORNING', 'EVENING') then
    raise exception using errcode = '22023', message = 'Shift must be MORNING or EVENING.';
  end if;

  select * into v_shift
  from public.shifts sh
  where sh.shift_code = v_shift_code
    and sh.active = true
    and sh.deleted_at is null
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'Selected shift is not available.';
  end if;

  v_week_start := public.production_roster_week_start(v_business_date);

  select prv.* into v_roster
  from public.production_roster_versions prv
  join public.roster_periods rp
    on rp.roster_period_id = prv.roster_period_id
  where rp.week_start = v_week_start
    and prv.shift_id = v_shift.shift_id
    and prv.status = 'PUBLISHED'
  order by prv.published_at desc nulls last, prv.version_number desc
  limit 1;

  if v_actor_staff_id is not null then
    select sm.display_name
    into v_actor_name
    from public.staff_members sm
    where sm.staff_id = v_actor_staff_id;
  end if;

  if v_roster.roster_version_id is not null then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'staff_id', q.staff_id,
        'display_name', q.staff_display_name,
        'day_status', q.day_status,
        'assignment_type', q.assignment_type,
        'role_code', q.role_code,
        'role_name', q.role_name,
        'area_code', q.area_code,
        'station_code', q.station_code,
        'display_section_code', q.display_section_code,
        'planned_start_time', q.planned_start_time,
        'planned_end_time', q.planned_end_time,
        'is_cover', q.assignment_type = 'COVER'
      )
      order by lower(q.staff_display_name), q.staff_id
    ), '[]'::jsonb)
    into v_staff
    from (
      select
        pre.staff_id,
        pre.staff_display_name_snapshot as staff_display_name,
        pre.day_status,
        pre.assignment_type,
        coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) as role_code,
        coalesce(nullif(pre.operational_role_name_snapshot, ''), opr.role_name) as role_name,
        coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) as area_code,
        coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) as station_code,
        pre.display_section_code,
        pre.planned_start_time,
        pre.planned_end_time
      from public.production_roster_entries pre
      left join public.operational_roles opr
        on opr.operational_role_id = pre.operational_role_id
      left join public.areas a
        on a.area_id = pre.area_id
      left join public.stations st
        on st.station_id = pre.station_id
      where pre.roster_version_id = v_roster.roster_version_id
        and pre.work_date = v_business_date
        and pre.day_status = 'WORKING'
        and (
          coalesce(nullif(pre.area_code_snapshot, ''), a.area_code) = 'SORTING'
          or coalesce(nullif(pre.station_code_snapshot, ''), st.station_code) = 'SORTING_MAIN'
          or pre.display_section_code = 'SORTING_AREA'
          or coalesce(nullif(pre.operational_role_code_snapshot, ''), opr.role_code) = 'SORTING_AREA'
        )
    ) q;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'event_id', q.trolley_event_id,
      'trolley_code', q.trolley_code,
      'customer_id', q.customer_id,
      'customer_code', q.customer_code,
      'customer_name', q.customer_name,
      'event_type', q.event_type,
      'exception_type', q.exception_type,
      'review_status', q.review_status,
      'performed_by', q.performed_by,
      'created_at', q.created_at
    )
    order by q.created_at desc
  ), '[]'::jsonb)
  into v_recent
  from (
    select
      te.trolley_event_id,
      t.trolley_code,
      te.customer_id,
      c.customer_code,
      c.customer_name,
      te.event_type,
      s.exception_type,
      s.review_status,
      performer.display_name as performed_by,
      te.created_at
    from public.trolley_events te
    join public.trolleys t
      on t.trolley_id = te.trolley_id
    left join public.customers c
      on c.customer_id = te.customer_id
    left join public.trolley_customer_stays s
      on s.stay_id = te.stay_id
    left join public.staff_members performer
      on performer.staff_id = te.performed_by
    where te.business_date = v_business_date
      and te.event_type in (
        'ARRIVED_AT_SORTING',
        'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND',
        'CUSTOMER_MISMATCH'
      )
    order by te.created_at desc
    limit 30
  ) q;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', c.customer_id,
      'customer_code', c.customer_code,
      'customer_name', c.customer_name
    )
    order by lower(c.customer_name), c.customer_code
  ), '[]'::jsonb)
  into v_customers
  from public.customers c
  where c.active = true
    and c.deleted_at is null;

  return jsonb_build_object(
    'business_date', v_business_date,
    'today', current_date,
    'is_today', v_business_date = current_date,
    'shift', jsonb_build_object(
      'shift_id', v_shift.shift_id,
      'shift_code', v_shift.shift_code,
      'shift_name', v_shift.shift_name
    ),
    'roster', case
      when v_roster.roster_version_id is null then null
      else jsonb_build_object(
        'roster_version_id', v_roster.roster_version_id,
        'version_number', v_roster.version_number,
        'status', v_roster.status,
        'published_at', v_roster.published_at,
        'week_start', v_week_start
      )
    end,
    'planned_staff', v_staff,
    'planned_staff_count', jsonb_array_length(v_staff),
    'recent_arrivals', v_recent,
    'customers', v_customers,
    'operator', jsonb_build_object(
      'staff_id', v_actor_staff_id,
      'display_name', v_actor_name
    ),
    'source', 'PUBLISHED_PRODUCTION_ROSTER'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Trolley intake preview
-- ---------------------------------------------------------------------

create or replace function public.get_sorting_trolley_intake_preview(
  p_trolley_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_code text := upper(trim(coalesce(p_trolley_code, '')));
  v_record jsonb;
  v_trolley jsonb;
  v_suggestion jsonb;
  v_current jsonb;
  v_status text;
  v_confirmation_source text;
begin
  perform public.require_sorting_operational_access();

  if v_code = '' then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  v_record := public.get_trolley_record(v_code);
  v_trolley := coalesce(v_record -> 'trolley', '{}'::jsonb);
  v_suggestion := coalesce(v_record -> 'suggestion', '{}'::jsonb);
  v_current := v_record -> 'current_stay';
  v_status := upper(coalesce(v_trolley ->> 'status', ''));

  v_confirmation_source := case
    when v_current is not null and jsonb_typeof(v_current) = 'object' then 'OPEN_STAY'
    when coalesce(v_suggestion ->> 'reason', '') = 'LAST_KNOWN_CUSTOMER' then 'LAST_KNOWN_CUSTOMER'
    else 'MANUAL_SELECTION'
  end;

  return jsonb_build_object(
    'trolley', jsonb_build_object(
      'trolley_id', v_trolley ->> 'trolley_id',
      'trolley_code', v_trolley ->> 'trolley_code',
      'status', v_trolley ->> 'status',
      'type_code', v_trolley ->> 'trolley_type_code',
      'type_name', v_trolley ->> 'trolley_type_name',
      'type_display_code', v_trolley ->> 'trolley_type_display_code'
    ),
    'suggestion', v_suggestion,
    'current_stay', v_current,
    'recommended_customer_id', nullif(v_suggestion ->> 'customer_id', '')::uuid,
    'recommended_customer_name', v_suggestion ->> 'customer_name',
    'suggestion_reason', coalesce(v_suggestion ->> 'reason', 'NO_HISTORY'),
    'confirmation_source', v_confirmation_source,
    'needs_review_if_confirmed', v_current is null or jsonb_typeof(v_current) <> 'object',
    'blocked', v_status in ('OUT_OF_SERVICE', 'RETIRED'),
    'message', case
      when v_status = 'OUT_OF_SERVICE' then 'This trolley is out of service and cannot be received in Sorting.'
      when v_status = 'RETIRED' then 'This trolley is retired and cannot be received in Sorting.'
      when v_current is not null and jsonb_typeof(v_current) = 'object' then 'Open customer custody found. Confirm the customer before recording the Sorting arrival.'
      when nullif(v_suggestion ->> 'customer_id', '') is not null then 'No open outbound stay was found. The last known customer is suggested; confirmation will create a review item.'
      else 'No customer history was found. Select the confirmed customer; the arrival will be recorded for review without inventing an outbound date.'
    end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Current-day Sorting trolley intake
-- ---------------------------------------------------------------------

create or replace function public.record_sorting_trolley_intake(
  p_trolley_code text,
  p_customer_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_code text := upper(trim(coalesce(p_trolley_code, '')));
  v_trolley_id uuid;
  v_suggestion record;
  v_confirmation_source text := 'MANUAL_SELECTION';
  v_result jsonb;
  v_customer_name text;
begin
  perform public.require_sorting_operational_access();

  if v_code = '' then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  if p_customer_id is null then
    raise exception using errcode = '22023', message = 'Confirmed customer is required.';
  end if;

  if length(coalesce(p_notes, '')) > 1000 then
    raise exception using errcode = '22023', message = 'Sorting intake notes must be 1000 characters or fewer.';
  end if;

  select t.trolley_id
  into v_trolley_id
  from public.trolleys t
  where lower(t.trolley_code) = lower(v_code)
    and t.deleted_at is null;

  if v_trolley_id is null then
    raise exception using errcode = 'P0002', message = format('Trolley not found: %s', v_code);
  end if;

  if exists (
    select 1
    from public.trolley_events te
    where te.trolley_id = v_trolley_id
      and te.business_date = current_date
      and te.customer_id = p_customer_id
      and te.event_type in (
        'ARRIVED_AT_SORTING',
        'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND',
        'CUSTOMER_MISMATCH'
      )
      and te.created_at >= now() - interval '10 minutes'
  ) then
    raise exception using
      errcode = '23505',
      message = format('Trolley %s was already recorded at Sorting a few minutes ago.', v_code);
  end if;

  select * into v_suggestion
  from public.suggest_trolley_customer(v_code);

  if v_suggestion.stay_id is not null then
    v_confirmation_source := 'OPEN_STAY';
  elsif v_suggestion.customer_id = p_customer_id
        and coalesce(v_suggestion.reason, '') = 'LAST_KNOWN_CUSTOMER' then
    v_confirmation_source := 'LAST_KNOWN_CUSTOMER';
  else
    v_confirmation_source := 'MANUAL_SELECTION';
  end if;

  v_result := public.confirm_trolley_sorting_arrival(
    p_trolley_code => v_code,
    p_customer_id => p_customer_id,
    p_arrived_on => current_date,
    p_confirmation_source => v_confirmation_source,
    p_notes => nullif(trim(p_notes), '')
  );

  select c.customer_name
  into v_customer_name
  from public.customers c
  where c.customer_id = p_customer_id;

  return v_result || jsonb_build_object(
    'trolley_code', v_code,
    'customer_id', p_customer_id,
    'customer_name', v_customer_name,
    'confirmation_source', v_confirmation_source,
    'message', case
      when coalesce(v_result ->> 'review_status', '') = 'PENDING'
        then 'Trolley arrival recorded. A review item was created because the trolley history did not fully match the confirmed customer.'
      else 'Trolley arrival recorded successfully.'
    end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Browser privileges
-- ---------------------------------------------------------------------

revoke all on function public.require_sorting_operational_access() from public, anon, authenticated;
revoke all on function public.get_sorting_daily_context(date, text) from public, anon, authenticated;
revoke all on function public.get_sorting_trolley_intake_preview(text) from public, anon, authenticated;
revoke all on function public.record_sorting_trolley_intake(text, uuid, text) from public, anon, authenticated;

grant execute on function public.get_sorting_daily_context(date, text) to authenticated;
grant execute on function public.get_sorting_trolley_intake_preview(text) to authenticated;
grant execute on function public.record_sorting_trolley_intake(text, uuid, text) to authenticated;

comment on function public.get_sorting_daily_context(date, text) is
  'Returns current Sorting staff from the PUBLISHED Production Roster plus recent Sorting trolley arrivals. Draft roster data is never used as the operational plan.';

comment on function public.get_sorting_trolley_intake_preview(text) is
  'Returns a controlled trolley/customer suggestion for Sorting intake without changing lifecycle state.';

comment on function public.record_sorting_trolley_intake(text, uuid, text) is
  'Records a current-day Sorting trolley arrival through the existing Physical Trolley Lifecycle and preserves missing-outbound/customer-mismatch review behavior.';

commit;
