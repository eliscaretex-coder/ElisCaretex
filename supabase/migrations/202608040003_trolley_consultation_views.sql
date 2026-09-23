-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608040003_trolley_consultation_views.sql
-- Purpose:
--   Reframe the Physical Trolleys module as a consultation and master-data
--   surface. Finish/Mop production assignment and Sorting intake remain in
--   their own future operational applications. This migration adds:
--   - a safe current-location overview grouped by Elis Laundry/customer;
--   - days at the current location;
--   - a traceable RETIRE_TROLLEY master-data action;
--   - no Distribution Daily Plan or delivery confirmation workflow.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Retired trolley event support
-- ---------------------------------------------------------------------

alter table public.trolley_events
  drop constraint if exists trolley_event_type_check;

alter table public.trolley_events
  add constraint trolley_event_type_check
  check (
    event_type in (
      'TROLLEY_REGISTERED',
      'ASSIGNED_IN_PRODUCTION',
      'SENT_TO_CUSTOMER',
      'DELIVERY_CONFIRMED',
      'RECEIVED_FROM_CUSTOMER',
      'RECEIVED_WITHOUT_OUTBOUND',
      'ARRIVED_AT_SORTING',
      'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND',
      'CUSTOMER_MISMATCH',
      'EXCEPTION_REVIEW_STARTED',
      'EXCEPTION_REOPENED',
      'EXCEPTION_REVIEWED',
      'RECORD_CORRECTED',
      'MARKED_OUT_OF_SERVICE',
      'RETURNED_TO_SERVICE',
      'TROLLEY_RETIRED'
    )
  );

-- ---------------------------------------------------------------------
-- 2. Current location consultation
-- ---------------------------------------------------------------------

create or replace function public.get_trolley_location_overview(
  p_search text default null,
  p_location_filter text default 'ALL'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_search text := lower(nullif(trim(p_search), ''));
  v_filter text := upper(coalesce(nullif(trim(p_location_filter), ''), 'ALL'));
  v_warning_days integer;
  v_overdue_days integer;
  v_result jsonb;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  if v_filter not in ('ALL', 'ELIS_LAUNDRY', 'CUSTOMERS', 'LOCATION_UNCONFIRMED') then
    raise exception using errcode = '22023', message = 'Invalid trolley location filter.';
  end if;

  select coalesce((value_json #>> '{}')::integer, 14)
  into v_warning_days
  from public.app_config
  where config_key = 'trolley_warning_days';

  select coalesce((value_json #>> '{}')::integer, 30)
  into v_overdue_days
  from public.app_config
  where config_key = 'trolley_overdue_days';

  with trolley_state as (
    select
      t.trolley_id,
      t.trolley_code,
      t.status as stored_status,
      t.active,
      t.registered_on,
      t.retired_on,
      t.notes,
      t.metadata,
      tt.trolley_type_code,
      tt.trolley_type_name,
      coalesce(tt.display_code, tt.trolley_type_code) as trolley_type_display_code,
      open_stay.stay_id as open_stay_id,
      open_stay.outbound_customer_id,
      c.customer_code,
      c.customer_name,
      open_stay.production_business_date,
      open_stay.production_area_code,
      open_stay.planned_delivery_on,
      open_stay.sent_on,
      open_stay.custody_start_source,
      last_arrival.business_date as last_arrival_on,
      case
        when t.status = 'RETIRED' then 'RETIRED'
        when t.status = 'OUT_OF_SERVICE' then 'OUT_OF_SERVICE'
        when open_stay.stay_id is not null and open_stay.sent_on <= current_date then 'CUSTOMER'
        when open_stay.stay_id is not null and open_stay.sent_on > current_date then 'ELIS_LAUNDRY'
        when t.status = 'AVAILABLE' then 'ELIS_LAUNDRY'
        when t.status = 'LOCATION_UNCONFIRMED' then 'LOCATION_UNCONFIRMED'
        else 'LOCATION_UNCONFIRMED'
      end as location_type,
      case
        when open_stay.stay_id is not null and open_stay.sent_on <= current_date then open_stay.sent_on
        when open_stay.stay_id is not null and open_stay.sent_on > current_date then
          coalesce(open_stay.production_business_date, current_date)
        when t.status = 'AVAILABLE' then coalesce(last_arrival.business_date, t.registered_on)
        else null
      end as location_since,
      case
        when open_stay.stay_id is not null and open_stay.sent_on <= current_date then
          greatest(current_date - open_stay.sent_on, 0)
        when open_stay.stay_id is not null and open_stay.sent_on > current_date then
          greatest(current_date - coalesce(open_stay.production_business_date, current_date), 0)
        when t.status = 'AVAILABLE' then
          greatest(current_date - coalesce(last_arrival.business_date, t.registered_on), 0)
        else null
      end as days_at_location,
      exists (
        select 1
        from public.trolley_customer_stays review_stay
        where review_stay.trolley_id = t.trolley_id
          and review_stay.exception_type is not null
          and review_stay.review_status in ('PENDING', 'UNDER_REVIEW')
      ) as has_review_required
    from public.trolleys t
    join public.trolley_types tt
      on tt.trolley_type_id = t.trolley_type_id
    left join lateral (
      select s.*
      from public.trolley_customer_stays s
      where s.trolley_id = t.trolley_id
        and s.received_on is null
      order by s.created_at desc
      limit 1
    ) open_stay on true
    left join public.customers c
      on c.customer_id = open_stay.outbound_customer_id
    left join lateral (
      select e.business_date
      from public.trolley_events e
      where e.trolley_id = t.trolley_id
        and e.event_type in (
          'ARRIVED_AT_SORTING',
          'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND',
          'RECEIVED_FROM_CUSTOMER',
          'RECEIVED_WITHOUT_OUTBOUND',
          'RETURNED_TO_SERVICE'
        )
      order by e.business_date desc, e.created_at desc
      limit 1
    ) last_arrival on true
    where t.deleted_at is null
  ), operational_locations as (
    select
      ts.*,
      case
        when ts.location_type = 'CUSTOMER' then ts.outbound_customer_id::text
        when ts.location_type = 'ELIS_LAUNDRY' then 'ELIS_LAUNDRY'
        else 'LOCATION_UNCONFIRMED'
      end as location_key,
      case
        when ts.location_type = 'CUSTOMER' then ts.customer_name
        when ts.location_type = 'ELIS_LAUNDRY' then 'Elis Laundry'
        else 'Location unconfirmed'
      end as location_name,
      case
        when ts.location_type = 'CUSTOMER' then ts.customer_code
        when ts.location_type = 'ELIS_LAUNDRY' then 'ELIS'
        else null
      end as location_code,
      case
        when ts.location_type = 'CUSTOMER'
             and ts.days_at_location >= coalesce(v_overdue_days, 30) then 'OVERDUE'
        when ts.location_type = 'CUSTOMER'
             and ts.days_at_location >= coalesce(v_warning_days, 14) then 'WARNING'
        else 'NORMAL'
      end as attention_status,
      case
        when ts.location_type = 'ELIS_LAUNDRY'
             and ts.open_stay_id is not null
             and ts.sent_on > current_date then 'PREPARED_FOR_DELIVERY'
        when ts.location_type = 'ELIS_LAUNDRY' then 'AT_LAUNDRY'
        when ts.location_type = 'CUSTOMER' then 'AT_CUSTOMER'
        else 'LOCATION_UNCONFIRMED'
      end as location_status
    from trolley_state ts
    where ts.location_type in ('ELIS_LAUNDRY', 'CUSTOMER', 'LOCATION_UNCONFIRMED')
  ), filtered as (
    select ol.*
    from operational_locations ol
    where (
      v_search is null
      or lower(ol.trolley_code) like '%' || v_search || '%'
      or lower(coalesce(ol.trolley_type_name, '')) like '%' || v_search || '%'
      or lower(coalesce(ol.location_name, '')) like '%' || v_search || '%'
      or lower(coalesce(ol.location_code, '')) like '%' || v_search || '%'
    )
      and case v_filter
        when 'ALL' then true
        when 'ELIS_LAUNDRY' then ol.location_type = 'ELIS_LAUNDRY'
        when 'CUSTOMERS' then ol.location_type = 'CUSTOMER'
        when 'LOCATION_UNCONFIRMED' then ol.location_type = 'LOCATION_UNCONFIRMED'
        else false
      end
  ), location_groups as (
    select
      f.location_key,
      f.location_type,
      f.location_name,
      f.location_code,
      case
        when f.location_type = 'ELIS_LAUNDRY' then 1
        when f.location_type = 'CUSTOMER' then 2
        else 3
      end as sort_group,
      count(*) as trolley_count,
      count(*) filter (where f.location_status = 'PREPARED_FOR_DELIVERY') as prepared_count,
      count(*) filter (where f.attention_status = 'WARNING') as warning_count,
      count(*) filter (where f.attention_status = 'OVERDUE') as overdue_count,
      count(*) filter (where f.has_review_required) as review_required_count,
      max(f.days_at_location) as longest_days,
      min(f.location_since) as oldest_location_since,
      jsonb_agg(
        jsonb_build_object(
          'trolley_id', f.trolley_id,
          'trolley_code', f.trolley_code,
          'trolley_type_code', f.trolley_type_code,
          'trolley_type_name', f.trolley_type_name,
          'trolley_type_display_code', f.trolley_type_display_code,
          'location_status', f.location_status,
          'location_since', f.location_since,
          'days_at_location', f.days_at_location,
          'attention_status', f.attention_status,
          'has_review_required', f.has_review_required,
          'customer_id', f.outbound_customer_id,
          'customer_code', f.customer_code,
          'customer_name', f.customer_name,
          'production_business_date', f.production_business_date,
          'production_area_code', f.production_area_code,
          'planned_delivery_on', f.planned_delivery_on,
          'custody_start_source', f.custody_start_source
        )
        order by
          case f.attention_status when 'OVERDUE' then 1 when 'WARNING' then 2 else 3 end,
          f.days_at_location desc nulls last,
          lower(f.trolley_code)
      ) as trolleys
    from filtered f
    group by f.location_key, f.location_type, f.location_name, f.location_code
  )
  select jsonb_build_object(
    'generated_on', current_date,
    'warning_days', coalesce(v_warning_days, 14),
    'overdue_days', coalesce(v_overdue_days, 30),
    'filter', v_filter,
    'search', p_search,
    'summary', jsonb_build_object(
      'operational_trolleys', (
        select count(*)
        from operational_locations
      ),
      'at_laundry', (
        select count(*)
        from operational_locations
        where location_type = 'ELIS_LAUNDRY'
      ),
      'prepared_for_delivery', (
        select count(*)
        from operational_locations
        where location_status = 'PREPARED_FOR_DELIVERY'
      ),
      'at_customers', (
        select count(*)
        from operational_locations
        where location_type = 'CUSTOMER'
      ),
      'customer_locations', (
        select count(distinct outbound_customer_id)
        from operational_locations
        where location_type = 'CUSTOMER'
      ),
      'location_unconfirmed', (
        select count(*)
        from operational_locations
        where location_type = 'LOCATION_UNCONFIRMED'
      ),
      'warning', (
        select count(*)
        from operational_locations
        where attention_status = 'WARNING'
      ),
      'overdue', (
        select count(*)
        from operational_locations
        where attention_status = 'OVERDUE'
      ),
      'out_of_service', (
        select count(*)
        from trolley_state
        where stored_status = 'OUT_OF_SERVICE'
      ),
      'retired', (
        select count(*)
        from trolley_state
        where stored_status = 'RETIRED'
      )
    ),
    'groups', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'location_key', lg.location_key,
            'location_type', lg.location_type,
            'location_name', lg.location_name,
            'location_code', lg.location_code,
            'trolley_count', lg.trolley_count,
            'prepared_count', lg.prepared_count,
            'warning_count', lg.warning_count,
            'overdue_count', lg.overdue_count,
            'review_required_count', lg.review_required_count,
            'longest_days', lg.longest_days,
            'oldest_location_since', lg.oldest_location_since,
            'trolleys', lg.trolleys
          )
          order by lg.sort_group, lower(lg.location_name), lg.location_code
        )
        from location_groups lg
      ),
      '[]'::jsonb
    )
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.get_trolley_location_overview(text, text)
  is 'Returns current trolley locations grouped by Elis Laundry, customer or location-unconfirmed, including days at the current location.';

-- ---------------------------------------------------------------------
-- 3. Controlled master-data status actions, including retirement
-- ---------------------------------------------------------------------

create or replace function public.set_trolley_service_status(
  p_trolley_code text,
  p_action text,
  p_reason text,
  p_source_application text default 'TROLLEY_CONTROL'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff_id uuid;
  v_action text := upper(trim(p_action));
  v_trolley public.trolleys%rowtype;
  v_old_data jsonb;
  v_event_type text;
  v_return_status text;
begin
  perform public.require_any_trolley_role(array['ADMIN', 'MANAGER']);

  if v_action is null or v_action not in (
    'MARK_OUT_OF_SERVICE',
    'RETURN_TO_SERVICE',
    'RETIRE_TROLLEY'
  ) then
    raise exception using errcode = '22023', message = 'Invalid trolley service action.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason is required.';
  end if;

  select * into v_trolley
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(p_trolley_code))
    and t.deleted_at is null
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Trolley not found.';
  end if;

  v_old_data := to_jsonb(v_trolley);
  v_staff_id := public.current_staff_id();

  if v_action in ('MARK_OUT_OF_SERVICE', 'RETIRE_TROLLEY') and exists (
    select 1
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.received_on is null
  ) then
    raise exception using errcode = '23514', message =
      case
        when v_action = 'RETIRE_TROLLEY'
          then 'A trolley with an open customer assignment cannot be retired.'
        else 'A trolley with an open customer assignment cannot be marked out of service.'
      end;
  end if;

  if v_action = 'MARK_OUT_OF_SERVICE' then
    if v_trolley.status = 'RETIRED' then
      raise exception using errcode = '23514', message = 'A retired trolley cannot be changed.';
    end if;

    if v_trolley.status = 'OUT_OF_SERVICE' then
      raise exception using errcode = '23514', message = 'Trolley is already out of service.';
    end if;

    update public.trolleys
    set
      status_before_service_hold = v_trolley.status,
      status = 'OUT_OF_SERVICE',
      updated_by = auth.uid()
    where trolley_id = v_trolley.trolley_id
    returning * into v_trolley;

    v_event_type := 'MARKED_OUT_OF_SERVICE';

  elsif v_action = 'RETURN_TO_SERVICE' then
    if v_trolley.status <> 'OUT_OF_SERVICE' then
      raise exception using errcode = '23514', message = 'Only an out-of-service trolley can be returned to service.';
    end if;

    v_return_status := coalesce(v_trolley.status_before_service_hold, 'AVAILABLE');

    if v_return_status not in ('LOCATION_UNCONFIRMED', 'AVAILABLE') then
      v_return_status := 'AVAILABLE';
    end if;

    update public.trolleys
    set
      status = v_return_status,
      status_before_service_hold = null,
      updated_by = auth.uid()
    where trolley_id = v_trolley.trolley_id
    returning * into v_trolley;

    v_event_type := 'RETURNED_TO_SERVICE';

  else
    if v_trolley.status = 'RETIRED' then
      raise exception using errcode = '23514', message = 'Trolley is already retired.';
    end if;

    update public.trolleys
    set
      status = 'RETIRED',
      active = false,
      retired_on = current_date,
      status_before_service_hold = null,
      updated_by = auth.uid()
    where trolley_id = v_trolley.trolley_id
    returning * into v_trolley;

    v_event_type := 'TROLLEY_RETIRED';
  end if;

  insert into public.trolley_events (
    trolley_id,
    event_type,
    business_date,
    performed_by,
    source_application,
    reason
  ) values (
    v_trolley.trolley_id,
    v_event_type,
    current_date,
    v_staff_id,
    p_source_application,
    p_reason
  );

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
  ) values (
    auth.uid(),
    v_staff_id,
    v_event_type,
    'trolleys',
    v_trolley.trolley_id::text,
    v_old_data,
    to_jsonb(v_trolley),
    p_reason,
    p_source_application
  );

  return jsonb_build_object(
    'trolley_id', v_trolley.trolley_id,
    'trolley_code', v_trolley.trolley_code,
    'status', v_trolley.status,
    'active', v_trolley.active,
    'retired_on', v_trolley.retired_on
  );
end;
$$;

comment on function public.set_trolley_service_status(text, text, text, text)
  is 'Changes trolley service status and supports traceable retirement without deleting trolley history.';

-- ---------------------------------------------------------------------
-- 4. Controlled grants
-- ---------------------------------------------------------------------

revoke all on function public.get_trolley_location_overview(text, text)
  from public, anon;
grant execute on function public.get_trolley_location_overview(text, text)
  to authenticated;

revoke all on function public.set_trolley_service_status(text, text, text, text)
  from public, anon;
grant execute on function public.set_trolley_service_status(text, text, text, text)
  to authenticated;

commit;
