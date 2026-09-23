-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608040001_trolley_production_sorting_flow.sql
-- Purpose:
--   Align Physical Trolley Lifecycle with the confirmed real operation:
--   - Finish/Mop assigns a physical trolley when a customer is processed;
--   - delivery is inferred for the next Distribution business day while
--     portable scanning is unavailable;
--   - Sorting scans the returning dirty trolley and confirms its customer;
--   - days at customer are measured from the tracked delivery/custody date
--     to the Sorting arrival date;
--   - imported trolley location is never invented.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Trolley master and lifecycle provenance
-- ---------------------------------------------------------------------

alter table public.trolleys
  add column if not exists metadata jsonb not null default '{}'::jsonb,
  add column if not exists status_before_service_hold text;

alter table public.trolleys
  drop constraint if exists trolleys_status_check;

alter table public.trolleys
  add constraint trolleys_status_check
  check (
    status in (
      'LOCATION_UNCONFIRMED',
      'AVAILABLE',
      'AT_CUSTOMER',
      'IN_PRODUCTION',
      'OUT_OF_SERVICE',
      'RETIRED'
    )
  );

alter table public.trolleys
  drop constraint if exists trolleys_status_before_service_hold_check;

alter table public.trolleys
  add constraint trolleys_status_before_service_hold_check
  check (
    status_before_service_hold is null
    or status_before_service_hold in (
      'LOCATION_UNCONFIRMED',
      'AVAILABLE',
      'AT_CUSTOMER',
      'IN_PRODUCTION'
    )
  );

alter table public.trolley_customer_stays
  add column if not exists production_business_date date,
  add column if not exists planned_delivery_on date,
  add column if not exists production_area_code text,
  add column if not exists custody_start_source text,
  add column if not exists source_schedule_version_id uuid
    references public.customer_schedule_versions(schedule_version_id) on delete restrict,
  add column if not exists source_schedule_day_id uuid
    references public.customer_schedule_days(schedule_day_id) on delete restrict,
  add column if not exists source_schedule_product_id uuid
    references public.customer_schedule_products(schedule_product_id) on delete restrict,
  add column if not exists production_recorded_by uuid
    references public.staff_members(staff_id) on delete set null,
  add column if not exists production_recorded_at timestamptz;

alter table public.trolley_customer_stays
  drop constraint if exists trolley_stay_production_area_check;

alter table public.trolley_customer_stays
  add constraint trolley_stay_production_area_check
  check (
    production_area_code is null
    or production_area_code in ('FINISH', 'MOP')
  );

alter table public.trolley_customer_stays
  drop constraint if exists trolley_stay_custody_start_source_check;

alter table public.trolley_customer_stays
  add constraint trolley_stay_custody_start_source_check
  check (
    custody_start_source is null
    or custody_start_source in (
      'PRODUCTION_NEXT_DAY_INFERENCE',
      'DISTRIBUTION_CONFIRMED',
      'MANUAL_DELIVERY_CONFIRMATION',
      'SUPERVISOR_CORRECTION'
    )
  );

alter table public.trolley_customer_stays
  drop constraint if exists trolley_stay_production_dates_check;

alter table public.trolley_customer_stays
  add constraint trolley_stay_production_dates_check
  check (
    production_business_date is null
    or (
      planned_delivery_on is not null
      and planned_delivery_on >= production_business_date
      and sent_on is not null
      and sent_on >= production_business_date
      and production_area_code is not null
      and custody_start_source is not null
      and source_schedule_version_id is not null
      and source_schedule_day_id is not null
      and source_schedule_product_id is not null
      and production_recorded_at is not null
    )
  );

create index if not exists trolley_stays_production_lookup_idx
  on public.trolley_customer_stays
  (production_business_date desc, production_area_code, outbound_customer_id)
  where production_business_date is not null;

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
      'RETURNED_TO_SERVICE'
    )
  );

-- ---------------------------------------------------------------------
-- 2. Central next-delivery-date rule
-- ---------------------------------------------------------------------

create or replace function public.next_distribution_business_date(
  p_production_date date
)
returns date
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select case extract(isodow from p_production_date)::integer
    when 6 then p_production_date + 2
    when 7 then p_production_date + 1
    else p_production_date + 1
  end;
$$;

comment on function public.next_distribution_business_date(date)
  is 'Returns the next Distribution date after production, skipping Sunday.';

-- ---------------------------------------------------------------------
-- 3. Capabilities and safe reference access
-- ---------------------------------------------------------------------

create or replace function public.get_trolley_lifecycle_capabilities()
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select jsonb_build_object(
    'can_view_trolleys', public.has_any_role(
      array[
        'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
        'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
        'FINISH_OPERATOR', 'MOP_OPERATOR'
      ]
    ),
    'can_assign_trolleys_from_production', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'FINISH_OPERATOR', 'MOP_OPERATOR']
    ),
    'can_assign_finish_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'FINISH_OPERATOR']
    ),
    'can_assign_mop_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'MOP_OPERATOR']
    ),
    'can_dispatch_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR']
    ),
    'can_receive_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']
    ),
    'can_confirm_sorting_arrival', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']
    ),
    'can_view_trolley_exceptions', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR']
    ),
    'can_review_trolley_exceptions', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR']
    ),
    'can_manage_trolley_master', public.has_any_role(
      array['ADMIN', 'MANAGER']
    )
  );
$$;

create or replace function public.get_trolley_reference_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_warning_days integer;
  v_overdue_days integer;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  select coalesce((value_json #>> '{}')::integer, 14)
  into v_warning_days
  from public.app_config
  where config_key = 'trolley_warning_days';

  select coalesce((value_json #>> '{}')::integer, 30)
  into v_overdue_days
  from public.app_config
  where config_key = 'trolley_overdue_days';

  return jsonb_build_object(
    'capabilities', public.get_trolley_lifecycle_capabilities(),
    'warning_days', coalesce(v_warning_days, 14),
    'overdue_days', coalesce(v_overdue_days, 30),
    'delivery_tracking_mode', 'PRODUCTION_NEXT_DAY_INFERENCE',
    'customers', case
      when public.has_any_role(array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']) then
        coalesce(
          (
            select jsonb_agg(
              jsonb_build_object(
                'customer_id', c.customer_id,
                'customer_code', c.customer_code,
                'customer_name', c.customer_name
              ) order by lower(c.customer_name), c.customer_code
            )
            from public.customers c
            where c.active = true
              and c.deleted_at is null
          ),
          '[]'::jsonb
        )
      else '[]'::jsonb
    end,
    'trolley_types', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'trolley_type_id', tt.trolley_type_id,
            'trolley_type_code', tt.trolley_type_code,
            'trolley_type_name', tt.trolley_type_name,
            'display_code', coalesce(tt.display_code, tt.trolley_type_code)
          ) order by tt.sort_order, tt.trolley_type_code
        )
        from public.trolley_types tt
        where tt.active = true
          and tt.deleted_at is null
      ),
      '[]'::jsonb
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Production assignment context
-- ---------------------------------------------------------------------

create or replace function public.get_trolley_production_customers(
  p_area_code text,
  p_business_date date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_area_code text := upper(nullif(trim(p_area_code), ''));
  v_business_date date := coalesce(p_business_date, current_date);
  v_product_code text;
begin
  if v_area_code not in ('FINISH', 'MOP') then
    raise exception using errcode = '22023', message = 'Production area must be FINISH or MOP.';
  end if;

  if v_area_code = 'FINISH' then
    perform public.require_any_trolley_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'FINISH_OPERATOR']
    );
    v_product_code := 'CLOTHES';
  else
    perform public.require_any_trolley_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'MOP_OPERATOR']
    );
    v_product_code := 'MOP';
  end if;

  return jsonb_build_object(
    'area_code', v_area_code,
    'product_code', v_product_code,
    'business_date', v_business_date,
    'planned_delivery_on', public.next_distribution_business_date(v_business_date),
    'customers', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'customer_id', scheduled.customer_id,
            'customer_code', scheduled.customer_code,
            'customer_name', scheduled.customer_name,
            'schedule_version_id', scheduled.schedule_version_id,
            'schedule_day_id', scheduled.schedule_day_id,
            'schedule_product_id', scheduled.schedule_product_id,
            'production_order', scheduled.production_order,
            'production_instructions', scheduled.production_instructions,
            'operational_alert', scheduled.operational_alert
          ) order by scheduled.production_order nulls last, lower(scheduled.customer_name), scheduled.customer_code
        )
        from (
          select distinct on (c.customer_id)
            c.customer_id,
            c.customer_code,
            c.customer_name,
            c.operational_alert,
            v.schedule_version_id,
            d.schedule_day_id,
            sp.schedule_product_id,
            sp.production_order,
            sp.production_instructions,
            v.version_number
          from public.customer_schedule_versions v
          join public.customers c
            on c.customer_id = v.customer_id
          join public.customer_schedule_days d
            on d.schedule_version_id = v.schedule_version_id
          join public.customer_schedule_products sp
            on sp.schedule_day_id = d.schedule_day_id
          join public.product_types pt
            on pt.product_type_id = sp.product_type_id
          where v.status = 'PUBLISHED'
            and v_business_date >= v.effective_from
            and (v.effective_until is null or v_business_date <= v.effective_until)
            and d.active = true
            and d.production_weekday = extract(isodow from v_business_date)::smallint
            and sp.active = true
            and pt.active = true
            and pt.deleted_at is null
            and pt.product_code = v_product_code
            and c.active = true
            and c.deleted_at is null
          order by c.customer_id, v.version_number desc
        ) scheduled
      ),
      '[]'::jsonb
    )
  );
end;
$$;

comment on function public.get_trolley_production_customers(text, date)
  is 'Returns customers scheduled for Finish or Mop production on the selected business date.';

create or replace function public.assign_trolley_to_customer_from_production(
  p_trolley_code text,
  p_customer_id uuid,
  p_production_business_date date,
  p_area_code text,
  p_notes text default null,
  p_source_application text default 'TROLLEY_PRODUCTION_ASSIGNMENT'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff_id uuid;
  v_area_code text := upper(nullif(trim(p_area_code), ''));
  v_product_code text;
  v_production_date date := coalesce(p_production_business_date, current_date);
  v_delivery_date date;
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_schedule record;
begin
  if nullif(trim(p_trolley_code), '') is null then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  if p_customer_id is null then
    raise exception using errcode = '22023', message = 'Customer is required.';
  end if;

  if v_area_code not in ('FINISH', 'MOP') then
    raise exception using errcode = '22023', message = 'Production area must be FINISH or MOP.';
  end if;

  if extract(isodow from v_production_date)::integer = 7 then
    raise exception using errcode = '22023', message = 'Sunday is not a production day.';
  end if;

  if v_area_code = 'FINISH' then
    perform public.require_any_trolley_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'FINISH_OPERATOR']
    );
    v_product_code := 'CLOTHES';
  else
    perform public.require_any_trolley_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'MOP_OPERATOR']
    );
    v_product_code := 'MOP';
  end if;

  select
    v.schedule_version_id,
    d.schedule_day_id,
    sp.schedule_product_id,
    c.customer_code,
    c.customer_name
  into v_schedule
  from public.customer_schedule_versions v
  join public.customers c
    on c.customer_id = v.customer_id
  join public.customer_schedule_days d
    on d.schedule_version_id = v.schedule_version_id
  join public.customer_schedule_products sp
    on sp.schedule_day_id = d.schedule_day_id
  join public.product_types pt
    on pt.product_type_id = sp.product_type_id
  where v.customer_id = p_customer_id
    and v.status = 'PUBLISHED'
    and v_production_date >= v.effective_from
    and (v.effective_until is null or v_production_date <= v.effective_until)
    and d.active = true
    and d.production_weekday = extract(isodow from v_production_date)::smallint
    and sp.active = true
    and pt.active = true
    and pt.deleted_at is null
    and pt.product_code = v_product_code
    and c.active = true
    and c.deleted_at is null
  order by v.version_number desc
  limit 1;

  if v_schedule.schedule_product_id is null then
    raise exception using
      errcode = '22023',
      message = format(
        'The selected customer is not scheduled for %s production on %s.',
        v_area_code,
        to_char(v_production_date, 'DD Mon YYYY')
      );
  end if;

  v_delivery_date := public.next_distribution_business_date(v_production_date);
  v_staff_id := public.current_staff_id();

  select *
  into v_trolley
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(p_trolley_code))
    and t.deleted_at is null
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = format('Trolley not found: %s', trim(p_trolley_code));
  end if;

  if not v_trolley.active
     or v_trolley.status not in ('AVAILABLE', 'LOCATION_UNCONFIRMED') then
    raise exception using
      errcode = '23514',
      message = format(
        'Trolley %s cannot be assigned from production. Current status: %s',
        v_trolley.trolley_code,
        v_trolley.status
      );
  end if;

  if exists (
    select 1
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.received_on is null
  ) then
    raise exception using
      errcode = '23505',
      message = format('Trolley %s already has an open customer stay.', v_trolley.trolley_code);
  end if;

  insert into public.trolley_customer_stays (
    trolley_id,
    outbound_customer_id,
    sent_on,
    status,
    review_status,
    sent_recorded_by,
    notes,
    production_business_date,
    planned_delivery_on,
    production_area_code,
    custody_start_source,
    source_schedule_version_id,
    source_schedule_day_id,
    source_schedule_product_id,
    production_recorded_by,
    production_recorded_at
  )
  values (
    v_trolley.trolley_id,
    p_customer_id,
    v_delivery_date,
    'OPEN',
    'NOT_REQUIRED',
    v_staff_id,
    nullif(trim(p_notes), ''),
    v_production_date,
    v_delivery_date,
    v_area_code,
    'PRODUCTION_NEXT_DAY_INFERENCE',
    v_schedule.schedule_version_id,
    v_schedule.schedule_day_id,
    v_schedule.schedule_product_id,
    v_staff_id,
    now()
  )
  returning * into v_stay;

  update public.trolleys
  set
    status = 'IN_PRODUCTION',
    updated_by = auth.uid()
  where trolley_id = v_trolley.trolley_id;

  insert into public.trolley_events (
    trolley_id,
    stay_id,
    event_type,
    customer_id,
    business_date,
    performed_by,
    source_application,
    reason,
    metadata
  )
  values (
    v_trolley.trolley_id,
    v_stay.stay_id,
    'ASSIGNED_IN_PRODUCTION',
    p_customer_id,
    v_production_date,
    v_staff_id,
    p_source_application,
    p_notes,
    jsonb_build_object(
      'production_area_code', v_area_code,
      'product_code', v_product_code,
      'planned_delivery_on', v_delivery_date,
      'custody_start_source', 'PRODUCTION_NEXT_DAY_INFERENCE',
      'schedule_version_id', v_schedule.schedule_version_id,
      'schedule_day_id', v_schedule.schedule_day_id,
      'schedule_product_id', v_schedule.schedule_product_id
    )
  );

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
    v_staff_id,
    'ASSIGN_TROLLEY_FROM_PRODUCTION',
    'trolley_customer_stays',
    v_stay.stay_id::text,
    to_jsonb(v_stay),
    p_notes,
    p_source_application
  );

  return jsonb_build_object(
    'trolley_id', v_trolley.trolley_id,
    'trolley_code', v_trolley.trolley_code,
    'stay_id', v_stay.stay_id,
    'customer_id', p_customer_id,
    'customer_code', v_schedule.customer_code,
    'customer_name', v_schedule.customer_name,
    'production_business_date', v_production_date,
    'planned_delivery_on', v_delivery_date,
    'production_area_code', v_area_code,
    'custody_start_source', v_stay.custody_start_source,
    'status', 'IN_PRODUCTION'
  );
end;
$$;

comment on function public.assign_trolley_to_customer_from_production(text, uuid, date, text, text, text)
  is 'Assigns a physical trolley to a scheduled Finish/Mop customer and records an explicitly inferred next-day delivery date.';

-- ---------------------------------------------------------------------
-- 5. Read models with effective location state
-- ---------------------------------------------------------------------

create or replace function public.get_trolley_dashboard(
  p_search text default null,
  p_filter text default 'ALL'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_filter text := upper(coalesce(nullif(trim(p_filter), ''), 'ALL'));
  v_search text := lower(nullif(trim(p_search), ''));
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

  if v_filter not in (
    'ALL', 'LOCATION_UNCONFIRMED', 'AVAILABLE', 'IN_PRODUCTION',
    'AT_CUSTOMER', 'ATTENTION', 'REVIEW_REQUIRED',
    'OUT_OF_SERVICE', 'RETIRED'
  ) then
    raise exception using errcode = '22023', message = 'Invalid trolley dashboard filter.';
  end if;

  select coalesce((value_json #>> '{}')::integer, 14)
  into v_warning_days
  from public.app_config
  where config_key = 'trolley_warning_days';

  select coalesce((value_json #>> '{}')::integer, 30)
  into v_overdue_days
  from public.app_config
  where config_key = 'trolley_overdue_days';

  with trolley_rows as (
    select
      t.trolley_id,
      t.trolley_code,
      t.status as stored_status,
      case
        when t.status in ('OUT_OF_SERVICE', 'RETIRED') then t.status
        when open_stay.stay_id is not null and open_stay.sent_on > current_date then 'IN_PRODUCTION'
        when open_stay.stay_id is not null then 'AT_CUSTOMER'
        else t.status
      end as effective_status,
      t.active,
      t.registered_on,
      t.retired_on,
      t.notes,
      t.metadata,
      tt.trolley_type_id,
      tt.trolley_type_code,
      tt.trolley_type_name,
      coalesce(tt.display_code, tt.trolley_type_code) as trolley_type_display_code,
      open_stay.stay_id as open_stay_id,
      open_stay.outbound_customer_id as current_customer_id,
      current_customer.customer_code as current_customer_code,
      current_customer.customer_name as current_customer_name,
      open_stay.production_business_date,
      open_stay.production_area_code,
      open_stay.planned_delivery_on,
      open_stay.sent_on,
      open_stay.custody_start_source,
      case
        when open_stay.sent_on is null or open_stay.sent_on > current_date then null
        else current_date - open_stay.sent_on
      end as days_out,
      case
        when open_stay.sent_on is null or open_stay.sent_on > current_date then null
        when current_date - open_stay.sent_on >= coalesce(v_overdue_days, 30) then 'OVERDUE'
        when current_date - open_stay.sent_on >= coalesce(v_warning_days, 14) then 'WARNING'
        else 'NORMAL'
      end as attention_status,
      exists (
        select 1
        from public.trolley_customer_stays review_stay
        where review_stay.trolley_id = t.trolley_id
          and review_stay.exception_type is not null
          and review_stay.review_status in ('PENDING', 'UNDER_REVIEW')
      ) as has_review_required,
      last_event.event_type as last_event_type,
      last_event.business_date as last_event_business_date,
      last_event.created_at as last_event_created_at
    from public.trolleys t
    left join public.trolley_types tt
      on tt.trolley_type_id = t.trolley_type_id
    left join lateral (
      select s.*
      from public.trolley_customer_stays s
      where s.trolley_id = t.trolley_id
        and s.received_on is null
      order by s.created_at desc
      limit 1
    ) open_stay on true
    left join public.customers current_customer
      on current_customer.customer_id = open_stay.outbound_customer_id
    left join lateral (
      select e.event_type, e.business_date, e.created_at
      from public.trolley_events e
      where e.trolley_id = t.trolley_id
      order by e.created_at desc
      limit 1
    ) last_event on true
    where t.deleted_at is null
  ),
  filtered_rows as (
    select tr.*
    from trolley_rows tr
    where (
      v_search is null
      or lower(tr.trolley_code) like '%' || v_search || '%'
      or lower(coalesce(tr.trolley_type_name, '')) like '%' || v_search || '%'
      or lower(coalesce(tr.current_customer_name, '')) like '%' || v_search || '%'
      or lower(coalesce(tr.current_customer_code, '')) like '%' || v_search || '%'
    )
      and case v_filter
        when 'ALL' then true
        when 'LOCATION_UNCONFIRMED' then tr.effective_status = 'LOCATION_UNCONFIRMED'
        when 'AVAILABLE' then tr.effective_status = 'AVAILABLE'
        when 'IN_PRODUCTION' then tr.effective_status = 'IN_PRODUCTION'
        when 'AT_CUSTOMER' then tr.effective_status = 'AT_CUSTOMER'
        when 'ATTENTION' then tr.attention_status in ('WARNING', 'OVERDUE')
        when 'REVIEW_REQUIRED' then tr.has_review_required
        when 'OUT_OF_SERVICE' then tr.effective_status = 'OUT_OF_SERVICE'
        when 'RETIRED' then tr.effective_status = 'RETIRED'
        else false
      end
  ),
  limited_rows as (
    select *
    from filtered_rows
    order by
      case attention_status when 'OVERDUE' then 1 when 'WARNING' then 2 else 3 end,
      has_review_required desc,
      lower(trolley_code)
    limit 1000
  )
  select jsonb_build_object(
    'generated_on', current_date,
    'warning_days', coalesce(v_warning_days, 14),
    'overdue_days', coalesce(v_overdue_days, 30),
    'delivery_tracking_mode', 'PRODUCTION_NEXT_DAY_INFERENCE',
    'filter', v_filter,
    'search', p_search,
    'summary', (
      select jsonb_build_object(
        'total_active', count(*) filter (where active and effective_status <> 'RETIRED'),
        'location_unconfirmed', count(*) filter (where effective_status = 'LOCATION_UNCONFIRMED'),
        'available', count(*) filter (where effective_status = 'AVAILABLE'),
        'in_production', count(*) filter (where effective_status = 'IN_PRODUCTION'),
        'at_customer', count(*) filter (where effective_status = 'AT_CUSTOMER'),
        'warning', count(*) filter (where attention_status = 'WARNING'),
        'overdue', count(*) filter (where attention_status = 'OVERDUE'),
        'review_required', count(*) filter (where has_review_required),
        'out_of_service', count(*) filter (where effective_status = 'OUT_OF_SERVICE')
      )
      from trolley_rows
    ),
    'items', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'trolley_id', lr.trolley_id,
            'trolley_code', lr.trolley_code,
            'status', lr.effective_status,
            'stored_status', lr.stored_status,
            'active', lr.active,
            'registered_on', lr.registered_on,
            'retired_on', lr.retired_on,
            'notes', lr.notes,
            'metadata', lr.metadata,
            'trolley_type_id', lr.trolley_type_id,
            'trolley_type_code', lr.trolley_type_code,
            'trolley_type_name', lr.trolley_type_name,
            'trolley_type_display_code', lr.trolley_type_display_code,
            'open_stay_id', lr.open_stay_id,
            'current_customer_id', lr.current_customer_id,
            'current_customer_code', lr.current_customer_code,
            'current_customer_name', lr.current_customer_name,
            'production_business_date', lr.production_business_date,
            'production_area_code', lr.production_area_code,
            'planned_delivery_on', lr.planned_delivery_on,
            'sent_on', lr.sent_on,
            'custody_start_source', lr.custody_start_source,
            'days_out', lr.days_out,
            'attention_status', lr.attention_status,
            'has_review_required', lr.has_review_required,
            'last_event_type', lr.last_event_type,
            'last_event_business_date', lr.last_event_business_date,
            'last_event_created_at', lr.last_event_created_at
          ) order by
            case lr.attention_status when 'OVERDUE' then 1 when 'WARNING' then 2 else 3 end,
            lr.has_review_required desc,
            lower(lr.trolley_code)
        )
        from limited_rows lr
      ),
      '[]'::jsonb
    )
  ) into v_result;

  return v_result;
end;
$$;

create or replace function public.suggest_trolley_customer(
  p_trolley_code text
)
returns table (
  trolley_id uuid,
  trolley_code text,
  open_stay_id uuid,
  suggested_customer_id uuid,
  suggested_customer_name text,
  suggestion_reason text,
  last_sent_on date,
  last_received_on date
)
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_trolley public.trolleys%rowtype;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  if nullif(trim(p_trolley_code), '') is null then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  select * into v_trolley
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(p_trolley_code))
    and t.deleted_at is null;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = format('Trolley not found: %s', trim(p_trolley_code));
  end if;

  return query
  with open_record as (
    select
      s.stay_id,
      s.outbound_customer_id as customer_id,
      s.sent_on,
      s.received_on,
      1 as priority,
      'OPEN_STAY'::text as reason
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.received_on is null
    order by s.created_at desc
    limit 1
  ),
  last_confirmed as (
    select
      null::uuid as stay_id,
      s.received_from_customer_id as customer_id,
      s.sent_on,
      s.received_on,
      2 as priority,
      'LAST_KNOWN_CUSTOMER'::text as reason
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.received_from_customer_id is not null
    order by s.received_on desc nulls last, s.created_at desc
    limit 1
  ),
  last_outbound as (
    select
      null::uuid as stay_id,
      s.outbound_customer_id as customer_id,
      s.sent_on,
      s.received_on,
      3 as priority,
      'LAST_KNOWN_CUSTOMER'::text as reason
    from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.outbound_customer_id is not null
    order by s.sent_on desc nulls last, s.created_at desc
    limit 1
  ),
  suggestion as (
    select * from open_record
    union all
    select * from last_confirmed
    union all
    select * from last_outbound
    order by priority
    limit 1
  )
  select
    v_trolley.trolley_id,
    v_trolley.trolley_code,
    suggestion.stay_id,
    suggestion.customer_id,
    c.customer_name,
    coalesce(suggestion.reason, 'NO_HISTORY'),
    suggestion.sent_on,
    suggestion.received_on
  from (select 1) seed
  left join suggestion on true
  left join public.customers c
    on c.customer_id = suggestion.customer_id;
end;
$$;

create or replace function public.get_trolley_record(
  p_trolley_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_trolley_id uuid;
  v_result jsonb;
begin
  perform public.require_any_trolley_role(
    array[
      'ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR',
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR',
      'FINISH_OPERATOR', 'MOP_OPERATOR'
    ]
  );

  select t.trolley_id into v_trolley_id
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(p_trolley_code))
    and t.deleted_at is null;

  if v_trolley_id is null then
    raise exception using
      errcode = 'P0002',
      message = format('Trolley not found: %s', trim(p_trolley_code));
  end if;

  select jsonb_build_object(
    'trolley', jsonb_build_object(
      'trolley_id', t.trolley_id,
      'trolley_code', t.trolley_code,
      'status', case
        when t.status in ('OUT_OF_SERVICE', 'RETIRED') then t.status
        when current_stay.stay_id is not null and current_stay.sent_on > current_date then 'IN_PRODUCTION'
        when current_stay.stay_id is not null then 'AT_CUSTOMER'
        else t.status
      end,
      'stored_status', t.status,
      'active', t.active,
      'registered_on', t.registered_on,
      'retired_on', t.retired_on,
      'notes', t.notes,
      'metadata', t.metadata,
      'trolley_type_id', tt.trolley_type_id,
      'trolley_type_code', tt.trolley_type_code,
      'trolley_type_name', tt.trolley_type_name,
      'trolley_type_display_code', coalesce(tt.display_code, tt.trolley_type_code)
    ),
    'suggestion', (
      select to_jsonb(suggestion)
      from public.suggest_trolley_customer(t.trolley_code) suggestion
    ),
    'current_stay', case
      when current_stay.stay_id is null then null
      else jsonb_build_object(
        'stay_id', current_stay.stay_id,
        'outbound_customer_id', current_stay.outbound_customer_id,
        'customer_code', current_customer.customer_code,
        'customer_name', current_customer.customer_name,
        'production_business_date', current_stay.production_business_date,
        'production_area_code', current_stay.production_area_code,
        'planned_delivery_on', current_stay.planned_delivery_on,
        'sent_on', current_stay.sent_on,
        'custody_start_source', current_stay.custody_start_source,
        'days_out', case
          when current_stay.sent_on is null or current_stay.sent_on > current_date then null
          else current_date - current_stay.sent_on
        end,
        'notes', current_stay.notes
      )
    end,
    'history', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'stay_id', history.stay_id,
            'outbound_customer_id', history.outbound_customer_id,
            'outbound_customer_code', outbound.customer_code,
            'outbound_customer_name', outbound.customer_name,
            'received_from_customer_id', history.received_from_customer_id,
            'received_customer_code', received.customer_code,
            'received_customer_name', received.customer_name,
            'production_business_date', history.production_business_date,
            'production_area_code', history.production_area_code,
            'planned_delivery_on', history.planned_delivery_on,
            'sent_on', history.sent_on,
            'custody_start_source', history.custody_start_source,
            'received_on', history.received_on,
            'days_out', case
              when history.sent_on is null then null
              when history.received_on is null and history.sent_on <= current_date then current_date - history.sent_on
              when history.received_on is null then null
              else history.received_on - history.sent_on
            end,
            'production_to_sorting_days', case
              when history.production_business_date is null or history.received_on is null then null
              else history.received_on - history.production_business_date
            end,
            'status', history.status,
            'exception_type', history.exception_type,
            'confirmation_source', history.confirmation_source,
            'review_status', history.review_status,
            'review_decision', history.review_decision,
            'review_notes', history.review_notes,
            'reviewed_at', history.reviewed_at,
            'notes', history.notes,
            'created_at', history.created_at
          ) order by history.created_at desc
        )
        from (
          select s.*
          from public.trolley_customer_stays s
          where s.trolley_id = t.trolley_id
          order by s.created_at desc
          limit 50
        ) history
        left join public.customers outbound
          on outbound.customer_id = history.outbound_customer_id
        left join public.customers received
          on received.customer_id = history.received_from_customer_id
      ),
      '[]'::jsonb
    ),
    'events', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'trolley_event_id', event_rows.trolley_event_id,
            'stay_id', event_rows.stay_id,
            'event_type', event_rows.event_type,
            'customer_id', event_rows.customer_id,
            'customer_code', event_customer.customer_code,
            'customer_name', event_customer.customer_name,
            'business_date', event_rows.business_date,
            'performed_by', performer.display_name,
            'source_application', event_rows.source_application,
            'reason', event_rows.reason,
            'metadata', event_rows.metadata,
            'created_at', event_rows.created_at
          ) order by event_rows.created_at desc
        )
        from (
          select e.*
          from public.trolley_events e
          where e.trolley_id = t.trolley_id
          order by e.created_at desc
          limit 50
        ) event_rows
        left join public.customers event_customer
          on event_customer.customer_id = event_rows.customer_id
        left join public.staff_members performer
          on performer.staff_id = event_rows.performed_by
      ),
      '[]'::jsonb
    )
  ) into v_result
  from public.trolleys t
  left join public.trolley_types tt
    on tt.trolley_type_id = t.trolley_type_id
  left join lateral (
    select s.*
    from public.trolley_customer_stays s
    where s.trolley_id = t.trolley_id
      and s.received_on is null
    order by s.created_at desc
    limit 1
  ) current_stay on true
  left join public.customers current_customer
    on current_customer.customer_id = current_stay.outbound_customer_id
  where t.trolley_id = v_trolley_id;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Manual delivery fallback and Sorting arrival
-- ---------------------------------------------------------------------

create or replace function public.send_trolley_to_customer(
  p_trolley_code text,
  p_customer_id uuid,
  p_sent_on date default current_date,
  p_notes text default null,
  p_source_application text default 'TROLLEY_CONTROL'
)
returns public.trolley_customer_stays
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff_id uuid;
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
begin
  perform public.require_any_trolley_role(array['ADMIN', 'MANAGER', 'SUPERVISOR']);

  if p_customer_id is null then
    raise exception using errcode = '22023', message = 'Customer is required.';
  end if;

  v_staff_id := public.current_staff_id();

  select * into v_trolley
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(p_trolley_code))
    and t.deleted_at is null
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = format('Trolley not found: %s', trim(p_trolley_code));
  end if;

  if not v_trolley.active
     or v_trolley.status not in ('AVAILABLE', 'LOCATION_UNCONFIRMED') then
    raise exception using
      errcode = '23514',
      message = format('Trolley %s is not available for manual delivery. Current status: %s', v_trolley.trolley_code, v_trolley.status);
  end if;

  if not exists (
    select 1 from public.customers c
    where c.customer_id = p_customer_id
      and c.active = true
      and c.deleted_at is null
  ) then
    raise exception using errcode = '22023', message = 'Customer is not active or does not exist.';
  end if;

  if exists (
    select 1 from public.trolley_customer_stays s
    where s.trolley_id = v_trolley.trolley_id
      and s.received_on is null
  ) then
    raise exception using errcode = '23505', message = format('Trolley %s already has an open customer stay.', v_trolley.trolley_code);
  end if;

  insert into public.trolley_customer_stays (
    trolley_id,
    outbound_customer_id,
    sent_on,
    planned_delivery_on,
    custody_start_source,
    status,
    review_status,
    sent_recorded_by,
    operator_confirmed,
    notes
  ) values (
    v_trolley.trolley_id,
    p_customer_id,
    coalesce(p_sent_on, current_date),
    coalesce(p_sent_on, current_date),
    'MANUAL_DELIVERY_CONFIRMATION',
    'OPEN',
    'NOT_REQUIRED',
    v_staff_id,
    true,
    nullif(trim(p_notes), '')
  ) returning * into v_stay;

  update public.trolleys
  set status = 'AT_CUSTOMER', updated_by = auth.uid()
  where trolley_id = v_trolley.trolley_id;

  insert into public.trolley_events (
    trolley_id, stay_id, event_type, customer_id, business_date,
    performed_by, source_application, reason,
    metadata
  ) values (
    v_trolley.trolley_id, v_stay.stay_id, 'SENT_TO_CUSTOMER', p_customer_id,
    coalesce(p_sent_on, current_date), v_staff_id, p_source_application, p_notes,
    jsonb_build_object('custody_start_source', 'MANUAL_DELIVERY_CONFIRMATION')
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(), v_staff_id, 'SEND_TROLLEY_TO_CUSTOMER',
    'trolley_customer_stays', v_stay.stay_id::text,
    to_jsonb(v_stay), p_notes, p_source_application
  );

  return v_stay;
end;
$$;

create or replace function public.receive_trolley_from_customer(
  p_trolley_code text,
  p_received_from_customer_id uuid,
  p_received_on date default current_date,
  p_confirmation_source text default 'MANUAL_SELECTION',
  p_notes text default null,
  p_source_application text default 'SORTING_TROLLEY_RECEPTION'
)
returns public.trolley_customer_stays
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff_id uuid;
  v_received_date date := coalesce(p_received_on, current_date);
  v_trolley public.trolleys%rowtype;
  v_stay public.trolley_customer_stays%rowtype;
  v_mismatch boolean := false;
  v_event_type text;
begin
  perform public.require_any_trolley_role(
    array['ADMIN', 'MANAGER', 'SUPERVISOR', 'SORTING_OPERATOR']
  );

  if p_received_from_customer_id is null then
    raise exception using errcode = '22023', message = 'Confirmed customer is required.';
  end if;

  if p_confirmation_source is null or p_confirmation_source not in (
    'OPEN_STAY', 'LAST_KNOWN_CUSTOMER', 'MANUAL_SELECTION', 'SUPERVISOR_CORRECTION'
  ) then
    raise exception using errcode = '22023', message = 'Invalid confirmation source.';
  end if;

  v_staff_id := public.current_staff_id();

  select * into v_trolley
  from public.trolleys t
  where lower(t.trolley_code) = lower(trim(p_trolley_code))
    and t.deleted_at is null
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = format('Trolley not found: %s', trim(p_trolley_code));
  end if;

  if v_trolley.status in ('OUT_OF_SERVICE', 'RETIRED') then
    raise exception using
      errcode = '23514',
      message = format('Trolley %s cannot be recorded at Sorting while its status is %s.', v_trolley.trolley_code, v_trolley.status);
  end if;

  if not exists (
    select 1 from public.customers c
    where c.customer_id = p_received_from_customer_id
      and c.active = true
      and c.deleted_at is null
  ) then
    raise exception using errcode = '22023', message = 'Confirmed customer is not active or does not exist.';
  end if;

  select * into v_stay
  from public.trolley_customer_stays s
  where s.trolley_id = v_trolley.trolley_id
    and s.received_on is null
  order by s.created_at desc
  limit 1
  for update;

  if found then
    if v_stay.sent_on is not null and v_received_date < v_stay.sent_on then
      raise exception using
        errcode = '22023',
        message = 'Sorting arrival date cannot be before the tracked delivery date.';
    end if;

    v_mismatch := v_stay.outbound_customer_id is distinct from p_received_from_customer_id;

    update public.trolley_customer_stays
    set
      received_from_customer_id = p_received_from_customer_id,
      received_on = v_received_date,
      status = case when v_mismatch then 'REVIEW_REQUIRED' else 'RECEIVED' end,
      exception_type = case when v_mismatch then 'CUSTOMER_MISMATCH' else null end,
      confirmation_source = 'OPEN_STAY',
      operator_confirmed = true,
      review_status = case when v_mismatch then 'PENDING' else 'NOT_REQUIRED' end,
      review_started_at = null,
      review_started_by = null,
      reviewed_at = null,
      reviewed_by = null,
      review_decision = null,
      review_notes = null,
      received_recorded_by = v_staff_id,
      notes = case
        when nullif(trim(p_notes), '') is null then notes
        when nullif(trim(notes), '') is null then trim(p_notes)
        else notes || E'\nSorting arrival: ' || trim(p_notes)
      end
    where stay_id = v_stay.stay_id
    returning * into v_stay;

    v_event_type := case when v_mismatch then 'CUSTOMER_MISMATCH' else 'ARRIVED_AT_SORTING' end;
  else
    insert into public.trolley_customer_stays (
      trolley_id,
      outbound_customer_id,
      received_from_customer_id,
      sent_on,
      received_on,
      status,
      exception_type,
      confirmation_source,
      operator_confirmed,
      review_status,
      received_recorded_by,
      notes
    ) values (
      v_trolley.trolley_id,
      null,
      p_received_from_customer_id,
      null,
      v_received_date,
      'REVIEW_REQUIRED',
      'MISSING_OUTBOUND_RECORD',
      p_confirmation_source,
      true,
      'PENDING',
      v_staff_id,
      nullif(trim(p_notes), '')
    ) returning * into v_stay;

    v_event_type := 'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND';
  end if;

  update public.trolleys
  set status = 'AVAILABLE', updated_by = auth.uid()
  where trolley_id = v_trolley.trolley_id;

  insert into public.trolley_events (
    trolley_id, stay_id, event_type, customer_id, business_date,
    performed_by, source_application, reason, metadata
  ) values (
    v_trolley.trolley_id,
    v_stay.stay_id,
    v_event_type,
    p_received_from_customer_id,
    v_received_date,
    v_staff_id,
    p_source_application,
    p_notes,
    jsonb_build_object(
      'outbound_customer_id', v_stay.outbound_customer_id,
      'received_from_customer_id', v_stay.received_from_customer_id,
      'production_business_date', v_stay.production_business_date,
      'planned_delivery_on', v_stay.planned_delivery_on,
      'custody_start_source', v_stay.custody_start_source,
      'confirmation_source', v_stay.confirmation_source,
      'exception_type', v_stay.exception_type,
      'review_status', v_stay.review_status
    )
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    new_data, reason, source_application
  ) values (
    auth.uid(),
    v_staff_id,
    case
      when v_event_type = 'ARRIVED_AT_SORTING_WITHOUT_OUTBOUND' then 'SORTING_ARRIVAL_WITHOUT_OUTBOUND'
      when v_event_type = 'CUSTOMER_MISMATCH' then 'SORTING_ARRIVAL_CUSTOMER_MISMATCH'
      else 'CONFIRM_TROLLEY_SORTING_ARRIVAL'
    end,
    'trolley_customer_stays',
    v_stay.stay_id::text,
    to_jsonb(v_stay),
    p_notes,
    p_source_application
  );

  return v_stay;
end;
$$;

create or replace function public.confirm_trolley_sorting_arrival(
  p_trolley_code text,
  p_customer_id uuid,
  p_arrived_on date default current_date,
  p_confirmation_source text default 'MANUAL_SELECTION',
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_stay public.trolley_customer_stays%rowtype;
begin
  v_stay := public.receive_trolley_from_customer(
    p_trolley_code => p_trolley_code,
    p_received_from_customer_id => p_customer_id,
    p_received_on => p_arrived_on,
    p_confirmation_source => p_confirmation_source,
    p_notes => p_notes,
    p_source_application => 'SORTING_INTAKE'
  );

  return jsonb_build_object(
    'stay_id', v_stay.stay_id,
    'trolley_id', v_stay.trolley_id,
    'outbound_customer_id', v_stay.outbound_customer_id,
    'received_from_customer_id', v_stay.received_from_customer_id,
    'production_business_date', v_stay.production_business_date,
    'planned_delivery_on', v_stay.planned_delivery_on,
    'sent_on', v_stay.sent_on,
    'arrived_sorting_on', v_stay.received_on,
    'days_at_customer', case
      when v_stay.sent_on is null then null
      else v_stay.received_on - v_stay.sent_on
    end,
    'exception_type', v_stay.exception_type,
    'review_status', v_stay.review_status,
    'status', v_stay.status
  );
end;
$$;

comment on function public.confirm_trolley_sorting_arrival(text, uuid, date, text, text)
  is 'Records the first reliable inbound scan at Sorting and closes the trolley customer stay.';

-- ---------------------------------------------------------------------
-- 7. Service-status restoration preserves unknown initial location
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

  if v_action is null or v_action not in ('MARK_OUT_OF_SERVICE', 'RETURN_TO_SERVICE') then
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

  if v_action = 'MARK_OUT_OF_SERVICE' then
    if exists (
      select 1 from public.trolley_customer_stays s
      where s.trolley_id = v_trolley.trolley_id
        and s.received_on is null
    ) then
      raise exception using errcode = '23514', message = 'A trolley with an open customer assignment cannot be marked out of service.';
    end if;

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
  else
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
  end if;

  insert into public.trolley_events (
    trolley_id, event_type, business_date, performed_by, source_application, reason
  ) values (
    v_trolley.trolley_id, v_event_type, current_date, v_staff_id, p_source_application, p_reason
  );

  insert into public.audit_log (
    actor_auth_user_id, actor_staff_id, action, entity_table, entity_id,
    old_data, new_data, reason, source_application
  ) values (
    auth.uid(), v_staff_id, v_event_type, 'trolleys', v_trolley.trolley_id::text,
    v_old_data, to_jsonb(v_trolley), p_reason, p_source_application
  );

  return jsonb_build_object(
    'trolley_id', v_trolley.trolley_id,
    'trolley_code', v_trolley.trolley_code,
    'status', v_trolley.status
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Controlled execution grants
-- ---------------------------------------------------------------------

revoke all on function public.next_distribution_business_date(date)
  from public, anon;
revoke all on function public.get_trolley_production_customers(text, date)
  from public, anon;
revoke all on function public.assign_trolley_to_customer_from_production(text, uuid, date, text, text, text)
  from public, anon;
revoke all on function public.confirm_trolley_sorting_arrival(text, uuid, date, text, text)
  from public, anon;

grant execute on function public.next_distribution_business_date(date)
  to authenticated;
grant execute on function public.get_trolley_production_customers(text, date)
  to authenticated;
grant execute on function public.assign_trolley_to_customer_from_production(text, uuid, date, text, text, text)
  to authenticated;
grant execute on function public.confirm_trolley_sorting_arrival(text, uuid, date, text, text)
  to authenticated;

commit;
