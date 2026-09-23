-- =====================================================================
-- ElisCaretex V2
-- Migration: 202608030006_physical_trolley_lifecycle_management.sql
-- Purpose:
--   Complete the controlled Physical Trolley Lifecycle foundation.
--
-- Confirmed business rules:
--   - each physical trolley has an individual code;
--   - only one open customer stay is allowed per trolley;
--   - sent_on and received_on are the primary custody dates;
--   - a receipt without an outbound record is supported and keeps sent_on NULL;
--   - customer mismatches preserve both customer identities;
--   - exceptions remain traceable and require management review;
--   - frontend access is through controlled RPC functions, not direct writes.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Review state for tracked trolley exceptions
-- ---------------------------------------------------------------------

alter table public.trolley_customer_stays
  add column if not exists review_status text not null default 'NOT_REQUIRED',
  add column if not exists review_started_at timestamptz,
  add column if not exists review_started_by uuid
    references public.staff_members(staff_id) on delete set null,
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid
    references public.staff_members(staff_id) on delete set null,
  add column if not exists review_decision text,
  add column if not exists review_notes text;

alter table public.trolley_customer_stays
  drop constraint if exists trolley_stay_review_status_check;

alter table public.trolley_customer_stays
  add constraint trolley_stay_review_status_check
  check (
    review_status in (
      'NOT_REQUIRED',
      'PENDING',
      'UNDER_REVIEW',
      'RESOLVED'
    )
  );

alter table public.trolley_customer_stays
  drop constraint if exists trolley_stay_review_decision_check;

alter table public.trolley_customer_stays
  add constraint trolley_stay_review_decision_check
  check (
    review_decision is null
    or review_decision in ('CONFIRMED_AS_RECORDED')
  );

update public.trolley_customer_stays
set review_status = 'PENDING'
where exception_type is not null
  and review_status = 'NOT_REQUIRED';

create index if not exists trolley_stays_review_queue_idx
  on public.trolley_customer_stays
  (review_status, received_on desc, created_at desc)
  where exception_type is not null;

alter table public.trolley_events
  drop constraint if exists trolley_event_type_check;

alter table public.trolley_events
  add constraint trolley_event_type_check
  check (
    event_type in (
      'TROLLEY_REGISTERED',
      'SENT_TO_CUSTOMER',
      'RECEIVED_FROM_CUSTOMER',
      'RECEIVED_WITHOUT_OUTBOUND',
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
-- 2. Role boundary helpers
-- ---------------------------------------------------------------------

create or replace function public.require_any_trolley_role(
  p_role_codes text[]
)
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null or not public.has_any_role(p_role_codes) then
    raise exception using
      errcode = '42501',
      message = 'Permission denied for this trolley operation.';
  end if;
end;
$$;

comment on function public.require_any_trolley_role(text[])
  is 'Internal authorization helper for the Physical Trolley Lifecycle RPC surface.';

revoke all on function public.require_any_trolley_role(text[])
  from public, anon, authenticated;

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
        'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR'
      ]
    ),
    'can_dispatch_trolleys', public.has_any_role(
      array['ADMIN', 'MANAGER', 'SUPERVISOR', 'DISTRIBUTION_OPERATOR']
    ),
    'can_receive_trolleys', public.has_any_role(
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

comment on function public.get_trolley_lifecycle_capabilities()
  is 'Returns role-derived Physical Trolley Lifecycle capabilities for the signed-in staff member.';

-- ---------------------------------------------------------------------
-- 3. Controlled reference and dashboard read models
-- ---------------------------------------------------------------------

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
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR'
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
    'customers', coalesce(
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
    ),
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

comment on function public.get_trolley_reference_data()
  is 'Returns safe customer, trolley type, threshold and capability reference data for the trolley module.';

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
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR'
    ]
  );

  if v_filter not in (
    'ALL', 'AVAILABLE', 'AT_CUSTOMER', 'ATTENTION',
    'REVIEW_REQUIRED', 'OUT_OF_SERVICE', 'RETIRED'
  ) then
    raise exception using
      errcode = '22023',
      message = 'Invalid trolley dashboard filter.';
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
      t.status,
      t.active,
      t.registered_on,
      t.retired_on,
      t.notes,
      tt.trolley_type_id,
      tt.trolley_type_code,
      tt.trolley_type_name,
      coalesce(tt.display_code, tt.trolley_type_code) as trolley_type_display_code,
      open_stay.stay_id as open_stay_id,
      open_stay.outbound_customer_id as current_customer_id,
      current_customer.customer_code as current_customer_code,
      current_customer.customer_name as current_customer_name,
      open_stay.sent_on,
      case
        when open_stay.sent_on is null then null
        else current_date - open_stay.sent_on
      end as days_out,
      case
        when open_stay.sent_on is null then null
        when current_date - open_stay.sent_on >= coalesce(v_overdue_days, 30)
          then 'OVERDUE'
        when current_date - open_stay.sent_on >= coalesce(v_warning_days, 14)
          then 'WARNING'
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
        when 'AVAILABLE' then tr.status = 'AVAILABLE'
        when 'AT_CUSTOMER' then tr.status = 'AT_CUSTOMER'
        when 'ATTENTION' then tr.attention_status in ('WARNING', 'OVERDUE')
        when 'REVIEW_REQUIRED' then tr.has_review_required
        when 'OUT_OF_SERVICE' then tr.status = 'OUT_OF_SERVICE'
        when 'RETIRED' then tr.status = 'RETIRED'
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
    limit 500
  )
  select jsonb_build_object(
    'generated_on', current_date,
    'warning_days', coalesce(v_warning_days, 14),
    'overdue_days', coalesce(v_overdue_days, 30),
    'filter', v_filter,
    'search', p_search,
    'summary', jsonb_build_object(
      'total_active', count(*) filter (where active and status <> 'RETIRED'),
      'available', count(*) filter (where status = 'AVAILABLE'),
      'at_customer', count(*) filter (where status = 'AT_CUSTOMER'),
      'warning', count(*) filter (where attention_status = 'WARNING'),
      'overdue', count(*) filter (where attention_status = 'OVERDUE'),
      'review_required', count(*) filter (where has_review_required),
      'out_of_service', count(*) filter (where status = 'OUT_OF_SERVICE')
    ),
    'items', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'trolley_id', lr.trolley_id,
            'trolley_code', lr.trolley_code,
            'status', lr.status,
            'active', lr.active,
            'registered_on', lr.registered_on,
            'retired_on', lr.retired_on,
            'notes', lr.notes,
            'trolley_type_id', lr.trolley_type_id,
            'trolley_type_code', lr.trolley_type_code,
            'trolley_type_name', lr.trolley_type_name,
            'trolley_type_display_code', lr.trolley_type_display_code,
            'open_stay_id', lr.open_stay_id,
            'current_customer_id', lr.current_customer_id,
            'current_customer_code', lr.current_customer_code,
            'current_customer_name', lr.current_customer_name,
            'sent_on', lr.sent_on,
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
  )
  into v_result
  from trolley_rows;

  return v_result;
end;
$$;

comment on function public.get_trolley_dashboard(text, text)
  is 'Returns Physical Trolley Lifecycle KPIs and a safe filtered trolley list.';

-- ---------------------------------------------------------------------
-- 4. Secure customer suggestion and detailed trolley history
-- ---------------------------------------------------------------------

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
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR'
    ]
  );

  if nullif(trim(p_trolley_code), '') is null then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  select *
  into v_trolley
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
      'DISTRIBUTION_OPERATOR', 'SORTING_OPERATOR'
    ]
  );

  select t.trolley_id
  into v_trolley_id
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
      'status', t.status,
      'active', t.active,
      'registered_on', t.registered_on,
      'retired_on', t.retired_on,
      'notes', t.notes,
      'trolley_type_id', tt.trolley_type_id,
      'trolley_type_code', tt.trolley_type_code,
      'trolley_type_name', tt.trolley_type_name,
      'trolley_type_display_code', coalesce(tt.display_code, tt.trolley_type_code)
    ),
    'suggestion', (
      select to_jsonb(suggestion)
      from public.suggest_trolley_customer(t.trolley_code) suggestion
    ),
    'current_stay', (
      select jsonb_build_object(
        'stay_id', s.stay_id,
        'outbound_customer_id', s.outbound_customer_id,
        'customer_code', c.customer_code,
        'customer_name', c.customer_name,
        'sent_on', s.sent_on,
        'days_out', current_date - s.sent_on,
        'notes', s.notes
      )
      from public.trolley_customer_stays s
      join public.customers c
        on c.customer_id = s.outbound_customer_id
      where s.trolley_id = t.trolley_id
        and s.received_on is null
      order by s.created_at desc
      limit 1
    ),
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
            'sent_on', history.sent_on,
            'received_on', history.received_on,
            'days_out', case
              when history.sent_on is null then null
              when history.received_on is null then current_date - history.sent_on
              else history.received_on - history.sent_on
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
  )
  into v_result
  from public.trolleys t
  left join public.trolley_types tt
    on tt.trolley_type_id = t.trolley_type_id
  where t.trolley_id = v_trolley_id;

  return v_result;
end;
$$;

comment on function public.get_trolley_record(text)
  is 'Returns a safe physical trolley snapshot with current custody, suggestion, stays and event history.';

create or replace function public.get_trolley_reconciliation_queue()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_any_trolley_role(
    array['ADMIN', 'MANAGER', 'SUPERVISOR', 'AUDITOR']
  );

  return jsonb_build_object(
    'items', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'stay_id', s.stay_id,
            'trolley_id', t.trolley_id,
            'trolley_code', t.trolley_code,
            'outbound_customer_id', s.outbound_customer_id,
            'outbound_customer_code', outbound.customer_code,
            'outbound_customer_name', outbound.customer_name,
            'received_from_customer_id', s.received_from_customer_id,
            'received_customer_code', received.customer_code,
            'received_customer_name', received.customer_name,
            'sent_on', s.sent_on,
            'received_on', s.received_on,
            'recorded_days_out', case
              when s.sent_on is null then null
              else s.received_on - s.sent_on
            end,
            'exception_type', s.exception_type,
            'confirmation_source', s.confirmation_source,
            'review_status', s.review_status,
            'review_started_at', s.review_started_at,
            'reviewed_at', s.reviewed_at,
            'review_decision', s.review_decision,
            'review_notes', s.review_notes,
            'notes', s.notes,
            'created_at', s.created_at
          ) order by
            case s.review_status when 'PENDING' then 1 when 'UNDER_REVIEW' then 2 else 3 end,
            s.received_on desc nulls last,
            s.created_at desc
        )
        from public.trolley_customer_stays s
        join public.trolleys t
          on t.trolley_id = s.trolley_id
        left join public.customers outbound
          on outbound.customer_id = s.outbound_customer_id
        left join public.customers received
          on received.customer_id = s.received_from_customer_id
        where s.exception_type is not null
          and s.review_status in ('PENDING', 'UNDER_REVIEW')
      ),
      '[]'::jsonb
    )
  );
end;
$$;

comment on function public.get_trolley_reconciliation_queue()
  is 'Returns unresolved missing-outbound and customer-mismatch trolley exceptions.';

-- ---------------------------------------------------------------------
-- 5. Controlled master-data and service-state operations
-- ---------------------------------------------------------------------

create or replace function public.register_physical_trolley(
  p_trolley_code text,
  p_trolley_type_id uuid,
  p_registered_on date default current_date,
  p_notes text default null,
  p_source_application text default 'TROLLEY_CONTROL'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_staff_id uuid;
  v_code text := trim(p_trolley_code);
  v_trolley public.trolleys%rowtype;
begin
  perform public.require_any_trolley_role(array['ADMIN', 'MANAGER']);

  if v_code is null or v_code = '' then
    raise exception using errcode = '22023', message = 'Trolley code is required.';
  end if;

  if length(v_code) > 80 then
    raise exception using errcode = '22023', message = 'Trolley code is too long.';
  end if;

  if exists (
    select 1
    from public.trolleys t
    where lower(t.trolley_code) = lower(v_code)
  ) then
    raise exception using errcode = '23505', message = 'Trolley code already exists.';
  end if;

  if not exists (
    select 1
    from public.trolley_types tt
    where tt.trolley_type_id = p_trolley_type_id
      and tt.active = true
      and tt.deleted_at is null
  ) then
    raise exception using errcode = '22023', message = 'Trolley type is not active or does not exist.';
  end if;

  v_staff_id := public.current_staff_id();

  insert into public.trolleys (
    trolley_code,
    trolley_type_id,
    status,
    active,
    registered_on,
    notes,
    created_by,
    updated_by
  )
  values (
    v_code,
    p_trolley_type_id,
    'AVAILABLE',
    true,
    coalesce(p_registered_on, current_date),
    nullif(trim(p_notes), ''),
    auth.uid(),
    auth.uid()
  )
  returning * into v_trolley;

  insert into public.trolley_events (
    trolley_id,
    event_type,
    business_date,
    performed_by,
    source_application,
    reason,
    metadata
  )
  values (
    v_trolley.trolley_id,
    'TROLLEY_REGISTERED',
    v_trolley.registered_on,
    v_staff_id,
    p_source_application,
    p_notes,
    jsonb_build_object('trolley_type_id', p_trolley_type_id)
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
    'REGISTER_PHYSICAL_TROLLEY',
    'trolleys',
    v_trolley.trolley_id::text,
    to_jsonb(v_trolley),
    p_notes,
    p_source_application
  );

  return jsonb_build_object(
    'trolley_id', v_trolley.trolley_id,
    'trolley_code', v_trolley.trolley_code,
    'status', v_trolley.status,
    'registered_on', v_trolley.registered_on
  );
end;
$$;

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
begin
  perform public.require_any_trolley_role(array['ADMIN', 'MANAGER']);

  if v_action is null or v_action not in ('MARK_OUT_OF_SERVICE', 'RETURN_TO_SERVICE') then
    raise exception using errcode = '22023', message = 'Invalid trolley service action.';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason is required.';
  end if;

  select *
  into v_trolley
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
      select 1
      from public.trolley_customer_stays s
      where s.trolley_id = v_trolley.trolley_id
        and s.received_on is null
    ) then
      raise exception using
        errcode = '23514',
        message = 'A trolley at a customer cannot be marked out of service.';
    end if;

    if v_trolley.status = 'RETIRED' then
      raise exception using errcode = '23514', message = 'A retired trolley cannot be changed.';
    end if;

    update public.trolleys
    set status = 'OUT_OF_SERVICE', updated_by = auth.uid()
    where trolley_id = v_trolley.trolley_id
    returning * into v_trolley;

    v_event_type := 'MARKED_OUT_OF_SERVICE';
  else
    if v_trolley.status <> 'OUT_OF_SERVICE' then
      raise exception using errcode = '23514', message = 'Only an out-of-service trolley can be returned to service.';
    end if;

    update public.trolleys
    set status = 'AVAILABLE', updated_by = auth.uid()
    where trolley_id = v_trolley.trolley_id
    returning * into v_trolley;

    v_event_type := 'RETURNED_TO_SERVICE';
  end if;

  insert into public.trolley_events (
    trolley_id,
    event_type,
    business_date,
    performed_by,
    source_application,
    reason
  )
  values (
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
  )
  values (
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
    'status', v_trolley.status
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Dispatch and receipt transactions (replacement implementations)
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
  perform public.require_any_trolley_role(
    array['ADMIN', 'MANAGER', 'SUPERVISOR', 'DISTRIBUTION_OPERATOR']
  );

  if p_customer_id is null then
    raise exception using errcode = '22023', message = 'Customer is required.';
  end if;

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
     or v_trolley.status in ('OUT_OF_SERVICE', 'RETIRED') then
    raise exception using
      errcode = '23514',
      message = format(
        'Trolley %s is not available for sending. Current status: %s',
        v_trolley.trolley_code,
        v_trolley.status
      );
  end if;

  if not exists (
    select 1
    from public.customers c
    where c.customer_id = p_customer_id
      and c.active = true
      and c.deleted_at is null
  ) then
    raise exception using errcode = '22023', message = 'Customer is not active or does not exist.';
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
    notes
  )
  values (
    v_trolley.trolley_id,
    p_customer_id,
    coalesce(p_sent_on, current_date),
    'OPEN',
    'NOT_REQUIRED',
    v_staff_id,
    nullif(trim(p_notes), '')
  )
  returning * into v_stay;

  update public.trolleys
  set status = 'AT_CUSTOMER', updated_by = auth.uid()
  where trolley_id = v_trolley.trolley_id;

  insert into public.trolley_events (
    trolley_id,
    stay_id,
    event_type,
    customer_id,
    business_date,
    performed_by,
    source_application,
    reason
  )
  values (
    v_trolley.trolley_id,
    v_stay.stay_id,
    'SENT_TO_CUSTOMER',
    p_customer_id,
    coalesce(p_sent_on, current_date),
    v_staff_id,
    p_source_application,
    p_notes
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
    'SEND_TROLLEY_TO_CUSTOMER',
    'trolley_customer_stays',
    v_stay.stay_id::text,
    to_jsonb(v_stay),
    p_notes,
    p_source_application
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
    'OPEN_STAY',
    'LAST_KNOWN_CUSTOMER',
    'MANUAL_SELECTION',
    'SUPERVISOR_CORRECTION'
  ) then
    raise exception using errcode = '22023', message = 'Invalid confirmation source.';
  end if;

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

  if v_trolley.status in ('OUT_OF_SERVICE', 'RETIRED') then
    raise exception using
      errcode = '23514',
      message = format('Trolley %s cannot be received while its status is %s.', v_trolley.trolley_code, v_trolley.status);
  end if;

  if not exists (
    select 1
    from public.customers c
    where c.customer_id = p_received_from_customer_id
      and c.active = true
      and c.deleted_at is null
  ) then
    raise exception using errcode = '22023', message = 'Confirmed customer is not active or does not exist.';
  end if;

  select *
  into v_stay
  from public.trolley_customer_stays s
  where s.trolley_id = v_trolley.trolley_id
    and s.received_on is null
  order by s.created_at desc
  limit 1
  for update;

  if found then
    v_mismatch :=
      v_stay.outbound_customer_id is distinct from p_received_from_customer_id;

    update public.trolley_customer_stays
    set
      received_from_customer_id = p_received_from_customer_id,
      received_on = coalesce(p_received_on, current_date),
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
        else notes || E'\nReceipt: ' || trim(p_notes)
      end
    where stay_id = v_stay.stay_id
    returning * into v_stay;

    v_event_type := case
      when v_mismatch then 'CUSTOMER_MISMATCH'
      else 'RECEIVED_FROM_CUSTOMER'
    end;
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
    )
    values (
      v_trolley.trolley_id,
      null,
      p_received_from_customer_id,
      null,
      coalesce(p_received_on, current_date),
      'REVIEW_REQUIRED',
      'MISSING_OUTBOUND_RECORD',
      p_confirmation_source,
      true,
      'PENDING',
      v_staff_id,
      nullif(trim(p_notes), '')
    )
    returning * into v_stay;

    v_event_type := 'RECEIVED_WITHOUT_OUTBOUND';
  end if;

  update public.trolleys
  set status = 'AVAILABLE', updated_by = auth.uid()
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
    v_event_type,
    p_received_from_customer_id,
    coalesce(p_received_on, current_date),
    v_staff_id,
    p_source_application,
    p_notes,
    jsonb_build_object(
      'outbound_customer_id', v_stay.outbound_customer_id,
      'received_from_customer_id', v_stay.received_from_customer_id,
      'confirmation_source', v_stay.confirmation_source,
      'exception_type', v_stay.exception_type,
      'review_status', v_stay.review_status
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
    case
      when v_event_type = 'RECEIVED_WITHOUT_OUTBOUND'
        then 'RECEIVE_TROLLEY_WITHOUT_OUTBOUND'
      when v_event_type = 'CUSTOMER_MISMATCH'
        then 'RECEIVE_TROLLEY_CUSTOMER_MISMATCH'
      else 'RECEIVE_TROLLEY_FROM_CUSTOMER'
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

-- ---------------------------------------------------------------------
-- 7. Exception review without erasing the original custody history
-- ---------------------------------------------------------------------

create or replace function public.review_trolley_exception(
  p_stay_id uuid,
  p_action text,
  p_notes text default null,
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
  v_stay public.trolley_customer_stays%rowtype;
  v_event_type text;
  v_old_data jsonb;
begin
  perform public.require_any_trolley_role(array['ADMIN', 'MANAGER', 'SUPERVISOR']);

  if v_action is null or v_action not in ('START_REVIEW', 'RESOLVE_AS_RECORDED', 'REOPEN') then
    raise exception using errcode = '22023', message = 'Invalid trolley exception review action.';
  end if;

  select *
  into v_stay
  from public.trolley_customer_stays s
  where s.stay_id = p_stay_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Trolley stay was not found.';
  end if;

  if v_stay.exception_type is null then
    raise exception using errcode = '23514', message = 'This trolley stay does not contain a tracked exception.';
  end if;

  if v_action = 'START_REVIEW' and v_stay.review_status <> 'PENDING' then
    raise exception using errcode = '23514', message = 'Only a pending exception can enter review.';
  end if;

  if v_action = 'RESOLVE_AS_RECORDED'
     and v_stay.review_status not in ('PENDING', 'UNDER_REVIEW') then
    raise exception using errcode = '23514', message = 'Only an unresolved exception can be resolved.';
  end if;

  if v_action = 'REOPEN' and v_stay.review_status <> 'RESOLVED' then
    raise exception using errcode = '23514', message = 'Only a resolved exception can be reopened.';
  end if;

  if v_action = 'RESOLVE_AS_RECORDED' and nullif(trim(p_notes), '') is null then
    raise exception using errcode = '22023', message = 'Review notes are required to resolve an exception.';
  end if;

  v_staff_id := public.current_staff_id();
  v_old_data := to_jsonb(v_stay);

  if v_action = 'START_REVIEW' then
    update public.trolley_customer_stays
    set
      review_status = 'UNDER_REVIEW',
      review_started_at = coalesce(review_started_at, now()),
      review_started_by = coalesce(review_started_by, v_staff_id),
      review_notes = case
        when nullif(trim(p_notes), '') is null then review_notes
        when nullif(trim(review_notes), '') is null then trim(p_notes)
        else review_notes || E'\n' || trim(p_notes)
      end
    where stay_id = p_stay_id
    returning * into v_stay;

    v_event_type := 'EXCEPTION_REVIEW_STARTED';
  elsif v_action = 'RESOLVE_AS_RECORDED' then
    update public.trolley_customer_stays
    set
      review_status = 'RESOLVED',
      review_started_at = coalesce(review_started_at, now()),
      review_started_by = coalesce(review_started_by, v_staff_id),
      reviewed_at = now(),
      reviewed_by = v_staff_id,
      review_decision = 'CONFIRMED_AS_RECORDED',
      review_notes = trim(p_notes)
    where stay_id = p_stay_id
    returning * into v_stay;

    v_event_type := 'EXCEPTION_REVIEWED';
  else
    update public.trolley_customer_stays
    set
      review_status = 'PENDING',
      review_started_at = null,
      review_started_by = null,
      reviewed_at = null,
      reviewed_by = null,
      review_decision = null,
      review_notes = nullif(trim(p_notes), '')
    where stay_id = p_stay_id
    returning * into v_stay;

    v_event_type := 'EXCEPTION_REOPENED';
  end if;

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
    v_stay.trolley_id,
    v_stay.stay_id,
    v_event_type,
    coalesce(v_stay.received_from_customer_id, v_stay.outbound_customer_id),
    current_date,
    v_staff_id,
    p_source_application,
    p_notes,
    jsonb_build_object(
      'action', v_action,
      'exception_type', v_stay.exception_type,
      'review_status', v_stay.review_status,
      'review_decision', v_stay.review_decision
    )
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
  )
  values (
    auth.uid(),
    v_staff_id,
    'REVIEW_TROLLEY_EXCEPTION_' || v_action,
    'trolley_customer_stays',
    v_stay.stay_id::text,
    v_old_data,
    to_jsonb(v_stay),
    p_notes,
    p_source_application
  );

  return jsonb_build_object(
    'stay_id', v_stay.stay_id,
    'trolley_id', v_stay.trolley_id,
    'exception_type', v_stay.exception_type,
    'review_status', v_stay.review_status,
    'review_decision', v_stay.review_decision,
    'reviewed_at', v_stay.reviewed_at
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Remove broad direct browser access and expose only controlled RPCs
-- ---------------------------------------------------------------------

drop policy if exists "authenticated_read_trolley_types"
  on public.trolley_types;
drop policy if exists "authenticated_read_trolleys"
  on public.trolleys;
drop policy if exists "authenticated_read_trolley_stays"
  on public.trolley_customer_stays;
drop policy if exists "authenticated_read_trolley_events"
  on public.trolley_events;

revoke all on table public.trolley_types from anon, authenticated;
revoke all on table public.trolleys from anon, authenticated;
revoke all on table public.trolley_customer_stays from anon, authenticated;
revoke all on table public.trolley_events from anon, authenticated;
revoke all on table public.v_trolleys_at_customers from anon, authenticated;
revoke all on table public.v_trolley_reconciliation_queue from anon, authenticated;
revoke all on table public.v_trolley_customer_history from anon, authenticated;

revoke all on function public.get_trolley_lifecycle_capabilities()
  from public, anon, authenticated;
revoke all on function public.get_trolley_reference_data()
  from public, anon, authenticated;
revoke all on function public.get_trolley_dashboard(text, text)
  from public, anon, authenticated;
revoke all on function public.suggest_trolley_customer(text)
  from public, anon, authenticated;
revoke all on function public.get_trolley_record(text)
  from public, anon, authenticated;
revoke all on function public.get_trolley_reconciliation_queue()
  from public, anon, authenticated;
revoke all on function public.register_physical_trolley(text, uuid, date, text, text)
  from public, anon, authenticated;
revoke all on function public.set_trolley_service_status(text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.send_trolley_to_customer(text, uuid, date, text, text)
  from public, anon, authenticated;
revoke all on function public.receive_trolley_from_customer(text, uuid, date, text, text, text)
  from public, anon, authenticated;
revoke all on function public.review_trolley_exception(uuid, text, text, text)
  from public, anon, authenticated;

grant execute on function public.get_trolley_lifecycle_capabilities()
  to authenticated;
grant execute on function public.get_trolley_reference_data()
  to authenticated;
grant execute on function public.get_trolley_dashboard(text, text)
  to authenticated;
grant execute on function public.suggest_trolley_customer(text)
  to authenticated;
grant execute on function public.get_trolley_record(text)
  to authenticated;
grant execute on function public.get_trolley_reconciliation_queue()
  to authenticated;
grant execute on function public.register_physical_trolley(text, uuid, date, text, text)
  to authenticated;
grant execute on function public.set_trolley_service_status(text, text, text, text)
  to authenticated;
grant execute on function public.send_trolley_to_customer(text, uuid, date, text, text)
  to authenticated;
grant execute on function public.receive_trolley_from_customer(text, uuid, date, text, text, text)
  to authenticated;
grant execute on function public.review_trolley_exception(uuid, text, text, text)
  to authenticated;

commit;
